const std = @import("std");
const sdk = @import("zttp-sdk");

var test_allocator = std.testing.allocator;
var module_states = @as([128]?*anyopaque, @splat(null));

const sqlite_error = "sqlite unavailable in sdk test shim";

// Capability denial bitmask consulted by `zttpSdkHasCapability`. Default
// is 0 (all capabilities allowed) so existing tests written against the
// permissive shim keep passing unchanged. Tests that need to exercise a
// rejection path call `denyCapability` and either pair it with `defer
// allowCapability(...)` or `defer allowAllCapabilities()` to reset.
//
// 64 bits is sufficient for the current ModuleCapability enum (well under
// 32 variants). The mask is process-global, not thread-local, because
// Zig's default test runner executes tests serially on one thread.
var denied_capabilities_mask: u64 = 0;

pub fn denyCapability(capability: sdk.ModuleCapability) void {
    const tag: u6 = @intCast(@backingInt(capability));
    denied_capabilities_mask |= (@as(u64, 1) << tag);
}

pub fn allowCapability(capability: sdk.ModuleCapability) void {
    const tag: u6 = @intCast(@backingInt(capability));
    denied_capabilities_mask &= ~(@as(u64, 1) << tag);
}

pub fn allowAllCapabilities() void {
    denied_capabilities_mask = 0;
}

pub export fn zttpSdkHasCapability(_: *sdk.ModuleHandle, capability_tag: u8) bool {
    // Tags outside the mask's range fall back to "allowed" — matches the
    // original shim's behavior and avoids spuriously failing tests that
    // probe capability values the enum does not yet define.
    if (capability_tag >= 64) return true;
    const bit: u6 = @intCast(capability_tag);
    return (denied_capabilities_mask & (@as(u64, 1) << bit)) == 0;
}

pub export fn zttpSdkNowMs(_: *sdk.ModuleHandle, out_ms: *i64) bool {
    out_ms.* = 0;
    return true;
}

// When true, the random fill reports failure (mirrors the runtime bridge when
// OS entropy is unavailable) so tests can exercise the error path. Default
// false; reset with `allowRandom` (process-global, like the capability mask).
var random_should_fail: bool = false;

pub fn failRandom() void {
    random_should_fail = true;
}

pub fn allowRandom() void {
    random_should_fail = false;
}

pub export fn zttpSdkFillRandom(_: *sdk.ModuleHandle, buf_ptr: [*]u8, len: usize) bool {
    @memset(buf_ptr[0..len], 0);
    return !random_should_fail;
}

pub export fn zttpSdkWriteStderr(_: *sdk.ModuleHandle, _: [*]const u8, _: usize) bool {
    return true;
}

// String support. The shim used to report every value as a non-string, which
// made the success path of anything reading a string argument untestable. It
// now keeps a small interning table: `internString` mints a value the shim
// recognizes, and every other value (ints, undefined, objects) still extracts
// as a non-string. Values are borrowed slices of caller memory, so a test
// interning a temporary must not outlive it; `resetStrings` clears the table.
const STRING_PREFIX: u64 = 0xFFFC_0000_0000_0000;
const max_shim_strings = 32;
var shim_strings: [max_shim_strings][]const u8 = undefined;
var shim_string_count: usize = 0;

/// Mint a JSValue the shim extracts as `text`. Borrows `text`.
pub fn internString(text: []const u8) sdk.JSValue {
    if (shim_string_count == max_shim_strings) @panic("sdk test shim string table is full");
    shim_strings[shim_string_count] = text;
    const index = shim_string_count;
    shim_string_count += 1;
    return .{ .raw = STRING_PREFIX | @as(u64, index) };
}

/// Drop every interned string. Call when the borrowed memory goes out of scope.
pub fn resetStrings() void {
    shim_string_count = 0;
}

fn shimStringSlice(val: sdk.JSValue) ?[]const u8 {
    if ((val.raw & 0xFFFF_0000_0000_0000) != STRING_PREFIX) return null;
    const index: usize = @intCast(val.raw & 0xFFFF_FFFF);
    if (index >= shim_string_count) return null;
    return shim_strings[index];
}

pub export fn zttpSdkExtractString(val: sdk.JSValue, out_ptr: *[*]const u8, out_len: *usize) bool {
    const slice = shimStringSlice(val) orelse return false;
    out_ptr.* = slice.ptr;
    out_len.* = slice.len;
    return true;
}

pub export fn zttpSdkCreateString(_: *sdk.ModuleHandle, ptr: [*]const u8, len: usize, out: *sdk.JSValue) bool {
    out.* = internString(ptr[0..len]);
    return true;
}

pub export fn zttpSdkCreateObject(_: *sdk.ModuleHandle, out: *sdk.JSValue) bool {
    out.* = sdk.JSValue.undefined_val;
    return true;
}

pub export fn zttpSdkObjectSet(_: *sdk.ModuleHandle, _: sdk.JSValue, _: [*]const u8, _: usize, _: sdk.JSValue) bool {
    return true;
}

pub export fn zttpSdkObjectGet(_: *sdk.ModuleHandle, _: sdk.JSValue, _: [*]const u8, _: usize, _: *sdk.JSValue) bool {
    return false;
}

pub export fn zttpSdkThrowError(_: *sdk.ModuleHandle, _: [*]const u8, _: usize, _: [*]const u8, _: usize) sdk.JSValue {
    return sdk.JSValue.undefined_val;
}

pub export fn zttpSdkResultOk(_: *sdk.ModuleHandle, payload: sdk.JSValue, out: *sdk.JSValue) bool {
    out.* = payload;
    return true;
}

pub export fn zttpSdkResultErr(_: *sdk.ModuleHandle, _: [*]const u8, _: usize, out: *sdk.JSValue) bool {
    out.* = sdk.JSValue.undefined_val;
    return true;
}

pub export fn zttpSdkResultErrValue(_: *sdk.ModuleHandle, payload: sdk.JSValue, out: *sdk.JSValue) bool {
    out.* = payload;
    return true;
}

pub export fn zttpSdkResultErrs(_: *sdk.ModuleHandle, payload: sdk.JSValue, out: *sdk.JSValue) bool {
    out.* = payload;
    return true;
}

pub export fn zttpSdkGetAllocator(_: *sdk.ModuleHandle) *const std.mem.Allocator {
    return &test_allocator;
}

pub export fn zttpSdkGetStateAllocator(_: *sdk.ModuleHandle) *const std.mem.Allocator {
    return &test_allocator;
}

pub export fn zttpSdkSha256WithHandle(_: *sdk.ModuleHandle, data_ptr: [*]const u8, data_len: usize, out: [*]u8) bool {
    std.crypto.hash.sha2.Sha256.hash(data_ptr[0..data_len], out[0..32], .{});
    return true;
}

// A real HMAC-SHA256, like the real SHA-256 above, so module tests can sign
// and verify tokens: a zero MAC would make every key produce the same
// signature and a wrong-key test would pass vacuously.
pub export fn zttpSdkHmacSha256WithHandle(_: *sdk.ModuleHandle, data_ptr: [*]const u8, data_len: usize, key_ptr: [*]const u8, key_len: usize, out: [*]u8) bool {
    std.crypto.auth.hmac.sha2.HmacSha256.create(out[0..32], data_ptr[0..data_len], key_ptr[0..key_len]);
    return true;
}

pub export fn zttpSdkParseJson(_: *sdk.ModuleHandle, _: [*]const u8, _: usize, out: *sdk.JSValue) bool {
    out.* = sdk.JSValue.undefined_val;
    return true;
}

pub export fn zttpSdkGetModuleState(_: *sdk.ModuleHandle, slot: usize) ?*anyopaque {
    if (slot >= module_states.len) return null;
    return module_states[slot];
}

pub export fn zttpSdkSetModuleState(_: *sdk.ModuleHandle, slot: usize, ptr: *anyopaque, _: sdk.StateDeinitFn) bool {
    if (slot >= module_states.len) return false;
    module_states[slot] = ptr;
    return true;
}

pub export fn zttpSdkIsString(val: sdk.JSValue) bool {
    return shimStringSlice(val) != null;
}

pub export fn zttpSdkIsObject(_: sdk.JSValue) bool {
    return false;
}

pub export fn zttpSdkIsArray(_: sdk.JSValue) bool {
    return false;
}

pub export fn zttpSdkArrayLength(_: sdk.JSValue, out: *u32) bool {
    out.* = 0;
    return true;
}

pub export fn zttpSdkArrayGet(_: *sdk.ModuleHandle, _: sdk.JSValue, _: u32, _: *sdk.JSValue) bool {
    return false;
}

pub export fn zttpSdkArraySet(_: *sdk.ModuleHandle, _: sdk.JSValue, _: u32, _: sdk.JSValue) bool {
    return true;
}

pub export fn zttpSdkCreateArray(_: *sdk.ModuleHandle, out: *sdk.JSValue) bool {
    out.* = sdk.JSValue.undefined_val;
    return true;
}

pub export fn zttpSdkObjectKeys(_: *sdk.ModuleHandle, _: sdk.JSValue, out: *sdk.JSValue) bool {
    out.* = sdk.JSValue.undefined_val;
    return true;
}

pub export fn zttpSdkReadEnv(_: *sdk.ModuleHandle, _: [*]const u8, _: usize, _: *[*]const u8, _: *usize) bool {
    return false;
}

pub export fn zttpSdkAllowsEnv(_: *sdk.ModuleHandle, _: [*]const u8, _: usize) bool {
    return true;
}

pub export fn zttpSdkAllowsCacheNamespace(_: *sdk.ModuleHandle, _: [*]const u8, _: usize) bool {
    return true;
}

pub export fn zttpSdkAllowsSqlQuery(_: *sdk.ModuleHandle, _: [*]const u8, _: usize) bool {
    return true;
}

pub export fn zttpSdkAllowsSqlWrite(_: *sdk.ModuleHandle, _: [*]const u8, _: usize) bool {
    return true;
}

pub export fn zttpSdkArrayPush(_: *sdk.ModuleHandle, _: sdk.JSValue, _: sdk.JSValue) bool {
    return true;
}

pub export fn zttpSdkSqliteOpen(_: *sdk.ModuleHandle, _: [*]const u8, _: usize, _: **sdk.SqliteDb) bool {
    return false;
}

pub export fn zttpSdkSqliteClose(_: *sdk.SqliteDb) void {}

pub export fn zttpSdkSqliteChanges(_: *sdk.SqliteDb) i32 {
    return 0;
}

pub export fn zttpSdkSqliteLastInsertRowId(_: *sdk.SqliteDb) i64 {
    return 0;
}

pub export fn zttpSdkSqliteErrmsg(_: *sdk.SqliteDb, out_ptr: *[*]const u8, out_len: *usize) void {
    out_ptr.* = sqlite_error.ptr;
    out_len.* = sqlite_error.len;
}

pub export fn zttpSdkSqlitePrepare(_: *sdk.SqliteDb, _: [*]const u8, _: usize, _: **sdk.SqliteStmt) bool {
    return false;
}

pub export fn zttpSdkSqliteFinalize(_: *sdk.SqliteStmt) void {}

pub export fn zttpSdkSqliteStep(_: *sdk.SqliteStmt) i32 {
    return sdk.sqlite_done;
}

pub export fn zttpSdkSqliteReadonly(_: *sdk.SqliteStmt) bool {
    return true;
}

pub export fn zttpSdkSqliteStmtErrmsg(_: *sdk.SqliteStmt, out_ptr: *[*]const u8, out_len: *usize) void {
    out_ptr.* = sqlite_error.ptr;
    out_len.* = sqlite_error.len;
}

pub export fn zttpSdkSqliteParamCount(_: *sdk.SqliteStmt) u32 {
    return 0;
}

pub export fn zttpSdkSqliteParamName(_: *sdk.SqliteStmt, _: u32, _: *[*]const u8, _: *usize) bool {
    return false;
}

pub export fn zttpSdkSqliteBindNull(_: *sdk.SqliteStmt, _: u32) bool {
    return true;
}

pub export fn zttpSdkSqliteBindInt64(_: *sdk.SqliteStmt, _: u32, _: i64) bool {
    return true;
}

pub export fn zttpSdkSqliteBindDouble(_: *sdk.SqliteStmt, _: u32, _: f64) bool {
    return true;
}

pub export fn zttpSdkSqliteBindText(_: *sdk.SqliteStmt, _: u32, _: [*]const u8, _: usize) bool {
    return true;
}

pub export fn zttpSdkSqliteColumnCount(_: *sdk.SqliteStmt) u32 {
    return 0;
}

pub export fn zttpSdkSqliteColumnName(_: *sdk.SqliteStmt, _: u32, out_ptr: *[*]const u8, out_len: *usize) void {
    out_ptr.* = sqlite_error.ptr;
    out_len.* = 0;
}

pub export fn zttpSdkSqliteColumnType(_: *sdk.SqliteStmt, _: u32) i32 {
    return sdk.sqlite_null;
}

pub export fn zttpSdkSqliteColumnInt64(_: *sdk.SqliteStmt, _: u32) i64 {
    return 0;
}

pub export fn zttpSdkSqliteColumnDouble(_: *sdk.SqliteStmt, _: u32) f64 {
    return 0;
}

pub export fn zttpSdkSqliteColumnText(_: *sdk.SqliteStmt, _: u32, out_ptr: *[*]const u8, out_len: *usize) void {
    out_ptr.* = sqlite_error.ptr;
    out_len.* = 0;
}

// ---------------------------------------------------------------------------
// Capability-denial round-trip tests live in `test_root.zig`: `test_shim.zig`
// is imported as a separate named module, so `test` blocks placed here are
// never collected by `zig build test-sdk`.
