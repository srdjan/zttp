//! zttp:fetch - web-standard outbound HTTP.
//!
//! The native fn only validates arguments, fetches the installed runtime
//! callback, and delegates. The callback is populated during runtime
//! bootstrap from zts side (see packages/zts/src/modules/net/fetch.zig).

const std = @import("std");
const sdk = @import("zttp-sdk");
const util = @import("../internal/util.zig");

pub const MODULE_STATE_SLOT: usize = 11; // module_slots.Slot.fetch

pub const FetchCallFn = *const fn (
    runtime_ptr: *anyopaque,
    handle: *sdk.ModuleHandle,
    args: []const sdk.JSValue,
) anyerror!sdk.JSValue;

pub const FetchDeadlinePassedFn = *const fn (
    runtime_ptr: *anyopaque,
    handle: *sdk.ModuleHandle,
) bool;

/// Builds the runtime's 599 fetch error with `code` and `details`, so a
/// refusal here has the same shape as one the runtime gives.
pub const FetchRefuseFn = *const fn (
    runtime_ptr: *anyopaque,
    handle: *sdk.ModuleHandle,
    code: []const u8,
    details: []const u8,
) anyerror!sdk.JSValue;

pub const FetchState = struct {
    runtime_ptr: *anyopaque,
    call_fn: FetchCallFn,
    deadline_passed_fn: ?FetchDeadlinePassedFn = null,
    refuse_fn: ?FetchRefuseFn = null,
};

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:fetch",
    .name = "fetch",
    .summary = "Fetch an HTTP resource. In an agent turn, a refused fetch returns status 599 with error AgentTurnRefused and a details tag: deadline_exceeded, budget_exhausted, recorder_unavailable, outcome_unknown, tool_denied, or tool_failed.",
    .required_capabilities = &.{ .network, .runtime_callback },
    .stateful = true,
    .exports = &.{
        .{
            .name = "fetch",
            .module_func = fetchImpl,
            .arg_count = 2,
            // A GET is written `fetch(url)`, and `fetchImpl` only refuses
            // `args.len == 0`. The `is_fetch` branch this binding replaced
            // truncated the parameter list to one, which made the init object
            // optional by accident; naming both parameters made it required by
            // accident. It is optional on purpose.
            .required_arg_count = 1,
            .effect = .write,
            // An external service failure: a non-2xx response or a refusal is
            // a fault the handler must answer. `x.ok` on the result forks the
            // path generator (the signature declares the `ok: boolean` record),
            // and a 2xx answer on the failure path is reported, not refused.
            .failure_severity = .upstream,
            .returns = .object,
            .param_types = &.{ .string, .object },
            .param_names = &.{ "url", "init" },
            // The shape the runtime actually hands back and the options it
            // actually reads, spelled here rather than assembled in
            // `module_types.zig` behind an `is_fetch` branch that also
            // truncated the parameter list to one - so `init` typed as
            // nothing at all.
            //
            // The return is not spec 7.2's `Result<Response, FetchError>`,
            // and the reason is the type system rather than this binding: the
            // checker's `Result` is one fixed record with no type parameters,
            // so `Result<Response, FetchError>` collapses to it and loses
            // both arms. Phase 7's parameterized `Result` is where that
            // lands, alongside `responseJson` and `requestJson`, which are
            // deferred there for the same reason. Until then the precise
            // response record is strictly more than the coarse `.object` this
            // export declared before.
            .signature = .{
                .params = &.{ "string", "FetchOptions" },
                .returns = "{ ok: boolean; status: number; statusText: string; body: string; error?: string; details?: string; headers: { get: (name: string) => string | undefined; has: (name: string) => boolean }; json: () => unknown; text: () => string }",
            },
            .return_labels = .{ .external = true },
            .contract_extractions = &.{
                .{ .arg_position = 0, .category = .fetch_host, .transform = .extract_host },
            },
        },
        .{
            .name = "fetchWithRetry",
            .module_func = fetchWithRetryImpl,
            .arg_count = 3,
            .required_arg_count = 1,
            .effect = .write,
            // An external service failure: a non-2xx response or a refusal is
            // a fault the handler must answer. `x.ok` on the result forks the
            // path generator (the signature declares the `ok: boolean` record),
            // and a 2xx answer on the failure path is reported, not refused.
            .failure_severity = .upstream,
            .returns = .object,
            .param_types = &.{ .string, .object, .object },
            .param_names = &.{ "url", "init", "retry" },
            // The same options and the same response. The third argument
            // keeps its coarse `object`: its four retry fields are read by
            // `fetchWithRetryImpl` here rather than by the runtime, and
            // spec 7.2 does not name a type for them. `return_labels` stay
            // `.external`, which is correct and unaffected - a response body
            // is data from the host, not from the arguments.
            .signature = .{
                .params = &.{ "string", "FetchOptions", "object" },
                .returns = "{ ok: boolean; status: number; statusText: string; body: string; error?: string; details?: string; headers: { get: (name: string) => string | undefined; has: (name: string) => boolean }; json: () => unknown; text: () => string }",
            },
            .return_labels = .{ .external = true },
            .contract_extractions = &.{
                .{ .arg_position = 0, .category = .fetch_host, .transform = .extract_host },
            },
        },
    },
};

fn fetchImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const state = sdk.getModuleState(handle, FetchState, MODULE_STATE_SLOT) orelse {
        return sdk.throwError(handle, "Error", "fetch() requires runtime installation (no runtime callback wired)");
    };
    if (args.len == 0) return util.throwTypeError(handle, "fetch() requires a URL string or init object");
    try sdk.requireCapability(handle, .runtime_callback);
    return state.call_fn(state.runtime_ptr, handle, args);
}

// Default retry-on status codes: rate-limited + server errors.
const DEFAULT_RETRY_STATUSES = [_]i32{ 429, 500, 502, 503, 504 };
const DEFAULT_MAX_RETRIES: i32 = 3;
const DEFAULT_BASE_DELAY_MS: i64 = 100;
const DEFAULT_MAX_DELAY_MS: i64 = 5000;
const MAX_ALLOWED_RETRIES: i32 = 10;
const MAX_ALLOWED_BASE_DELAY_MS: i64 = 5000;
const MAX_ALLOWED_DELAY_MS: i64 = 30000;

/// fetchWithRetry(url, init?, retryOptions?)
///
/// retryOptions shape (all optional):
///   maxRetries    - number of additional attempts after the first (default 3)
///   baseDelayMs   - base delay in ms for exponential backoff (default 100)
///   maxDelayMs    - cap on computed delay (default 5000)
///   retryOn       - array of status codes to retry on (default [429,500,502,503,504])
///
/// A request whose init carries the retired `credential` option is refused
/// with `CredentialRefused` before any request is sent. So is a request with
/// an `authorization`, `proxy-authorization`, or `cookie` header (any case)
/// whose method is not GET, HEAD, or OPTIONS. A credentialed read and a write
/// without a credential are still retried.
///
/// Safety limits: maxRetries <= 10, baseDelayMs <= 5000, maxDelayMs <= 30000.
/// Negative retry/delay values are normalized to 0.
///
/// Backoff formula: delay = min(baseDelayMs * 2^attempt, maxDelayMs)
/// Delays are skipped once the runtime request deadline has passed, because
/// this synchronous native loop is not interrupted by interpreter backedges.
fn fetchWithRetryImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const state = sdk.getModuleState(handle, FetchState, MODULE_STATE_SLOT) orelse {
        return sdk.throwError(handle, "Error", "fetchWithRetry() requires runtime installation (no runtime callback wired)");
    };
    if (args.len == 0) return util.throwTypeError(handle, "fetchWithRetry() requires a URL string");
    try sdk.requireCapability(handle, .runtime_callback);

    // Build the args slice for the underlying fetch call: (url, init).
    const fetch_args = args[0..@min(args.len, 2)];

    // This loop resends a request, a write whose outcome is unknown included,
    // so it never resends a write with a credential (M4 T6 design note,
    // section 5, Q2; v0.26.0 plan Decision 9).
    if (namesCredential(handle, fetch_args)) {
        const refuse = state.refuse_fn orelse {
            return sdk.throwError(handle, "Error", "fetchWithRetry() cannot carry a credential");
        };
        return refuse(state.runtime_ptr, handle, "CredentialRefused", "path_unsupported");
    }

    // Parse retryOptions from the third argument, if present.
    var max_retries: i32 = DEFAULT_MAX_RETRIES;
    var base_delay_ms: i64 = DEFAULT_BASE_DELAY_MS;
    var max_delay_ms: i64 = DEFAULT_MAX_DELAY_MS;
    // retry_on_custom: null means use DEFAULT_RETRY_STATUSES
    var retry_on_custom: ?sdk.JSValue = null;

    if (args.len >= 3 and sdk.isObject(args[2])) {
        const opts = args[2];
        if (sdk.objectGet(handle, opts, "maxRetries")) |v| {
            if (sdk.extractInt(v)) |n| max_retries = n;
        }
        if (sdk.objectGet(handle, opts, "baseDelayMs")) |v| {
            if (sdk.extractInt(v)) |n| base_delay_ms = @intCast(n);
        }
        if (sdk.objectGet(handle, opts, "maxDelayMs")) |v| {
            if (sdk.extractInt(v)) |n| max_delay_ms = @intCast(n);
        }
        if (sdk.objectGet(handle, opts, "retryOn")) |v| {
            if (sdk.isArray(v)) retry_on_custom = v;
        }
    }

    if (normalizeRetryOptions(&max_retries, &base_delay_ms, &max_delay_ms)) |message| {
        return util.throwTypeError(handle, message);
    }

    var last_response: sdk.JSValue = undefined;
    var attempt: i32 = 0;
    while (true) {
        last_response = try state.call_fn(state.runtime_ptr, handle, fetch_args);
        const deadline_passed = requestDeadlinePassed(state, handle);

        // If the response has ok=true, return immediately.
        if (sdk.isObject(last_response)) {
            if (sdk.objectGet(handle, last_response, "ok")) |ok_val| {
                if (ok_val.isTrue()) return last_response;
            }
            // Check whether the status code is in the retryOn list.
            const status_val = sdk.objectGet(handle, last_response, "status");
            const status: i32 = if (status_val) |sv| sdk.extractInt(sv) orelse 0 else 0;
            const should_retry = blk: {
                if (retry_on_custom) |arr| {
                    const len_u32 = sdk.arrayLength(arr) orelse break :blk false;
                    var i: u32 = 0;
                    while (i < len_u32) : (i += 1) {
                        const elem = sdk.arrayGet(handle, arr, i) orelse continue;
                        if (sdk.extractInt(elem)) |code| {
                            if (code == status) break :blk true;
                        }
                    }
                    break :blk false;
                } else {
                    for (DEFAULT_RETRY_STATUSES) |code| {
                        if (code == status) break :blk true;
                    }
                    break :blk false;
                }
            };
            if (!should_retry) return last_response;
        } else {
            // Non-object response (network error path): always retry if attempts remain.
        }

        if (attempt >= max_retries) return last_response;
        if (shouldStopBeforeBackoff(deadline_passed, attempt, max_retries)) return last_response;

        // Compute exponential delay: base * 2^attempt, capped at max.
        const shift: u6 = @intCast(@min(attempt, 62));
        const multiplier: i64 = @as(i64, 1) << shift;
        const delay = @min(base_delay_ms *| multiplier, max_delay_ms);
        if (delay > 0 and @import("builtin").target.os.tag != .freestanding) {
            const delay_ns: u64 = @intCast(delay * std.time.ns_per_ms);
            const ts = std.c.timespec{
                .sec = @intCast(delay_ns / std.time.ns_per_s),
                .nsec = @intCast(delay_ns % std.time.ns_per_s),
            };
            _ = std.c.nanosleep(&ts, null);
        }
        attempt += 1;
    }
}

/// True when the init of a `(url, init)` or `(init)` call must not be resent:
/// it carries the retired `credential` option, or it sends a header named
/// `authorization`, `proxy-authorization`, or `cookie` (any case) with a
/// method that is not safe to repeat. The runtime reads `headers` as a plain
/// object, so this guard reads the same shape.
fn namesCredential(handle: *sdk.ModuleHandle, fetch_args: []const sdk.JSValue) bool {
    for (fetch_args) |arg| {
        if (!sdk.isObject(arg)) continue;
        if (sdk.objectGet(handle, arg, "credential")) |credential| {
            if (!credential.isUndefined()) return true;
        }
        const headers = sdk.objectGet(handle, arg, "headers") orelse continue;
        if (!sdk.isObject(headers)) continue;
        if (headersNameCredential(handle, headers) and !methodIsSafe(handle, arg)) return true;
    }
    return false;
}

const SAFE_METHODS = [_][]const u8{ "GET", "HEAD", "OPTIONS" };

/// A resent GET, HEAD, or OPTIONS repeats no write, so a credential on it
/// grants nothing a single send did not. A missing method is GET. A method
/// this guard cannot read is treated as unsafe.
fn methodIsSafe(handle: *sdk.ModuleHandle, init: sdk.JSValue) bool {
    const method_val = sdk.objectGet(handle, init, "method") orelse return true;
    if (method_val.isUndefined()) return true;
    const method = sdk.extractString(method_val) orelse return false;
    for (SAFE_METHODS) |name| {
        if (std.ascii.eqlIgnoreCase(method, name)) return true;
    }
    return false;
}

const CREDENTIAL_HEADERS = [_][]const u8{ "authorization", "proxy-authorization", "cookie" };

fn headersNameCredential(handle: *sdk.ModuleHandle, headers: sdk.JSValue) bool {
    // A headers object this guard cannot read is treated as a credential:
    // a wrong `false` here resends an authorized request.
    const keys = sdk.objectKeys(handle, headers) catch return true;
    const len = sdk.arrayLength(keys) orelse return true;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key_val = sdk.arrayGet(handle, keys, i) orelse return true;
        const key = sdk.extractString(key_val) orelse return true;
        for (CREDENTIAL_HEADERS) |name| {
            if (std.ascii.eqlIgnoreCase(key, name)) return true;
        }
    }
    return false;
}

fn requestDeadlinePassed(state: *const FetchState, handle: *sdk.ModuleHandle) bool {
    const deadline_passed_fn = state.deadline_passed_fn orelse return false;
    return deadline_passed_fn(state.runtime_ptr, handle);
}

fn shouldStopBeforeBackoff(deadline_passed: bool, attempt: i32, max_retries: i32) bool {
    return deadline_passed or attempt >= max_retries;
}

fn normalizeRetryOptions(max_retries: *i32, base_delay_ms: *i64, max_delay_ms: *i64) ?[]const u8 {
    if (max_retries.* < 0) max_retries.* = 0;
    if (base_delay_ms.* < 0) base_delay_ms.* = 0;
    if (max_delay_ms.* < 0) max_delay_ms.* = 0;

    if (max_retries.* > MAX_ALLOWED_RETRIES) return "fetchWithRetry() maxRetries must be <= 10";
    if (base_delay_ms.* > MAX_ALLOWED_BASE_DELAY_MS) return "fetchWithRetry() baseDelayMs must be <= 5000";
    if (max_delay_ms.* > MAX_ALLOWED_DELAY_MS) return "fetchWithRetry() maxDelayMs must be <= 30000";
    return null;
}

const testing = std.testing;

test "fetchWithRetry retry options reject unbounded sleeps" {
    var retries: i32 = 11;
    var base_delay_ms: i64 = DEFAULT_BASE_DELAY_MS;
    var max_delay_ms: i64 = DEFAULT_MAX_DELAY_MS;
    try testing.expectEqualStrings("fetchWithRetry() maxRetries must be <= 10", normalizeRetryOptions(&retries, &base_delay_ms, &max_delay_ms).?);

    retries = DEFAULT_MAX_RETRIES;
    base_delay_ms = 5001;
    max_delay_ms = DEFAULT_MAX_DELAY_MS;
    try testing.expectEqualStrings("fetchWithRetry() baseDelayMs must be <= 5000", normalizeRetryOptions(&retries, &base_delay_ms, &max_delay_ms).?);

    retries = DEFAULT_MAX_RETRIES;
    base_delay_ms = DEFAULT_BASE_DELAY_MS;
    max_delay_ms = 30001;
    try testing.expectEqualStrings("fetchWithRetry() maxDelayMs must be <= 30000", normalizeRetryOptions(&retries, &base_delay_ms, &max_delay_ms).?);
}

test "fetchWithRetry retry options normalize negative values" {
    var retries: i32 = -1;
    var base_delay_ms: i64 = -10;
    var max_delay_ms: i64 = -20;

    try testing.expect(normalizeRetryOptions(&retries, &base_delay_ms, &max_delay_ms) == null);
    try testing.expectEqual(@as(i32, 0), retries);
    try testing.expectEqual(@as(i64, 0), base_delay_ms);
    try testing.expectEqual(@as(i64, 0), max_delay_ms);
}

test "fetchWithRetry deadline short-circuits before backoff" {
    try testing.expect(shouldStopBeforeBackoff(true, 0, MAX_ALLOWED_RETRIES));
    try testing.expect(!shouldStopBeforeBackoff(false, 0, MAX_ALLOWED_RETRIES));
    try testing.expect(shouldStopBeforeBackoff(false, MAX_ALLOWED_RETRIES, MAX_ALLOWED_RETRIES));
}
