//! The bridge between module code and the runtime: the Zig-facing helpers
//! (values, Result objects, module state, allocator) and the C-ABI `export`
//! family the zttp-sdk FFI boundary calls.
//!
//! Split out of module_binding.zig, which re-exports every name here.

const std = @import("std");
const build_options = @import("build_options");
const object = @import("../object.zig");
const value = @import("../value.zig");
const context = @import("../context.zig");
const cost_meter = context.cost_meter;
const compat = @import("zts-base").compat;
const file_io = @import("../file_io.zig");
const sqlite_runtime = @import("../sqlite.zig");
const security_events = @import("../security_events.zig");
const gc = @import("../gc.zig");
const handler_policy = @import("../handler_policy.zig");
const module_slots = @import("zts-base").module_slots;
const capabilities = @import("capabilities.zig");

const ModuleHandle = capabilities.ModuleHandle;
const ModuleCapability = capabilities.ModuleCapability;
const handleToContext = capabilities.handleToContext;
const hasCapability = capabilities.hasCapability;
const activeModuleOwnsStateSlot = capabilities.activeModuleOwnsStateSlot;
const allowsCacheNamespaceChecked = capabilities.allowsCacheNamespaceChecked;
const allowsEnvChecked = capabilities.allowsEnvChecked;
const allowsSqlQueryChecked = capabilities.allowsSqlQueryChecked;
const allowsSqlWriteChecked = capabilities.allowsSqlWriteChecked;
const fillRandomForActiveModule = capabilities.fillRandomForActiveModule;
const hmacSha256ForActiveModule = capabilities.hmacSha256ForActiveModule;
const nowMsForActiveModule = capabilities.nowMsForActiveModule;
const openSqliteDbChecked = capabilities.openSqliteDbChecked;
const readEnvChecked = capabilities.readEnvChecked;
const readFileChecked = capabilities.readFileChecked;
const sha256ForActiveModule = capabilities.sha256ForActiveModule;
const writeStderrForActiveModule = capabilities.writeStderrForActiveModule;

/// Create a new JS string value. Ownership transfers to the GC.
pub fn createString(handle: *ModuleHandle, data: []const u8) !value.JSValue {
    const ctx = handleToContext(handle);
    return ctx.createString(data);
}

/// Extract a borrowed string slice from a JSValue.
/// The returned slice is valid only during the current function call.
pub fn extractString(val: value.JSValue) ?[]const u8 {
    const str = val.toStringStruct() orelse return null;
    return str.asSlice();
}

pub fn extractInt(val: value.JSValue) ?i32 {
    return val.toInt();
}

pub fn extractFloat(val: value.JSValue) ?f64 {
    return val.toFloat();
}

/// Create a Result object: { ok: true, value: payload }
pub fn resultOk(handle: *ModuleHandle, payload: value.JSValue) !value.JSValue {
    const ctx = handleToContext(handle);
    const util = @import("../modules/internal/util.zig");
    return util.createPlainResultOk(ctx, payload);
}

/// Create a Result object: { ok: false, error: message }
pub fn resultErr(handle: *ModuleHandle, message: []const u8) !value.JSValue {
    const ctx = handleToContext(handle);
    const util = @import("../modules/internal/util.zig");
    return util.createPlainResultErr(ctx, message);
}

/// Create a Result object: { ok: false, error: payload }
pub fn resultErrValue(handle: *ModuleHandle, payload: value.JSValue) !value.JSValue {
    const ctx = handleToContext(handle);
    const util = @import("../modules/internal/util.zig");
    return util.createPlainResultErrValue(ctx, payload);
}

/// Create a Result object: { ok: false, errors: payload }
pub fn resultErrs(handle: *ModuleHandle, payload: value.JSValue) !value.JSValue {
    const ctx = handleToContext(handle);
    const util = @import("../modules/internal/util.zig");
    return util.createPlainResultErrs(ctx, payload);
}

/// Throw a JS error. Sets ctx.exception and returns exception_val.
pub fn throwError(handle: *ModuleHandle, name: []const u8, message: []const u8) value.JSValue {
    const ctx = handleToContext(handle);
    const util = @import("../modules/internal/util.zig");
    return util.throwError(ctx, name, message);
}

/// Get typed module state from a slot. Returns null if not initialized.
pub fn getState(handle: *ModuleHandle, comptime T: type, slot: usize) ?*T {
    const ctx = handleToContext(handle);
    return ctx.getModuleState(T, slot);
}

/// Set module state in a slot with a cleanup callback.
pub fn setState(
    handle: *ModuleHandle,
    slot: usize,
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
) void {
    const ctx = handleToContext(handle);
    ctx.setModuleState(slot, ptr, deinit_fn);
}

/// Get the runtime allocator for persistent allocations.
pub fn getAllocator(handle: *ModuleHandle) std.mem.Allocator {
    const ctx = handleToContext(handle);
    return ctx.allocator;
}

/// SDK C-ABI bridge. These `export` functions are the runtime half of the
/// zttp-sdk FFI boundary. Wrapping them in a struct that is referenced
/// only from the comptime gate below lets `analyzer_only` builds (wasm) drop
/// the whole family - and with it the interpreter value layer, SQLite, and
/// libc - from the module graph. Native builds reference `sdk_bridge` and
/// emit every declared bridge symbol.
pub const sdk_bridge = struct {
    pub export fn zttpSdkHasCapability(handle: *ModuleHandle, capability_tag: u8) bool {
        if (capability_tag > @intFromEnum(ModuleCapability.policy_check)) return false;
        const capability: ModuleCapability = @enumFromInt(capability_tag);
        return hasCapability(handle, capability);
    }

    pub export fn zttpSdkNowMs(handle: *ModuleHandle, out_ms: *i64) bool {
        out_ms.* = nowMsForActiveModule(handleToContext(handle)) catch return false;
        return true;
    }

    pub export fn zttpSdkFillRandom(handle: *ModuleHandle, buf_ptr: [*]u8, len: usize) bool {
        if (len == 0) return true;
        // The callers (zttp:id) pass `undefined`-initialized stack buffers and
        // emit them as security tokens. If the fill fails (missing capability or
        // OS entropy unavailable), zero the buffer so no uninitialized stack
        // memory leaks as a "random" value, AND return false so the caller
        // surfaces a clean error rather than emitting an all-zero, predictable
        // token. Fails closed without a process panic.
        fillRandomForActiveModule(handleToContext(handle), buf_ptr[0..len]) catch {
            @memset(buf_ptr[0..len], 0);
            return false;
        };
        return true;
    }

    pub export fn zttpSdkWriteStderr(handle: *ModuleHandle, buf_ptr: [*]const u8, len: usize) bool {
        if (len == 0) return true;
        writeStderrForActiveModule(handleToContext(handle), buf_ptr[0..len]) catch return false;
        return true;
    }

    // SDK bridge: handle-bound runtime operations. JSValue crosses the ABI
    // directly because zts's value.JSValue and sdk.JSValue are packed
    // struct(u64) with layout equivalence verified in module_binding_adapter.

    const util_mod = @import("../modules/internal/util.zig");

    pub export fn zttpSdkExtractString(val: value.JSValue, out_ptr: *[*]const u8, out_len: *usize) bool {
        const slice = util_mod.extractString(val) orelse return false;
        out_ptr.* = slice.ptr;
        out_len.* = slice.len;
        return true;
    }

    pub export fn zttpSdkCreateString(handle: *ModuleHandle, ptr: [*]const u8, len: usize, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        out.* = ctx.createString(ptr[0..len]) catch return false;
        return true;
    }

    pub export fn zttpSdkCreateObject(handle: *ModuleHandle, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        const obj = ctx.createObject(ctx.object_prototype) catch return false;
        out.* = obj.toValue();
        return true;
    }

    pub export fn zttpSdkObjectSet(
        handle: *ModuleHandle,
        obj_val: value.JSValue,
        key_ptr: [*]const u8,
        key_len: usize,
        val: value.JSValue,
    ) bool {
        const ctx = handleToContext(handle);
        if (!obj_val.isObject()) return false;
        const obj = obj_val.toPtr(object.JSObject);
        const atom = ctx.atoms.intern(key_ptr[0..key_len]) catch return false;
        ctx.setPropertyChecked(obj, atom, val) catch return false;
        return true;
    }

    pub export fn zttpSdkObjectGet(
        handle: *ModuleHandle,
        obj_val: value.JSValue,
        key_ptr: [*]const u8,
        key_len: usize,
        out: *value.JSValue,
    ) bool {
        const ctx = handleToContext(handle);
        if (!obj_val.isObject()) return false;
        const obj = obj_val.toPtr(object.JSObject);
        const atom = ctx.atoms.intern(key_ptr[0..key_len]) catch return false;
        const pool = ctx.hidden_class_pool orelse return false;
        out.* = obj.getProperty(pool, atom) orelse return false;
        return true;
    }

    pub export fn zttpSdkThrowError(
        handle: *ModuleHandle,
        name_ptr: [*]const u8,
        name_len: usize,
        msg_ptr: [*]const u8,
        msg_len: usize,
    ) value.JSValue {
        const ctx = handleToContext(handle);
        return util_mod.throwError(ctx, name_ptr[0..name_len], msg_ptr[0..msg_len]);
    }

    pub export fn zttpSdkResultOk(handle: *ModuleHandle, payload: value.JSValue, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        out.* = util_mod.createPlainResultOk(ctx, payload) catch return false;
        return true;
    }

    pub export fn zttpSdkResultErr(
        handle: *ModuleHandle,
        msg_ptr: [*]const u8,
        msg_len: usize,
        out: *value.JSValue,
    ) bool {
        const ctx = handleToContext(handle);
        out.* = util_mod.createPlainResultErr(ctx, msg_ptr[0..msg_len]) catch return false;
        return true;
    }

    pub export fn zttpSdkResultErrValue(handle: *ModuleHandle, payload: value.JSValue, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        out.* = util_mod.createPlainResultErrValue(ctx, payload);
        return true;
    }

    pub export fn zttpSdkResultErrs(handle: *ModuleHandle, payload: value.JSValue, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        out.* = util_mod.createPlainResultErrs(ctx, payload) catch return false;
        return true;
    }

    pub export fn zttpSdkGetAllocator(handle: *ModuleHandle) *const std.mem.Allocator {
        const ctx = handleToContext(handle);
        return &ctx.allocator;
    }

    pub export fn zttpSdkSha256WithHandle(
        handle: *ModuleHandle,
        data_ptr: [*]const u8,
        data_len: usize,
        out: [*]u8,
    ) bool {
        sha256ForActiveModule(handleToContext(handle), @ptrCast(out[0..32]), data_ptr[0..data_len]) catch return false;
        return true;
    }

    pub export fn zttpSdkHmacSha256WithHandle(
        handle: *ModuleHandle,
        data_ptr: [*]const u8,
        data_len: usize,
        key_ptr: [*]const u8,
        key_len: usize,
        out: [*]u8,
    ) bool {
        hmacSha256ForActiveModule(handleToContext(handle), @ptrCast(out[0..32]), data_ptr[0..data_len], key_ptr[0..key_len]) catch return false;
        return true;
    }

    pub export fn zttpSdkParseJson(
        handle: *ModuleHandle,
        json_ptr: [*]const u8,
        json_len: usize,
        out: *value.JSValue,
    ) bool {
        const ctx = handleToContext(handle);
        const json = @import("../builtins/json.zig");
        out.* = json.parseJsonValue(ctx, json_ptr[0..json_len]) catch return false;
        return true;
    }

    // SDK module-state envelope. The C-ABI deinit callback SDK modules provide
    // takes only the state pointer (std.mem.Allocator is not C-ABI stable).
    // Zigts wraps the envelope so the Context's internal deinit_fn signature
    // stays unchanged; modules store their own allocator inside their state.
    const SdkStateEnvelope = struct {
        user_ptr: *anyopaque,
        sdk_deinit: *const fn (*anyopaque) callconv(.c) void,
        allocator: std.mem.Allocator,

        fn envelopeDeinit(ptr: *anyopaque, _: std.mem.Allocator) void {
            const env: *SdkStateEnvelope = @ptrCast(@alignCast(ptr));
            env.sdk_deinit(env.user_ptr);
            env.allocator.destroy(env);
        }
    };

    pub export fn zttpSdkGetModuleState(handle: *ModuleHandle, slot: usize) ?*anyopaque {
        if (!activeModuleOwnsStateSlot(handle, slot)) return null;
        const ctx = handleToContext(handle);
        return getSdkModuleStatePtr(ctx, slot);
    }

    pub export fn zttpSdkSetModuleState(
        handle: *ModuleHandle,
        slot: usize,
        user_ptr: *anyopaque,
        sdk_deinit: *const fn (*anyopaque) callconv(.c) void,
    ) bool {
        if (!activeModuleOwnsStateSlot(handle, slot)) return false;
        const ctx = handleToContext(handle);
        installSdkModuleState(ctx, slot, user_ptr, sdk_deinit) catch return false;
        return true;
    }

    /// Read an SDK-installed module state pointer from a slot. Returns the
    /// user pointer stashed inside the envelope, or null if the slot is empty.
    /// Use this from zts-internal bootstrap code (e.g. `installStore`) that
    /// needs to reach modules living in peer packages through the SDK boundary.
    pub fn getSdkModuleStatePtr(ctx: *context.Context, slot: usize) ?*anyopaque {
        const env = ctx.getModuleState(SdkStateEnvelope, slot) orelse return null;
        return env.user_ptr;
    }

    /// Install an SDK-layout module state envelope from the zts side of the
    /// peer-package boundary. Required whenever the runtime pre-installs state
    /// for a module that reads via the SDK's `getModuleState` (which unwraps an
    /// `SdkStateEnvelope`); writing a bare pointer would leave the module
    /// reading the envelope bytes as user state.
    pub fn installSdkModuleState(
        ctx: *context.Context,
        slot: usize,
        user_ptr: *anyopaque,
        sdk_deinit: *const fn (*anyopaque) callconv(.c) void,
    ) !void {
        const env = try ctx.allocator.create(SdkStateEnvelope);
        env.* = .{ .user_ptr = user_ptr, .sdk_deinit = sdk_deinit, .allocator = ctx.allocator };
        ctx.setModuleState(slot, env, SdkStateEnvelope.envelopeDeinit);
    }

    pub export fn zttpSdkIsCallable(val: value.JSValue) bool {
        return val.isCallable();
    }

    pub export fn zttpSdkReadFile(
        handle: *ModuleHandle,
        path_ptr: [*]const u8,
        path_len: usize,
        max_size: usize,
        out_ptr: *[*]u8,
        out_len: *usize,
    ) bool {
        const ctx = handleToContext(handle);
        const buf = readFileChecked(ctx, path_ptr[0..path_len], max_size) catch return false;
        out_ptr.* = buf.ptr;
        out_len.* = buf.len;
        return true;
    }

    pub export fn zttpSdkIsString(val: value.JSValue) bool {
        return val.isStringOrRope();
    }

    pub export fn zttpSdkIsObject(val: value.JSValue) bool {
        return val.isObject();
    }

    pub export fn zttpSdkIsArray(val: value.JSValue) bool {
        return val.isArray();
    }

    pub export fn zttpSdkArrayLength(val: value.JSValue, out: *u32) bool {
        if (!val.isArray()) return false;
        const arr = val.toPtr(object.JSObject);
        out.* = arr.getArrayLength();
        return true;
    }

    pub export fn zttpSdkArrayGet(handle: *ModuleHandle, arr_val: value.JSValue, index: u32, out: *value.JSValue) bool {
        _ = handle;
        if (!arr_val.isArray()) return false;
        const arr = arr_val.toPtr(object.JSObject);
        out.* = arr.getIndex(index) orelse return false;
        return true;
    }

    pub export fn zttpSdkArraySet(handle: *ModuleHandle, arr_val: value.JSValue, index: u32, val: value.JSValue) bool {
        const ctx = handleToContext(handle);
        if (!arr_val.isArray()) return false;
        const arr = arr_val.toPtr(object.JSObject);
        ctx.setIndexChecked(arr, index, val) catch return false;
        return true;
    }

    pub export fn zttpSdkCreateArray(handle: *ModuleHandle, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        const arr = ctx.createArray() catch return false;
        out.* = arr.toValue();
        return true;
    }

    pub export fn zttpSdkStringify(handle: *ModuleHandle, val: value.JSValue, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        const http_mod = @import("../http.zig");
        const js_str = http_mod.valueToJsonString(ctx, val) catch return false;
        out.* = value.JSValue.fromPtr(js_str);
        return true;
    }

    pub export fn zttpSdkObjectKeys(handle: *ModuleHandle, obj_val: value.JSValue, out: *value.JSValue) bool {
        const ctx = handleToContext(handle);
        if (!obj_val.isObject()) return false;
        const obj = obj_val.toPtr(object.JSObject);
        const pool = ctx.hidden_class_pool orelse return false;

        const atoms = obj.getOwnEnumerableKeys(ctx.allocator, pool) catch return false;
        defer ctx.allocator.free(atoms);

        const arr = ctx.createArray() catch return false;
        for (atoms, 0..) |atom, i| {
            const name = util_mod.atomToString(atom, &ctx.atoms) orelse continue;
            const name_val = ctx.createString(name) catch return false;
            ctx.setIndexChecked(arr, @intCast(i), name_val) catch return false;
        }
        out.* = arr.toValue();
        return true;
    }

    pub export fn zttpSdkReadEnv(
        handle: *ModuleHandle,
        name_ptr: [*]const u8,
        name_len: usize,
        out_ptr: *[*]const u8,
        out_len: *usize,
    ) bool {
        const ctx = handleToContext(handle);
        if (name_len >= 256) return false;
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..name_len], name_ptr[0..name_len]);
        buf[name_len] = 0;
        const result = (readEnvChecked(ctx, buf[0..name_len :0]) catch return false) orelse return false;
        out_ptr.* = result.ptr;
        out_len.* = result.len;
        return true;
    }

    pub export fn zttpSdkAllowsEnv(
        handle: *ModuleHandle,
        name_ptr: [*]const u8,
        name_len: usize,
    ) bool {
        const ctx = handleToContext(handle);
        return allowsEnvChecked(ctx, name_ptr[0..name_len]) catch return false;
    }

    pub export fn zttpSdkAllowsCacheNamespace(
        handle: *ModuleHandle,
        ns_ptr: [*]const u8,
        ns_len: usize,
    ) bool {
        const ctx = handleToContext(handle);
        return allowsCacheNamespaceChecked(ctx, ns_ptr[0..ns_len]) catch return false;
    }

    pub export fn zttpSdkAllowsSqlQuery(
        handle: *ModuleHandle,
        name_ptr: [*]const u8,
        name_len: usize,
    ) bool {
        const ctx = handleToContext(handle);
        return allowsSqlQueryChecked(ctx, name_ptr[0..name_len]) catch return false;
    }

    pub export fn zttpSdkAllowsSqlWrite(
        handle: *ModuleHandle,
        name_ptr: [*]const u8,
        name_len: usize,
    ) bool {
        const ctx = handleToContext(handle);
        return allowsSqlWriteChecked(ctx, name_ptr[0..name_len]) catch return false;
    }

    pub export fn zttpSdkArrayPush(
        handle: *ModuleHandle,
        arr_val: value.JSValue,
        val: value.JSValue,
    ) bool {
        const ctx = handleToContext(handle);
        if (!arr_val.isArray()) return false;
        const arr = arr_val.toPtr(object.JSObject);
        arr.arrayPush(ctx.allocator, val) catch return false;
        return true;
    }

    // -------------------------------------------------------------------------
    // SQLite bridge. Opaque handles are the raw sqlite3 / sqlite3_stmt
    // pointers; the runtime owns their lifetime until close/finalize.
    // -------------------------------------------------------------------------

    const SdkSqliteDb = opaque {};
    const SdkSqliteStmt = opaque {};

    pub export fn zttpSdkSqliteOpen(
        handle: *ModuleHandle,
        path_ptr: [*]const u8,
        path_len: usize,
        out: **SdkSqliteDb,
    ) bool {
        const ctx = handleToContext(handle);
        const db = openSqliteDbChecked(ctx, path_ptr[0..path_len]) catch return false;
        out.* = @ptrCast(db.handle);
        return true;
    }

    pub export fn zttpSdkSqliteClose(opaque_db: *SdkSqliteDb) void {
        const raw: *sqlite_runtime.c.sqlite3 = @ptrCast(@alignCast(opaque_db));
        _ = sqlite_runtime.c.sqlite3_close(raw);
    }

    pub export fn zttpSdkSqliteChanges(opaque_db: *SdkSqliteDb) i32 {
        const raw: *sqlite_runtime.c.sqlite3 = @ptrCast(@alignCast(opaque_db));
        return sqlite_runtime.c.sqlite3_changes(raw);
    }

    pub export fn zttpSdkSqliteLastInsertRowId(opaque_db: *SdkSqliteDb) i64 {
        const raw: *sqlite_runtime.c.sqlite3 = @ptrCast(@alignCast(opaque_db));
        return sqlite_runtime.c.sqlite3_last_insert_rowid(raw);
    }

    pub export fn zttpSdkSqliteErrmsg(
        opaque_db: *SdkSqliteDb,
        out_ptr: *[*]const u8,
        out_len: *usize,
    ) void {
        const raw: *sqlite_runtime.c.sqlite3 = @ptrCast(@alignCast(opaque_db));
        const msg = std.mem.span(sqlite_runtime.c.sqlite3_errmsg(raw));
        out_ptr.* = msg.ptr;
        out_len.* = msg.len;
    }

    pub export fn zttpSdkSqlitePrepare(
        opaque_db: *SdkSqliteDb,
        sql_ptr: [*]const u8,
        sql_len: usize,
        out: **SdkSqliteStmt,
    ) bool {
        const raw_db: *sqlite_runtime.c.sqlite3 = @ptrCast(@alignCast(opaque_db));
        var stmt: ?*sqlite_runtime.c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const rc = sqlite_runtime.c.sqlite3_prepare_v2(raw_db, sql_ptr, @intCast(sql_len), &stmt, &tail);
        if (rc != sqlite_runtime.c.SQLITE_OK or stmt == null) return false;
        // prepare_v2 compiles only the FIRST statement and leaves `tail` pointing
        // past it. A registered query with a second `;`-separated statement would
        // otherwise run only the first and silently drop the rest while still
        // reporting success. Fail closed instead (matches the positional-parameter
        // rejection one layer up), leaving the DB un-mutated for that call.
        if (tail != null) {
            const consumed: usize = @intFromPtr(tail) - @intFromPtr(sql_ptr);
            if (consumed < sql_len) {
                for (sql_ptr[consumed..sql_len]) |c| {
                    if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != ';') {
                        _ = sqlite_runtime.c.sqlite3_finalize(stmt.?);
                        return false;
                    }
                }
            }
        }
        out.* = @ptrCast(stmt.?);
        return true;
    }

    pub export fn zttpSdkSqliteFinalize(opaque_stmt: *SdkSqliteStmt) void {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        _ = sqlite_runtime.c.sqlite3_finalize(raw);
    }

    pub export fn zttpSdkSqliteStep(opaque_stmt: *SdkSqliteStmt) i32 {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_step(raw);
    }

    pub export fn zttpSdkSqliteReadonly(opaque_stmt: *SdkSqliteStmt) bool {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_stmt_readonly(raw) != 0;
    }

    pub export fn zttpSdkSqliteStmtErrmsg(
        opaque_stmt: *SdkSqliteStmt,
        out_ptr: *[*]const u8,
        out_len: *usize,
    ) void {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        const db = sqlite_runtime.c.sqlite3_db_handle(raw);
        const msg = std.mem.span(sqlite_runtime.c.sqlite3_errmsg(db));
        out_ptr.* = msg.ptr;
        out_len.* = msg.len;
    }

    pub export fn zttpSdkSqliteParamCount(opaque_stmt: *SdkSqliteStmt) u32 {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return @intCast(sqlite_runtime.c.sqlite3_bind_parameter_count(raw));
    }

    pub export fn zttpSdkSqliteParamName(
        opaque_stmt: *SdkSqliteStmt,
        index: u32,
        out_ptr: *[*]const u8,
        out_len: *usize,
    ) bool {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        const c_name = sqlite_runtime.c.sqlite3_bind_parameter_name(raw, @intCast(index));
        const normalized = sqlite_runtime.normalizeParamName(c_name) orelse return false;
        out_ptr.* = normalized.ptr;
        out_len.* = normalized.len;
        return true;
    }

    pub export fn zttpSdkSqliteBindNull(opaque_stmt: *SdkSqliteStmt, index: u32) bool {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_bind_null(raw, @intCast(index)) == sqlite_runtime.c.SQLITE_OK;
    }

    pub export fn zttpSdkSqliteBindInt64(opaque_stmt: *SdkSqliteStmt, index: u32, v: i64) bool {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_bind_int64(raw, @intCast(index), v) == sqlite_runtime.c.SQLITE_OK;
    }

    pub export fn zttpSdkSqliteBindDouble(opaque_stmt: *SdkSqliteStmt, index: u32, v: f64) bool {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_bind_double(raw, @intCast(index), v) == sqlite_runtime.c.SQLITE_OK;
    }

    pub export fn zttpSdkSqliteBindText(
        opaque_stmt: *SdkSqliteStmt,
        index: u32,
        ptr: [*]const u8,
        len: usize,
    ) bool {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_bind_text(raw, @intCast(index), ptr, @intCast(len), null) == sqlite_runtime.c.SQLITE_OK;
    }

    pub export fn zttpSdkSqliteColumnCount(opaque_stmt: *SdkSqliteStmt) u32 {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return @intCast(sqlite_runtime.c.sqlite3_column_count(raw));
    }

    pub export fn zttpSdkSqliteColumnName(
        opaque_stmt: *SdkSqliteStmt,
        index: u32,
        out_ptr: *[*]const u8,
        out_len: *usize,
    ) void {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        const c_name = sqlite_runtime.c.sqlite3_column_name(raw, @intCast(index));
        const name = if (c_name) |p| std.mem.span(p) else "";
        out_ptr.* = name.ptr;
        out_len.* = name.len;
    }

    pub export fn zttpSdkSqliteColumnType(opaque_stmt: *SdkSqliteStmt, index: u32) i32 {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_column_type(raw, @intCast(index));
    }

    pub export fn zttpSdkSqliteColumnInt64(opaque_stmt: *SdkSqliteStmt, index: u32) i64 {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_column_int64(raw, @intCast(index));
    }

    pub export fn zttpSdkSqliteColumnDouble(opaque_stmt: *SdkSqliteStmt, index: u32) f64 {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        return sqlite_runtime.c.sqlite3_column_double(raw, @intCast(index));
    }

    pub export fn zttpSdkSqliteColumnText(
        opaque_stmt: *SdkSqliteStmt,
        index: u32,
        out_ptr: *[*]const u8,
        out_len: *usize,
    ) void {
        const raw: *sqlite_runtime.c.sqlite3_stmt = @ptrCast(@alignCast(opaque_stmt));
        const text = sqlite_runtime.c.sqlite3_column_text(raw, @intCast(index));
        if (text == null) {
            out_ptr.* = "".ptr;
            out_len.* = 0;
            return;
        }
        const len: usize = @intCast(sqlite_runtime.c.sqlite3_column_bytes(raw, @intCast(index)));
        out_ptr.* = text;
        out_len.* = len;
    }
};

// The SDK bridge is part of the binary ABI on native builds only.
comptime {
    if (!build_options.analyzer_only) _ = sdk_bridge;
}
