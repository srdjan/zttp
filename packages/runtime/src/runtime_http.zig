//! Outbound HTTP and fetch native implementations.
//!
//! This module implements HTTP constructors, body tracking, the synchronous
//! `fetch` bridge and the low-level `zttp:http.request` operation.
//! Host-dependent operations take a borrowed View. HandlerInstance composes
//! that view and recovers the host in its native callback adapters.

const std = @import("std");
const ascii = std.ascii;
const zq = @import("zts");
const http_parser = @import("http_parser.zig");

const http_types = @import("http_types.zig");
const HttpResponse = http_types.HttpResponse;
const HttpRequestView = http_types.HttpRequestView;
const HttpRequestOwned = http_types.HttpRequestOwned;
const QueryParam = http_types.QueryParam;
const HttpHeader = http_types.HttpHeader;
const ResponseHeader = http_types.ResponseHeader;

/// Context owns the installed prototypes. This state borrows them and owns
/// the allocation that tracks body consumption for the current request.
pub const HttpState = struct {
    request_prototype: ?*zq.JSObject = null,
    response_prototype: ?*zq.JSObject = null,
    headers_prototype: ?*zq.JSObject = null,
    consumed_body_objects: std.AutoHashMapUnmanaged(*zq.JSObject, void) = .empty,

    pub fn installPrototypes(self: *HttpState, request: *zq.JSObject, response: *zq.JSObject, headers: *zq.JSObject) void {
        self.request_prototype = request;
        self.response_prototype = response;
        self.headers_prototype = headers;
    }

    pub fn reset(self: *HttpState) void {
        self.consumed_body_objects.clearRetainingCapacity();
    }

    pub fn deinit(self: *HttpState, allocator: std.mem.Allocator) void {
        self.consumed_body_objects.deinit(allocator);
        self.* = .{};
    }
};

pub const Config = struct {
    enabled: bool = false,
    allow_host: ?[]const u8 = null,
    max_response_bytes: usize = 1024 * 1024,
    timeout_ms: u32 = 10_000,
    replay: bool = false,
};

/// Borrowed for one synchronous operation. The backend remains at its stable
/// owner address because its Io vtable and userdata point into that storage.
pub const View = struct {
    allocator: std.mem.Allocator,
    ctx: *zq.Context,
    state: *HttpState,
    config: Config,
    backend: ?*OutboundIo,
};

const FetchResponseObjects = struct {
    value: zq.JSValue,
    response: *zq.JSObject,
    headers: *zq.JSObject,
};

fn effectiveOutboundTimeoutMs(rt: View) u32 {
    return rt.config.timeout_ms;
}
const natives = @import("runtime_natives.zig");
pub const getStringData = natives.getStringData;
// Context-aware string accessor for flat and slice strings. Response extraction
// uses it so slice bodies and headers are not dropped.
const getStringDataCtx = zq.builtins.helpers.getStringDataCtx;
const getDynamicProperty = natives.getDynamicProperty;
const getObjectProperty = natives.getObjectProperty;
const getHeaderAtom = natives.getHeaderAtom;
const HeaderAssignMode = natives.HeaderAssignMode;
const statusTextFor = natives.statusTextFor;
const getNamedGlobalPrototype = natives.getNamedGlobalPrototype;
const throwTypeError = natives.throwTypeError;

pub fn beginBodyRead(ctx: *zq.Context, state: ?*HttpState, allocator: std.mem.Allocator, this: zq.JSValue) zq.JSValue {
    if (!this.isObject()) {
        return throwTypeError(ctx, "Body reader target must be an object");
    }
    const obj = this.toPtr(zq.JSObject);
    if (state) |http_state| {
        if (http_state.consumed_body_objects.contains(obj)) {
            return throwTypeError(ctx, "Body has already been consumed");
        }
        http_state.consumed_body_objects.put(allocator, obj, {}) catch {
            return throwTypeError(ctx, "Failed to track body consumption");
        };
    }
    return getBodyValue(ctx, this) orelse zq.JSValue.undefined_val;
}

const getHeaderValueCaseInsensitive = natives.getHeaderValueCaseInsensitive;
const validateHeaderPair = natives.validateHeaderPair;
const setHeaderValue = natives.setHeaderValue;
const createHeadersObjectDynamic = natives.createHeadersObjectDynamic;
const copyHeadersIntoObject = natives.copyHeadersIntoObject;
const splitPathAndQuery = natives.splitPathAndQuery;
const buildQueryObject = natives.buildQueryObject;
const upgradeResponseValue = natives.upgradeResponseValue;

const OwnedResponseHeader = struct {
    name: []u8,
    value: []u8,
};

const OwnedResponseHead = struct {
    reason: []u8,
    headers: std.ArrayListUnmanaged(OwnedResponseHeader) = .empty,

    fn deinit(self: *OwnedResponseHead, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        for (self.headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        self.headers.deinit(allocator);
    }

    fn contentType(self: *const OwnedResponseHead) ?[]const u8 {
        for (self.headers.items) |header| {
            if (ascii.eqlIgnoreCase(header.name, "content-type")) {
                return header.value;
            }
        }
        return null;
    }
};

fn snapshotResponseHead(allocator: std.mem.Allocator, head: anytype) !OwnedResponseHead {
    var owned = OwnedResponseHead{
        .reason = try allocator.dupe(u8, head.reason),
    };
    errdefer owned.deinit(allocator);

    var header_it = head.iterateHeaders();
    while (header_it.next()) |header| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try owned.headers.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    return owned;
}

fn createResponseHeadersObject(rt: View) !*zq.JSObject {
    if (rt.ctx.http.shapes) |shapes| {
        return rt.ctx.createObjectWithClass(shapes.response_headers.class_idx, rt.state.headers_prototype);
    }
    return rt.ctx.createObject(rt.state.headers_prototype);
}

pub fn createFetchResponse(rt: View, status: u16, status_text: []const u8, body: []const u8, content_type: ?[]const u8) !FetchResponseObjects {
    const body_val = try rt.ctx.createString(body);
    const body_str = body_val.toPtr(zq.JSString);
    const response_val = try zq.http.createResponseFromString(
        rt.ctx,
        body_str,
        status,
        content_type orelse "application/octet-stream",
    );
    const response_obj = response_val.toPtr(zq.JSObject);
    if (rt.state.response_prototype) |proto| {
        response_obj.prototype = proto;
    }

    const status_text_atom = if (rt.ctx.http.strings) |cache|
        cache.status_text_atom
    else
        try rt.ctx.atoms.intern("statusText");
    const status_text_val = try rt.ctx.createString(status_text);
    try rt.ctx.setPropertyChecked(response_obj, status_text_atom, status_text_val);

    const headers_obj = try createResponseHeadersObject(rt);
    try rt.ctx.setPropertyChecked(response_obj, zq.Atom.headers, headers_obj.toValue());

    if (content_type) |ct| {
        const ct_atom = try getHeaderAtom(rt.ctx, "content-type");
        const ct_val = try rt.ctx.createString(ct);
        try rt.ctx.setPropertyChecked(headers_obj, ct_atom, ct_val);
    }

    return .{
        .value = response_val,
        .response = response_obj,
        .headers = headers_obj,
    };
}

pub fn createFetchErrorResponse(rt: View, err_code: []const u8, details: []const u8) !zq.JSValue {
    const error_body = try httpRequestErrorJsonAlloc(rt.allocator, err_code, details);
    defer rt.allocator.free(error_body);

    const created = try createFetchResponse(rt, 599, err_code, error_body, "application/json");
    const error_atom = try rt.ctx.atoms.intern("error");
    const details_atom = try rt.ctx.atoms.intern("details");
    const error_val = try rt.ctx.createString(err_code);
    const details_val = try rt.ctx.createString(details);
    try rt.ctx.setPropertyChecked(created.response, error_atom, error_val);
    try rt.ctx.setPropertyChecked(created.response, details_atom, details_val);
    return created.value;
}

fn getBodyValue(ctx: *zq.Context, this: zq.JSValue) ?zq.JSValue {
    if (!this.isObject()) return null;
    const pool = ctx.hidden_class_pool orelse return null;
    const obj = this.toPtr(zq.JSObject);
    return obj.getProperty(pool, zq.Atom.body);
}

pub fn headersGetNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    if (!this.isObject() or args.len == 0) return zq.JSValue.undefined_val;

    const wanted = getStringDataCtx(args[0], ctx) orelse return zq.JSValue.undefined_val;
    const pool = ctx.hidden_class_pool orelse return zq.JSValue.undefined_val;
    const headers_obj = this.toPtr(zq.JSObject);
    return getHeaderValueCaseInsensitive(ctx, headers_obj, pool, wanted) orelse zq.JSValue.undefined_val;
}

pub fn headersHasNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    if (!this.isObject() or args.len == 0) return zq.JSValue.false_val;

    const wanted = getStringDataCtx(args[0], ctx) orelse return zq.JSValue.false_val;
    const pool = ctx.hidden_class_pool orelse return zq.JSValue.false_val;
    const headers_obj = this.toPtr(zq.JSObject);
    return zq.JSValue.fromBool(getHeaderValueCaseInsensitive(ctx, headers_obj, pool, wanted) != null);
}

fn headersSetLikeNative(
    ctx: *zq.Context,
    this: zq.JSValue,
    args: []const zq.JSValue,
    mode: HeaderAssignMode,
) !zq.JSValue {
    if (!this.isObject()) return throwTypeError(ctx, "Headers target must be an object");
    if (args.len < 2) return throwTypeError(ctx, "Headers mutation requires name and value");

    const name = getStringDataCtx(args[0], ctx) orelse return throwTypeError(ctx, "Header name must be string");
    const value = getStringDataCtx(args[1], ctx) orelse return throwTypeError(ctx, "Header value must be string");
    if (!validateHeaderPair(name, value)) {
        return throwTypeError(ctx, "Header name/value is invalid");
    }
    try setHeaderValue(ctx, this.toPtr(zq.JSObject), name, value, mode);
    return zq.JSValue.undefined_val;
}

pub fn headersSetNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return headersSetLikeNative(ctx, this, args, .replace);
}

pub fn headersAppendNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return headersSetLikeNative(ctx, this, args, .append);
}

pub fn headersDeleteNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    if (!this.isObject() or args.len == 0) return zq.JSValue.undefined_val;

    const wanted = getStringDataCtx(args[0], ctx) orelse return zq.JSValue.undefined_val;
    const pool = ctx.hidden_class_pool orelse return zq.JSValue.undefined_val;
    const headers_obj = this.toPtr(zq.JSObject);
    const keys = headers_obj.getOwnEnumerableKeys(ctx.allocator, pool) catch return zq.JSValue.undefined_val;
    defer ctx.allocator.free(keys);

    for (keys) |key_atom| {
        const key_name = ctx.atoms.getName(key_atom) orelse continue;
        if (!ascii.eqlIgnoreCase(key_name, wanted)) continue;
        _ = headers_obj.deleteProperty(pool, key_atom);
    }
    return zq.JSValue.undefined_val;
}

pub fn headersConstructorNative(ctx_ptr: *anyopaque, _: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    const headers_obj = try createHeadersObjectDynamic(ctx);

    if (args.len > 0 and !args[0].isUndefined() and !args[0].isNull()) {
        copyHeadersIntoObject(ctx, args[0], headers_obj) catch |err| switch (err) {
            error.InvalidHeaders => return throwTypeError(ctx, "Headers(init) expects object<string,string>"),
            else => return err,
        };
    }

    return headers_obj.toValue();
}

pub fn requestConstructorNative(ctx_ptr: *anyopaque, _: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));

    const url = if (args.len > 0) getStringData(args[0]) else null;
    if (url == null or url.?.len == 0) {
        return throwTypeError(ctx, "Request(url, init?) expects a non-empty string url");
    }

    var method: []const u8 = "GET";
    var body: ?[]const u8 = null;
    const headers_obj = try createHeadersObjectDynamic(ctx);

    if (args.len > 1 and args[1].isObject()) {
        const pool = ctx.hidden_class_pool orelse return error.NoHiddenClassPool;
        const init = args[1].toPtr(zq.JSObject);

        if (getObjectProperty(ctx, init, pool, zq.Atom.method, "method")) |method_val| {
            method = getStringData(method_val) orelse return throwTypeError(ctx, "Request method must be string");
        }
        if (getObjectProperty(ctx, init, pool, zq.Atom.body, "body")) |body_val| {
            if (body_val.isNull() or body_val.isUndefined()) {
                body = null;
            } else {
                body = getStringData(body_val) orelse return throwTypeError(ctx, "Request body must be string|null");
            }
        }
        if (getObjectProperty(ctx, init, pool, zq.Atom.headers, "headers")) |headers_val| {
            copyHeadersIntoObject(ctx, headers_val, headers_obj) catch |err| switch (err) {
                error.InvalidHeaders => return throwTypeError(ctx, "Request headers must be object<string,string>"),
                else => return err,
            };
        }
    }

    const split = splitPathAndQuery(url.?);
    const parsed_query = try http_parser.parseQueryString(ctx.allocator, split.query_string, http_parser.DEFAULT_MAX_QUERY_LENGTH);
    defer if (parsed_query.storage) |storage| ctx.allocator.free(storage);
    defer if (parsed_query.decoded_storage) |storage| ctx.allocator.free(storage);

    const req_obj = try ctx.createObject(getNamedGlobalPrototype(ctx, "Request"));
    const url_val = try ctx.createString(url.?);
    try ctx.setPropertyChecked(req_obj, zq.Atom.url, url_val);
    try ctx.setPropertyChecked(req_obj, zq.Atom.method, try ctx.createString(method));
    try ctx.setPropertyChecked(req_obj, zq.Atom.path, try ctx.createString(split.path));
    try ctx.setPropertyChecked(req_obj, zq.Atom.query, (try buildQueryObject(ctx, parsed_query.params)).toValue());
    if (body) |body_str| {
        try ctx.setPropertyChecked(req_obj, zq.Atom.body, try ctx.createString(body_str));
    } else {
        try ctx.setPropertyChecked(req_obj, zq.Atom.body, zq.JSValue.undefined_val);
    }
    try ctx.setPropertyChecked(req_obj, zq.Atom.headers, headers_obj.toValue());

    return req_obj.toValue();
}

pub fn responseConstructorNative(ctx_ptr: *anyopaque, _: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    const response_val = try zq.http.responseConstructor(ctx, zq.JSValue.undefined_val, args);
    if (ctx.hasException()) return error.NativeFunctionError;

    const upgraded = try upgradeResponseValue(ctx, response_val);
    if (args.len < 2 or !args[1].isObject()) return upgraded;

    const pool = ctx.hidden_class_pool orelse return error.NoHiddenClassPool;
    const init = args[1].toPtr(zq.JSObject);
    const headers_val = getObjectProperty(ctx, init, pool, zq.Atom.headers, "headers") orelse return upgraded;

    const response_obj = upgraded.toPtr(zq.JSObject);
    const headers_obj = try createHeadersObjectDynamic(ctx);
    if (response_obj.getProperty(pool, zq.Atom.headers)) |existing_headers_val| {
        if (existing_headers_val.isObject()) {
            try copyHeadersIntoObject(ctx, existing_headers_val, headers_obj);
        }
    }
    copyHeadersIntoObject(ctx, headers_val, headers_obj) catch |err| switch (err) {
        error.InvalidHeaders => return throwTypeError(ctx, "Response headers must be object<string,string>"),
        else => return err,
    };
    try ctx.setPropertyChecked(response_obj, zq.Atom.headers, headers_obj.toValue());
    return upgraded;
}

fn wrapResponseStatic(
    ctx: *zq.Context,
    this: zq.JSValue,
    args: []const zq.JSValue,
    func: *const fn (*anyopaque, zq.JSValue, []const zq.JSValue) anyerror!zq.JSValue,
) !zq.JSValue {
    const result = try func(ctx, this, args);
    return upgradeResponseValue(ctx, result);
}

pub fn responseJsonStaticNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return wrapResponseStatic(ctx, this, args, zq.http.responseJson);
}

pub fn responseTextStaticNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return wrapResponseStatic(ctx, this, args, zq.http.responseText);
}

pub fn responseHtmlStaticNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return wrapResponseStatic(ctx, this, args, zq.http.responseHtml);
}

pub fn responseRawJsonStaticNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return wrapResponseStatic(ctx, this, args, zq.http.responseRawJson);
}

pub fn responseRedirectStaticNative(ctx_ptr: *anyopaque, this: zq.JSValue, args: []const zq.JSValue) anyerror!zq.JSValue {
    const ctx: *zq.Context = @ptrCast(@alignCast(ctx_ptr));
    return wrapResponseStatic(ctx, this, args, zq.http.responseRedirect);
}

/// Split a slice of headers (any struct with .key/.value) into parallel
/// name/value arrays for trace recording. Returns the count written.
pub fn splitHeaderKV(headers: anytype, names: *[64][]const u8, values: *[64][]const u8) usize {
    const count = @min(headers.len, 64);
    for (headers[0..count], 0..) |hdr, i| {
        names[i] = hdr.key;
        values[i] = hdr.value;
    }
    return count;
}

/// Authorize the destination this request would reach.
///
/// The policy names endpoints - `scheme://host:port` - so the URL is
/// canonicalized by the same rule that produced those entries and the two are
/// compared byte for byte. A host comparison could not tell
/// `https://api.example.com` from `http://api.example.com:8080`, which are two
/// servers, and a URL the rule refuses (userinfo, a scheme outside the set)
/// is denied rather than connected to.
///
/// `--allow-host` stays a host comparison: it is a coarse operator switch over
/// whatever the policy already permits, not the policy itself.
fn outboundEndpointViolation(rt: View, url: []const u8, host: []const u8) ?[]const u8 {
    if (rt.config.allow_host) |allowed_host| {
        if (!ascii.eqlIgnoreCase(host, allowed_host)) {
            zq.policy.emitDenied(.{
                .action = .http_outbound,
                .resource = .{ .kind = zq.policy.resource_kind_endpoint, .id = host },
                .policy_generation = rt.ctx.policy_generation,
            }, .not_in_allowlist);
            return allowed_host;
        }
    }

    var buf: [zq.endpoint.max_endpoint_bytes]u8 = undefined;
    const normalized = zq.endpoint.normalize(url, &buf) catch {
        zq.policy.emitDenied(.{
            .action = .http_outbound,
            .resource = .{ .kind = zq.policy.resource_kind_endpoint, .id = host },
            .policy_generation = rt.ctx.policy_generation,
        }, .not_in_allowlist);
        return "url names no endpoint this policy can decide";
    };
    if (!rt.ctx.capability_policy.allowsEgressEndpoint(normalized)) {
        zq.policy.emitDenied(.{
            .action = .http_outbound,
            .resource = .{ .kind = zq.policy.resource_kind_endpoint, .id = host },
            .policy_generation = rt.ctx.policy_generation,
        }, .not_in_allowlist);
        return "capability policy";
    }
    return null;
}

/// The widest text an address takes here: an IPv4-mapped IPv6 address written
/// in full, `::ffff:255.255.255.255`.
const max_address_text_bytes: usize = 45;

/// One resolved address the policy admits, in the form the connect takes.
const ResolvedTarget = struct {
    buffer: [max_address_text_bytes]u8 = undefined,
    len: usize = 0,
    scope: zq.endpoint.AddressScope = .unspecified,

    /// The address as the connect target. `HostName.init` validates RFC 1123
    /// names and would refuse the colons in an IPv6 literal, so this is built
    /// rather than validated: it is text this process just wrote from bytes
    /// the resolver returned, and the resolver reads it back as a literal.
    fn hostName(self: *const ResolvedTarget) std.Io.net.HostName {
        return .{ .bytes = self.buffer[0..self.len] };
    }
};

const ScopeDecision = union(enum) {
    /// `target` holds an address whose scope the policy admits.
    allowed,
    /// The policy admits no address this name answered with.
    denied: []const u8,
    /// The name answered with no address, or the resolver failed.
    unresolved: []const u8,
};

fn resolvedAddressOf(address: std.Io.net.IpAddress) zq.endpoint.ResolvedAddress {
    return switch (address) {
        .ip4 => |v4| .{ .v4 = v4.bytes },
        .ip6 => |v6| .{ .v6 = v6.bytes },
    };
}

fn writeAddressText(address: std.Io.net.IpAddress, target: *ResolvedTarget) bool {
    var writer = std.Io.Writer.fixed(&target.buffer);
    switch (address) {
        .ip4 => |v4| writer.print("{d}.{d}.{d}.{d}", .{
            v4.bytes[0],
            v4.bytes[1],
            v4.bytes[2],
            v4.bytes[3],
        }) catch return false,
        .ip6 => |v6| writer.print("{f}", .{&v6}) catch return false,
    }
    target.len = writer.buffered().len;
    return target.len > 0;
}

/// What the developer is told when no answer was in scope. One constant per
/// scope: the scope is the decision, and the address itself is not repeated
/// back to the handler.
fn scopeDenialText(scope: zq.endpoint.AddressScope) []const u8 {
    return switch (scope) {
        .public => "the name resolved to a public address, which egress.allow_address_scopes does not name",
        .private => "the name resolved to a private address, which egress.allow_address_scopes does not name",
        .loopback => "the name resolved to a loopback address, which egress.allow_address_scopes does not name",
        .link_local => "the name resolved to a link_local address, which egress.allow_address_scopes does not name",
        .multicast => "the name resolved to a multicast address, which egress.allow_address_scopes does not name",
        .unspecified => "the name resolved to an unspecified address, which egress.allow_address_scopes does not name",
    };
}

/// Classify what the name answered with, before any socket.
///
/// `outboundEndpointViolation` authorized a destination the handler named. A
/// name is not an address: nothing in `https://api.example.com` says the answer
/// will not be `169.254.169.254`, and the answer is chosen by whoever serves
/// the zone. So the name is resolved here, every answer is classified, and the
/// connection is opened to an answer that passed - as a literal, so the connect
/// resolves nothing. Handing `std.http.Client` the name again would let it
/// resolve a second time and reach an address this never saw.
fn resolvedScopeDecision(
    io: std.Io,
    policy: *const zq.RuntimePolicy,
    policy_generation: u64,
    host: std.Io.net.HostName,
    port: u16,
    target: *ResolvedTarget,
) ScopeDecision {
    var lookup_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    var lookup = io.async(std.Io.net.HostName.lookup, .{ host, io, &lookup_queue, .{ .port = port } });
    defer lookup.cancel(io) catch {};

    var admitted = false;
    var refused: ?zq.endpoint.AddressScope = null;
    var text_failed = false;
    var failure: ?[]const u8 = null;

    // Drain to the end even after one address passes: the resolver writes into
    // a bounded queue, and a reader that stops reading stops it mid-write.
    while (lookup_queue.getOne(io)) |result| switch (result) {
        .canonical_name => continue,
        .address => |address| {
            if (admitted) continue;
            const scope = zq.endpoint.scopeOf(resolvedAddressOf(address));
            if (!policy.allowsAddressScope(scope)) {
                if (refused == null) refused = scope;
                continue;
            }
            if (!writeAddressText(address, target)) {
                text_failed = true;
                continue;
            }
            target.scope = scope;
            admitted = true;
        },
    } else |err| switch (err) {
        error.Canceled => failure = "outbound name resolution was canceled",
        error.Closed => lookup.await(io) catch |lookup_err| {
            failure = switch (lookup_err) {
                error.UnknownHostName => "name did not resolve",
                else => "name resolution failed",
            };
        },
    }

    if (admitted) return .allowed;
    if (refused) |scope| {
        zq.policy.emitDenied(.{
            .action = .http_outbound,
            .resource = .{ .kind = zq.policy.resource_kind_address_scope, .id = host.bytes },
            .policy_generation = policy_generation,
        }, .address_scope_not_allowed);
        return .{ .denied = scopeDenialText(scope) };
    }
    if (text_failed) return .{ .unresolved = "resolved address has no text form" };
    return .{ .unresolved = failure orelse "name did not resolve" };
}

pub fn fetchSync(rt: View, args: []const zq.JSValue) !zq.JSValue {
    return fetchAndRecord(rt, args);
}

fn fetchAndRecord(rt: View, args: []const zq.JSValue) !zq.JSValue {
    const result = fetchSyncResult(rt, args) catch |err|
        return createFetchErrorResponse(rt, "InternalError", @errorName(err));

    // Record fetchSync to trace (it's outside virtual module dispatch)
    const ctx = rt.ctx;
    if (ctx.getModuleState(zq.TraceRecorder, zq.TRACE_STATE_SLOT)) |recorder| {
        recorder.recordIO("http", "fetchSync", ctx, args, result);
    }

    return result;
}

/// Parsed fetch arguments: URL, URI, and optional init object.
/// Parse arguments for the synchronous fetch path.
const FetchArgs = struct {
    url: []const u8,
    uri: std.Uri,
    init_obj: ?*zq.JSObject,
};

const FetchArgsResult = union(enum) {
    ok: FetchArgs,
    err: zq.JSValue,
};

const FetchInitOptions = struct {
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    max_response_bytes: usize,
    headers: std.ArrayList(std.http.Header) = .empty,
    fn deinit(self: *FetchInitOptions, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
    }
};

const FetchInitResult = union(enum) {
    ok: FetchInitOptions,
    err: zq.JSValue,
};

fn fetchInitError(
    rt: View,
    allocator: std.mem.Allocator,
    options: *FetchInitOptions,
    code: []const u8,
    details: []const u8,
) !FetchInitResult {
    options.deinit(allocator);
    return .{ .err = try createFetchErrorResponse(rt, code, details) };
}

/// Resolve a URI host into a fixed buffer without the std panic. `Uri.getHost`
/// percent-decodes the host into the caller's `[HostName.max_len]u8` buffer and
/// `catch unreachable`s on overflow (std Uri.zig), so a crafted URL whose
/// percent-DECODED host exceeds 255 bytes (e.g. `https://%41…×300.com/`) would
/// crash the worker. The decoded length never exceeds the encoded length, so an
/// encoded host that fits the buffer is always safe; reject an over-long host up
/// front (a real DNS name is <= 253 bytes), returning the same UriMissingHost
/// error the call sites already surface as a clean InvalidUrl.
fn resolveHostSafe(uri: std.Uri, buf: *[std.Io.net.HostName.max_len]u8) std.Io.net.HostName.FromUriError!std.Io.net.HostName {
    if (uri.host) |h| {
        const encoded = switch (h) {
            .raw, .percent_encoded => |s| s,
        };
        if (encoded.len > buf.len) return error.UriMissingHost;
    }
    const component = uri.host orelse return error.UriMissingHost;
    const bytes = component.toRaw(buf) catch return error.NameTooLong;
    // IP literals are valid URI hosts but IPv6 is outside DNS-name syntax.
    if (std.Io.net.IpAddress.parseLiteral(bytes)) |_| return .{ .bytes = bytes } else |_| {}
    return std.Io.net.HostName.fromUri(uri, buf);
}

/// Parse and validate the (url, init?) arguments common to all fetch call sites.
/// Returns a JS error response (status 599) on validation failure.
pub fn parseFetchArgs(rt: View, pool: *const zq.HiddenClassPool, args: []const zq.JSValue) !FetchArgsResult {
    if (args.len == 0) {
        return .{ .err = try createFetchErrorResponse(rt, "InvalidArgs", "expected url string or init object") };
    }

    var init_obj: ?*zq.JSObject = null;
    const url = blk: {
        if (args[0].isObject()) {
            init_obj = args[0].toPtr(zq.JSObject);
            const url_val = getObjectProperty(rt.ctx, init_obj.?, pool, zq.Atom.url, "url") orelse {
                return .{ .err = try createFetchErrorResponse(rt, "InvalidUrl", "missing url field") };
            };
            const url_str = getStringData(url_val) orelse {
                return .{ .err = try createFetchErrorResponse(rt, "InvalidUrl", "url must be a non-empty string") };
            };
            if (url_str.len == 0) {
                return .{ .err = try createFetchErrorResponse(rt, "InvalidUrl", "url must be a non-empty string") };
            }
            break :blk url_str;
        }
        const url_str = getStringData(args[0]) orelse {
            return .{ .err = try createFetchErrorResponse(rt, "InvalidArgs", "expected url string or init object") };
        };
        if (url_str.len == 0) {
            return .{ .err = try createFetchErrorResponse(rt, "InvalidUrl", "url must be a non-empty string") };
        }
        if (args.len > 1 and args[1].isObject()) {
            init_obj = args[1].toPtr(zq.JSObject);
        }
        break :blk url_str;
    };

    // The base `url` is the compile-time literal (so egress stays provable);
    // any dynamic `query` object in the init is appended here at runtime.
    const final_url = switch (try buildFetchUrl(rt, pool, url, init_obj)) {
        .ok => |u| u,
        .err => |e| return .{ .err = e },
    };
    // From here `final_url` is owned on rt.allocator and the caller frees it.
    // The local .err returns below must free it explicitly: a union .err is a
    // normal (non-error) return, so an errdefer would not fire.
    const uri = std.Uri.parse(final_url) catch {
        rt.allocator.free(final_url);
        return .{ .err = try createFetchErrorResponse(rt, "InvalidUrl", "url parse failed") };
    };
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = resolveHostSafe(uri, &host_buf) catch {
        rt.allocator.free(final_url);
        return .{ .err = try createFetchErrorResponse(rt, "InvalidUrl", "url host is required") };
    };
    if (outboundEndpointViolation(rt, final_url, host.bytes)) |details| {
        rt.allocator.free(final_url);
        return .{ .err = try createFetchErrorResponse(rt, "HostNotAllowed", details) };
    }

    return .{ .ok = .{ .url = final_url, .uri = uri, .init_obj = init_obj } };
}

const FetchUrlResult = union(enum) {
    ok: []const u8,
    err: zq.JSValue,
};

/// Build the final fetch URL from the literal base plus an optional dynamic
/// `query` object on the init. The base URL stays a compile-time literal so
/// the contract proves the egress host; the query object carries the dynamic,
/// possibly user-supplied values (e.g. weather coordinates), percent-encoded
/// here.
///
/// Returns an owned slice on `rt.allocator` (a copy of the base when there is
/// no query, for uniform caller ownership), or a JS error response if `query`
/// is present but not an object / holds an unencodable value.
pub fn buildFetchUrl(
    rt: View,
    pool: *const zq.HiddenClassPool,
    base_url: []const u8,
    init_obj: ?*zq.JSObject,
) !FetchUrlResult {
    const query_obj = blk: {
        const init = init_obj orelse break :blk null;
        const query_val = getDynamicProperty(rt.ctx, init, pool, "query") orelse break :blk null;
        if (query_val.isUndefined() or query_val.isNull()) break :blk null;
        if (!query_val.isObject()) {
            return .{ .err = try createFetchErrorResponse(rt, "InvalidQuery", "query must be object<string, string|number|boolean>") };
        }
        break :blk query_val.toPtr(zq.JSObject);
    };

    const q = query_obj orelse return .{ .ok = try rt.allocator.dupe(u8, base_url) };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(rt.allocator);
    try buf.appendSlice(rt.allocator, base_url);

    const keys = try q.getOwnEnumerableKeys(rt.allocator, pool);
    defer rt.allocator.free(keys);

    var wrote_any = std.mem.indexOfScalar(u8, base_url, '?') != null;
    for (keys) |key_atom| {
        const key_name = rt.ctx.atoms.getName(key_atom) orelse continue;
        const item = q.getOwnProperty(pool, key_atom) orelse continue;
        if (item.isUndefined()) continue;

        try buf.append(rt.allocator, if (wrote_any) '&' else '?');
        try appendPercentEncoded(rt, &buf, key_name);
        try buf.append(rt.allocator, '=');
        if (!try appendEncodedJsValue(rt, &buf, item)) {
            buf.deinit(rt.allocator);
            // Disarm the errdefer: a `.err` union return does not trip it, but
            // the fallible createFetchErrorResponse below would, double-deinit'ing
            // the just-freed (now undefined) buffer. Reset to empty so the
            // errdefer's deinit is a safe no-op on either exit.
            buf = .empty;
            return .{ .err = try createFetchErrorResponse(rt, "InvalidQuery", "query values must be string|number|boolean") };
        }
        wrote_any = true;
    }

    return .{ .ok = try buf.toOwnedSlice(rt.allocator) };
}

fn parseFetchInitOptions(
    rt: View,
    allocator: std.mem.Allocator,
    pool: *const zq.HiddenClassPool,
    init_obj: ?*zq.JSObject,
) !FetchInitResult {
    var options = FetchInitOptions{
        .max_response_bytes = @max(@as(usize, 1), rt.config.max_response_bytes),
    };

    const init = init_obj orelse return .{ .ok = options };

    if (getObjectProperty(rt.ctx, init, pool, zq.Atom.method, "method")) |method_val| {
        const method_name = getStringData(method_val) orelse {
            return fetchInitError(rt, allocator, &options, "InvalidMethod", "method must be string");
        };
        options.method = parseHttpMethod(method_name) orelse {
            return fetchInitError(rt, allocator, &options, "InvalidMethod", method_name);
        };
    }

    if (getObjectProperty(rt.ctx, init, pool, zq.Atom.body, "body")) |body_val| {
        if (body_val.isNull() or body_val.isUndefined()) {
            options.body = null;
        } else if (zq.bytes.asBytes(body_val)) |raw| {
            // Spec 7.2 types the body `string | Bytes`. A Bytes sends its
            // octets unchanged, which is the whole reason to pass one rather
            // than a string: a string here would have to be text, and binary
            // that survives a round trip through one is binary that happened
            // to be valid UTF-8.
            options.body = zq.bytes.data(raw);
        } else {
            const body_string = getStringData(body_val);
            options.body = body_string orelse {
                return fetchInitError(rt, allocator, &options, "InvalidBody", "body must be string|Bytes|null");
            };
        }
    }

    if (getDynamicProperty(rt.ctx, init, pool, "maxResponseBytes")) |max_val| {
        if (!max_val.isInt()) {
            return fetchInitError(rt, allocator, &options, "InvalidMaxResponseBytes", "maxResponseBytes must be integer");
        }
        const req_max = std.math.cast(usize, max_val.getInt()) orelse {
            return fetchInitError(rt, allocator, &options, "InvalidMaxResponseBytes", "maxResponseBytes out of range");
        };
        options.max_response_bytes = @min(options.max_response_bytes, @max(@as(usize, 1), req_max));
    } else if (getDynamicProperty(rt.ctx, init, pool, "max_response_bytes")) |max_val| {
        if (!max_val.isInt()) {
            return fetchInitError(rt, allocator, &options, "InvalidMaxResponseBytes", "max_response_bytes must be integer");
        }
        const req_max = std.math.cast(usize, max_val.getInt()) orelse {
            return fetchInitError(rt, allocator, &options, "InvalidMaxResponseBytes", "max_response_bytes out of range");
        };
        options.max_response_bytes = @min(options.max_response_bytes, @max(@as(usize, 1), req_max));
    }

    if (getObjectProperty(rt.ctx, init, pool, zq.Atom.headers, "headers")) |headers_val| {
        if (!headers_val.isObject()) {
            return fetchInitError(rt, allocator, &options, "InvalidHeaders", "headers must be object<string,string>");
        }
        const headers_obj = headers_val.toPtr(zq.JSObject);
        const keys = try headers_obj.getOwnEnumerableKeys(allocator, pool);
        defer allocator.free(keys);

        for (keys) |key_atom| {
            const key_name = rt.ctx.atoms.getName(key_atom) orelse continue;
            const header_val = headers_obj.getOwnProperty(pool, key_atom) orelse continue;
            const header_str = getStringData(header_val) orelse {
                return fetchInitError(rt, allocator, &options, "InvalidHeaders", "header values must be strings");
            };
            if (key_name.len == 0) {
                return fetchInitError(rt, allocator, &options, "InvalidHeaders", "header name must be non-empty");
            }
            if (std.mem.indexOfAny(u8, key_name, "\r\n") != null) {
                return fetchInitError(rt, allocator, &options, "InvalidHeaders", "header name contains newline");
            }
            if (std.mem.indexOfAny(u8, header_str, "\r\n") != null) {
                return fetchInitError(rt, allocator, &options, "InvalidHeaders", "header value contains newline");
            }
            try options.headers.append(allocator, .{ .name = key_name, .value = header_str });
        }
    }

    if (hasCredentialOption(rt, init, pool)) {
        return fetchInitError(rt, allocator, &options, "CredentialRefused", "path_unsupported");
    }

    return .{ .ok = options };
}

/// Report whether a fetch init requests removed credential authority.
fn hasCredentialOption(rt: View, init: *zq.JSObject, pool: *const zq.HiddenClassPool) bool {
    return getDynamicProperty(rt.ctx, init, pool, "credential") != null;
}

fn credentialOptionRefusal(rt: View) !zq.JSValue {
    return createFetchErrorResponse(rt, "CredentialRefused", "path_unsupported");
}

/// Keep removed credential authority outside replay wrappers.
/// Those wrappers can return a recorded result without calling the fetch body.
pub fn refuseCredentialOption(rt: View, args: []const zq.JSValue) !?zq.JSValue {
    const pool = rt.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;
    if (fetchInitObject(args)) |init| {
        if (hasCredentialOption(rt, init, pool)) return try credentialOptionRefusal(rt);
    }
    return null;
}

fn fetchInitObject(args: []const zq.JSValue) ?*zq.JSObject {
    if (args.len >= 1 and args[0].isObject()) return args[0].toPtr(zq.JSObject);
    if (args.len >= 2 and args[1].isObject()) return args[1].toPtr(zq.JSObject);
    return null;
}

// Shared outbound-fetch plumbing for the two call sites below: synchronous
// fetchSyncResult and the native HTTP bridge. Both pre-create the connection to apply a
// connect timeout, so they share the same two std.http.Client quirks.

/// std.http.Client loads the CA bundle and stamps client.now lazily inside
/// request(); but because we pre-create the connection, Connection.Tls.create
/// would assert on a null client.now. Bootstrap that TLS state up front. After
/// this, request() sees client.now != null and skips its own rescan, and
/// client.deinit() frees the bundle. No-op for plain HTTP.
fn bootstrapClientTls(client: *std.http.Client, protocol: std.http.Client.Protocol) error{CertificateBundleLoadFailure}!void {
    if (protocol != .tls) return;
    const now = std.Io.Clock.real.now(client.io);
    client.ca_bundle.rescan(client.allocator, client.io, now) catch return error.CertificateBundleLoadFailure;
    client.now = now;
}

/// Read a response body, transparently decoding Content-Encoding and
/// Transfer-Encoding. The plain response.reader() returns raw chunked/compressed
/// bytes, and std.http.Client advertises gzip/deflate by default, so a compressed
/// or chunked body would otherwise reach the caller verbatim (and JSON.parse then
/// yields {}). readerDecompressing handles gzip/deflate/zstd; identity passes
/// through. Pair with `.accept_encoding = .omit` on the request to prefer identity.
fn readResponseBody(response: *std.http.Client.Response, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var body_transfer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var reader = response.readerDecompressing(&body_transfer, &decompress, &decompress_buf);
    // allocRemaining reports StreamTooLong once the limit is *reached*, not just
    // exceeded, so a body of exactly max_bytes would be wrongly rejected. Read
    // one extra byte and enforce the real cap here so exactly-max-bytes succeeds
    // while anything larger still surfaces StreamTooLong (-> 599 ResponseTooLarge).
    const body = try reader.allocRemaining(allocator, std.Io.Limit.limited(max_bytes +| 1));
    if (body.len > max_bytes) {
        allocator.free(body);
        return error.StreamTooLong;
    }
    // std's Content-Length reader reports a peer close before the declared
    // length as a clean EndOfStream, which allocRemaining accepts as the end.
    // A body still owed bytes was not read in full, so it is not a response.
    if (response.request.reader.state == .body_remaining_content_length) {
        allocator.free(body);
        return error.HttpContentLengthTruncated;
    }
    return body;
}

/// The body to send: the handler's, or an empty one for a method that carries
/// a body (POST, PUT, PATCH) when the handler gave none. std's `sendBodiless`
/// asserts that the method has no body, so without this a bodiless POST
/// panics the worker.
fn outboundBody(method: std.http.Method, body: ?[]const u8) ?[]const u8 {
    if (body) |payload| return payload;
    return if (method.requestHasBody()) "" else null;
}

/// The outbound-exchange watchdog. Defined in its own file so the developer
/// CLI can arm the same one without importing this module; see that file for
/// why std cannot bound the exchange itself.
const FetchDeadline = @import("fetch_deadline.zig").FetchDeadline;
const OutboundIo = @import("outbound_io.zig").OutboundIo;

/// The public adapters own validation and serialization. This native exchange
/// owns every transport resource and returns response bytes detached from std's
/// connection buffers.
const ExchangeInput = struct {
    uri: std.Uri,
    host: std.Io.net.HostName,
    method: std.http.Method,
    body: ?[]const u8,
    headers: []const std.http.Header,
    max_response_bytes: usize,
};

const ExchangeFailure = struct {
    code: []const u8 = undefined,
    details: []const u8 = undefined,

    fn set(self: *ExchangeFailure, code: []const u8, details: []const u8) error{OutboundExchangeFailed} {
        self.* = .{ .code = code, .details = details };
        return error.OutboundExchangeFailed;
    }
};

const OwnedExchange = struct {
    head: OwnedResponseHead,
    body: []u8,
    status: u16,
    ok: bool,

    fn deinit(self: *OwnedExchange, allocator: std.mem.Allocator) void {
        self.head.deinit(allocator);
        allocator.free(self.body);
    }
};

fn outboundExchange(rt: View, input: ExchangeInput, failure: *ExchangeFailure) !OwnedExchange {
    const allocator = rt.allocator;
    const backend = rt.backend.?;
    var client = std.http.Client{
        .allocator = allocator,
        .io = backend.io(),
    };
    defer client.deinit();

    const protocol = std.http.Client.Protocol.fromUri(input.uri) orelse {
        return failure.set("InvalidUrl", "unsupported URI scheme");
    };
    bootstrapClientTls(&client, protocol) catch {
        return failure.set("ConnectFailed", "CertificateBundleLoadFailure");
    };
    const port: u16 = input.uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
    var target: ResolvedTarget = .{};
    switch (resolvedScopeDecision(client.io, &rt.ctx.capability_policy, rt.ctx.policy_generation, input.host, port, &target)) {
        .allowed => {},
        .denied => |details| return failure.set("AddressScopeNotAllowed", details),
        .unresolved => |details| return failure.set("ConnectFailed", details),
    }

    // One budget for connect, handshake, and exchange, starting after name
    // resolution. The backend arms the watchdog when the connect succeeds.
    const fetch_timeout_ms = effectiveOutboundTimeoutMs(rt);
    var deadline: FetchDeadline = .{ .timeout_ms = fetch_timeout_ms, .io = client.io };
    backend.beginFetch(&deadline) catch |err| return failure.set("DeadlineUnavailable", @errorName(err));
    // Declared after the client's deinit defer, so the watchdog is joined
    // before the client closes any connection.
    defer backend.endFetch();

    const connection = client.connectTcpOptions(.{
        // Connect to the address that passed, name the destination for TLS.
        .host = target.hostName(),
        .port = port,
        .protocol = protocol,
        .proxied_host = input.host,
        .proxied_port = port,
    }) catch |err| {
        return failure.set(deadline.connectFailCode(err), @errorName(err));
    };
    if (!deadline.isArmed()) {
        client.connection_pool.release(connection, client.io);
        return failure.set("DeadlineUnavailable", "connection has no watchdog");
    }

    var req = client.request(input.method, input.uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
        // Prefer an identity body (see readResponseBody); we decode anyway.
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = input.headers,
    }) catch |err| {
        client.connection_pool.release(connection, client.io);
        return failure.set("RequestInitFailed", @errorName(err));
    };
    defer req.deinit();

    if (outboundBody(input.method, input.body)) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var request_body = req.sendBodyUnflushed(&.{}) catch |err| {
            return failure.set(deadline.failCode("RequestSendFailed"), @errorName(err));
        };
        request_body.writer.writeAll(payload) catch |err| {
            return failure.set(deadline.failCode("RequestSendFailed"), @errorName(err));
        };
        request_body.end() catch |err| {
            return failure.set(deadline.failCode("RequestSendFailed"), @errorName(err));
        };
        req.connection.?.flush() catch |err| {
            return failure.set(deadline.failCode("RequestSendFailed"), @errorName(err));
        };
    } else {
        req.sendBodiless() catch |err| {
            return failure.set(deadline.failCode("RequestSendFailed"), @errorName(err));
        };
    }

    var response = req.receiveHead(&.{}) catch |err|
        return failure.set(deadline.failCode("ResponseHeadFailed"), @errorName(err));
    const status = @backingInt(response.head.status);
    var owned_head = try snapshotResponseHead(allocator, response.head);
    errdefer owned_head.deinit(allocator);

    const response_body = readResponseBody(&response, allocator, input.max_response_bytes) catch |err| switch (err) {
        error.StreamTooLong => return failure.set("ResponseTooLarge", "response exceeded max_response_bytes"),
        else => return failure.set(deadline.failCode("ResponseReadFailed"), @errorName(err)),
    };
    errdefer allocator.free(response_body);

    // A connection-close body terminated by the watchdog's shutdown reads as
    // a clean EOF; reject it instead of returning a truncated response.
    if (deadline.expired()) {
        return failure.set("TimedOut", "exceeded outbound_timeout_ms");
    }

    return .{ .head = owned_head, .body = response_body, .status = status, .ok = response.head.status.class() != .server_error and response.head.status.class() != .client_error };
}

fn fetchSyncResult(rt: View, args: []const zq.JSValue) !zq.JSValue {
    if (!rt.config.enabled) {
        return createFetchErrorResponse(rt, "OutboundHttpDisabled", "set runtime outbound_http_enabled=true");
    }

    const pool = rt.ctx.hidden_class_pool orelse return error.NoHiddenClassPool;

    const parsed = try parseFetchArgs(rt, pool, args);
    const fetch_args = switch (parsed) {
        .ok => |fa| fa,
        .err => |err_val| return err_val,
    };
    defer rt.allocator.free(fetch_args.url);
    const uri = fetch_args.uri;
    const init_obj = fetch_args.init_obj;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = resolveHostSafe(uri, &host_buf) catch {
        return createFetchErrorResponse(rt, "InvalidUrl", "url host is required");
    };

    var options = switch (try parseFetchInitOptions(rt, rt.allocator, pool, init_obj)) {
        .ok => |parsed_options| parsed_options,
        .err => |err_val| return err_val,
    };
    defer options.deinit(rt.allocator);

    var failure: ExchangeFailure = .{};
    var exchange = outboundExchange(rt, .{
        .uri = uri,
        .host = host,
        .method = options.method,
        .body = options.body,
        .headers = options.headers.items,
        .max_response_bytes = options.max_response_bytes,
    }, &failure) catch |err| switch (err) {
        error.OutboundExchangeFailed => return createFetchErrorResponse(rt, failure.code, failure.details),
        else => return err,
    };
    defer exchange.deinit(rt.allocator);

    const created = try createFetchResponse(rt, exchange.status, exchange.head.reason, exchange.body, exchange.head.contentType());
    for (exchange.head.headers.items) |header| {
        const key_atom = try getHeaderAtom(rt.ctx, header.name);
        const value_str = try rt.ctx.createString(header.value);
        try rt.ctx.setPropertyChecked(created.headers, key_atom, value_str);
    }

    return created.value;
}

pub fn dispatchFetchModule(rt: View, args: []const zq.JSValue) !zq.JSValue {
    if (rt.config.replay) {
        return fetchModuleReplay(rt);
    }

    return fetchAndRecord(rt, args);
}

fn fetchModuleReplay(rt: View) !zq.JSValue {
    const state = rt.ctx.getModuleState(zq.trace.ReplayState, zq.trace.REPLAY_STATE_SLOT) orelse {
        return createFetchErrorResponse(rt, "ReplayNotConfigured", "fetch replay state is not installed");
    };
    const entry_opt = if (replayNextIs(state, "http", "fetchSync")) blk: {
        const inner = state.nextIO("http", "fetchSync");
        // Traced zttp:fetch records fetchSync first, then the outer module
        // wrapper. Replay executes the module implementation directly, so it
        // must consume both rows to keep the cursor aligned.
        if (replayNextIs(state, "fetch", "fetch")) {
            _ = state.nextIO("fetch", "fetch");
        }
        break :blk inner;
    } else state.nextIO("fetch", "fetch");
    const entry = entry_opt orelse {
        return createFetchErrorResponse(rt, "ReplayMiss", "no recorded zttp:fetch response");
    };

    const status_raw = zq.trace.findJsonIntValue(entry.result_json, "\"status\"") orelse 200;
    const status: u16 = @intCast(@max(100, @min(599, status_raw)));
    const status_text_raw = zq.trace.findJsonStringValue(entry.result_json, "\"statusText\"") orelse "OK";
    const status_text = try zq.trace.unescapeJson(rt.allocator, status_text_raw);
    defer rt.allocator.free(status_text);

    const body_raw = zq.trace.findJsonStringValue(entry.result_json, "\"body\"");
    const body = if (body_raw) |raw|
        try zq.trace.unescapeJson(rt.allocator, raw)
    else
        try rt.allocator.dupe(u8, entry.result_json);
    defer rt.allocator.free(body);

    const headers_json = zq.trace.findJsonObjectValue(entry.result_json, "\"headers\"");
    const content_type_raw = if (headers_json) |headers|
        zq.trace.findJsonStringValue(headers, "\"content-type\"") orelse
            zq.trace.findJsonStringValue(headers, "\"Content-Type\"")
    else
        zq.trace.findJsonStringValue(entry.result_json, "\"contentType\"");
    const content_type_owned: ?[]u8 = if (content_type_raw) |raw|
        try zq.trace.unescapeJson(rt.allocator, raw)
    else
        null;
    defer if (content_type_owned) |content_type| rt.allocator.free(content_type);

    const created = try createFetchResponse(rt, status, status_text, body, content_type_owned);
    if (headers_json) |headers| {
        try copyRecordedFetchHeaders(rt, created.headers, headers);
    }
    return created.value;
}

fn replayNextIs(state: *const zq.trace.ReplayState, module_name: []const u8, fn_name: []const u8) bool {
    const cursor: usize = @intCast(state.cursor);
    if (cursor >= state.io_calls.len) return false;
    const entry = state.io_calls[cursor];
    return std.mem.eql(u8, entry.module, module_name) and std.mem.eql(u8, entry.func, fn_name);
}

fn copyRecordedFetchHeaders(rt: View, headers_obj: *zq.JSObject, headers_json: []const u8) !void {
    var pos = skipJsonWhitespace(headers_json, 0);
    if (pos >= headers_json.len or headers_json[pos] != '{') return;
    pos += 1;

    while (pos < headers_json.len) {
        pos = skipJsonWhitespace(headers_json, pos);
        if (pos >= headers_json.len or headers_json[pos] == '}') return;
        if (headers_json[pos] != '"') return;

        const key_raw = jsonStringSlice(headers_json, pos) orelse return;
        pos = key_raw.end;
        pos = skipJsonWhitespace(headers_json, pos);
        if (pos >= headers_json.len or headers_json[pos] != ':') return;
        pos += 1;
        pos = skipJsonWhitespace(headers_json, pos);
        if (pos >= headers_json.len or headers_json[pos] != '"') return;

        const value_raw = jsonStringSlice(headers_json, pos) orelse return;
        pos = value_raw.end;

        const key = try zq.trace.unescapeJson(rt.allocator, key_raw.data);
        defer rt.allocator.free(key);
        const value = try zq.trace.unescapeJson(rt.allocator, value_raw.data);
        defer rt.allocator.free(value);

        const key_atom = try getHeaderAtom(rt.ctx, key);
        const value_str = try rt.ctx.createString(value);
        try rt.ctx.setPropertyChecked(headers_obj, key_atom, value_str);

        pos = skipJsonWhitespace(headers_json, pos);
        if (pos < headers_json.len and headers_json[pos] == ',') {
            pos += 1;
            continue;
        }
        if (pos < headers_json.len and headers_json[pos] == '}') return;
    }
}

const JsonStringSlice = struct {
    data: []const u8,
    end: usize,
};

fn jsonStringSlice(json: []const u8, start: usize) ?JsonStringSlice {
    if (start >= json.len or json[start] != '"') return null;
    var pos = start + 1;
    const data_start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (json[pos] == '"') {
            return .{ .data = json[data_start..pos], .end = pos + 1 };
        }
    }
    return null;
}

fn skipJsonWhitespace(json: []const u8, start: usize) usize {
    var pos = start;
    while (pos < json.len and switch (json[pos]) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    }) : (pos += 1) {}
    return pos;
}

fn appendEncodedJsValue(rt: View, buf: *std.ArrayList(u8), val: zq.JSValue) !bool {
    if (getStringData(val)) |text| {
        try appendPercentEncoded(rt, buf, text);
        return true;
    }
    if (val.isInt()) {
        var num_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&num_buf, "{d}", .{val.getInt()}) catch return false;
        try appendPercentEncoded(rt, buf, text);
        return true;
    }
    if (val.isBool()) {
        try appendPercentEncoded(rt, buf, if (val.getBool()) "true" else "false");
        return true;
    }
    if (val.isFloat()) {
        var num_buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&num_buf, "{d}", .{val.getFloat64()}) catch return false;
        try appendPercentEncoded(rt, buf, text);
        return true;
    }
    return false;
}

fn appendPercentEncoded(rt: View, buf: *std.ArrayList(u8), input: []const u8) !void {
    return appendPercentEncodedInto(rt.allocator, buf, input);
}

pub fn appendPercentEncodedInto(allocator: std.mem.Allocator, buf: anytype, input: []const u8) !void {
    for (input) |byte| {
        if (isUrlUnreserved(byte)) {
            try buf.append(allocator, byte);
            continue;
        }

        try buf.append(allocator, '%');
        const hex = std.fmt.bytesToHex([_]u8{byte}, .upper);
        try buf.appendSlice(allocator, &hex);
    }
}

fn isUrlUnreserved(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '_' or
        byte == '.' or
        byte == '~';
}

pub fn httpRequest(rt: View, args: []const zq.JSValue) !zq.JSValue {
    const out = httpRequestResultJsonAlloc(rt, args) catch |err| {
        const fallback = try httpRequestErrorJsonAlloc(rt.allocator, "InternalError", @errorName(err));
        defer rt.allocator.free(fallback);
        return rt.ctx.createString(fallback);
    };
    defer rt.allocator.free(out);
    return rt.ctx.createString(out);
}

fn httpRequestResultJsonAlloc(rt: View, args: []const zq.JSValue) ![]u8 {
    const a = rt.allocator;
    if (!rt.config.enabled) {
        return try httpRequestErrorJsonAlloc(a, "OutboundHttpDisabled", "set runtime outbound_http_enabled=true");
    }
    if (args.len == 0 or !args[0].isString()) {
        return try httpRequestErrorJsonAlloc(a, "InvalidArgs", "expected one JSON string argument");
    }

    const input_json = args[0].toPtr(zq.JSString).data();
    var parsed = std.json.parseFromSlice(std.json.Value, a, input_json, .{}) catch {
        return try httpRequestErrorJsonAlloc(a, "InvalidJson", "failed to parse request JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try httpRequestErrorJsonAlloc(a, "InvalidJson", "request JSON must be an object");
    }
    const obj = parsed.value.object;

    // The runtime refuses the removed credential option before sending.
    if (obj.get("credential") != null) {
        return try httpRequestErrorJsonAlloc(a, "CredentialRefused", "path_unsupported");
    }

    const url_v = obj.get("url") orelse {
        return try httpRequestErrorJsonAlloc(a, "InvalidUrl", "missing url field");
    };
    if (url_v != .string or url_v.string.len == 0) {
        return try httpRequestErrorJsonAlloc(a, "InvalidUrl", "url must be a non-empty string");
    }
    const uri = std.Uri.parse(url_v.string) catch {
        return try httpRequestErrorJsonAlloc(a, "InvalidUrl", "url parse failed");
    };

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = resolveHostSafe(uri, &host_buf) catch {
        return try httpRequestErrorJsonAlloc(a, "InvalidUrl", "url host is required");
    };
    if (outboundEndpointViolation(rt, url_v.string, host.bytes)) |details| {
        return try httpRequestErrorJsonAlloc(a, "HostNotAllowed", details);
    }

    const method = blk: {
        if (obj.get("method")) |method_v| {
            if (method_v != .string) {
                return try httpRequestErrorJsonAlloc(a, "InvalidMethod", "method must be string");
            }
            break :blk parseHttpMethod(method_v.string) orelse {
                return try httpRequestErrorJsonAlloc(a, "InvalidMethod", method_v.string);
            };
        }
        break :blk std.http.Method.GET;
    };

    const body: ?[]const u8 = if (obj.get("body")) |body_v| switch (body_v) {
        .null => null,
        .string => |s| s,
        else => return try httpRequestErrorJsonAlloc(a, "InvalidBody", "body must be string|null"),
    } else null;

    const max_response_bytes = blk: {
        const cfg_max = @max(@as(usize, 1), rt.config.max_response_bytes);
        if (obj.get("max_response_bytes")) |max_v| switch (max_v) {
            .integer => |i| {
                const req_max = std.math.cast(usize, i) orelse {
                    return try httpRequestErrorJsonAlloc(a, "InvalidMaxResponseBytes", "max_response_bytes out of range");
                };
                break :blk @min(cfg_max, @max(@as(usize, 1), req_max));
            },
            else => return try httpRequestErrorJsonAlloc(a, "InvalidMaxResponseBytes", "max_response_bytes must be integer"),
        };
        break :blk cfg_max;
    };

    var headers = std.array_list.Managed(std.http.Header).init(a);
    defer headers.deinit();

    if (obj.get("headers")) |headers_v| {
        if (headers_v != .object) {
            return try httpRequestErrorJsonAlloc(a, "InvalidHeaders", "headers must be object<string,string>");
        }
        var it = headers_v.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) {
                return try httpRequestErrorJsonAlloc(a, "InvalidHeaders", "header values must be strings");
            }
            // The parsed JSON outlives the synchronous exchange and request
            // teardown, so these slices need no second owner.
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.string;
            if (name.len == 0) return try httpRequestErrorJsonAlloc(a, "InvalidHeaders", "header name must be non-empty");
            if (std.mem.indexOfAny(u8, name, "\r\n") != null) return try httpRequestErrorJsonAlloc(a, "InvalidHeaders", "header name contains newline");
            if (std.mem.indexOfAny(u8, value, "\r\n") != null) return try httpRequestErrorJsonAlloc(a, "InvalidHeaders", "header value contains newline");

            try headers.append(.{ .name = name, .value = value });
        }
    }

    var failure: ExchangeFailure = .{};
    var exchange = outboundExchange(rt, .{
        .uri = uri,
        .host = host,
        .method = method,
        .body = body,
        .headers = headers.items,
        .max_response_bytes = max_response_bytes,
    }, &failure) catch |err| switch (err) {
        error.OutboundExchangeFailed => return httpRequestErrorJsonAlloc(a, failure.code, failure.details),
        else => return err,
    };
    defer exchange.deinit(a);

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var stream: std.json.Stringify = .{ .writer = &aw.writer };
    try stream.beginObject();
    try stream.objectField("ok");
    try stream.write(exchange.ok);
    try stream.objectField("status");
    try stream.write(exchange.status);
    try stream.objectField("reason");
    try stream.write(exchange.head.reason);
    if (exchange.head.contentType()) |ct| {
        try stream.objectField("content_type");
        try stream.write(ct);
    }
    try stream.objectField("body");
    try stream.write(exchange.body);
    try stream.endObject();
    return try aw.toOwnedSlice();
}

fn parseHttpMethod(raw: []const u8) ?std.http.Method {
    if (ascii.eqlIgnoreCase(raw, "GET")) return .GET;
    if (ascii.eqlIgnoreCase(raw, "POST")) return .POST;
    if (ascii.eqlIgnoreCase(raw, "PUT")) return .PUT;
    if (ascii.eqlIgnoreCase(raw, "PATCH")) return .PATCH;
    if (ascii.eqlIgnoreCase(raw, "DELETE")) return .DELETE;
    if (ascii.eqlIgnoreCase(raw, "HEAD")) return .HEAD;
    if (ascii.eqlIgnoreCase(raw, "OPTIONS")) return .OPTIONS;
    return null;
}

pub fn httpRequestErrorJsonAlloc(a: std.mem.Allocator, err_code: []const u8, details: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var stream: std.json.Stringify = .{ .writer = &aw.writer };
    try stream.beginObject();
    try stream.objectField("ok");
    try stream.write(false);
    try stream.objectField("error");
    try stream.write(err_code);
    try stream.objectField("details");
    try stream.write(details);
    try stream.endObject();
    return try aw.toOwnedSlice();
}

// HTTP helpers and context-policy checks. Handler integration lives in
// zruntime_tests.zig. These fixtures require no runtime-owner dependency.

const testing = std.testing;

test "JSON HTTP header refusal releases parsed headers under allocation failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fixture_allocator = arena.allocator();
    var gc = try zq.GC.init(fixture_allocator, .{});
    defer gc.deinit();
    const ctx = try zq.Context.init(fixture_allocator, &gc, .{});
    defer ctx.deinit();
    var state: HttpState = .{};
    defer state.deinit(fixture_allocator);
    const rt = View{ .allocator = fixture_allocator, .ctx = ctx, .state = &state, .config = .{ .enabled = true }, .backend = null };
    rt.ctx.capability_policy = .{ .egress = .{ .enabled = true, .values = &.{"http://127.0.0.1:1"} } };

    const Probe = struct {
        fn run(allocator: std.mem.Allocator, runtime: View, input: zq.JSValue, expected: []const u8) !void {
            var view = runtime;
            view.allocator = allocator;
            const result = httpRequestResultJsonAlloc(view, &.{input}) catch |err| switch (err) {
                // JSON serialization exposes allocator exhaustion as a writer
                // failure; keep the allocation-failure harness informed.
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer allocator.free(result);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
            defer parsed.deinit();
            try testing.expectEqualStrings("InvalidHeaders", parsed.value.object.get("error").?.string);
            try testing.expectEqualStrings(expected, parsed.value.object.get("details").?.string);
        }
    };
    const cases = .{
        .{ "{\"x-first\":\"kept\",\"\":\"invalid\"}", "header name must be non-empty" },
        .{ "{\"x-first\":\"kept\",\"bad\\rname\":\"invalid\"}", "header name contains newline" },
        .{ "{\"x-first\":\"kept\",\"x-last\":\"bad\\nvalue\"}", "header value contains newline" },
    };
    inline for (cases) |case| {
        const input = try rt.ctx.createString("{\"url\":\"http://127.0.0.1:1\",\"headers\":" ++ case[0] ++ "}");
        var no_resize = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        try testing.checkAllAllocationFailures(no_resize.allocator(), Probe.run, .{ rt, input, case[1] });
    }
}

test "header splitting copies every pair and reports the count" {
    const Hdr = struct { key: []const u8, value: []const u8 };
    var names: [64][]const u8 = undefined;
    var values: [64][]const u8 = undefined;

    const headers = [_]Hdr{
        .{ .key = "content-type", .value = "application/json" },
        .{ .key = "x-trace", .value = "abc" },
    };
    const n = splitHeaderKV(&headers, &names, &values);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("content-type", names[0]);
    try testing.expectEqualStrings("application/json", values[0]);
    try testing.expectEqualStrings("x-trace", names[1]);
    try testing.expectEqualStrings("abc", values[1]);
}

test "header splitting is empty-safe and caps at the buffer size" {
    const Hdr = struct { key: []const u8, value: []const u8 };
    var names: [64][]const u8 = undefined;
    var values: [64][]const u8 = undefined;

    const empty: []const Hdr = &.{};
    try testing.expectEqual(@as(usize, 0), splitHeaderKV(empty, &names, &values));

    // 70 pairs into a 64-slot buffer: the cap must hold, or this writes past the
    // caller's fixed arrays.
    var many: [70]Hdr = undefined;
    for (&many, 0..) |*h, i| {
        _ = i;
        h.* = .{ .key = "k", .value = "v" };
    }
    try testing.expectEqual(@as(usize, 64), splitHeaderKV(&many, &names, &values));
}

test "host resolution accepts a plain host and rejects a missing one" {
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;

    // A normal URL resolves. The exact accessor for the resolved name is not
    // asserted here; the behavior that matters is that this succeeds and the
    // hostless case below does not.
    const ok = try std.Uri.parse("https://example.com/path");
    _ = try resolveHostSafe(ok, &buf);

    // A URI with no host must surface an error rather than resolving to
    // something empty that later reads as "any host".
    const no_host = try std.Uri.parse("file:///tmp/x");
    try testing.expectError(error.UriMissingHost, resolveHostSafe(no_host, &buf));
}

test "host resolution preserves IPv6 literals and refuses oversized encoded hosts" {
    var buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const uri = try std.Uri.parse("http://[::1]:8080/");
    try testing.expectEqualStrings("[::1]", (try resolveHostSafe(uri, &buffer)).bytes);
    const encoded: [300]u8 = @bitCast(@as([100][3]u8, @splat("%41".*)));
    const overlong: std.Uri = .{ .scheme = "https", .host = .{ .percent_encoded = &encoded } };
    try testing.expectError(error.UriMissingHost, resolveHostSafe(overlong, &buffer));
}

test "the egress allowlist rejects a host it does not name" {
    // The HTTP view carries the operator host restriction independently of the host runtime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var gc = try zq.GC.init(allocator, .{});
    defer gc.deinit();
    const ctx = try zq.Context.init(allocator, &gc, .{});
    defer ctx.deinit();
    var state: HttpState = .{};
    defer state.deinit(allocator);
    const rt = View{ .allocator = allocator, .ctx = ctx, .state = &state, .config = .{ .allow_host = "api.example.com" }, .backend = null };

    // Exact match passes the allowlist check. Whether the capability policy also
    // allows it is a separate gate, so only assert the allowlist verdict here.
    const violation = outboundEndpointViolation(rt, "https://evil.example.com/x", "evil.example.com");
    try testing.expect(violation != null);
    try testing.expectEqualStrings("api.example.com", violation.?);
}

test "the egress allowlist is case-insensitive on the host" {
    // DNS is case-insensitive, so "API.Example.com" is the same host. Treating it
    // as a mismatch would break legitimate callers; treating a DIFFERENT host as
    // a match would be a hole. This pins the first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var gc = try zq.GC.init(allocator, .{});
    defer gc.deinit();
    const ctx = try zq.Context.init(allocator, &gc, .{});
    defer ctx.deinit();
    var state: HttpState = .{};
    defer state.deinit(allocator);
    const rt = View{ .allocator = allocator, .ctx = ctx, .state = &state, .config = .{ .allow_host = "api.example.com" }, .backend = null };

    // Not the allowlist's complaint: any violation here comes from the
    // capability policy, never from a case difference.
    if (outboundEndpointViolation(rt, "https://API.Example.COM/x", "API.Example.COM")) |reason| {
        try testing.expectEqualStrings("capability policy", reason);
    }
}

test "the endpoint decides, not the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var gc = try zq.GC.init(allocator, .{});
    defer gc.deinit();
    const ctx = try zq.Context.init(allocator, &gc, .{});
    defer ctx.deinit();
    var state: HttpState = .{};
    defer state.deinit(allocator);
    const rt = View{ .allocator = allocator, .ctx = ctx, .state = &state, .config = .{}, .backend = null };

    const allowed = [_][]const u8{"https://api.example.com:443"};
    rt.ctx.capability_policy = .{ .egress = .{ .enabled = true, .values = &allowed } };

    // The endpoint the policy names, written three ways that canonicalize to it.
    try testing.expect(outboundEndpointViolation(rt, "https://api.example.com/v1?x=1", "api.example.com") == null);
    try testing.expect(outboundEndpointViolation(rt, "https://API.Example.COM.", "API.Example.COM.") == null);
    try testing.expect(outboundEndpointViolation(rt, "https://api.example.com:443/", "api.example.com") == null);

    // Same host, other scheme or port: another server, and denied.
    try testing.expect(outboundEndpointViolation(rt, "http://api.example.com", "api.example.com") != null);
    try testing.expect(outboundEndpointViolation(rt, "https://api.example.com:8443", "api.example.com") != null);

    // A URL the rule cannot canonicalize is refused rather than connected to,
    // and userinfo is the case a host-only check reads as the allowed host.
    const refused = outboundEndpointViolation(rt, "https://api.example.com@evil.example", "evil.example") orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("url names no endpoint this policy can decide", refused);
}
