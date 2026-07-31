//! JavaScript execution context
//!
//! Thread-local context with stack, atoms, and global state.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const gc = @import("gc.zig");
const heap = @import("heap.zig");
const object = @import("object.zig");
const atom_table_mod = @import("atom_table.zig");
const http_cache_mod = @import("http_cache.zig");
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

/// Cached strings for small integers (0-999) to avoid repeated allocations
/// Re-exports: the HTTP/JSX caches live in http_cache.zig, which the runtime
/// and http.zig import directly. `Context.http` holds the one instance.
pub const HttpRequestShape = http_cache_mod.HttpRequestShape;
pub const HttpResponseShape = http_cache_mod.HttpResponseShape;
pub const HttpHeadersShape = http_cache_mod.HttpHeadersShape;
pub const HttpRequestHeadersShape = http_cache_mod.HttpRequestHeadersShape;
pub const VnodeShape = http_cache_mod.VnodeShape;
pub const HttpShapeCache = http_cache_mod.HttpShapeCache;
pub const HttpStringCache = http_cache_mod.HttpStringCache;
pub const HttpCache = http_cache_mod.HttpCache;

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

/// Host callback for invoking a JS function the engine holds: JSX function
/// components during SSR, and the array higher-order functions. Declared here
/// rather than in `http.zig` because the Context stores it; `http.zig` aliases
/// this name.
///
/// The `ctx` parameter is what makes the callback reentrant: the host recovers
/// its own runtime from it, so a nested dispatch on a different Context cannot
/// disturb the caller.
pub const CallFunctionFn = *const fn (
    ctx: *Context,
    func: *object.JSObject,
    args: []const value.JSValue,
) anyerror!value.JSValue;

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
    /// HTTP/JSX fast-path caches: Request/Response/vnode hidden-class shapes
    /// and interned status, content-type, and method strings.
    http: HttpCache,
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
    /// Callback the host installs so the engine can invoke a JS function it was
    /// handed: JSX function components during SSR, and the array higher-order
    /// functions. Per-Context rather than thread-local, so a nested dispatch on
    /// another Context cannot clear the caller's.
    call_function_callback: ?CallFunctionFn = null,
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
            .http = .{},
            .small_int_cache = small_int_cache,
            .literal_shapes = .empty,
            .module_state = .{null} ** MAX_MODULE_STATE_SLOTS,
            .capability_policy = .{},
            .cost_meter = .{},
            .sdk_file_allowlist = .{},
            .sdk_sqlite_allowlist = .{},
            .interrupt_requested = std.atomic.Value(bool).init(false),
            .deadline_ns = 0,
            .call_function_callback = null,
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

        if (ctx.hidden_class_pool) |pool| {
            if (config.use_http_shape_cache) {
                try ctx.http.initShapes(pool, &ctx.atoms);
                try ctx.http.initVnode(pool);
            }
        }
        if (config.use_http_string_cache) {
            try ctx.http.initStrings(allocator, &ctx.atoms);
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
        return self.http.statusText(status);
    }

    pub fn getCachedContentType(self: *const Context, content_type: []const u8) ?*string.JSString {
        return self.http.contentType(content_type);
    }

    /// Get a cached HTTP method string or null if not cached
    pub fn getCachedMethod(self: *const Context, method: []const u8) ?*string.JSString {
        return self.http.method(method);
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
        self.http.deinit(self.allocator);
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

/// Re-export: the table itself lives in atom_table.zig, which the parser and
/// the analyzers import directly so they do not pull in the runtime Context.
pub const AtomTable = atom_table_mod.AtomTable;

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
