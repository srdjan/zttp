//! HTTP and JSX shape/string caches, owned as one side structure rather than
//! as three optional fields on `Context`.
//!
//! The caches are pure fast-path data: hidden-class shapes for Request,
//! Response, and vnode objects, plus interned status/content-type/method
//! strings. Holding them here keeps `Context` to engine state and gives
//! http.zig, the runtime, and precompile one thing to reach for.
//! `context.HttpShapeCache` and friends stay as re-exports.

const std = @import("std");
const object = @import("object.zig");
const string = @import("string.zig");
const atom_table = @import("atom_table.zig");

pub const HttpRequestShape = struct {
    class_idx: object.HiddenClassIndex,
    method_slot: u16,
    url_slot: u16,
    path_slot: u16,
    query_slot: u16,
    body_slot: u16,
    headers_slot: u16,
};

pub const HttpResponseShape = struct {
    class_idx: object.HiddenClassIndex,
    body_slot: u16,
    status_slot: u16,
    status_text_slot: u16,
    ok_slot: u16,
    headers_slot: u16,
};

pub const HttpHeadersShape = struct {
    class_idx: object.HiddenClassIndex,
    content_type_slot: u16,
    content_length_slot: u16,
    cache_control_slot: u16,
};

pub const HttpRequestHeadersShape = struct {
    class_idx: object.HiddenClassIndex,
    authorization_slot: u16,
    content_type_slot: u16,
    accept_slot: u16,
    host_slot: u16,
    user_agent_slot: u16,
    accept_encoding_slot: u16,
    connection_slot: u16,
};

pub const VnodeShape = struct {
    class_idx: object.HiddenClassIndex,
    tag_slot: u16,
    props_slot: u16,
    children_slot: u16,
};

pub const HttpShapeCache = struct {
    request: HttpRequestShape,
    response: HttpResponseShape,
    response_headers: HttpHeadersShape,
    request_headers: HttpRequestHeadersShape,
};

pub const HttpStringCache = struct {
    status_ok: *string.JSString,
    status_created: *string.JSString,
    status_no_content: *string.JSString,
    status_moved_permanently: *string.JSString,
    status_found: *string.JSString,
    status_bad_request: *string.JSString,
    status_unauthorized: *string.JSString,
    status_forbidden: *string.JSString,
    status_not_found: *string.JSString,
    status_internal_error: *string.JSString,
    content_type_json: *string.JSString,
    content_type_text: *string.JSString,
    content_type_html: *string.JSString,
    // HTTP method strings (common methods to avoid per-request allocation)
    method_get: *string.JSString,
    method_post: *string.JSString,
    method_put: *string.JSString,
    method_delete: *string.JSString,
    method_patch: *string.JSString,
    method_options: *string.JSString,
    method_head: *string.JSString,
    status_text_atom: object.Atom,
    content_type_atom: object.Atom,
};

pub const HttpCache = struct {
    shapes: ?HttpShapeCache = null,
    vnode: ?VnodeShape = null,
    strings: ?HttpStringCache = null,

    pub fn initShapes(self: *HttpCache, pool: *object.HiddenClassPool, atoms: *atom_table.AtomTable) !void {
        if (self.shapes != null) return;

        const status_text_atom = try atoms.intern("statusText");
        const content_type_atom = try atoms.intern("Content-Type");

        const addProp = struct {
            fn add(hc_pool: *object.HiddenClassPool, class_idx: *object.HiddenClassIndex, name: object.Atom) !u16 {
                const next = try hc_pool.addProperty(class_idx.*, name);
                const slot = hc_pool.getPropertyCount(next) - 1;
                class_idx.* = next;
                return slot;
            }
        }.add;

        var req_class = pool.getEmptyClass();
        const method_slot = try addProp(pool, &req_class, .method);
        const url_slot = try addProp(pool, &req_class, .url);
        const path_slot = try addProp(pool, &req_class, .path);
        const query_slot = try addProp(pool, &req_class, .query);
        const body_slot = try addProp(pool, &req_class, .body);
        const headers_slot = try addProp(pool, &req_class, .headers);

        var resp_class = pool.getEmptyClass();
        const resp_body_slot = try addProp(pool, &resp_class, .body);
        const resp_status_slot = try addProp(pool, &resp_class, .status);
        const resp_status_text_slot = try addProp(pool, &resp_class, status_text_atom);
        const resp_ok_slot = try addProp(pool, &resp_class, .ok);
        const resp_headers_slot = try addProp(pool, &resp_class, .headers);

        var resp_headers_class = pool.getEmptyClass();
        const content_type_slot = try addProp(pool, &resp_headers_class, content_type_atom);
        const content_length_slot = try addProp(pool, &resp_headers_class, .@"content-length");
        const cache_control_slot = try addProp(pool, &resp_headers_class, .@"cache-control");

        // Request headers shape for common inbound HTTP headers.
        // This enables direct slot writes in runtime request object creation.
        var req_headers_class = pool.getEmptyClass();
        const req_auth_slot = try addProp(pool, &req_headers_class, .authorization);
        const req_content_type_slot = try addProp(pool, &req_headers_class, content_type_atom);
        const req_accept_slot = try addProp(pool, &req_headers_class, .accept);
        const req_host_slot = try addProp(pool, &req_headers_class, .host);
        const req_user_agent_slot = try addProp(pool, &req_headers_class, .@"user-agent");
        const req_accept_encoding_slot = try addProp(pool, &req_headers_class, .@"accept-encoding");
        const req_connection_slot = try addProp(pool, &req_headers_class, .connection);

        self.shapes = .{
            .request = .{
                .class_idx = req_class,
                .method_slot = method_slot,
                .url_slot = url_slot,
                .path_slot = path_slot,
                .query_slot = query_slot,
                .body_slot = body_slot,
                .headers_slot = headers_slot,
            },
            .response = .{
                .class_idx = resp_class,
                .body_slot = resp_body_slot,
                .status_slot = resp_status_slot,
                .status_text_slot = resp_status_text_slot,
                .ok_slot = resp_ok_slot,
                .headers_slot = resp_headers_slot,
            },
            .response_headers = .{
                .class_idx = resp_headers_class,
                .content_type_slot = content_type_slot,
                .content_length_slot = content_length_slot,
                .cache_control_slot = cache_control_slot,
            },
            .request_headers = .{
                .class_idx = req_headers_class,
                .authorization_slot = req_auth_slot,
                .content_type_slot = req_content_type_slot,
                .accept_slot = req_accept_slot,
                .host_slot = req_host_slot,
                .user_agent_slot = req_user_agent_slot,
                .accept_encoding_slot = req_accept_encoding_slot,
                .connection_slot = req_connection_slot,
            },
        };
    }

    pub fn initVnode(self: *HttpCache, pool: *object.HiddenClassPool) !void {
        if (self.vnode != null) return;

        const addProp = struct {
            fn add(hc_pool: *object.HiddenClassPool, class_idx: *object.HiddenClassIndex, name: object.Atom) !u16 {
                const next = try hc_pool.addProperty(class_idx.*, name);
                const slot = hc_pool.getPropertyCount(next) - 1;
                class_idx.* = next;
                return slot;
            }
        }.add;

        var vnode_class = pool.getEmptyClass();
        const tag_slot = try addProp(pool, &vnode_class, .tag);
        const props_slot = try addProp(pool, &vnode_class, .props);
        const children_slot = try addProp(pool, &vnode_class, .children);

        self.vnode = .{
            .class_idx = vnode_class,
            .tag_slot = tag_slot,
            .props_slot = props_slot,
            .children_slot = children_slot,
        };
    }

    pub fn initStrings(self: *HttpCache, allocator: std.mem.Allocator, atoms: *atom_table.AtomTable) !void {
        if (self.strings != null) return;

        const status_text_atom = try atoms.intern("statusText");
        const content_type_atom = try atoms.intern("Content-Type");

        const status_ok = try string.createString(allocator, "OK");
        errdefer string.freeString(allocator, status_ok);
        const status_created = try string.createString(allocator, "Created");
        errdefer string.freeString(allocator, status_created);
        const status_no_content = try string.createString(allocator, "No Content");
        errdefer string.freeString(allocator, status_no_content);
        const status_moved_permanently = try string.createString(allocator, "Moved Permanently");
        errdefer string.freeString(allocator, status_moved_permanently);
        const status_found = try string.createString(allocator, "Found");
        errdefer string.freeString(allocator, status_found);
        const status_bad_request = try string.createString(allocator, "Bad Request");
        errdefer string.freeString(allocator, status_bad_request);
        const status_unauthorized = try string.createString(allocator, "Unauthorized");
        errdefer string.freeString(allocator, status_unauthorized);
        const status_forbidden = try string.createString(allocator, "Forbidden");
        errdefer string.freeString(allocator, status_forbidden);
        const status_not_found = try string.createString(allocator, "Not Found");
        errdefer string.freeString(allocator, status_not_found);
        const status_internal_error = try string.createString(allocator, "Internal Server Error");
        errdefer string.freeString(allocator, status_internal_error);
        const content_type_json = try string.createString(allocator, "application/json");
        errdefer string.freeString(allocator, content_type_json);
        const content_type_text = try string.createString(allocator, "text/plain; charset=utf-8");
        errdefer string.freeString(allocator, content_type_text);
        const content_type_html = try string.createString(allocator, "text/html; charset=utf-8");
        errdefer string.freeString(allocator, content_type_html);

        // HTTP method strings
        const method_get = try string.createString(allocator, "GET");
        errdefer string.freeString(allocator, method_get);
        const method_post = try string.createString(allocator, "POST");
        errdefer string.freeString(allocator, method_post);
        const method_put = try string.createString(allocator, "PUT");
        errdefer string.freeString(allocator, method_put);
        const method_delete = try string.createString(allocator, "DELETE");
        errdefer string.freeString(allocator, method_delete);
        const method_patch = try string.createString(allocator, "PATCH");
        errdefer string.freeString(allocator, method_patch);
        const method_options = try string.createString(allocator, "OPTIONS");
        errdefer string.freeString(allocator, method_options);
        const method_head = try string.createString(allocator, "HEAD");
        errdefer string.freeString(allocator, method_head);

        self.strings = .{
            .status_ok = status_ok,
            .status_created = status_created,
            .status_no_content = status_no_content,
            .status_moved_permanently = status_moved_permanently,
            .status_found = status_found,
            .status_bad_request = status_bad_request,
            .status_unauthorized = status_unauthorized,
            .status_forbidden = status_forbidden,
            .status_not_found = status_not_found,
            .status_internal_error = status_internal_error,
            .content_type_json = content_type_json,
            .content_type_text = content_type_text,
            .content_type_html = content_type_html,
            .method_get = method_get,
            .method_post = method_post,
            .method_put = method_put,
            .method_delete = method_delete,
            .method_patch = method_patch,
            .method_options = method_options,
            .method_head = method_head,
            .status_text_atom = status_text_atom,
            .content_type_atom = content_type_atom,
        };
    }

    /// Free the owned status/content-type/method strings. Shapes and the vnode
    /// class hold hidden-class indices owned by the pool, so they need no cleanup.
    pub fn deinit(self: *HttpCache, allocator: std.mem.Allocator) void {
        if (self.strings) |cache| {
            string.freeString(allocator, cache.status_ok);
            string.freeString(allocator, cache.status_created);
            string.freeString(allocator, cache.status_no_content);
            string.freeString(allocator, cache.status_moved_permanently);
            string.freeString(allocator, cache.status_found);
            string.freeString(allocator, cache.status_bad_request);
            string.freeString(allocator, cache.status_unauthorized);
            string.freeString(allocator, cache.status_forbidden);
            string.freeString(allocator, cache.status_not_found);
            string.freeString(allocator, cache.status_internal_error);
            string.freeString(allocator, cache.content_type_json);
            string.freeString(allocator, cache.content_type_text);
            string.freeString(allocator, cache.content_type_html);
            string.freeString(allocator, cache.method_get);
            string.freeString(allocator, cache.method_post);
            string.freeString(allocator, cache.method_put);
            string.freeString(allocator, cache.method_delete);
            string.freeString(allocator, cache.method_patch);
            string.freeString(allocator, cache.method_options);
            string.freeString(allocator, cache.method_head);
        }
        self.strings = null;
    }

    pub fn statusText(self: *const HttpCache, status: u16) ?*string.JSString {
        const cache = self.strings orelse return null;
        return switch (status) {
            200 => cache.status_ok,
            201 => cache.status_created,
            204 => cache.status_no_content,
            301 => cache.status_moved_permanently,
            302 => cache.status_found,
            400 => cache.status_bad_request,
            401 => cache.status_unauthorized,
            403 => cache.status_forbidden,
            404 => cache.status_not_found,
            500 => cache.status_internal_error,
            else => null,
        };
    }

    pub fn contentType(self: *const HttpCache, content_type: []const u8) ?*string.JSString {
        const cache = self.strings orelse return null;
        if (std.mem.eql(u8, content_type, "application/json")) return cache.content_type_json;
        if (std.mem.eql(u8, content_type, "text/plain; charset=utf-8")) return cache.content_type_text;
        if (std.mem.eql(u8, content_type, "text/html; charset=utf-8")) return cache.content_type_html;
        return null;
    }

    pub fn method(self: *const HttpCache, name: []const u8) ?*string.JSString {
        const cache = self.strings orelse return null;
        if (std.mem.eql(u8, name, "GET")) return cache.method_get;
        if (std.mem.eql(u8, name, "POST")) return cache.method_post;
        if (std.mem.eql(u8, name, "PUT")) return cache.method_put;
        if (std.mem.eql(u8, name, "DELETE")) return cache.method_delete;
        if (std.mem.eql(u8, name, "PATCH")) return cache.method_patch;
        if (std.mem.eql(u8, name, "OPTIONS")) return cache.method_options;
        if (std.mem.eql(u8, name, "HEAD")) return cache.method_head;
        return null;
    }
};
