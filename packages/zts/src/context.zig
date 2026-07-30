//! JavaScript execution context
//!
//! Thread-local context with stack, atoms, and global state.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const gc = @import("gc.zig");
const heap = @import("heap.zig");
const object = @import("object.zig");
const arena_mod = @import("arena.zig");
const string = @import("string.zig");
const interp_util = @import("interpreter/util.zig");
const cmp = @import("interpreter/cmp.zig");
const builtins = @import("builtins/root.zig");
const bytecode = @import("bytecode.zig");
const handler_policy = @import("handler_policy.zig");
const modules = @import("modules/root.zig");

pub const cost_meter = @import("cost_meter.zig");

/// Enhanced JIT metrics for monitoring and tuning compilation behavior
/// Context configuration
pub const ContextConfig = struct {
    stack_size: usize = 1024 * 1024, // 1MB value stack
    call_stack_size: usize = 1024, // Max call depth
    init_globals: bool = true, // Initialize global object
    use_http_shape_cache: bool = true, // Prebuild HTTP Request/Response shapes
    use_http_string_cache: bool = true, // Cache common HTTP strings
};

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

/// Cached strings for small integers (0-999) to avoid repeated allocations
pub const SmallIntStringCache = struct {
    /// Cached string representations for integers 0-999
    strings: [1000]*string.JSString,

    pub fn init(allocator: std.mem.Allocator) !SmallIntStringCache {
        var cache: SmallIntStringCache = undefined;
        var initialized: usize = 0;
        errdefer {
            for (cache.strings[0..initialized]) |str| {
                string.freeString(allocator, str);
            }
        }

        var buf: [4]u8 = undefined;
        for (0..1000) |i| {
            const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            cache.strings[i] = try string.createString(allocator, slice);
            initialized += 1;
        }
        return cache;
    }

    pub fn deinit(self: *const SmallIntStringCache, allocator: std.mem.Allocator) void {
        for (self.strings) |str| {
            string.freeString(allocator, str);
        }
    }

    /// Get cached string for integer, or null if out of range
    pub inline fn get(self: *const SmallIntStringCache, n: i32) ?*string.JSString {
        if (n >= 0 and n < 1000) {
            return self.strings[@intCast(n)];
        }
        return null;
    }
};

/// Call frame on the call stack
pub const CallFrame = struct {
    return_pc: usize,
    return_sp: usize,
    return_fp: usize,
    func: value.JSValue,
    this: value.JSValue,
};

/// Maximum number of virtual module state slots.
/// Sized to accommodate all built-in and extension module state slots.
pub const MAX_MODULE_STATE_SLOTS = 16;

/// Per-runtime state entry for a virtual module.
/// Modules that need persistent state (caches, registries) store an opaque
/// pointer here, along with a cleanup function called during Context.deinit.
pub const ModuleStateEntry = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const SdkPathAllowList = struct {
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *SdkPathAllowList, allocator: std.mem.Allocator) void {
        for (self.values.items) |item| allocator.free(item);
        self.values.deinit(allocator);
    }

    pub fn appendUnique(self: *SdkPathAllowList, allocator: std.mem.Allocator, canonical_path: []const u8) !void {
        if (self.contains(canonical_path)) return;
        try self.values.append(allocator, try allocator.dupe(u8, canonical_path));
    }

    pub fn contains(self: *const SdkPathAllowList, canonical_path: []const u8) bool {
        for (self.values.items) |item| {
            if (std.mem.eql(u8, item, canonical_path)) return true;
        }
        return false;
    }
};

/// JavaScript execution context
pub const Context = struct {
    /// Allocator for context-owned memory
    allocator: std.mem.Allocator,
    /// Garbage collector
    gc_state: *gc.GC,
    /// Value stack
    stack: []value.JSValue,
    /// Stack pointer (grows up)
    sp: usize,
    /// Frame pointer
    fp: usize,
    /// Call stack
    call_stack: []CallFrame,
    /// Call stack depth
    call_depth: usize,
    /// Global object
    global: value.JSValue,
    /// Global object (as JSObject pointer for fast access)
    global_obj: ?*object.JSObject,
    /// Index-based hidden class pool with SoA layout
    hidden_class_pool: ?*object.HiddenClassPool,
    /// Root class index in the pool
    root_class_idx: object.HiddenClassIndex,
    /// Built-in prototypes
    array_prototype: ?*object.JSObject,
    string_prototype: ?*object.JSObject,
    object_prototype: ?*object.JSObject,
    function_prototype: ?*object.JSObject,
    result_prototype: ?*object.JSObject,
    /// Atom table for dynamic atoms
    atoms: AtomTable,
    /// Exception value (if any)
    exception: value.JSValue,
    /// Configuration
    config: ContextConfig,
    /// Optional hybrid allocator for request-scoped allocation
    /// When set, ephemeral allocations use arena, persistent use standard allocator
    hybrid: ?*arena_mod.HybridAllocator,
    /// Whether to enforce arena escape checking (default true for HTTP handlers)
    /// Set to false for scripts/benchmarks where arena lifetime matches script lifetime
    enforce_arena_escape: bool = true,
    /// Reusable buffer for JSON serialization to reduce allocations
    json_writer: std.Io.Writer.Allocating,
    /// Reusable buffer for JSX renderToString to reduce allocations
    render_writer: std.Io.Writer.Allocating,
    /// JIT compilation metrics (compiled out in ReleaseFast)
    /// Interpreter pointer for JIT IC fast path access
    /// Set before JIT code execution, null otherwise
    /// Allows JIT-compiled code to access the interpreter's PIC cache directly
    /// Builtin objects registered during initialization (Math, JSON, etc.)
    /// Tracked for proper cleanup in deinit
    builtin_objects: std.ArrayList(*object.JSObject),
    /// Bytecode functions created by make_function/make_async/make_closure.
    /// Owns nested FunctionBytecode payloads (codegen does not free these;
    /// see CodeGen.freeOwnedConstantPayloads contract).
    bytecode_functions: std.ArrayList(*object.JSObject),
    /// Owns heap-allocated script roots loaded from serialized bytecode. Their
    /// nested functions can also be reachable through bytecode_functions;
    /// cached_bytecode marks those function objects as borrowers at teardown.
    bytecode_roots: std.ArrayList(*bytecode.FunctionBytecode),
    /// Every bytecode node reachable from bytecode_roots. Populated before a
    /// deserialized root transfers ownership so cached function objects can be
    /// identified during teardown without allocating.
    cached_bytecode: object.JSObject.FunctionBytecodeSeen,
    /// Cached HTTP shapes for fast Request/Response creation
    http_shapes: ?HttpShapeCache,
    /// Cached vnode shape for fast JSX virtual DOM node creation
    vnode_shape: ?VnodeShape,
    /// Cached HTTP strings and atoms for common values
    http_strings: ?HttpStringCache,
    /// Cached strings for small integers (0-99) to avoid repeated allocations
    small_int_cache: SmallIntStringCache,
    /// Pre-built hidden class indices for object literal shapes.
    /// Indexed by shape_idx from bytecode, populated via materializeShapes().
    literal_shapes: std.ArrayList(object.HiddenClassIndex),
    /// Per-module persistent state (caches, registries).
    /// Indexed by module_slots.Slot ordinal. Null when module has no state.
    module_state: [MAX_MODULE_STATE_SLOTS]?ModuleStateEntry,
    /// Embedded capability policy for precompiled handlers.
    capability_policy: handler_policy.RuntimePolicy,
    /// Per-request virtual-module call counters, reset by the runtime after
    /// request accounting has observed them.
    cost_meter: cost_meter.Meter = .{},
    /// Canonical filesystem paths that SDK modules may read. Empty means deny.
    sdk_file_allowlist: SdkPathAllowList,
    /// Canonical SQLite database paths that SDK modules may open. Empty means deny.
    sdk_sqlite_allowlist: SdkPathAllowList,
    /// Cooperative per-request interrupt. Self-set by the deadline check at loop
    /// back-edges; may be set by any thread (atomic) for forced aborts.
    interrupt_requested: std.atomic.Value(bool),
    /// Monotonic deadline in ns for the current request. 0 = no deadline.
    deadline_ns: u64,
    /// Opaque pointer to whatever host object owns this Context, set by whoever
    /// created it. The engine never dereferences it and never frees it.
    ///
    /// It exists so a native callback, which the engine hands a `*Context`, can
    /// reach its own host runtime by an explicit cast instead of a threadlocal.
    /// The host is responsible for the cast being sound: set it to exactly one
    /// type per Context, and clear it before the pointee dies.
    host: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, gc_state: *gc.GC, config: ContextConfig) !*Context {
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);

        const stack = try allocator.alloc(value.JSValue, config.stack_size / @sizeOf(value.JSValue));
        errdefer allocator.free(stack);

        const call_stack = try allocator.alloc(CallFrame, config.call_stack_size);
        errdefer allocator.free(call_stack);

        // Create index-based hidden class pool
        const hidden_class_pool = try object.HiddenClassPool.init(allocator);
        errdefer hidden_class_pool.deinit();

        // Clear global JSON shape cache to avoid stale references from previous contexts
        builtins.clearJsonShapeCache();

        // Create global object using pool-based class
        const global_obj = try object.JSObject.create(allocator, hidden_class_pool.getEmptyClass(), null, hidden_class_pool);
        errdefer global_obj.destroy(allocator);

        // Initialize small integer string cache (0-99)
        const small_int_cache = try SmallIntStringCache.init(allocator);
        errdefer small_int_cache.deinit(allocator);

        ctx.* = .{
            .allocator = allocator,
            .gc_state = gc_state,
            .stack = stack,
            .sp = 0,
            .fp = 0,
            .call_stack = call_stack,
            .call_depth = 0,
            .global = global_obj.toValue(),
            .global_obj = global_obj,
            .hidden_class_pool = hidden_class_pool,
            .root_class_idx = hidden_class_pool.getEmptyClass(),
            .array_prototype = null,
            .string_prototype = null,
            .object_prototype = null,
            .function_prototype = null,
            .result_prototype = null,
            .atoms = AtomTable.init(allocator),
            .exception = value.JSValue.undefined_val,
            .config = config,
            .hybrid = null,
            .enforce_arena_escape = true,
            .json_writer = std.Io.Writer.Allocating.init(allocator),
            .render_writer = std.Io.Writer.Allocating.init(allocator),
            .builtin_objects = .empty,
            .bytecode_functions = .empty,
            .bytecode_roots = .empty,
            .cached_bytecode = .empty,
            .http_shapes = null,
            .vnode_shape = null,
            .http_strings = null,
            .small_int_cache = small_int_cache,
            .literal_shapes = .empty,
            .module_state = .{null} ** MAX_MODULE_STATE_SLOTS,
            .capability_policy = .{},
            .cost_meter = .{},
            .sdk_file_allowlist = .{},
            .sdk_sqlite_allowlist = .{},
            .interrupt_requested = std.atomic.Value(bool).init(false),
            .deadline_ns = 0,
            .host = null,
        };
        errdefer {
            ctx.literal_shapes.deinit(allocator);
            ctx.cached_bytecode.deinit(allocator);
            ctx.bytecode_roots.deinit(allocator);
            ctx.bytecode_functions.deinit(allocator);
            ctx.builtin_objects.deinit(allocator);
            ctx.sdk_sqlite_allowlist.deinit(allocator);
            ctx.sdk_file_allowlist.deinit(allocator);
            ctx.render_writer.deinit();
            ctx.json_writer.deinit();
            ctx.atoms.deinit();
        }

        if (config.use_http_shape_cache) {
            try ctx.initHttpShapes();
            try ctx.initVnodeShape();
        }
        if (config.use_http_string_cache) {
            try ctx.initHttpStrings();
        }

        return ctx;
    }

    /// Set hybrid allocator (called by Runtime when using hybrid allocation)
    /// Also enables hybrid_mode on GC to disable collection
    pub fn setHybridAllocator(self: *Context, hybrid: *arena_mod.HybridAllocator) void {
        self.hybrid = hybrid;
        // Disable GC when hybrid allocator is active - arena handles ephemeral cleanup
        self.gc_state.hybrid_mode = true;
    }

    pub fn createObjectWithClass(self: *Context, class_idx: object.HiddenClassIndex, prototype: ?*object.JSObject) !*object.JSObject {
        if (self.hybrid) |h| {
            return object.JSObject.createWithArena(h.arena, class_idx, prototype, self.hidden_class_pool) orelse return error.OutOfMemory;
        }
        return try object.JSObject.create(self.allocator, class_idx, prototype, self.hidden_class_pool);
    }

    fn initHttpShapes(self: *Context) !void {
        if (self.http_shapes != null) return;
        const pool = self.hidden_class_pool orelse return;

        const status_text_atom = try self.atoms.intern("statusText");
        const content_type_atom = try self.atoms.intern("Content-Type");

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

        self.http_shapes = .{
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

    fn initVnodeShape(self: *Context) !void {
        if (self.vnode_shape != null) return;
        const pool = self.hidden_class_pool orelse return;

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

        self.vnode_shape = .{
            .class_idx = vnode_class,
            .tag_slot = tag_slot,
            .props_slot = props_slot,
            .children_slot = children_slot,
        };
    }

    fn initHttpStrings(self: *Context) !void {
        if (self.http_strings != null) return;

        const status_text_atom = try self.atoms.intern("statusText");
        const content_type_atom = try self.atoms.intern("Content-Type");

        const status_ok = try string.createString(self.allocator, "OK");
        errdefer string.freeString(self.allocator, status_ok);
        const status_created = try string.createString(self.allocator, "Created");
        errdefer string.freeString(self.allocator, status_created);
        const status_no_content = try string.createString(self.allocator, "No Content");
        errdefer string.freeString(self.allocator, status_no_content);
        const status_moved_permanently = try string.createString(self.allocator, "Moved Permanently");
        errdefer string.freeString(self.allocator, status_moved_permanently);
        const status_found = try string.createString(self.allocator, "Found");
        errdefer string.freeString(self.allocator, status_found);
        const status_bad_request = try string.createString(self.allocator, "Bad Request");
        errdefer string.freeString(self.allocator, status_bad_request);
        const status_unauthorized = try string.createString(self.allocator, "Unauthorized");
        errdefer string.freeString(self.allocator, status_unauthorized);
        const status_forbidden = try string.createString(self.allocator, "Forbidden");
        errdefer string.freeString(self.allocator, status_forbidden);
        const status_not_found = try string.createString(self.allocator, "Not Found");
        errdefer string.freeString(self.allocator, status_not_found);
        const status_internal_error = try string.createString(self.allocator, "Internal Server Error");
        errdefer string.freeString(self.allocator, status_internal_error);
        const content_type_json = try string.createString(self.allocator, "application/json");
        errdefer string.freeString(self.allocator, content_type_json);
        const content_type_text = try string.createString(self.allocator, "text/plain; charset=utf-8");
        errdefer string.freeString(self.allocator, content_type_text);
        const content_type_html = try string.createString(self.allocator, "text/html; charset=utf-8");
        errdefer string.freeString(self.allocator, content_type_html);

        // HTTP method strings
        const method_get = try string.createString(self.allocator, "GET");
        errdefer string.freeString(self.allocator, method_get);
        const method_post = try string.createString(self.allocator, "POST");
        errdefer string.freeString(self.allocator, method_post);
        const method_put = try string.createString(self.allocator, "PUT");
        errdefer string.freeString(self.allocator, method_put);
        const method_delete = try string.createString(self.allocator, "DELETE");
        errdefer string.freeString(self.allocator, method_delete);
        const method_patch = try string.createString(self.allocator, "PATCH");
        errdefer string.freeString(self.allocator, method_patch);
        const method_options = try string.createString(self.allocator, "OPTIONS");
        errdefer string.freeString(self.allocator, method_options);
        const method_head = try string.createString(self.allocator, "HEAD");
        errdefer string.freeString(self.allocator, method_head);

        self.http_strings = .{
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

    /// Materialize object literal shapes from bytecode.
    /// Builds hidden class chains for each shape and stores the final class indices.
    /// Called when loading bytecode that uses the new_object_literal opcode.
    pub fn materializeShapes(self: *Context, shapes: []const []const object.Atom) !void {
        const pool = self.hidden_class_pool orelse return error.NoHiddenClassPool;

        try self.literal_shapes.ensureTotalCapacity(self.allocator, shapes.len);

        for (shapes) |shape| {
            var class_idx = pool.getEmptyClass();

            // Build the hidden class chain by adding properties in declaration order
            for (shape) |atom| {
                class_idx = try pool.addProperty(class_idx, atom);
            }

            try self.literal_shapes.append(self.allocator, class_idx);
        }
    }

    /// Get a pre-built hidden class index for an object literal shape.
    /// Returns null if the shape_idx is out of bounds.
    pub fn getLiteralShape(self: *const Context, shape_idx: u16) ?object.HiddenClassIndex {
        if (shape_idx >= self.literal_shapes.items.len) return null;
        return self.literal_shapes.items[shape_idx];
    }

    pub fn getCachedStatusText(self: *const Context, status: u16) ?*string.JSString {
        if (self.http_strings) |cache| {
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
        return null;
    }

    pub fn getCachedContentType(self: *const Context, content_type: []const u8) ?*string.JSString {
        if (self.http_strings) |cache| {
            if (std.mem.eql(u8, content_type, "application/json")) return cache.content_type_json;
            if (std.mem.eql(u8, content_type, "text/plain; charset=utf-8")) return cache.content_type_text;
            if (std.mem.eql(u8, content_type, "text/html; charset=utf-8")) return cache.content_type_html;
        }
        return null;
    }

    /// Get a cached HTTP method string or null if not cached
    pub fn getCachedMethod(self: *const Context, method: []const u8) ?*string.JSString {
        if (self.http_strings) |cache| {
            if (std.mem.eql(u8, method, "GET")) return cache.method_get;
            if (std.mem.eql(u8, method, "POST")) return cache.method_post;
            if (std.mem.eql(u8, method, "PUT")) return cache.method_put;
            if (std.mem.eql(u8, method, "DELETE")) return cache.method_delete;
            if (std.mem.eql(u8, method, "PATCH")) return cache.method_patch;
            if (std.mem.eql(u8, method, "OPTIONS")) return cache.method_options;
            if (std.mem.eql(u8, method, "HEAD")) return cache.method_head;
        }
        return null;
    }

    pub fn clearCompiledCodePointers(self: *Context) usize {
        var evicted: usize = 0;
        for (self.bytecode_roots.items) |func| {
            evicted += self.clearCompiledCodeRecursive(func);
        }
        for (self.bytecode_functions.items) |obj| {
            if (obj.getBytecodeFunctionData()) |data| {
                evicted += self.clearCompiledCodeRecursive(@constCast(data.bytecode));
            }
        }
        return evicted;
    }

    pub fn takeBytecodeRoot(self: *Context, func: *bytecode.FunctionBytecode) !void {
        if (self.cached_bytecode.contains(func)) return;

        const new_node_count = std.math.cast(
            u32,
            self.countUnregisteredCachedBytecode(func),
        ) orelse return error.OutOfMemory;
        try self.bytecode_roots.ensureUnusedCapacity(self.allocator, 1);
        try self.cached_bytecode.ensureUnusedCapacity(self.allocator, new_node_count);

        self.registerCachedBytecodeAssumeCapacity(func);
        self.bytecode_roots.appendAssumeCapacity(func);
    }

    fn countUnregisteredCachedBytecode(self: *const Context, func: *bytecode.FunctionBytecode) usize {
        if (self.cached_bytecode.contains(func)) return 0;

        var count: usize = 1;
        for (func.constants) |constant| {
            if (!constant.isExternPtr()) continue;
            const magic = constant.toExternPtr(u32);
            if (magic.* != bytecode.MAGIC) continue;
            count += self.countUnregisteredCachedBytecode(constant.toExternPtr(bytecode.FunctionBytecode));
        }
        return count;
    }

    fn registerCachedBytecodeAssumeCapacity(self: *Context, func: *bytecode.FunctionBytecode) void {
        if (self.cached_bytecode.contains(func)) return;
        self.cached_bytecode.putAssumeCapacity(func, {});

        for (func.constants) |constant| {
            if (!constant.isExternPtr()) continue;
            const magic = constant.toExternPtr(u32);
            if (magic.* != bytecode.MAGIC) continue;
            self.registerCachedBytecodeAssumeCapacity(constant.toExternPtr(bytecode.FunctionBytecode));
        }
    }

    // ========================================================================
    // Hybrid Allocation Helpers
    // ========================================================================

    /// Allocate ephemeral memory (dies at request end)
    /// Uses arena if hybrid allocator set, otherwise falls back to standard allocator
    pub fn allocEphemeral(self: *Context, size: usize) !*anyopaque {
        if (self.hybrid) |h| {
            return h.alloc(.ephemeral, size) orelse return error.OutOfMemory;
        }
        // Fallback to GC-managed allocation
        return self.gc_state.allocWithGC(size);
    }

    /// Allocate ephemeral typed object
    pub fn createEphemeral(self: *Context, comptime T: type) !*T {
        if (self.hybrid) |h| {
            return h.create(.ephemeral, T) orelse return error.OutOfMemory;
        }
        return self.allocator.create(T);
    }

    /// Allocate persistent memory (lives forever)
    /// Always uses standard allocator
    pub fn allocPersistent(self: *Context, size: usize) !*anyopaque {
        if (self.hybrid) |h| {
            return h.alloc(.persistent, size) orelse return error.OutOfMemory;
        }
        const mem = try self.allocator.alignedAlloc(u8, .@"8", size);
        return @ptrCast(mem.ptr);
    }

    /// Allocate persistent typed object
    pub fn createPersistent(self: *Context, comptime T: type) !*T {
        return self.allocator.create(T);
    }

    /// Create a JS object, using arena when hybrid mode is enabled
    pub fn createObject(self: *Context, prototype: ?*object.JSObject) !*object.JSObject {
        if (self.hybrid) |h| {
            return object.JSObject.createWithArena(h.arena, self.root_class_idx, prototype, self.hidden_class_pool) orelse
                return error.OutOfMemory;
        }
        return try object.JSObject.create(self.allocator, self.root_class_idx, prototype, self.hidden_class_pool);
    }

    /// Create a JS array, using arena when hybrid mode is enabled
    pub fn createArray(self: *Context) !*object.JSObject {
        if (self.hybrid) |h| {
            return object.JSObject.createArrayWithArena(h.arena, self.root_class_idx) orelse
                return error.OutOfMemory;
        }
        return try object.JSObject.createArray(self.allocator, self.root_class_idx);
    }

    /// Create a JS string pointer, using arena when hybrid mode is enabled
    pub fn createStringPtr(self: *Context, s: []const u8) !*string.JSString {
        if (self.hybrid) |h| {
            return string.createStringWithArena(h.arena, s) orelse return error.OutOfMemory;
        }
        return try string.createString(self.allocator, s);
    }

    /// Create a JS string value, using arena when hybrid mode is enabled
    pub fn createString(self: *Context, s: []const u8) !value.JSValue {
        const str = try self.createStringPtr(s);
        return value.JSValue.fromPtr(str);
    }

    /// Create a JS string slice, using arena when hybrid mode is enabled
    pub fn createSlicePtr(self: *Context, parent: *string.JSString, offset: u32, len: u32) !*string.SliceString {
        if (self.hybrid) |h| {
            return string.createSliceWithArena(h.arena, parent, offset, len) orelse return error.OutOfMemory;
        }
        return try string.createSlice(self.allocator, parent, offset, len);
    }

    /// Extract a string slice from a JSValue if it is a string
    pub fn getString(self: *const Context, val: value.JSValue) ?[]const u8 {
        _ = self;
        if (val.isString()) {
            return val.toPtr(string.JSString).data();
        }
        return null;
    }

    /// Check if hybrid allocation is enabled
    pub fn isHybridEnabled(self: *const Context) bool {
        return self.hybrid != null;
    }

    /// Check if a JSValue points to arena-allocated memory
    pub fn isEphemeralValue(self: *const Context, val: value.JSValue) bool {
        if (!val.isPtr()) return false;
        if (self.hybrid) |h| {
            const ptr: *anyopaque = @ptrCast(val.toPtr(u8));
            return h.arena.contains(ptr);
        }
        return false;
    }

    /// Set property with arena escape protection (reject-on-escape)
    /// Escape checking can be disabled via enforce_arena_escape for scripts/benchmarks
    pub fn setPropertyChecked(self: *Context, obj: *object.JSObject, name: object.Atom, val: value.JSValue) !void {
        if (self.enforce_arena_escape and self.hybrid != null and !obj.flags.is_arena and self.isEphemeralValue(val)) {
            self.throwException(value.JSValue.exception_val);
            return error.ArenaObjectEscape;
        }
        const pool = self.hidden_class_pool orelse return error.NoHiddenClassPool;
        // Fail closed: if the remembered-set entry cannot be allocated, do not
        // install a tenured-to-nursery edge that minor GC cannot see.
        self.gc_state.writeBarrier(@ptrCast(obj), val) catch |err| {
            self.throwException(value.JSValue.exception_val);
            return err;
        };
        obj.setProperty(self.allocator, pool, name, val) catch |err| {
            self.throwException(value.JSValue.exception_val);
            return err;
        };
    }

    /// Set array index with arena escape protection (reject-on-escape)
    /// Escape checking can be disabled via enforce_arena_escape for scripts/benchmarks
    pub fn setIndexChecked(self: *Context, obj: *object.JSObject, index: u32, val: value.JSValue) !void {
        if (self.enforce_arena_escape and self.hybrid != null and !obj.flags.is_arena and self.isEphemeralValue(val)) {
            self.throwException(value.JSValue.exception_val);
            return error.ArenaObjectEscape;
        }
        // Same fail-closed barrier as setPropertyChecked.
        self.gc_state.writeBarrier(@ptrCast(obj), val) catch |err| {
            self.throwException(value.JSValue.exception_val);
            return err;
        };
        obj.setIndex(self.allocator, index, val) catch |err| {
            self.throwException(value.JSValue.exception_val);
            return err;
        };
    }

    /// Store a value into a precomputed object slot with the cross-generation
    /// write barrier applied. Fail-closed on barrier OOM and installs an
    /// exception exactly like setPropertyChecked/setIndexChecked, so fast and
    /// slow store paths behave identically on failure (single barrier, no
    /// double-barrier).
    ///
    /// PRECONDITION: the caller has already run the arena-escape check for this
    /// store (the interpreter IC fast path does so before dispatching here, as
    /// does jitPutFieldIC). This helper deliberately does NOT re-run that check,
    /// so it must never be used on an unchecked store path.
    pub fn setSlotBarriered(self: *Context, obj: *object.JSObject, slot: u16, val: value.JSValue) !void {
        self.gc_state.writeBarrier(@ptrCast(obj), val) catch |err| {
            self.throwException(value.JSValue.exception_val);
            return err;
        };
        obj.setSlot(slot, val);
    }

    pub fn deinit(self: *Context) void {
        // Clean up per-module state (caches, registries) before destroying objects
        for (&self.module_state) |*slot| {
            if (slot.*) |entry| {
                entry.deinit_fn(entry.ptr, self.allocator);
                slot.* = null;
            }
        }

        // cached_bytecode is pre-populated before ownership transfer. Reuse it
        // as the seen-set so cached function objects borrow their bytecode and
        // teardown cannot lose an owned cached root to an allocation failure.
        // Source-compiled functions retain the existing tracked destruction.
        for (self.bytecode_functions.items) |obj| {
            obj.destroyFullTracked(self.allocator, &self.cached_bytecode);
        }
        self.bytecode_functions.deinit(self.allocator);

        // Independent deserializations produce disjoint trees. Duplicate root
        // transfers are ignored by takeBytecodeRoot, so each tree is owned and
        // destroyed exactly once here without a seen-set allocation.
        for (self.bytecode_roots.items) |func| {
            object.JSObject.destroyFunctionBytecode(self.allocator, func, null);
        }
        self.bytecode_roots.deinit(self.allocator);
        self.cached_bytecode.deinit(self.allocator);

        // Scrub every tracked builtin root before freeing any root. Builtins form
        // a graph, so freeing in registration order would leave dangling slots.
        if (self.hidden_class_pool) |pool| {
            if (self.array_prototype) |proto| proto.scrubBuiltin(self.allocator, pool);
            if (self.string_prototype) |proto| proto.scrubBuiltin(self.allocator, pool);
            if (self.object_prototype) |proto| proto.scrubBuiltin(self.allocator, pool);
            if (self.function_prototype) |proto| proto.scrubBuiltin(self.allocator, pool);
            if (self.result_prototype) |proto| proto.scrubBuiltin(self.allocator, pool);

            for (self.builtin_objects.items) |obj| {
                obj.scrubBuiltin(self.allocator, pool);
            }

            // All tracked slots are pointer-free; root destruction is now
            // allocation-free and independent of registration order.
            if (self.array_prototype) |proto| proto.destroy(self.allocator);
            if (self.string_prototype) |proto| proto.destroy(self.allocator);
            if (self.object_prototype) |proto| proto.destroy(self.allocator);
            if (self.function_prototype) |proto| proto.destroy(self.allocator);
            if (self.result_prototype) |proto| proto.destroy(self.allocator);

            for (self.builtin_objects.items) |obj| {
                obj.destroy(self.allocator);
            }

            if (self.global_obj) |g| g.destroy(self.allocator);
        }
        self.builtin_objects.deinit(self.allocator);
        if (self.http_strings) |cache| {
            string.freeString(self.allocator, cache.status_ok);
            string.freeString(self.allocator, cache.status_created);
            string.freeString(self.allocator, cache.status_no_content);
            string.freeString(self.allocator, cache.status_moved_permanently);
            string.freeString(self.allocator, cache.status_found);
            string.freeString(self.allocator, cache.status_bad_request);
            string.freeString(self.allocator, cache.status_unauthorized);
            string.freeString(self.allocator, cache.status_forbidden);
            string.freeString(self.allocator, cache.status_not_found);
            string.freeString(self.allocator, cache.status_internal_error);
            string.freeString(self.allocator, cache.content_type_json);
            string.freeString(self.allocator, cache.content_type_text);
            string.freeString(self.allocator, cache.content_type_html);
            string.freeString(self.allocator, cache.method_get);
            string.freeString(self.allocator, cache.method_post);
            string.freeString(self.allocator, cache.method_put);
            string.freeString(self.allocator, cache.method_delete);
            string.freeString(self.allocator, cache.method_patch);
            string.freeString(self.allocator, cache.method_options);
            string.freeString(self.allocator, cache.method_head);
        }
        self.small_int_cache.deinit(self.allocator);
        if (self.hidden_class_pool) |p| p.deinit();

        self.sdk_sqlite_allowlist.deinit(self.allocator);
        self.sdk_file_allowlist.deinit(self.allocator);

        // Clean up object literal shapes
        self.literal_shapes.deinit(self.allocator);

        self.atoms.deinit();
        self.json_writer.deinit();
        self.render_writer.deinit();
        self.allocator.free(self.call_stack);
        self.allocator.free(self.stack);
        self.allocator.destroy(self);
    }

    /// Get per-module state by slot index, cast to the expected type.
    pub fn getModuleState(self: *Context, comptime T: type, slot: usize) ?*T {
        if (slot >= MAX_MODULE_STATE_SLOTS) return null;
        const entry = self.module_state[slot] orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    /// Set per-module state for a slot. The deinit_fn will be called during Context.deinit.
    pub fn setModuleState(self: *Context, slot: usize, ptr: *anyopaque, deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void) void {
        if (slot >= MAX_MODULE_STATE_SLOTS) return;
        self.module_state[slot] = .{ .ptr = ptr, .deinit_fn = deinit_fn };
    }

    pub fn allowSdkFilePathCanonical(self: *Context, canonical_path: []const u8) !void {
        try self.sdk_file_allowlist.appendUnique(self.allocator, canonical_path);
    }

    pub fn allowSdkSqlitePathCanonical(self: *Context, canonical_path: []const u8) !void {
        try self.sdk_sqlite_allowlist.appendUnique(self.allocator, canonical_path);
    }

    pub fn allowsSdkFilePathCanonical(self: *const Context, canonical_path: []const u8) bool {
        return self.sdk_file_allowlist.contains(canonical_path);
    }

    pub fn allowsSdkSqlitePathCanonical(self: *const Context, canonical_path: []const u8) bool {
        return self.sdk_sqlite_allowlist.contains(canonical_path);
    }

    // ========================================================================
    // JIT Support
    // ========================================================================

    /// JIT helper: get element by index
    /// Intern a computed string property key into an Atom (flat/slice borrowed
    /// directly, multi-leaf rope flattened to a temporary). Mirrors the
    /// interpreter's helper so JIT and interpreter agree on `obj[stringKey]`.
    /// Intern a computed string property key into an Atom (flat/slice borrowed
    /// directly, multi-leaf rope flattened to a temporary). Single source of
    /// truth shared by the interpreter dispatch loop and the JIT helpers so
    /// `obj[stringKey]` resolves identically in both tiers.
    pub fn internComputedKey(self: *Context, key_val: value.JSValue) ?object.Atom {
        if (key_val.stringBytes()) |bytes| {
            return self.atoms.intern(bytes) catch null;
        }
        if (key_val.isRope()) {
            const rope = key_val.toPtr(string.RopeNode);
            const flat = rope.flatten(self.allocator) catch return null;
            defer string.freeString(self.allocator, flat);
            return self.atoms.intern(flat.data()) catch null;
        }
        return null;
    }

    pub fn lessThanCtx(self: *Context, a: value.JSValue, b: value.JSValue) bool {
        const o = cmp.compareValuesCtx(a, b, self) orelse return false;
        return o == .lt;
    }

    pub fn lessEqualCtx(self: *Context, a: value.JSValue, b: value.JSValue) bool {
        const o = cmp.compareValuesCtx(a, b, self) orelse return false;
        return o == .lt or o == .eq;
    }

    pub fn greaterThanCtx(self: *Context, a: value.JSValue, b: value.JSValue) bool {
        const o = cmp.compareValuesCtx(a, b, self) orelse return false;
        return o == .gt;
    }

    pub fn greaterEqualCtx(self: *Context, a: value.JSValue, b: value.JSValue) bool {
        const o = cmp.compareValuesCtx(a, b, self) orelse return false;
        return o == .gt or o == .eq;
    }

    // ========================================================================
    // Global Object Access
    // ========================================================================

    /// Get global property by atom
    pub fn getGlobal(self: *Context, atom: object.Atom) ?value.JSValue {
        const pool = self.hidden_class_pool orelse return null;
        if (self.global_obj) |g| {
            return g.getProperty(pool, atom);
        }
        return null;
    }

    /// Set global property by atom
    pub fn setGlobal(self: *Context, atom: object.Atom, val: value.JSValue) !void {
        if (self.global_obj) |g| {
            try self.setPropertyChecked(g, atom, val);
        }
    }

    /// Define global variable (same as set for now)
    pub fn defineGlobal(self: *Context, atom: object.Atom, val: value.JSValue) !void {
        try self.setGlobal(atom, val);
    }

    /// Register a native function on the global object
    pub fn registerGlobalFunction(self: *Context, name: object.Atom, func: object.NativeFn, arg_count: u8) !void {
        const pool = self.hidden_class_pool orelse return error.NoHiddenClassPool;
        const func_obj = try object.JSObject.createNativeFunction(self.allocator, pool, self.root_class_idx, func, name, arg_count);
        try self.setGlobal(name, func_obj.toValue());
    }

    // ========================================================================
    // Index-Based Hidden Class Operations
    // ========================================================================

    /// Get a hidden class with an additional property
    /// Returns the transitioned class index (cached if already exists)
    pub fn getClassWithProperty(self: *Context, from: object.HiddenClassIndex, name: object.Atom) !object.HiddenClassIndex {
        const pool = self.hidden_class_pool orelse return error.NoHiddenClassPool;
        return pool.addProperty(from, name);
    }

    /// Look up property offset in a hidden class
    /// Returns null if property not found
    pub fn getPropertyOffset(self: *const Context, class_idx: object.HiddenClassIndex, name: object.Atom) ?u16 {
        const pool = self.hidden_class_pool orelse return null;
        return pool.findProperty(class_idx, name);
    }

    /// Get property count for a hidden class
    pub fn getClassPropertyCount(self: *const Context, class_idx: object.HiddenClassIndex) u16 {
        const pool = self.hidden_class_pool orelse return 0;
        return pool.getPropertyCount(class_idx);
    }

    // ========================================================================
    // Stack Operations
    // ========================================================================

    /// Push value onto stack
    pub inline fn push(self: *Context, val: value.JSValue) !void {
        if (self.sp >= self.stack.len) {
            return error.StackOverflow;
        }
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    /// Push without bounds check - caller must ensure stack space
    pub inline fn pushUnchecked(self: *Context, val: value.JSValue) void {
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    /// Pop value from stack
    pub inline fn pop(self: *Context) value.JSValue {
        std.debug.assert(self.sp > 0);
        self.sp -= 1;
        return self.stack[self.sp];
    }

    /// Peek at stack top
    pub inline fn peek(self: *Context) value.JSValue {
        std.debug.assert(self.sp > 0);
        return self.stack[self.sp - 1];
    }

    /// Peek at stack offset from top
    pub inline fn peekAt(self: *Context, offset: usize) value.JSValue {
        std.debug.assert(self.sp > offset);
        return self.stack[self.sp - 1 - offset];
    }

    /// Swap top two stack values in place (no pop/push)
    pub inline fn swap2(self: *Context) void {
        std.debug.assert(self.sp >= 2);
        const a = self.stack[self.sp - 1];
        self.stack[self.sp - 1] = self.stack[self.sp - 2];
        self.stack[self.sp - 2] = a;
    }

    /// Rotate top 3 stack values: [a,b,c] -> [b,c,a] (no pop/push)
    pub inline fn rot3(self: *Context) void {
        std.debug.assert(self.sp >= 3);
        const c = self.stack[self.sp - 1];
        const b = self.stack[self.sp - 2];
        const a = self.stack[self.sp - 3];
        self.stack[self.sp - 3] = b;
        self.stack[self.sp - 2] = c;
        self.stack[self.sp - 1] = a;
    }

    /// Push call frame
    pub fn pushFrame(self: *Context, func: value.JSValue, this: value.JSValue, return_pc: usize) !void {
        if (self.call_depth >= self.call_stack.len) {
            return error.CallStackOverflow;
        }
        self.call_stack[self.call_depth] = .{
            .return_pc = return_pc,
            .return_sp = self.sp,
            .return_fp = self.fp,
            .func = func,
            .this = this,
        };
        self.call_depth += 1;
        self.fp = self.sp;
    }

    /// Pop call frame
    pub fn popFrame(self: *Context) ?CallFrame {
        if (self.call_depth == 0) return null;
        self.call_depth -= 1;
        const frame = self.call_stack[self.call_depth];
        self.fp = frame.return_fp;
        return frame;
    }

    /// Set exception
    pub fn throwException(self: *Context, exception: value.JSValue) void {
        self.exception = exception;
    }

    /// Clear exception
    pub fn clearException(self: *Context) void {
        self.exception = value.JSValue.undefined_val;
    }

    /// Check if exception is pending
    pub fn hasException(self: *Context) bool {
        return self.exception.isException() or
            (!self.exception.isUndefined() and !self.exception.isNull());
    }

    // ========================================================================
    // Local Variable Access
    // ========================================================================

    /// Get local variable by index (relative to frame pointer)
    pub inline fn getLocal(self: *Context, idx: usize) value.JSValue {
        return self.stack[self.fp + idx];
    }

    /// Get pointer to local variable slot (for upvalue capture)
    pub inline fn getLocalPtr(self: *Context, idx: usize) *value.JSValue {
        return &self.stack[self.fp + idx];
    }

    /// Set local variable by index
    pub inline fn setLocal(self: *Context, idx: usize, val: value.JSValue) void {
        self.stack[self.fp + idx] = val;
    }

    /// Get argument by index (before frame pointer)
    pub inline fn getArg(self: *Context, idx: usize, arg_count: usize) value.JSValue {
        // Arguments are pushed before the frame, in reverse order
        if (idx >= arg_count) return value.JSValue.undefined_val;
        const frame_base = if (self.call_depth > 0) self.call_stack[self.call_depth - 1].return_sp else 0;
        return self.stack[frame_base + idx];
    }

    /// Get 'this' value for current frame
    pub inline fn getThis(self: *Context) value.JSValue {
        if (self.call_depth == 0) return self.global;
        return self.call_stack[self.call_depth - 1].this;
    }

    /// Ensure stack has at least n slots
    pub inline fn ensureStack(self: *Context, n: usize) !void {
        if (self.sp + n > self.stack.len) {
            return error.StackOverflow;
        }
    }

    /// Get current stack depth from frame pointer
    pub inline fn stackDepth(self: *Context) usize {
        return self.sp - self.fp;
    }

    /// Drop n values from stack
    pub inline fn dropN(self: *Context, n: usize) void {
        std.debug.assert(self.sp >= n);
        self.sp -= n;
    }
};

/// Dynamic atom table with O(1) reverse lookup
pub const AtomTable = struct {
    strings: std.StringHashMap(object.Atom),
    reverse: std.AutoHashMap(object.Atom, []const u8), // O(1) reverse lookup
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AtomTable {
        return .{
            .strings = std.StringHashMap(object.Atom).init(allocator),
            .reverse = std.AutoHashMap(object.Atom, []const u8).init(allocator),
            .next_id = object.Atom.FIRST_DYNAMIC,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AtomTable) void {
        // Free owned key storage from the reverse map. The string-key map uses
        // those same slices for lookup, but the reverse map is the canonical
        // atom->name store we query during runtime.
        var it = self.reverse.valueIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.deinit();
        self.reverse.deinit();
    }

    /// Intern a string and get its atom
    pub fn intern(self: *AtomTable, s: []const u8) !object.Atom {
        if (object.lookupPredefinedAtom(s)) |predef| {
            return predef;
        }
        if (self.strings.get(s)) |existing| {
            return existing;
        }

        // Dynamic atom ids must stay below the reserved hidden-class transition
        // sentinels 0xFFFE/0xFFFF (HiddenClassPool.getOrCreateFunctionClass keys
        // its transition with atom 0xFFFE; http.zig skips atoms >= 0xFFFE as
        // reserved). Fail closed rather than let the 65293rd distinct interned
        // name alias a sentinel and silently corrupt an object's shape layout.
        if (self.next_id >= 0xFFFE) return error.OutOfMemory;
        const atom: object.Atom = @enumFromInt(self.next_id);
        const key = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(key);

        try self.strings.put(key, atom);
        errdefer _ = self.strings.remove(key);

        try self.reverse.put(atom, key);
        self.next_id += 1;

        return atom;
    }

    /// Prune unused atoms during major GC
    /// Takes a set of atoms that are still in use (referenced by live objects)
    pub fn pruneUnused(self: *AtomTable, used_atoms: *const std.AutoHashMap(object.Atom, void)) void {
        // Build list of atoms to remove (can't mutate maps during iteration).
        var atoms_to_remove: std.ArrayList(object.Atom) = .empty;
        defer atoms_to_remove.deinit(self.allocator);

        var it = self.reverse.iterator();
        while (it.next()) |entry| {
            const atom = entry.key_ptr.*;
            // Keep predefined atoms (they're always in use)
            if (atom.isPredefined()) continue;

            // Check if this dynamic atom is still referenced
            if (!used_atoms.contains(atom)) {
                atoms_to_remove.append(self.allocator, atom) catch continue;
            }
        }

        // Remove unreferenced atoms from both maps
        for (atoms_to_remove.items) |atom| {
            const key = self.reverse.get(atom) orelse continue;
            _ = self.strings.remove(key);
            _ = self.reverse.remove(atom);
            self.allocator.free(key);
        }
    }

    /// Reset atom table to initial state (for request isolation)
    pub fn reset(self: *AtomTable) void {
        var it = self.reverse.valueIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.strings.clearRetainingCapacity();
        self.reverse.clearRetainingCapacity();
        self.next_id = object.Atom.FIRST_DYNAMIC;
    }

    /// Get current atom count (for monitoring)
    pub fn count(self: *AtomTable) usize {
        return self.strings.count();
    }

    /// Get string name for an atom - O(1) using reverse lookup map
    pub fn getName(self: *AtomTable, atom: object.Atom) ?[]const u8 {
        // Check predefined atoms first (already O(1) via switch)
        if (atom.isPredefined()) {
            return atom.toPredefinedName();
        }
        // O(1) lookup for dynamic atoms
        return self.reverse.get(atom);
    }
};

test "Context stack operations" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    try ctx.push(value.JSValue.fromInt(42));
    try ctx.push(value.JSValue.true_val);

    try std.testing.expectEqual(value.JSValue.true_val, ctx.pop());
    try std.testing.expectEqual(@as(i32, 42), ctx.pop().getInt());
}

test "AtomTable interning" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    const atom1 = try atoms.intern("hello");
    const atom2 = try atoms.intern("hello");
    const atom3 = try atoms.intern("world");

    try std.testing.expectEqual(atom1, atom2);
    try std.testing.expect(atom1 != atom3);
}

test "Context pushFrame and popFrame" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Push a frame
    try ctx.pushFrame(value.JSValue.undefined_val, value.JSValue.undefined_val, 0);
    try std.testing.expectEqual(@as(usize, 1), ctx.call_depth);

    // Pop the frame
    const frame = ctx.popFrame();
    try std.testing.expect(frame != null);
    try std.testing.expectEqual(@as(usize, 0), ctx.call_depth);
}

test "Context exception handling" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Initially no exception
    try std.testing.expect(!ctx.hasException());

    // Throw exception
    ctx.throwException(value.JSValue.fromInt(42));
    try std.testing.expect(ctx.hasException());

    // Clear exception
    ctx.clearException();
    try std.testing.expect(!ctx.hasException());
}

test "setPropertyChecked fails before mutating when write barrier cannot allocate" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const pool = ctx.hidden_class_pool.?;
    var obj = try object.JSObject.create(allocator, ctx.root_class_idx, null, pool);
    defer obj.destroy(allocator);

    const nursery_ptr = gc_state.allocNursery(64) orelse return error.NurseryAllocFailed;
    const nursery_val = value.JSValue.fromPtr(nursery_ptr);

    gc_state.remembered_set.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    gc_state.remembered_set = gc.RememberedSet.init(failing.allocator());

    try std.testing.expectError(error.OutOfMemory, ctx.setPropertyChecked(obj, .name, nursery_val));
    try std.testing.expect(ctx.hasException());
    try std.testing.expect(!obj.hasOwnProperty(pool, .name));
    try std.testing.expectEqual(@as(usize, 0), gc_state.remembered_set.entries.items.len);
}

test "setIndexChecked fails before mutating when write barrier cannot allocate" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    var arr = try object.JSObject.createArray(allocator, ctx.root_class_idx);
    defer arr.destroy(allocator);

    const nursery_ptr = gc_state.allocNursery(64) orelse return error.NurseryAllocFailed;
    const nursery_val = value.JSValue.fromPtr(nursery_ptr);

    gc_state.remembered_set.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    gc_state.remembered_set = gc.RememberedSet.init(failing.allocator());

    try std.testing.expectError(error.OutOfMemory, ctx.setIndexChecked(arr, 0, nursery_val));
    try std.testing.expect(ctx.hasException());
    try std.testing.expectEqual(@as(u32, 0), arr.getArrayLength());
    try std.testing.expect(arr.getIndex(0) == null);
    try std.testing.expectEqual(@as(usize, 0), gc_state.remembered_set.entries.items.len);
}

test "setSlotBarriered fails before mutating when write barrier cannot allocate" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const pool = ctx.hidden_class_pool.?;
    var obj = try object.JSObject.create(allocator, ctx.root_class_idx, null, pool);
    defer obj.destroy(allocator);

    // obj is heap-allocated (tenured-classified); nursery_val is a young pointer,
    // so the barrier must record a cross-gen edge - which the failing allocator denies.
    const nursery_ptr = gc_state.allocNursery(64) orelse return error.NurseryAllocFailed;
    const nursery_val = value.JSValue.fromPtr(nursery_ptr);

    const slot: u16 = 0;
    const before = obj.inline_slots[slot];

    gc_state.remembered_set.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    gc_state.remembered_set = gc.RememberedSet.init(failing.allocator());

    try std.testing.expectError(error.OutOfMemory, ctx.setSlotBarriered(obj, slot, nursery_val));
    try std.testing.expect(ctx.hasException());
    try std.testing.expectEqual(before.raw, obj.inline_slots[slot].raw);
    try std.testing.expectEqual(@as(usize, 0), gc_state.remembered_set.entries.items.len);
}

test "setSlotBarriered records the cross-gen edge the interpreter fast path relies on" {
    // Regression for the put_field_ic / set_slot UAF: the bare obj.setSlot fast
    // path wrote the slot but never recorded the tenured->nursery edge, so minor
    // GC could not find the young survivor. The interpreter and JIT fast paths now
    // route through this helper; this exercises it directly.
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const pool = ctx.hidden_class_pool.?;
    var holder = try object.JSObject.create(allocator, ctx.root_class_idx, null, pool);
    defer holder.destroy(allocator);

    // holder is heap-allocated (tenured-classified); child is a young nursery value.
    const child = gc_state.allocNursery(64) orelse return error.NurseryAllocFailed;
    try std.testing.expect(!gc_state.isInNursery(@ptrCast(holder)));
    try std.testing.expect(gc_state.isInNursery(child));

    try std.testing.expectEqual(@as(usize, 0), gc_state.remembered_set.entries.items.len);
    try ctx.setSlotBarriered(holder, 1, value.JSValue.fromPtr(child));

    // The store both wrote the slot and recorded the cross-gen edge.
    try std.testing.expectEqual(value.JSValue.fromPtr(child).raw, holder.inline_slots[1].raw);
    try std.testing.expect(gc_state.remembered_set.contains(@ptrCast(holder)));
}

test "Context stack overflow surfaces typed errors" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    // Small caps keep the test fast; the bounds-check logic is identical to
    // the production 1MB value stack / 1024-frame call stack defaults.
    var ctx = try Context.init(allocator, &gc_state, .{
        .stack_size = 256, // 256 bytes / 8-byte JSValue = 32 value slots
        .call_stack_size = 4,
    });
    defer ctx.deinit();

    // Value stack: every slot fills, then push returns StackOverflow rather
    // than writing out of bounds.
    var pushed: usize = 0;
    while (pushed < ctx.stack.len) : (pushed += 1) {
        try ctx.push(value.JSValue.fromInt(@intCast(pushed)));
    }
    try std.testing.expectError(error.StackOverflow, ctx.push(value.JSValue.true_val));

    // Call stack: every frame fills, then pushFrame returns CallStackOverflow
    // (this is the cap that bounds unbounded handler recursion).
    var frames: usize = 0;
    while (frames < ctx.call_stack.len) : (frames += 1) {
        try ctx.pushFrame(value.JSValue.undefined_val, value.JSValue.undefined_val, 0);
    }
    try std.testing.expectError(
        error.CallStackOverflow,
        ctx.pushFrame(value.JSValue.undefined_val, value.JSValue.undefined_val, 0),
    );
}

test "Context global variables" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const atom = try ctx.atoms.intern("myVar");

    // Initially undefined
    try std.testing.expect(ctx.getGlobal(atom) == null);

    // Set global
    try ctx.setGlobal(atom, value.JSValue.fromInt(123));

    // Get global
    const val = ctx.getGlobal(atom);
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i32, 123), val.?.getInt());
}

test "Hybrid rejects arena value to global" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    var req_arena = try arena_mod.Arena.init(allocator, .{ .size = 4096 });
    defer req_arena.deinit();
    var hybrid = arena_mod.HybridAllocator{
        .persistent = allocator,
        .arena = &req_arena,
    };
    ctx.setHybridAllocator(&hybrid);

    const arena_obj = try ctx.createObject(null);
    const atom = try ctx.atoms.intern("ephemeral");

    try std.testing.expectError(error.ArenaObjectEscape, ctx.setGlobal(atom, arena_obj.toValue()));
    try std.testing.expect(ctx.hasException());
}

test "AtomTable getName" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    const atom = try atoms.intern("testName");
    const name = atoms.getName(atom);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("testName", name.?);
}

test "AtomTable count" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    try std.testing.expectEqual(@as(usize, 0), atoms.count());

    _ = try atoms.intern("first");
    try std.testing.expectEqual(@as(usize, 1), atoms.count());

    _ = try atoms.intern("second");
    try std.testing.expectEqual(@as(usize, 2), atoms.count());

    // Interning same string shouldn't increase count
    _ = try atoms.intern("first");
    try std.testing.expectEqual(@as(usize, 2), atoms.count());
}

test "AtomTable reset" {
    const allocator = std.testing.allocator;

    var atoms = AtomTable.init(allocator);
    defer atoms.deinit();

    _ = try atoms.intern("one");
    _ = try atoms.intern("two");
    try std.testing.expectEqual(@as(usize, 2), atoms.count());

    atoms.reset();
    try std.testing.expectEqual(@as(usize, 0), atoms.count());
}

test "Context popFrame on empty returns null" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // No frames pushed
    try std.testing.expect(ctx.popFrame() == null);
}

test "Context index-based hidden class pool" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Pool should be initialized
    try std.testing.expect(ctx.hidden_class_pool != null);

    // Root class index should be the empty class
    try std.testing.expectEqual(object.HiddenClassIndex.empty, ctx.root_class_idx);
    try std.testing.expectEqual(@as(u16, 0), ctx.getClassPropertyCount(ctx.root_class_idx));
}

test "Context getClassWithProperty transitions" {
    const allocator = std.testing.allocator;

    var gc_state = try gc.GC.init(allocator, .{ .nursery_size = 4096 });
    defer gc_state.deinit();

    var ctx = try Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    // Add property 'x' to empty class
    const class_x = try ctx.getClassWithProperty(ctx.root_class_idx, .length);
    try std.testing.expectEqual(@as(u16, 1), ctx.getClassPropertyCount(class_x));

    // Property offset should be 0
    const offset = ctx.getPropertyOffset(class_x, .length);
    try std.testing.expect(offset != null);
    try std.testing.expectEqual(@as(u16, 0), offset.?);

    // Add another property 'y'
    const class_xy = try ctx.getClassWithProperty(class_x, .name);
    try std.testing.expectEqual(@as(u16, 2), ctx.getClassPropertyCount(class_xy));

    // First property should still be at offset 0
    try std.testing.expectEqual(@as(u16, 0), ctx.getPropertyOffset(class_xy, .length).?);
    // Second property at offset 1
    try std.testing.expectEqual(@as(u16, 1), ctx.getPropertyOffset(class_xy, .name).?);
}
