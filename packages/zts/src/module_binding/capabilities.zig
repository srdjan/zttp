//! Capability enforcement for virtual modules.
//!
//! Owns the opaque `ModuleHandle`, the Context-owned active-module scope that
//! call-time checks read, the `ModuleCapability` vocabulary, and the families that
//! gate every host effect a module can reach: `*ForActiveModule` (returns the
//! error) and `*Checked` (turns a missing capability into a hard
//! `CapabilityViolation`, since a module that declared nothing has no
//! business asking).
//!
//! Split out of module_binding.zig, which re-exports every name here.

const std = @import("std");
const build_options = @import("build_options");
const object = @import("../object.zig");
const value = @import("../value.zig");
const context = @import("../context.zig");
const cost_meter = context.cost_meter;
const compat = @import("../compat.zig");
const file_io = @import("../file_io.zig");
const sqlite_runtime = @import("../sqlite.zig");
const security_events = @import("../security_events.zig");
const gc = @import("../gc.zig");
const handler_policy = @import("../handler_policy.zig");
const module_slots = @import("../module_slots.zig");
const module_authorization = @import("../module_authorization.zig");

// -------------------------------------------------------------------------
// Opaque handle for third-party module sandbox
// -------------------------------------------------------------------------

/// Opaque handle passed to third-party module functions.
/// Cannot be dereferenced - modules interact with the runtime exclusively
/// through the free functions below. Internally this is a *Context, but
/// that fact is hidden from module authors.
pub const ModuleHandle = opaque {};

/// Function signature for third-party (sandboxed) module functions.
/// Receives an opaque handle instead of raw *anyopaque.
pub const ModuleFn = *const fn (
    handle: *ModuleHandle,
    this: value.JSValue,
    args: []const value.JSValue,
) anyerror!value.JSValue;

const ActiveModuleScope = module_authorization.ActiveModuleScope;

pub const ActiveModuleToken = struct {
    context: *context.Context,
    previous: ?ActiveModuleScope,
};

threadlocal var sdk_prng: ?std.Random.DefaultPrng = null;
threadlocal var sdk_csprng: ?std.Random.DefaultCsprng = null;

/// Generate a NativeFn wrapper around a ModuleFn.
/// The wrapper casts *anyopaque to *ModuleHandle (a no-op pointer cast)
/// so the module receives the opaque handle it expects.
pub fn wrapModuleFn(comptime user_fn: ModuleFn) object.NativeFn {
    return wrapModuleFnWithCapabilities(user_fn, "<sandboxed>", &.{});
}

pub fn wrapNativeFnWithCapabilities(
    comptime user_fn: object.NativeFn,
    comptime specifier: []const u8,
    comptime required_capabilities: []const ModuleCapability,
) object.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
            const ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
            const token = pushActiveModuleContext(ctx, specifier, required_capabilities);
            defer popActiveModuleContext(token);
            ctx.cost_meter.bump(comptime cost_meter.classForSpecifier(specifier));
            return user_fn(ctx_ptr, this, args);
        }
    }.call;
}

pub fn wrapModuleFnWithCapabilities(
    comptime user_fn: ModuleFn,
    comptime specifier: []const u8,
    comptime required_capabilities: []const ModuleCapability,
) object.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
            const ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
            const token = pushActiveModuleContext(ctx, specifier, required_capabilities);
            defer popActiveModuleContext(token);
            ctx.cost_meter.bump(comptime cost_meter.classForSpecifier(specifier));
            return user_fn(contextToHandle(ctx), this, args);
        }
    }.call;
}

// -------------------------------------------------------------------------
// ModuleHandle free functions (the sandbox API)
// -------------------------------------------------------------------------

/// Cast a ModuleHandle to the underlying Context. Internal use only -
/// this function is called by the SDK free functions below, never by
/// module authors directly.
pub fn handleToContext(handle: *ModuleHandle) *context.Context {
    return @ptrCast(@alignCast(handle));
}

pub fn contextToHandle(ctx: *context.Context) *ModuleHandle {
    return @ptrCast(ctx);
}

fn activeContextHasCapability(ctx: *const context.Context, capability: ModuleCapability) bool {
    const active = ctx.active_module_scope orelse return false;
    for (active.required_capabilities) |candidate| {
        if (candidate == capability) return true;
    }
    return false;
}

pub fn activeModuleOwnsStateSlot(handle: *ModuleHandle, slot: usize) bool {
    const active = handleToContext(handle).active_module_scope orelse return false;
    return module_slots.isOwnedBySpecifier(slot, active.specifier);
}

pub fn hasCapability(handle: *ModuleHandle, capability: ModuleCapability) bool {
    return activeContextHasCapability(handleToContext(handle), capability);
}

pub const ModuleCapabilityError = error{MissingModuleCapability};

pub fn requireCapability(handle: *ModuleHandle, capability: ModuleCapability) ModuleCapabilityError!void {
    if (activeContextHasCapability(handleToContext(handle), capability)) return;
    return error.MissingModuleCapability;
}

pub fn pushActiveModuleContext(
    ctx: *context.Context,
    specifier: []const u8,
    required_capabilities: []const ModuleCapability,
) ActiveModuleToken {
    const prev = ctx.active_module_scope;
    ctx.active_module_scope = .{
        .specifier = specifier,
        .required_capabilities = required_capabilities,
    };
    return .{ .context = ctx, .previous = prev };
}

pub fn popActiveModuleContext(token: ActiveModuleToken) void {
    token.context.active_module_scope = token.previous;
}

// -------------------------------------------------------------------------
// Module implementation capability declarations
// -------------------------------------------------------------------------

/// Capabilities consumed by a virtual module's Zig implementation.
/// These are governance metadata for the module internals; they do not affect
/// handler-level effect classification or RuntimePolicy derivation.
pub const ModuleCapability = module_authorization.ModuleCapability;

/// The count and the canonical hash live in `module_authorization.zig`,
/// beside the enum they are derived from, so a contract can name the
/// capability vocabulary without importing the module bridge and the engine
/// behind it. Re-exported because every caller already reaches them here.
pub const capability_count = module_authorization.capability_count;
pub const capabilityHash = module_authorization.capabilityHash;

pub const ActiveCapabilityError = ModuleCapabilityError || error{
    ClockUnavailable,
    StderrWriteFailed,
    EntropyUnavailable,
};

fn currentActiveModuleSpecifier(ctx: *const context.Context) []const u8 {
    return if (ctx.active_module_scope) |active| active.specifier else "<no-active-module>";
}

fn requireActiveCapability(ctx: *const context.Context, capability: ModuleCapability) ActiveCapabilityError!void {
    if (activeContextHasCapability(ctx, capability)) return;
    return error.MissingModuleCapability;
}

fn panicCapabilityError(ctx: *const context.Context, err: ActiveCapabilityError, capability: ModuleCapability) error{CapabilityViolation} {
    const spec = currentActiveModuleSpecifier(ctx);
    switch (err) {
        error.MissingModuleCapability => std.log.err(
            "module '{s}' used undeclared capability '{s}'",
            .{ spec, @tagName(capability) },
        ),
        error.ClockUnavailable => std.log.err(
            "module '{s}' failed to access clock capability",
            .{spec},
        ),
        error.StderrWriteFailed => std.log.err(
            "module '{s}' failed to write to stderr capability",
            .{spec},
        ),
        error.EntropyUnavailable => std.log.err(
            "module '{s}' could not read OS entropy (/dev/urandom)",
            .{spec},
        ),
    }
    return error.CapabilityViolation;
}

pub fn nowMsForActiveModule(ctx: *context.Context) ActiveCapabilityError!i64 {
    try requireActiveCapability(ctx, .clock);
    return compat.realtimeNowMs() catch error.ClockUnavailable;
}

pub fn nowNsForActiveModule(ctx: *context.Context) ActiveCapabilityError!u64 {
    try requireActiveCapability(ctx, .clock);
    return compat.realtimeNowNs() catch error.ClockUnavailable;
}

pub fn clockNowMsChecked(ctx: *context.Context) error{CapabilityViolation}!i64 {
    return nowMsForActiveModule(ctx) catch |err| return panicCapabilityError(ctx, err, .clock);
}

pub fn clockNowNsChecked(ctx: *context.Context) error{CapabilityViolation}!u64 {
    return nowNsForActiveModule(ctx) catch |err| return panicCapabilityError(ctx, err, .clock);
}

pub fn clockNowSecsChecked(ctx: *context.Context) error{CapabilityViolation}!i64 {
    return @divTrunc(try clockNowMsChecked(ctx), 1000);
}

pub fn fillRandomForActiveModule(ctx: *context.Context, buf: []u8) ActiveCapabilityError!void {
    try requireActiveCapability(ctx, .random);
    if (buf.len == 0) return;

    if (comptime build_options.analyzer_only) {
        // The wasm/freestanding analyzer never executes handler code and has no
        // OS CSPRNG; a deterministic PRNG keeps that build linking. IDs minted
        // on this path are never security-bearing.
        if (sdk_prng == null) {
            const seed = std.hash.Wyhash.hash(0, currentActiveModuleSpecifier(ctx)) ^
                @as(u64, @bitCast(nowNsForActiveModule(ctx) catch 0));
            sdk_prng = std.Random.DefaultPrng.init(seed);
        }
        sdk_prng.?.random().bytes(buf);
        return;
    }

    // Hosted runtime: a forward-ratcheting ChaCha CSPRNG seeded once per thread
    // from the OS entropy pool. This backs zttp:id (uuid/ulid/nanoid), which
    // are routinely used as session tokens, reset tokens, and idempotency keys -
    // the previous Xoshiro256, seeded once from the wall clock, was both
    // low-entropy and state-recoverable from a single observed id.
    if (sdk_csprng == null) {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        // Fail closed but cleanly: a blocked /dev/urandom (e.g. a hardened
        // container) surfaces as a typed error the SDK bridge turns into a
        // caller-visible failure, instead of a process panic. Never fall back
        // to a weaker source - an unseeded CSPRNG must not mint tokens.
        fillOsEntropy(&seed) catch return error.EntropyUnavailable;
        sdk_csprng = std.Random.DefaultCsprng.init(seed);
    }
    sdk_csprng.?.random().bytes(buf);
}

/// Fill `buf` from the OS entropy pool (/dev/urandom). Mirrors the attestation
/// keypair's seeding; only ever referenced from the hosted (libc-linked) path.
fn fillOsEntropy(buf: []u8) !void {
    const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.UrandomOpenFailed;
    defer _ = std.c.close(fd);
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = std.c.read(fd, buf[filled..].ptr, buf.len - filled);
        if (n <= 0) return error.UrandomReadFailed;
        filled += @intCast(n);
    }
}

pub fn fillRandomChecked(ctx: *context.Context, buf: []u8) error{CapabilityViolation}!void {
    fillRandomForActiveModule(ctx, buf) catch |err| return panicCapabilityError(ctx, err, .random);
}

pub fn writeStderrForActiveModule(ctx: *context.Context, buf: []const u8) ActiveCapabilityError!void {
    try requireActiveCapability(ctx, .stderr);
    if (buf.len == 0) return;

    const written = std.c.write(std.c.STDERR_FILENO, buf.ptr, buf.len);
    if (written != @as(isize, @intCast(buf.len))) return error.StderrWriteFailed;
}

pub fn writeStderrChecked(ctx: *context.Context, buf: []const u8) error{CapabilityViolation}!void {
    writeStderrForActiveModule(ctx, buf) catch |err| return panicCapabilityError(ctx, err, .stderr);
}

pub fn runtimeCallbackCapabilityChecked(ctx: *context.Context) error{CapabilityViolation}!void {
    requireActiveCapability(ctx, .runtime_callback) catch |err| return panicCapabilityError(ctx, err, .runtime_callback);
}

pub fn getRuntimeCallbackStateChecked(
    ctx: *context.Context,
    comptime T: type,
    slot: usize,
) error{CapabilityViolation}!?*T {
    try runtimeCallbackCapabilityChecked(ctx);
    return ctx.getModuleState(T, slot);
}

fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.InvalidPath;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var resolved_buf: [std.c.PATH_MAX + 1]u8 = undefined;
    const resolved = std.c.realpath(path_z, &resolved_buf) orelse return error.PathNotCanonical;
    const len = std.mem.len(resolved);
    return try allocator.dupe(u8, resolved[0..len]);
}

fn canonicalizeExistingPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return realPathAlloc(allocator, path);
}

fn canonicalizeCreatablePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (realPathAlloc(allocator, path)) |resolved| return resolved else |err| switch (err) {
        error.PathNotCanonical => {},
        else => return err,
    }

    const dirname = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return error.InvalidPath;
    }

    const parent = try realPathAlloc(allocator, dirname);
    defer allocator.free(parent);
    return std.fs.path.join(allocator, &.{ parent, basename });
}

pub fn allowSdkFilePath(ctx: *context.Context, path: []const u8) !void {
    const canonical = try canonicalizeExistingPath(ctx.allocator, path);
    defer ctx.allocator.free(canonical);
    try ctx.allowSdkFilePathCanonical(canonical);
}

pub fn allowSdkSqlitePath(ctx: *context.Context, path: []const u8) !void {
    const canonical = try canonicalizeCreatablePath(ctx.allocator, path);
    defer ctx.allocator.free(canonical);
    try ctx.allowSdkSqlitePathCanonical(canonical);
}

pub fn readFileChecked(
    ctx: *context.Context,
    path: []const u8,
    max_size: usize,
) ![]u8 {
    requireActiveCapability(ctx, .filesystem) catch |err| return panicCapabilityError(ctx, err, .filesystem);
    const canonical = try canonicalizeExistingPath(ctx.allocator, path);
    defer ctx.allocator.free(canonical);
    if (!ctx.allowsSdkFilePathCanonical(canonical)) return error.FilePathNotAllowed;
    return file_io.readFile(ctx.allocator, path, max_size);
}

pub fn readEnvForActiveModule(ctx: *context.Context, name_z: [:0]const u8) ActiveCapabilityError!?[]const u8 {
    try requireActiveCapability(ctx, .env);
    // Enforce the env allowlist on the read itself, not only in the optional
    // sdk.allowsEnv pre-check. The built-in zttp:env module calls allowsEnv
    // first, but a third-party SDK module that declares .env and never calls it
    // would otherwise read any process env var (env values are flow-labeled
    // .secret), bypassing the policy the contract advertises. Mirrors
    // readFileChecked / openSqliteDbChecked, which gate internally. `allows`
    // returns true when no allowlist is configured, so this matches the
    // built-in module's behavior exactly and only closes the bypass.
    if (!ctx.capability_policy.allowsEnv(name_z)) {
        emitPolicyDenial(ctx, .policy_denied_env, name_z);
        return null;
    }
    const result = std.c.getenv(name_z) orelse return null;
    return std.mem.sliceTo(result, 0);
}

pub fn readEnvChecked(ctx: *context.Context, name_z: [:0]const u8) error{CapabilityViolation}!?[]const u8 {
    return readEnvForActiveModule(ctx, name_z) catch |err| return panicCapabilityError(ctx, err, .env);
}

pub fn sqliteCapabilityChecked(ctx: *context.Context) error{CapabilityViolation}!void {
    requireActiveCapability(ctx, .sqlite) catch |err| return panicCapabilityError(ctx, err, .sqlite);
}

pub fn getSqliteStateChecked(
    ctx: *context.Context,
    comptime T: type,
    slot: usize,
) error{CapabilityViolation}!?*T {
    try sqliteCapabilityChecked(ctx);
    return ctx.getModuleState(T, slot);
}

pub fn openSqliteDbChecked(
    ctx: *context.Context,
    path: []const u8,
) !sqlite_runtime.Db {
    try sqliteCapabilityChecked(ctx);
    const canonical = try canonicalizeCreatablePath(ctx.allocator, path);
    defer ctx.allocator.free(canonical);
    if (!ctx.allowsSdkSqlitePathCanonical(canonical)) return error.SqlitePathNotAllowed;
    return sqlite_runtime.Db.openReadWriteCreate(ctx.allocator, path);
}

pub fn hmacSha256ForActiveModule(
    ctx: *context.Context,
    out: *[std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8,
    data: []const u8,
    key: []const u8,
) ActiveCapabilityError!void {
    try requireActiveCapability(ctx, .crypto);
    std.crypto.auth.hmac.sha2.HmacSha256.create(out, data, key);
}

pub fn sha256ForActiveModule(
    ctx: *context.Context,
    out: *[std.crypto.hash.sha2.Sha256.digest_length]u8,
    data: []const u8,
) ActiveCapabilityError!void {
    try requireActiveCapability(ctx, .crypto);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    out.* = hasher.finalResult();
}

pub fn sha256Checked(
    ctx: *context.Context,
    out: *[std.crypto.hash.sha2.Sha256.digest_length]u8,
    data: []const u8,
) error{CapabilityViolation}!void {
    sha256ForActiveModule(ctx, out, data) catch |err| return panicCapabilityError(ctx, err, .crypto);
}

pub fn hmacSha256Checked(
    ctx: *context.Context,
    out: *[std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8,
    data: []const u8,
    key: []const u8,
) error{CapabilityViolation}!void {
    hmacSha256ForActiveModule(ctx, out, data, key) catch |err| return panicCapabilityError(ctx, err, .crypto);
}

fn emitPolicyDenial(ctx: *const context.Context, kind: security_events.SecurityEventKind, name: []const u8) void {
    security_events.emitGlobal(security_events.SecurityEvent.init(
        kind,
        currentActiveModuleSpecifier(ctx),
        name,
    ));
}

pub fn allowsCacheNamespaceForActiveModule(
    ctx: *context.Context,
    ns: []const u8,
) ActiveCapabilityError!bool {
    try requireActiveCapability(ctx, .policy_check);
    const allowed = ctx.capability_policy.allowsCacheNamespace(ns);
    if (!allowed) emitPolicyDenial(ctx, .policy_denied_cache, ns);
    return allowed;
}

pub fn allowsCacheNamespaceChecked(ctx: *context.Context, ns: []const u8) error{CapabilityViolation}!bool {
    return allowsCacheNamespaceForActiveModule(ctx, ns) catch |err| return panicCapabilityError(ctx, err, .policy_check);
}

pub fn allowsEnvForActiveModule(
    ctx: *context.Context,
    name: []const u8,
) ActiveCapabilityError!bool {
    try requireActiveCapability(ctx, .policy_check);
    const allowed = ctx.capability_policy.allowsEnv(name);
    if (!allowed) emitPolicyDenial(ctx, .policy_denied_env, name);
    return allowed;
}

pub fn allowsEnvChecked(ctx: *context.Context, name: []const u8) error{CapabilityViolation}!bool {
    return allowsEnvForActiveModule(ctx, name) catch |err| return panicCapabilityError(ctx, err, .policy_check);
}

pub fn allowsSqlQueryForActiveModule(
    ctx: *context.Context,
    name: []const u8,
) ActiveCapabilityError!bool {
    try requireActiveCapability(ctx, .policy_check);
    const allowed = ctx.capability_policy.allowsSqlQuery(name);
    if (!allowed) emitPolicyDenial(ctx, .policy_denied_sql, name);
    return allowed;
}

pub fn allowsSqlQueryChecked(ctx: *context.Context, name: []const u8) error{CapabilityViolation}!bool {
    return allowsSqlQueryForActiveModule(ctx, name) catch |err| return panicCapabilityError(ctx, err, .policy_check);
}

pub fn allowsSqlWriteForActiveModule(
    ctx: *context.Context,
    name: []const u8,
) ActiveCapabilityError!bool {
    try requireActiveCapability(ctx, .policy_check);
    const allowed = ctx.capability_policy.allowsSqlWrite(name);
    if (!allowed) {
        // Phase 1 dual-emit: legacy per-module event for existing JSONL
        // consumers, generic policy_denied for spec section 12 shape.
        // Phase 4 deprecates the legacy kinds once consumers migrate.
        emitPolicyDenial(ctx, .policy_denied_sql, name);
        const policy = @import("../policy.zig");
        policy.emitDenied(.{
            .action = .db_write,
            .resource = .{ .kind = policy.resource_kind_sql_query, .id = name },
        }, .not_in_allowlist);
    }
    return allowed;
}

pub fn allowsSqlWriteChecked(ctx: *context.Context, name: []const u8) error{CapabilityViolation}!bool {
    return allowsSqlWriteForActiveModule(ctx, name) catch |err| return panicCapabilityError(ctx, err, .policy_check);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "module call bumps the context cost meter" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const module_fn: ModuleFn = struct {
        fn f(_: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            return value.JSValue.true_val;
        }
    }.f;

    const wrapped = comptime wrapModuleFnWithCapabilities(
        module_fn,
        "zttp:sql",
        &.{},
    );

    _ = try wrapped(ctx, value.JSValue.undefined_val, &.{});
    _ = try wrapped(ctx, value.JSValue.undefined_val, &.{});

    try std.testing.expectEqual(@as(u32, 2), ctx.cost_meter.count(.sql));
    try std.testing.expectEqual(@as(u32, 2), ctx.cost_meter.total());
}

test "wrapNativeFnWithCapabilities activates context for built-in native fns" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const wrapped = comptime wrapNativeFnWithCapabilities(
        struct {
            fn f(ctx_ptr: *anyopaque, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
                const active_ctx: *context.Context = @ptrCast(@alignCast(ctx_ptr));
                _ = clockNowMsChecked(active_ctx) catch 0;
                return value.JSValue.true_val;
            }
        }.f,
        "zttp:test",
        &.{.clock},
    );

    const result = try wrapped(ctx, value.JSValue.undefined_val, &.{});
    try std.testing.expect(result.isTrue());
    try std.testing.expectEqual(@as(u32, 1), ctx.cost_meter.count(.other));
}

test "wrapModuleFnWithCapabilities invocation activates Context authorization" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const Observed = struct {
        var saw_clock: bool = false;
        var saw_random: bool = false;
        var specifier_seen: []const u8 = "";
    };
    Observed.saw_clock = false;
    Observed.saw_random = false;
    Observed.specifier_seen = "";

    const module_fn: ModuleFn = struct {
        fn f(handle: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            const active_ctx = handleToContext(handle);
            Observed.saw_clock = activeContextHasCapability(active_ctx, .clock);
            Observed.saw_random = activeContextHasCapability(active_ctx, .random);
            if (active_ctx.active_module_scope) |active_scope| {
                Observed.specifier_seen = active_scope.specifier;
            }
            return value.JSValue.true_val;
        }
    }.f;

    const wrapped = comptime wrapModuleFnWithCapabilities(
        module_fn,
        "zttp:invariant-test",
        &.{.clock},
    );

    const result = try wrapped(ctx, value.JSValue.undefined_val, &.{});
    try std.testing.expect(result.isTrue());
    try std.testing.expect(Observed.saw_clock);
    try std.testing.expect(!Observed.saw_random);
    try std.testing.expectEqualStrings("zttp:invariant-test", Observed.specifier_seen);
    try std.testing.expectEqual(@as(u32, 1), ctx.cost_meter.count(.other));

    // The Context scope must be torn down after the wrapped call returns so a
    // later call outside a module cannot inherit residual capabilities.
    try std.testing.expect(ctx.active_module_scope == null);
}

test "active module authorization is scoped to its Context" {
    const allocator = std.testing.allocator;

    var gc_a = try gc.GC.init(allocator, .{});
    defer gc_a.deinit();
    const ctx_a = try context.Context.init(allocator, &gc_a, .{});
    defer ctx_a.deinit();

    var gc_b = try gc.GC.init(allocator, .{});
    defer gc_b.deinit();
    const ctx_b = try context.Context.init(allocator, &gc_b, .{});
    defer ctx_b.deinit();

    const handle_a = contextToHandle(ctx_a);
    const handle_b = contextToHandle(ctx_b);

    const token_a = pushActiveModuleContext(ctx_a, "zttp:sql", &.{.clock});
    const token_b = pushActiveModuleContext(ctx_b, "zttp:cache", &.{.random});

    try std.testing.expect(hasCapability(handle_a, .clock));
    try std.testing.expect(!hasCapability(handle_a, .random));
    try std.testing.expect(hasCapability(handle_b, .random));
    try std.testing.expect(!hasCapability(handle_b, .clock));
    try std.testing.expect(activeModuleOwnsStateSlot(handle_a, @intFromEnum(module_slots.Slot.sql)));
    try std.testing.expect(!activeModuleOwnsStateSlot(handle_a, @intFromEnum(module_slots.Slot.cache)));
    try std.testing.expect(activeModuleOwnsStateSlot(handle_b, @intFromEnum(module_slots.Slot.cache)));
    try std.testing.expect(!activeModuleOwnsStateSlot(handle_b, @intFromEnum(module_slots.Slot.sql)));

    // Context scopes are independent stacks, so they may be restored in an
    // order that is not globally LIFO without disturbing the other Context.
    popActiveModuleContext(token_a);
    try std.testing.expect(!hasCapability(handle_a, .clock));
    try std.testing.expect(hasCapability(handle_b, .random));

    const next_token_a = pushActiveModuleContext(ctx_a, "zttp:service", &.{.stderr});
    try std.testing.expect(hasCapability(handle_a, .stderr));
    try std.testing.expect(hasCapability(handle_b, .random));

    popActiveModuleContext(token_b);
    try std.testing.expect(hasCapability(handle_a, .stderr));
    try std.testing.expect(!hasCapability(handle_b, .random));

    popActiveModuleContext(next_token_a);
    try std.testing.expect(!hasCapability(handle_a, .stderr));
}

test "reentrant module calls restore every caller scope" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const Calls = struct {
        fn expectScope(handle: *ModuleHandle, allowed: ModuleCapability, denied: ModuleCapability) !void {
            try std.testing.expect(hasCapability(handle, allowed));
            try std.testing.expect(!hasCapability(handle, denied));
        }

        fn reentered(handle: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            try expectScope(handle, .clock, .random);
            return value.JSValue.true_val;
        }

        const reentered_wrapped = wrapModuleFnWithCapabilities(
            reentered,
            "zttp:outer-reentered",
            &.{.clock},
        );

        fn inner(handle: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            try expectScope(handle, .random, .clock);
            _ = try reentered_wrapped(handleToContext(handle), value.JSValue.undefined_val, &.{});
            try expectScope(handle, .random, .clock);
            return value.JSValue.true_val;
        }

        const inner_wrapped = wrapModuleFnWithCapabilities(
            inner,
            "zttp:inner",
            &.{.random},
        );

        fn outer(handle: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            try expectScope(handle, .clock, .random);
            _ = try inner_wrapped(handleToContext(handle), value.JSValue.undefined_val, &.{});
            try expectScope(handle, .clock, .random);
            return value.JSValue.true_val;
        }
    };

    const outer_wrapped = comptime wrapModuleFnWithCapabilities(
        Calls.outer,
        "zttp:outer",
        &.{.clock},
    );
    const result = try outer_wrapped(ctx, value.JSValue.undefined_val, &.{});
    try std.testing.expect(result.isTrue());

    const handle = contextToHandle(ctx);
    try std.testing.expect(!hasCapability(handle, .clock));
    try std.testing.expect(!hasCapability(handle, .random));
}

test "module error restores outer scope and clears top level" {
    const allocator = std.testing.allocator;
    var gc_state = try gc.GC.init(allocator, .{});
    defer gc_state.deinit();
    const ctx = try context.Context.init(allocator, &gc_state, .{});
    defer ctx.deinit();

    const Calls = struct {
        fn inner(handle: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            try std.testing.expect(hasCapability(handle, .random));
            try std.testing.expect(!hasCapability(handle, .clock));
            return error.InnerFailure;
        }

        const inner_wrapped = wrapModuleFnWithCapabilities(
            inner,
            "zttp:error-inner",
            &.{.random},
        );

        fn outer(handle: *ModuleHandle, _: value.JSValue, _: []const value.JSValue) anyerror!value.JSValue {
            try std.testing.expect(hasCapability(handle, .clock));
            _ = inner_wrapped(handleToContext(handle), value.JSValue.undefined_val, &.{}) catch |err| {
                if (err != error.InnerFailure) return err;
                try std.testing.expect(hasCapability(handle, .clock));
                try std.testing.expect(!hasCapability(handle, .random));
                return value.JSValue.true_val;
            };
            return error.ExpectedInnerFailure;
        }
    };

    const outer_wrapped = comptime wrapModuleFnWithCapabilities(
        Calls.outer,
        "zttp:error-outer",
        &.{.clock},
    );
    const result = try outer_wrapped(ctx, value.JSValue.undefined_val, &.{});
    try std.testing.expect(result.isTrue());

    const handle = contextToHandle(ctx);
    try std.testing.expect(!hasCapability(handle, .clock));
    try std.testing.expect(!hasCapability(handle, .random));
}
