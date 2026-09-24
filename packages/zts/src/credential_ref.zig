//! Credential references (M4 T6): the deployment-owned description of one
//! upstream credential. A reference names the environment variable that holds
//! the value and the rules for the one kind of request the value may go into.
//! It never holds the value.
//!
//! zttp.json carries the references as an object keyed by name:
//!
//! ```json
//! "credentials": {
//!   "weather": {
//!     "env": "WEATHER_API_KEY",
//!     "endpoint": "https://api.weather.example",
//!     "header": "authorization",
//!     "scheme": "Bearer",
//!     "methods": ["GET"],
//!     "paths": ["/v1/forecast"]
//!   }
//! }
//! ```
//!
//! The handler contract carries the same references as an array in the
//! canonical form: sorted by name, the endpoint in the form `endpoint.zig`
//! writes, the header in lowercase, and the methods and paths sorted with no
//! repeat. `build` in the `.config` form canonicalizes; in the `.canonical`
//! form it refuses anything the `.config` form would not have written, so a
//! contract parser cannot accept a reference the build could not have made.
//!
//! The loader is closed. A reference that breaks a rule is refused with exactly
//! one member of `Refusal`, and allocation failure is the only Zig error.
//!
//! This file is in the `zts-base` tier and imports `std` and `endpoint.zig`, a
//! file of the same tier. See
//! docs/plans/2026-09-24-m4-t6-credential-injection-design.md, section 3.

const std = @import("std");
const endpoint = @import("endpoint.zig");

/// The most references one project may configure.
pub const max_credentials: usize = 64;
pub const max_name_bytes: usize = 64;
pub const max_env_bytes: usize = 128;
pub const max_header_bytes: usize = 64;
pub const max_scheme_bytes: usize = 32;
pub const max_paths: usize = 32;
pub const max_path_bytes: usize = 256;

/// The methods a reference may allow: the set the runtime's fetch parses. The
/// declaration order is the canonical order.
pub const Method = enum {
    DELETE,
    GET,
    HEAD,
    OPTIONS,
    PATCH,
    POST,
    PUT,
};

/// Headers the runtime or the HTTP client writes itself, or that frame or
/// route the message. A credential in one of them would either be overwritten
/// or change how the request is framed, so a reference may not name one.
const reserved_headers = [_][]const u8{
    "accept-encoding",
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "user-agent",
};

/// One accepted reference. Every string is owned.
pub const CredentialRef = struct {
    name: []const u8,
    env: []const u8,
    /// Canonical `scheme://host:port`.
    endpoint: []const u8,
    /// Lowercase header name.
    header: []const u8,
    /// Written before the value with one space, when present.
    scheme: ?[]const u8 = null,
    methods: std.EnumSet(Method),
    /// Sorted by bytes, no repeat. Each starts with `/`.
    paths: []const []const u8,

    pub fn deinit(self: *CredentialRef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.env);
        allocator.free(self.endpoint);
        allocator.free(self.header);
        if (self.scheme) |s| allocator.free(s);
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
        self.* = undefined;
    }

    pub fn dupe(self: CredentialRef, allocator: std.mem.Allocator) std.mem.Allocator.Error!CredentialRef {
        return build(allocator, .{
            .name = self.name,
            .env = self.env,
            .endpoint = self.endpoint,
            .header = self.header,
            .scheme = self.scheme,
            .methods = &.{},
            .paths = self.paths,
        }, self.methods);
    }
};

/// Free a list of references and the slice that holds them.
pub fn freeAll(allocator: std.mem.Allocator, refs: []CredentialRef) void {
    for (refs) |*r| r.deinit(allocator);
    allocator.free(refs);
}

/// An owned copy of every reference in `refs`, in the same order.
pub fn dupeAll(allocator: std.mem.Allocator, refs: []const CredentialRef) std.mem.Allocator.Error![]CredentialRef {
    const out = try allocator.alloc(CredentialRef, refs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*r| r.deinit(allocator);
        allocator.free(out);
    }
    for (refs) |r| {
        out[filled] = try r.dupe(allocator);
        filled += 1;
    }
    return out;
}

pub const Refusal = enum {
    /// `credentials` is not an object (zttp.json) or not an array (contract).
    set_not_container,
    /// More than `max_credentials` references.
    too_many_credentials,
    /// A reference is not an object.
    entry_not_object,
    /// A reference has a field other than the six it may hold (and `name` in
    /// the contract form).
    field_unknown,
    /// A reference lacks `env`, `endpoint`, `header`, `methods`, or `paths`.
    field_missing,
    /// A string field is not a string.
    field_not_string,
    /// `methods` or `paths` is not an array of strings.
    list_not_strings,
    /// The name is empty, longer than 64 bytes, or holds a byte outside
    /// `A-Z a-z 0-9 _ -`.
    name_invalid,
    /// The variable name is empty, longer than 128 bytes, or not an
    /// identifier of `A-Z a-z 0-9 _` that starts with a letter or `_`.
    env_invalid,
    /// The endpoint rule refuses the endpoint.
    endpoint_invalid,
    /// The endpoint has a path, a query, or a fragment.
    endpoint_not_origin,
    /// The endpoint is `http` and its host is not an IPv4 or IPv6 loopback
    /// literal.
    endpoint_plaintext,
    /// The header is empty, longer than 64 bytes, or not an HTTP token.
    header_invalid,
    /// The header is one the runtime or the client writes itself.
    header_reserved,
    /// The scheme is empty, longer than 32 bytes, or not an HTTP token.
    scheme_invalid,
    /// `methods` is empty.
    methods_empty,
    /// A method is not one of the seven the runtime's fetch parses, in
    /// uppercase.
    method_unknown,
    /// A method is listed twice.
    method_repeated,
    /// `paths` is empty.
    paths_empty,
    /// More than `max_paths` paths.
    too_many_paths,
    /// A path does not start with `/`, is longer than 256 bytes, holds a byte
    /// outside printable ASCII or one of `? # \`, holds an encoded `/` or `\`,
    /// has an empty, `.`, or `..` segment, or ends with `/` (other than `/`).
    path_invalid,
    /// A path is listed twice.
    path_repeated,
    /// Two references share a name.
    duplicate_name,
    /// Contract form only: the reference is valid but not in the form the
    /// build writes (endpoint, header case, method or path order, or name
    /// order).
    not_canonical,

    pub fn sentence(self: Refusal) []const u8 {
        return switch (self) {
            .set_not_container => "\"credentials\" must be an object that maps each credential name to its reference",
            .too_many_credentials => "a project may configure at most 64 credentials",
            .entry_not_object => "each credential reference must be an object",
            .field_unknown => "a credential reference may hold only env, endpoint, header, scheme, methods, and paths",
            .field_missing => "a credential reference needs env, endpoint, header, methods, and paths",
            .field_not_string => "env, endpoint, header, and scheme must be strings",
            .list_not_strings => "methods and paths must be arrays of strings",
            .name_invalid => "a credential name must be 1 to 64 bytes of A-Z, a-z, 0-9, _, and -",
            .env_invalid => "env must name an environment variable: a letter or _ followed by letters, digits, and _",
            .endpoint_invalid => "endpoint must be an http or https URL with a host and no userinfo",
            .endpoint_not_origin => "endpoint must be scheme://host[:port] with no path, query, or fragment",
            .endpoint_plaintext => "a credential needs an https endpoint; http is allowed only for a loopback IP literal (127.0.0.0/8 or [::1])",
            .header_invalid => "header must be an HTTP header name of at most 64 bytes",
            .header_reserved => "header names a header the runtime writes itself",
            .scheme_invalid => "scheme must be an HTTP token of at most 32 bytes, such as Bearer",
            .methods_empty => "methods must list at least one method",
            .method_unknown => "each method must be one of DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT, in uppercase",
            .method_repeated => "a method is listed twice",
            .paths_empty => "paths must list at least one path prefix",
            .too_many_paths => "a credential may list at most 32 path prefixes",
            .path_invalid => "each path must start with /, have no empty, . or .. segment, no ?, #, \\, or encoded / or \\, and no trailing /",
            .path_repeated => "a path is listed twice",
            .duplicate_name => "two credentials have the same name",
            .not_canonical => "the credential reference is not in the canonical form the build writes",
        };
    }
};

/// A refusal and the name of the reference it is about, copied so that it
/// outlives the input.
pub const Refused = struct {
    reason: Refusal,
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,

    pub fn name(self: *const Refused) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn of(reason: Refusal, entry_name: []const u8) Refused {
        var r: Refused = .{ .reason = reason };
        const len = @min(entry_name.len, max_name_bytes);
        @memcpy(r.name_buf[0..len], entry_name[0..len]);
        r.name_len = len;
        return r;
    }
};

pub const SetResult = union(enum) {
    /// Sorted by name. The caller owns the slice and every reference in it.
    ok: []CredentialRef,
    refused: Refused,
};

pub const Form = enum { config, canonical };

/// The fields of one reference before validation. Borrowed.
pub const Fields = struct {
    name: []const u8,
    env: []const u8,
    endpoint: []const u8,
    header: []const u8,
    scheme: ?[]const u8,
    methods: []const []const u8,
    paths: []const []const u8,
};

pub const EntryResult = union(enum) {
    ok: CredentialRef,
    refused: Refusal,
};

/// Validate one reference and return an owned copy. In the `.config` form the
/// endpoint is normalized, the header lowercased, and the lists sorted; in the
/// `.canonical` form each of those must already hold.
pub fn validate(allocator: std.mem.Allocator, fields: Fields, form: Form) std.mem.Allocator.Error!EntryResult {
    if (!validName(fields.name)) return .{ .refused = .name_invalid };
    if (!validEnv(fields.env)) return .{ .refused = .env_invalid };

    var endpoint_buf: [endpoint.max_endpoint_bytes]u8 = undefined;
    const canonical_endpoint = switch (checkEndpoint(fields.endpoint, &endpoint_buf)) {
        .ok => |e| e,
        .refused => |reason| return .{ .refused = reason },
    };
    if (form == .canonical and !std.mem.eql(u8, canonical_endpoint, fields.endpoint)) return .{ .refused = .not_canonical };

    if (!isToken(fields.header, max_header_bytes)) return .{ .refused = .header_invalid };
    var header_buf: [max_header_bytes]u8 = undefined;
    const header = std.ascii.lowerString(&header_buf, fields.header);
    for (reserved_headers) |reserved| {
        if (std.mem.eql(u8, header, reserved)) return .{ .refused = .header_reserved };
    }
    if (form == .canonical and !std.mem.eql(u8, header, fields.header)) return .{ .refused = .not_canonical };

    if (fields.scheme) |s| {
        if (!isToken(s, max_scheme_bytes)) return .{ .refused = .scheme_invalid };
    }

    if (fields.methods.len == 0) return .{ .refused = .methods_empty };
    var methods = std.EnumSet(Method).initEmpty();
    var previous_method: ?Method = null;
    for (fields.methods) |text| {
        const method = std.meta.stringToEnum(Method, text) orelse return .{ .refused = .method_unknown };
        if (methods.contains(method)) return .{ .refused = .method_repeated };
        if (form == .canonical) {
            if (previous_method) |p| {
                if (@intFromEnum(p) > @intFromEnum(method)) return .{ .refused = .not_canonical };
            }
        }
        previous_method = method;
        methods.insert(method);
    }

    if (fields.paths.len == 0) return .{ .refused = .paths_empty };
    if (fields.paths.len > max_paths) return .{ .refused = .too_many_paths };
    for (fields.paths) |p| {
        if (!validPath(p)) return .{ .refused = .path_invalid };
    }
    for (fields.paths, 0..) |p, i| {
        for (fields.paths[0..i]) |q| {
            if (std.mem.eql(u8, p, q)) return .{ .refused = .path_repeated };
        }
        if (form == .canonical and i > 0 and !lessThan({}, fields.paths[i - 1], p)) return .{ .refused = .not_canonical };
    }

    const ref = try build(allocator, .{
        .name = fields.name,
        .env = fields.env,
        .endpoint = canonical_endpoint,
        .header = header,
        .scheme = fields.scheme,
        .methods = &.{},
        .paths = fields.paths,
    }, methods);
    return .{ .ok = ref };
}

/// Parse zttp.json's `credentials` object. The result is sorted by name.
pub fn parseConfig(allocator: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!SetResult {
    if (value != .object) return .{ .refused = Refused.of(.set_not_container, "") };
    const object = value.object;
    if (object.count() > max_credentials) return .{ .refused = Refused.of(.too_many_credentials, "") };

    var refs: std.ArrayList(CredentialRef) = .empty;
    errdefer {
        for (refs.items) |*r| r.deinit(allocator);
        refs.deinit(allocator);
    }

    var methods_buf: [@typeInfo(Method).@"enum".fields.len * 2][]const u8 = undefined;
    var paths_buf: [max_paths][]const u8 = undefined;

    var it = object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const refused = struct {
            fn at(reason: Refusal, n: []const u8) SetResult {
                return .{ .refused = Refused.of(reason, n) };
            }
        }.at;
        if (!validName(name)) {
            freeList(allocator, &refs);
            return refused(.name_invalid, name);
        }
        const body = entry.value_ptr.*;
        if (body != .object) {
            freeList(allocator, &refs);
            return refused(.entry_not_object, name);
        }
        var field_it = body.object.iterator();
        while (field_it.next()) |field| {
            if (!isConfigField(field.key_ptr.*)) {
                freeList(allocator, &refs);
                return refused(.field_unknown, name);
            }
        }
        const extracted = extractFields(body.object, name, &methods_buf, &paths_buf);
        const fields = switch (extracted) {
            .ok => |f| f,
            .refused => |reason| {
                freeList(allocator, &refs);
                return refused(reason, name);
            },
        };
        switch (try validate(allocator, fields, .config)) {
            .ok => |ref| {
                refs.append(allocator, ref) catch |err| {
                    var owned = ref;
                    owned.deinit(allocator);
                    return err;
                };
            },
            .refused => |reason| {
                freeList(allocator, &refs);
                return refused(reason, name);
            },
        }
    }

    std.mem.sort(CredentialRef, refs.items, {}, nameLessThan);
    return .{ .ok = try refs.toOwnedSlice(allocator) };
}

/// Null when `refs` is sorted by name with no repeat, the order `parseConfig`
/// returns and the contract carries; otherwise the rule the order breaks.
pub fn setOrder(refs: []const CredentialRef) ?Refusal {
    if (refs.len > max_credentials) return .too_many_credentials;
    if (refs.len < 2) return null;
    for (refs[0 .. refs.len - 1], refs[1..]) |prev, r| {
        switch (std.mem.order(u8, prev.name, r.name)) {
            .lt => {},
            .eq => return .duplicate_name,
            .gt => return .not_canonical,
        }
    }
    return null;
}

/// The reference named `name`, or null.
pub fn find(refs: []const CredentialRef, name: []const u8) ?*const CredentialRef {
    for (refs) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------

fn freeList(allocator: std.mem.Allocator, refs: *std.ArrayList(CredentialRef)) void {
    for (refs.items) |*r| r.deinit(allocator);
    refs.clearAndFree(allocator);
}

const config_fields = [_][]const u8{ "env", "endpoint", "header", "scheme", "methods", "paths" };

fn isConfigField(key: []const u8) bool {
    for (config_fields) |f| {
        if (std.mem.eql(u8, key, f)) return true;
    }
    return false;
}

const FieldsResult = union(enum) { ok: Fields, refused: Refusal };

fn extractFields(
    object: std.json.ObjectMap,
    name: []const u8,
    methods_buf: []([]const u8),
    paths_buf: []([]const u8),
) FieldsResult {
    const env = requiredString(object, "env") orelse return .{ .refused = missingOrWrong(object, "env") };
    const endpoint_text = requiredString(object, "endpoint") orelse return .{ .refused = missingOrWrong(object, "endpoint") };
    const header = requiredString(object, "header") orelse return .{ .refused = missingOrWrong(object, "header") };
    const scheme: ?[]const u8 = if (object.get("scheme")) |s| switch (s) {
        .string => |text| text,
        else => return .{ .refused = .field_not_string },
    } else null;
    const methods = stringList(object, "methods", methods_buf) orelse return .{ .refused = listRefusal(object, "methods", methods_buf.len) };
    const paths = stringList(object, "paths", paths_buf) orelse return .{ .refused = listRefusal(object, "paths", paths_buf.len) };
    return .{ .ok = .{
        .name = name,
        .env = env,
        .endpoint = endpoint_text,
        .header = header,
        .scheme = scheme,
        .methods = methods,
        .paths = paths,
    } };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn missingOrWrong(object: std.json.ObjectMap, key: []const u8) Refusal {
    return if (object.get(key) == null) .field_missing else .field_not_string;
}

fn stringList(object: std.json.ObjectMap, key: []const u8, buf: []([]const u8)) ?[]const []const u8 {
    const v = object.get(key) orelse return null;
    if (v != .array) return null;
    if (v.array.items.len > buf.len) return null;
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return null;
        buf[i] = item.string;
    }
    return buf[0..v.array.items.len];
}

fn listRefusal(object: std.json.ObjectMap, key: []const u8, capacity: usize) Refusal {
    const v = object.get(key) orelse return .field_missing;
    if (v != .array) return .list_not_strings;
    for (v.array.items) |item| {
        if (item != .string) return .list_not_strings;
    }
    // Every item is a string, so the list is longer than the buffer.
    std.debug.assert(v.array.items.len > capacity);
    return if (std.mem.eql(u8, key, "paths")) .too_many_paths else .method_repeated;
}

/// Copy the validated parts into one owned reference.
fn build(allocator: std.mem.Allocator, fields: Fields, methods: std.EnumSet(Method)) std.mem.Allocator.Error!CredentialRef {
    const name = try allocator.dupe(u8, fields.name);
    errdefer allocator.free(name);
    const env = try allocator.dupe(u8, fields.env);
    errdefer allocator.free(env);
    const endpoint_text = try allocator.dupe(u8, fields.endpoint);
    errdefer allocator.free(endpoint_text);
    const header = try allocator.dupe(u8, fields.header);
    errdefer allocator.free(header);
    const scheme = if (fields.scheme) |s| try allocator.dupe(u8, s) else null;
    errdefer if (scheme) |s| allocator.free(s);

    const paths = try allocator.alloc([]const u8, fields.paths.len);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |p| allocator.free(p);
        allocator.free(paths);
    }
    for (fields.paths) |p| {
        paths[filled] = try allocator.dupe(u8, p);
        filled += 1;
    }
    std.mem.sort([]const u8, paths, {}, lessThan);

    return .{
        .name = name,
        .env = env,
        .endpoint = endpoint_text,
        .header = header,
        .scheme = scheme,
        .methods = methods,
        .paths = paths,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn nameLessThan(_: void, a: CredentialRef, b: CredentialRef) bool {
    return lessThan({}, a.name, b.name);
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn validEnv(name: []const u8) bool {
    if (name.len == 0 or name.len > max_env_bytes) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// An HTTP token (RFC 9110 section 5.6.2) of 1 to `max` bytes.
fn isToken(text: []const u8, max: usize) bool {
    if (text.len == 0 or text.len > max) return false;
    for (text) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!ok) return false;
    }
    return true;
}

const EndpointCheck = union(enum) { ok: []const u8, refused: Refusal };

fn checkEndpoint(text: []const u8, buf: []u8) EndpointCheck {
    const normalized = endpoint.normalize(text, buf) catch return .{ .refused = .endpoint_invalid };
    const separator = std.mem.indexOf(u8, text, "://") orelse return .{ .refused = .endpoint_invalid };
    if (std.mem.indexOfAny(u8, text[separator + 3 ..], "/?#") != null) return .{ .refused = .endpoint_not_origin };
    if (std.mem.startsWith(u8, normalized, "http://") and !loopbackLiteral(hostOf(normalized))) {
        return .{ .refused = .endpoint_plaintext };
    }
    return .{ .ok = normalized };
}

/// The host of a canonical `scheme://host:port`.
fn hostOf(canonical: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, canonical, "://") orelse return "") + 3;
    const colon = std.mem.lastIndexOfScalar(u8, canonical, ':') orelse return "";
    if (colon <= start) return "";
    return canonical[start..colon];
}

/// `[::1]`, or a dotted-quad IPv4 address in 127.0.0.0/8 with no leading
/// zeros. A host name that resolves to loopback does not count: resolution can
/// change after the build.
pub fn loopbackLiteral(host: []const u8) bool {
    if (std.mem.eql(u8, host, "[::1]")) return true;
    var parts = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    var first: u16 = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3) return false;
        if (part.len > 1 and part[0] == '0') return false;
        var octet: u16 = 0;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return false;
            octet = octet * 10 + (c - '0');
        }
        if (octet > 255) return false;
        if (count == 0) first = octet;
        count += 1;
    }
    return count == 4 and first == 127;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes or path[0] != '/') return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    for (path) |c| {
        if (c <= 0x20 or c >= 0x7F) return false;
        if (c == '?' or c == '#' or c == '\\') return false;
    }
    var i: usize = 0;
    while (i + 2 < path.len) : (i += 1) {
        if (path[i] != '%') continue;
        const a = std.ascii.toLower(path[i + 1]);
        const b = std.ascii.toLower(path[i + 2]);
        if ((a == '2' and b == 'f') or (a == '5' and b == 'c')) return false;
    }
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseText(text: []const u8) !SetResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    return parseConfig(testing.allocator, parsed.value);
}

fn expectRefused(text: []const u8, reason: Refusal) !void {
    const result = try parseText(text);
    switch (result) {
        .ok => |refs| {
            freeAll(testing.allocator, refs);
            std.debug.print("expected refusal {s} for {s}\n", .{ @tagName(reason), text });
            return error.TestExpectedRefusal;
        },
        .refused => |r| {
            if (r.reason != reason) {
                std.debug.print("expected {s}, got {s} for {s}\n", .{ @tagName(reason), @tagName(r.reason), text });
                return error.TestWrongRefusal;
            }
        },
    }
}

const good_body =
    \\"env": "WEATHER_KEY", "endpoint": "HTTPS://Api.Weather.Example", "header": "Authorization",
    \\"scheme": "Bearer", "methods": ["POST", "GET"], "paths": ["/v1/forecast", "/v1/alerts"]
;

test "credential references load, canonicalize, and sort by name" {
    const result = try parseText("{\"weather\": {" ++ good_body ++ "}, \"billing\": {\"env\": \"BILL\", \"endpoint\": \"http://127.0.0.1:8080\", \"header\": \"x-api-key\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}");
    const refs = result.ok;
    defer freeAll(testing.allocator, refs);

    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqual(@as(?Refusal, null), setOrder(refs));
    try testing.expectEqualStrings("billing", refs[0].name);
    try testing.expectEqual(@as(?[]const u8, null), refs[0].scheme);
    try testing.expectEqualStrings("http://127.0.0.1:8080", refs[0].endpoint);

    const weather = refs[1];
    try testing.expectEqualStrings("weather", weather.name);
    try testing.expectEqualStrings("WEATHER_KEY", weather.env);
    try testing.expectEqualStrings("https://api.weather.example:443", weather.endpoint);
    try testing.expectEqualStrings("authorization", weather.header);
    try testing.expectEqualStrings("Bearer", weather.scheme.?);
    try testing.expect(weather.methods.contains(.GET) and weather.methods.contains(.POST));
    try testing.expectEqual(@as(usize, 2), weather.methods.count());
    try testing.expectEqualStrings("/v1/alerts", weather.paths[0]);
    try testing.expectEqualStrings("/v1/forecast", weather.paths[1]);
    try testing.expectEqual(@as(?*const CredentialRef, &refs[1]), find(refs, "weather"));
    try testing.expectEqual(@as(?*const CredentialRef, null), find(refs, "nope"));
}

test "a canonical reference validates in the canonical form, and a dupe is equal" {
    const result = try parseText("{\"weather\": {" ++ good_body ++ "}}");
    const refs = result.ok;
    defer freeAll(testing.allocator, refs);
    const ref = refs[0];

    var method_names: [7][]const u8 = undefined;
    var n: usize = 0;
    var it = ref.methods.iterator();
    while (it.next()) |m| : (n += 1) method_names[n] = @tagName(m);

    const again = try validate(testing.allocator, .{
        .name = ref.name,
        .env = ref.env,
        .endpoint = ref.endpoint,
        .header = ref.header,
        .scheme = ref.scheme,
        .methods = method_names[0..n],
        .paths = ref.paths,
    }, .canonical);
    var accepted = again.ok;
    defer accepted.deinit(testing.allocator);
    try testing.expectEqualStrings(ref.endpoint, accepted.endpoint);

    var copy = try ref.dupe(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expectEqualStrings(ref.header, copy.header);
    try testing.expectEqual(ref.methods, copy.methods);
    try testing.expectEqualStrings(ref.paths[1], copy.paths[1]);
}

const canonical_cases = [_]Fields{
    .{ .name = "w", .env = "K", .endpoint = "https://api.example", .header = "authorization", .scheme = null, .methods = &.{"GET"}, .paths = &.{"/v1"} },
    .{ .name = "w", .env = "K", .endpoint = "https://api.example:443", .header = "Authorization", .scheme = null, .methods = &.{"GET"}, .paths = &.{"/v1"} },
    .{ .name = "w", .env = "K", .endpoint = "https://api.example:443", .header = "authorization", .scheme = null, .methods = &.{ "POST", "GET" }, .paths = &.{"/v1"} },
    .{ .name = "w", .env = "K", .endpoint = "https://api.example:443", .header = "authorization", .scheme = null, .methods = &.{"GET"}, .paths = &.{ "/v2", "/v1" } },
};

test "the canonical form refuses what the build would not have written" {
    for (canonical_cases) |fields| {
        const result = try validate(testing.allocator, fields, .canonical);
        try testing.expectEqual(Refusal.not_canonical, result.refused);
    }
}

const RefusalCase = struct { text: []const u8, reason: Refusal };
const body_prefix = "\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x-key\", \"methods\": [\"GET\"], ";
const refusal_cases = [_]RefusalCase{
    .{ .text = "[]", .reason = .set_not_container },
    .{ .text = "{\"w\": []}", .reason = .entry_not_object },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/\"], \"value\": \"x\"}}", .reason = .field_unknown },
    .{ .text = "{\"w\": {\"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .field_missing },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"paths\": [\"/\"]}}", .reason = .field_missing },
    .{ .text = "{\"w\": {\"env\": 1, \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .field_not_string },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/\"], \"scheme\": 3}}", .reason = .field_not_string },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": \"/\"}}", .reason = .list_not_strings },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [1]}}", .reason = .list_not_strings },
    .{ .text = "{\"w x\": {" ++ body_prefix ++ "\"paths\": [\"/\"]}}", .reason = .name_invalid },
    .{ .text = "{\"\": {" ++ body_prefix ++ "\"paths\": [\"/\"]}}", .reason = .name_invalid },
    .{ .text = "{\"w\": {\"env\": \"1K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .env_invalid },
    .{ .text = "{\"w\": {\"env\": \"K-1\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .env_invalid },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"ftp://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_invalid },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://u@a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_invalid },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example/v1\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_not_origin },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example/\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_not_origin },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"http://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_plaintext },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"http://localhost:80\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_plaintext },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"http://10.0.0.1\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .endpoint_plaintext },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x key\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .header_invalid },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .header_invalid },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"Host\", \"methods\": [\"GET\"], \"paths\": [\"/\"]}}", .reason = .header_reserved },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/\"], \"scheme\": \"Bearer token\"}}", .reason = .scheme_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/\"], \"scheme\": \"\"}}", .reason = .scheme_invalid },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [], \"paths\": [\"/\"]}}", .reason = .methods_empty },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"get\"], \"paths\": [\"/\"]}}", .reason = .method_unknown },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"TRACE\"], \"paths\": [\"/\"]}}", .reason = .method_unknown },
    .{ .text = "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"GET\", \"GET\"], \"paths\": [\"/\"]}}", .reason = .method_repeated },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": []}}", .reason = .paths_empty },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"v1\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1/\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1//x\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1/../admin\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1/./x\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1%2Fadmin\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1%5cadmin\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1?x=1\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v 1\"]}}", .reason = .path_invalid },
    .{ .text = "{\"w\": {" ++ body_prefix ++ "\"paths\": [\"/v1\", \"/v1\"]}}", .reason = .path_repeated },
};

test "credential references refuse each rule with its named reason" {
    for (refusal_cases) |case| try expectRefused(case.text, case.reason);
}

/// A document one entry over a bound: too many paths, or too many references.
fn overBound(allocator: std.mem.Allocator, reason: Refusal) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    switch (reason) {
        .too_many_paths => {
            try text.appendSlice(allocator, "{\"w\": {\"env\": \"K\", \"endpoint\": \"https://a.example\", \"header\": \"x\", \"methods\": [\"GET\"], \"paths\": [");
            for (0..max_paths + 1) |i| {
                if (i > 0) try text.append(allocator, ',');
                try text.print(allocator, "\"/p{d}\"", .{i});
            }
            try text.appendSlice(allocator, "]}}");
        },
        .too_many_credentials => {
            try text.append(allocator, '{');
            for (0..max_credentials + 1) |i| {
                if (i > 0) try text.append(allocator, ',');
                try text.print(allocator, "\"c{d}\": {{}}", .{i});
            }
            try text.append(allocator, '}');
        },
        else => unreachable,
    }
    return text.toOwnedSlice(allocator);
}

test "a set over the bounds is refused" {
    for ([_]Refusal{ .too_many_paths, .too_many_credentials }) |reason| {
        const text = try overBound(testing.allocator, reason);
        defer testing.allocator.free(text);
        try expectRefused(text, reason);
    }
}

/// Two references, in the order given, for the set-order check.
fn orderedPair(first: []const u8, second: []const u8) ![2]CredentialRef {
    var out: [2]CredentialRef = undefined;
    for ([_][]const u8{ first, second }, 0..) |name, i| {
        const result = try validate(testing.allocator, .{ .name = name, .env = "K", .endpoint = "https://a.example", .header = "x", .scheme = null, .methods = &.{"GET"}, .paths = &.{"/"} }, .config);
        out[i] = result.ok;
    }
    return out;
}

test "the set order refuses a repeated name and a descending pair" {
    const cases = [_]struct { first: []const u8, second: []const u8, want: ?Refusal }{
        .{ .first = "a", .second = "b", .want = null },
        .{ .first = "a", .second = "a", .want = .duplicate_name },
        .{ .first = "b", .second = "a", .want = .not_canonical },
    };
    for (cases) |case| {
        var pair = try orderedPair(case.first, case.second);
        defer for (&pair) |*r| r.deinit(testing.allocator);
        try testing.expectEqual(case.want, setOrder(&pair));
    }
}

test "a refusal names the reference it is about" {
    const result = try parseText("{\"weather\": {" ++ good_body ++ "}, \"broken\": {\"env\": \"K\"}}");
    try testing.expectEqual(Refusal.field_missing, result.refused.reason);
    try testing.expectEqualStrings("broken", result.refused.name());
}

test "loopback literals are exact" {
    try testing.expect(loopbackLiteral("127.0.0.1"));
    try testing.expect(loopbackLiteral("127.255.3.4"));
    try testing.expect(loopbackLiteral("[::1]"));
    try testing.expect(!loopbackLiteral("localhost"));
    try testing.expect(!loopbackLiteral("127.0.0"));
    try testing.expect(!loopbackLiteral("127.0.0.01"));
    try testing.expect(!loopbackLiteral("127.0.0.256"));
    try testing.expect(!loopbackLiteral("128.0.0.1"));
    try testing.expect(!loopbackLiteral("[0:0:0:0:0:0:0:1]"));
    try testing.expect(!loopbackLiteral("127.0.0.1.example"));
}

test "census: every refusal is observed from a real input" {
    var observed = std.EnumSet(Refusal).initEmpty();

    for (refusal_cases) |case| {
        const result = try parseText(case.text);
        switch (result) {
            .ok => |refs| freeAll(testing.allocator, refs),
            .refused => |r| observed.insert(r.reason),
        }
    }
    for ([_]Refusal{ .too_many_paths, .too_many_credentials }) |reason| {
        const text = try overBound(testing.allocator, reason);
        defer testing.allocator.free(text);
        switch (try parseText(text)) {
            .ok => |refs| freeAll(testing.allocator, refs),
            .refused => |r| observed.insert(r.reason),
        }
    }
    for (canonical_cases) |fields| {
        switch (try validate(testing.allocator, fields, .canonical)) {
            .ok => |ref| {
                var owned = ref;
                owned.deinit(testing.allocator);
            },
            .refused => |reason| observed.insert(reason),
        }
    }
    for ([_][2][]const u8{ .{ "a", "a" }, .{ "b", "a" } }) |names| {
        var pair = try orderedPair(names[0], names[1]);
        defer for (&pair) |*r| r.deinit(testing.allocator);
        if (setOrder(&pair)) |reason| observed.insert(reason);
    }

    for (std.enums.values(Refusal)) |reason| {
        if (!observed.contains(reason)) {
            std.debug.print("refusal {s} was never observed\n", .{@tagName(reason)});
            return error.TestRefusalNotObserved;
        }
        try testing.expect(reason.sentence().len > 0);
    }
}
