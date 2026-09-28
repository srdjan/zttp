//! Caller identity, scope, and export grants for tool requests (M4 T5a).
//!
//! The server runs three checks on a request that matches a tool route, all
//! before any JS value exists. `verifyRequest` reads `Authorization: Bearer
//! <token>` and verifies it with the deployment's HS256 key; a refusal is a
//! 401. `checkScope` compares the input fields a catalog entry binds with the
//! verified subject and tenant; a difference is a 403. `grantFor` hands the
//! runtime the tool's export grant, which the module call wrapper enforces for
//! the duration of the handler call.
//!
//! The key is read once at startup from the environment variable the project
//! names (`auth.keyEnv`), outside the handler's own env allow list, and is
//! never logged or written anywhere.

const std = @import("std");
const zq = @import("zts");
const runtime_config = @import("runtime_config.zig");
const contract_runtime = @import("contract_runtime.zig");
const http_types = @import("http_types.zig");

pub const Hs256 = zq.Hs256;
pub const Claims = Hs256.Claims;
pub const VerifyRefusal = Hs256.Refusal;
pub const ToolAuthNames = runtime_config.ToolAuthNames;

/// Why a tool request was answered 401: no usable bearer token, or one of the
/// verifier's closed refusals.
pub const Refusal = union(enum) {
    missing_token,
    verifier: VerifyRefusal,

    pub fn name(self: Refusal) []const u8 {
        return switch (self) {
            .missing_token => "missing_token",
            .verifier => |reason| @tagName(reason),
        };
    }
};

pub const Verdict = union(enum) {
    /// The verified identity. Its arena lives in the request allocator.
    ok: Claims,
    refused: Refusal,
};

/// The deployment's key and tenant claim, loaded at startup. Owns both.
pub const KeyState = struct {
    allocator: std.mem.Allocator,
    key: []u8,
    tenant_claim: []u8,

    pub fn deinit(self: *KeyState) void {
        std.crypto.secureZero(u8, self.key);
        self.allocator.free(self.key);
        self.allocator.free(self.tenant_claim);
        self.* = undefined;
    }
};

pub const LoadError = error{
    /// The project configures no `auth` object (or the artifact's contract
    /// carries none).
    ToolAuthNotConfigured,
    /// The variable `auth.keyEnv` names is unset or empty.
    ToolAuthKeyMissing,
} || std.mem.Allocator.Error;

/// Read the key from the environment variable `names.key_env` names.
pub fn load(allocator: std.mem.Allocator, names: ?runtime_config.ToolAuthNames) LoadError!KeyState {
    const configured = names orelse return error.ToolAuthNotConfigured;
    const name_z = try allocator.dupeZ(u8, configured.key_env);
    defer allocator.free(name_z);
    const raw = std.c.getenv(name_z) orelse return error.ToolAuthKeyMissing;
    const value = std.mem.span(raw);
    if (value.len == 0) return error.ToolAuthKeyMissing;
    const key = try allocator.dupe(u8, value);
    errdefer {
        std.crypto.secureZero(u8, key);
        allocator.free(key);
    }
    const tenant_claim = try allocator.dupe(u8, configured.tenant_claim);
    return .{ .allocator = allocator, .key = key, .tenant_claim = tenant_claim };
}

/// The token of an `Authorization` value: the scheme `Bearer` in any case,
/// exactly one space, and a non-empty token with no leading space.
pub fn bearerToken(value: []const u8) ?[]const u8 {
    const scheme = "Bearer ";
    if (value.len <= scheme.len) return null;
    if (!std.ascii.eqlIgnoreCase(value[0 .. scheme.len - 1], scheme[0 .. scheme.len - 1])) return null;
    if (value[scheme.len - 1] != ' ') return null;
    const token = value[scheme.len..];
    if (token[0] == ' ') return null;
    return token;
}

/// Verify the request's bearer token. More than one `Authorization` header is
/// refused as `missing_token`: which one the handler would have seen is not a
/// question the verifier should answer.
pub fn verifyRequest(
    allocator: std.mem.Allocator,
    auth: *const KeyState,
    headers: []const http_types.HttpHeader,
    now_s: i64,
) Hs256.VerifyError!Verdict {
    var value: ?[]const u8 = null;
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.key, "authorization")) continue;
        if (value != null) return .{ .refused = .missing_token };
        value = header.value;
    }
    const token = bearerToken(value orelse return .{ .refused = .missing_token }) orelse
        return .{ .refused = .missing_token };
    return switch (try Hs256.verify(allocator, token, auth.key, auth.tenant_claim, now_s, runtime_mac)) {
        .ok => |claims| .{ .ok = claims },
        .refused => |reason| .{ .refused = .{ .verifier = reason } },
    };
}

/// std's HMAC-SHA256. The runtime is not a virtual module, so it computes the
/// MAC directly; the verifier itself reaches no capability.
const runtime_mac = Hs256.Mac{ .context = null, .compute = runtimeMacCompute };

fn runtimeMacCompute(_: ?*anyopaque, message: []const u8, key: []const u8, out: *[32]u8) Hs256.MacError!void {
    std.crypto.auth.hmac.sha2.HmacSha256.create(out, message, key);
}

/// Which bound field refused a scoped tool request, or `ok`.
pub const ScopeVerdict = enum { ok, tenant, subject };

/// Compare the input fields `tool` binds with the verified identity, byte for
/// byte. `body` already passed input validation, so it is bounded JSON whose
/// bound fields are required strings; anything else still refuses, because a
/// comparison that could not be made is not a match.
pub fn checkScope(
    scratch: std.mem.Allocator,
    tool: *const contract_runtime.AcceptedTool,
    body: []const u8,
    subject: []const u8,
    tenant: []const u8,
) ScopeVerdict {
    if (tool.scope_tenant == null and tool.scope_subject == null) return .ok;
    const first_bound: ScopeVerdict = if (tool.scope_tenant != null) .tenant else .subject;
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, body, .{}) catch return first_bound;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return first_bound,
    };
    if (tool.scope_tenant) |field| {
        if (!fieldEquals(object, field, tenant)) return .tenant;
    }
    if (tool.scope_subject) |field| {
        if (!fieldEquals(object, field, subject)) return .subject;
    }
    return .ok;
}

fn fieldEquals(object: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const value = object.get(field) orelse return false;
    return switch (value) {
        .string => |s| std.mem.eql(u8, s, expected),
        else => false,
    };
}

/// The exports every tool may call whatever its own set holds: the dispatch a
/// tool handler must run before its route function does. The build proves a
/// tool's set from the route function, and `routerMatch` runs in the shared
/// `handler` that selects it, so without this row no tool request could reach
/// its route. `routerMatch` reads the route table and the request and reaches
/// no host effect, so admitting it grants no authority.
const dispatch_exports = [_]contract_runtime.Export{
    .{ .module = "zttp:router", .name = "routerMatch" },
};

/// The export grant the runtime holds for one call to `tool`'s handler.
/// `tool` must outlive the call; the server holds the catalog under the
/// contract lock for the whole request.
pub fn grantFor(tool: *const contract_runtime.AcceptedTool) http_types.ToolGrant {
    return .{ .context = @ptrCast(tool), .allows = allowsThunk, .allows_credential = allowsCredentialThunk, .input_schema = tool.input_name };
}

/// The export, credential, and provider grant for one admitted agent request.
/// The agent carries no tool input schema.
pub fn agentGrantFor(agent: *const contract_runtime.AcceptedAgent) http_types.ToolGrant {
    return .{
        .context = @ptrCast(agent),
        .allows = allowsAgentThunk,
        .allows_credential = allowsAgentCredentialThunk,
        .input_schema = "",
        .agent = .{
            .provider_endpoint = agent.provider_endpoint,
            .provider_credential = agent.provider_credential,
            .no_durable = true,
        },
    };
}

fn allowsCredentialThunk(context: *const anyopaque, name: []const u8) bool {
    const tool: *const contract_runtime.AcceptedTool = @ptrCast(@alignCast(context));
    return tool.allowsCredential(name);
}

fn allowsThunk(context: *const anyopaque, module: []const u8, name: []const u8) bool {
    const tool: *const contract_runtime.AcceptedTool = @ptrCast(@alignCast(context));
    if (tool.allowsExport(module, name)) return true;
    for (dispatch_exports) |exp| {
        if (std.mem.eql(u8, exp.module, module) and std.mem.eql(u8, exp.name, name)) return true;
    }
    return false;
}

fn allowsAgentCredentialThunk(context: *const anyopaque, name: []const u8) bool {
    const agent: *const contract_runtime.AcceptedAgent = @ptrCast(@alignCast(context));
    return std.mem.eql(u8, agent.provider_credential, name);
}

fn allowsAgentThunk(context: *const anyopaque, module: []const u8, name: []const u8) bool {
    const agent: *const contract_runtime.AcceptedAgent = @ptrCast(@alignCast(context));
    if (agent.allowsExport(module, name)) return true;
    for (dispatch_exports) |exp| {
        if (std.mem.eql(u8, exp.module, module) and std.mem.eql(u8, exp.name, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bearerToken takes the scheme in any case and exactly one space" {
    try std.testing.expectEqualStrings("abc", bearerToken("Bearer abc").?);
    try std.testing.expectEqualStrings("abc", bearerToken("bearer abc").?);
    try std.testing.expectEqualStrings("abc", bearerToken("BEARER abc").?);
    try std.testing.expect(bearerToken("Bearer  abc") == null);
    try std.testing.expect(bearerToken("Bearer ") == null);
    try std.testing.expect(bearerToken("Bearer") == null);
    try std.testing.expect(bearerToken("Basic abc") == null);
    try std.testing.expect(bearerToken("Bearer\tabc") == null);
    try std.testing.expect(bearerToken("Bearerabc") == null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "load reads the named variable and refuses a missing or empty one" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ToolAuthNotConfigured, load(allocator, null));

    const names = runtime_config.ToolAuthNames{ .key_env = "ZTTP_TOOL_AUTH_LOAD_TEST", .tenant_claim = "org" };
    _ = unsetenv("ZTTP_TOOL_AUTH_LOAD_TEST");
    try std.testing.expectError(error.ToolAuthKeyMissing, load(allocator, names));
    _ = setenv("ZTTP_TOOL_AUTH_LOAD_TEST", "", 1);
    try std.testing.expectError(error.ToolAuthKeyMissing, load(allocator, names));
    _ = setenv("ZTTP_TOOL_AUTH_LOAD_TEST", "k3y", 1);
    defer _ = unsetenv("ZTTP_TOOL_AUTH_LOAD_TEST");
    var state = try load(allocator, names);
    defer state.deinit();
    try std.testing.expectEqualStrings("k3y", state.key);
    try std.testing.expectEqualStrings("org", state.tenant_claim);
}
