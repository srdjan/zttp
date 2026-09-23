//! zttp:auth - Authentication and JWT utilities
//!
//! Exports:
//!   parseBearer(header) -> string | undefined
//!   jwtVerify(token, secret, options?) -> Result<claims, string>
//!   jwtSign(claims_json, secret) -> string | undefined
//!   verifyWebhookSignature(payload, secret, signature) -> boolean
//!   timingSafeEqual(a, b) -> boolean

const std = @import("std");
const sdk = @import("zttp-sdk");

const base64url = std.base64.url_safe_no_pad;
const MAC_LEN = 32;

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:auth",
    .name = "auth",
    .required_capabilities = &.{ .crypto, .clock },
    .exports = &.{
        .{
            .name = "parseBearer",
            .derives_from_args = true,
            // Splits a header string. Reaches neither crypto nor the clock.
            .required_capabilities = &.{},
            .module_func = parseBearerImpl,
            .arg_count = 1,
            .effect = .none,
            .returns = .optional_string,
            .param_types = &.{.string},
            .param_names = &.{"authorizationHeader"},
            .failure_severity = .expected,
            .contract_flags = .{ .sets_bearer_auth = true },
            .return_labels = .{ .credential = true },
            .laws = &.{.pure},
        },
        .{
            .name = "jwtVerify",
            // hmacSha256 for the signature, nowMs for the exp claim.
            .required_capabilities = &.{ .crypto, .clock },
            .module_func = jwtVerifyImpl,
            .arg_count = 3,
            .required_arg_count = 2,
            .effect = .read,
            .returns = .result,
            // (token, secret, alg?) - the optional third algorithm argument is
            // documented (`jwtVerify(token, secret, "HS256")`), but callers may
            // omit it and use the verifier's HS256 default.
            .param_types = &.{ .string, .string, .string },
            .param_names = &.{ "token", "secret", "algorithm" },
            .failure_severity = .critical,
            .contract_flags = .{ .sets_jwt_auth = true },
            .return_labels = .{ .credential = true, .validated = true },
            .laws = &.{
                .{ .absorbing = .{
                    .arg_position = 0,
                    .argument_shape = .empty_string_literal,
                    .residue = .result_err,
                } },
            },
        },
        // hmacSha256 only: the caller supplies every claim, including exp.
        .{ .name = "jwtSign", .derives_from_args = true, .required_capabilities = &.{.crypto}, .module_func = jwtSignImpl, .arg_count = 2, .effect = .none, .returns = .string, .param_types = &.{ .string, .string }, .param_names = &.{ "claimsJson", "secret" }, .return_labels = .{ .credential = true } },
        .{
            .name = "verifyWebhookSignature",
            // hmacSha256 over the payload; no time window is checked here.
            .required_capabilities = &.{.crypto},
            .module_func = verifyWebhookSignatureImpl,
            .arg_count = 3,
            .effect = .none,
            .returns = .boolean,
            .param_types = &.{ .string, .string, .string },
            .param_names = &.{ "payload", "secret", "signature" },
            .laws = &.{.pure},
        },
        .{
            .name = "timingSafeEqual",
            // A constant-time byte compare. No crypto primitive, no clock.
            .required_capabilities = &.{},
            .module_func = timingSafeEqualImpl,
            .arg_count = 2,
            .effect = .none,
            .returns = .boolean,
            .param_types = &.{ .string, .string },
            .param_names = &.{ "a", "b" },
            .laws = &.{.pure},
        },
    },
};

fn parseBearerImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const header = (sdk.decodeArgs(&.{.string}, args) orelse return sdk.JSValue.undefined_val)[0];

    if (header.len < 7 or !std.ascii.eqlIgnoreCase(header[0..7], "Bearer ")) return sdk.JSValue.undefined_val;
    const token = header[7..];
    if (token.len == 0) return sdk.JSValue.undefined_val;
    return sdk.createString(handle, token) catch sdk.JSValue.undefined_val;
}

fn jwtVerifyImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    if (args.len < 2) return sdk.resultErr(handle, "missing arguments");
    const token_str = sdk.extractString(args[0]) orelse return sdk.resultErr(handle, "token must be a string");
    const secret = sdk.extractString(args[1]) orelse return sdk.resultErr(handle, "secret must be a string");
    if (args.len >= 3) {
        const alg = sdk.extractString(args[2]) orelse return sdk.resultErr(handle, "unsupported alg");
        validateCallerAlgorithm(alg) catch return sdk.resultErr(handle, "unsupported alg");
    }

    const parts = splitToken(token_str) orelse return sdk.resultErr(handle, "invalid token format");

    const allocator = sdk.getAllocator(handle);

    // Reject tokens whose header does not advertise the algorithm we verify
    // against. Without this check the HMAC would still match a forged token
    // that supplied a different `alg` (e.g. "none", "HS512", or omitted),
    // because downstream code never reads the header. Per RFC 7519 §5.1 and
    // RFC 8725 §3, the verifier MUST reject any algorithm it did not expect.
    validateHs256Header(allocator, parts.header_b64) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.HeaderTooLong => sdk.resultErr(handle, "jwt header too long"),
        error.InvalidBase64 => sdk.resultErr(handle, "invalid header encoding"),
        error.InvalidJson => sdk.resultErr(handle, "invalid header JSON"),
        error.MissingAlg => sdk.resultErr(handle, "missing alg header"),
        error.UnsupportedAlg => sdk.resultErr(handle, "unsupported alg"),
    };

    var expected_mac: sdk.HmacSha256Mac = undefined;
    try sdk.hmacSha256(handle, parts.signing_input, secret, &expected_mac);

    checkHs256Signature(parts.signature_b64, &expected_mac) catch |err| return sdk.resultErr(handle, switch (err) {
        error.InvalidEncoding => "invalid signature encoding",
        error.InvalidLength => "invalid signature length",
        error.Mismatch => "invalid signature",
    });

    const payload_bytes = decodeBase64url(allocator, parts.payload_b64) catch
        return sdk.resultErr(handle, "invalid payload encoding");
    defer allocator.free(payload_bytes);

    const claims_val = sdk.parseJson(handle, payload_bytes) catch
        return sdk.resultErr(handle, "invalid claims JSON");

    const now = @divTrunc(sdk.nowMs(handle) catch return sdk.resultErr(handle, "clock error"), 1000);

    // A present-but-non-numeric (or non-finite) exp/nbf must be rejected, not
    // silently treated as unconstrained: otherwise `{"exp":"9"}` bypasses
    // expiry. Only a wholly-absent claim skips the check.
    if (sdk.objectGet(handle, claims_val, "exp")) |exp_val| {
        const exp_f = sdk.extractFloat(exp_val) orelse return sdk.resultErr(handle, "invalid exp claim");
        checkExp(now, exp_f) catch |err| return sdk.resultErr(handle, switch (err) {
            error.InvalidTimeClaim => "invalid exp claim",
            error.Expired => "token expired",
        });
    }
    if (sdk.objectGet(handle, claims_val, "nbf")) |nbf_val| {
        const nbf_f = sdk.extractFloat(nbf_val) orelse return sdk.resultErr(handle, "invalid nbf claim");
        checkNbf(now, nbf_f) catch |err| return sdk.resultErr(handle, switch (err) {
            error.InvalidTimeClaim => "invalid nbf claim",
            error.NotYetValid => "token not yet valid",
        });
    }

    return sdk.resultOk(handle, claims_val);
}

// ---------------------------------------------------------------------------
// Shared HS256 pieces. `jwtVerifyImpl` (the handler export) and `verifyHs256`
// (the pure verifier the runtime calls before a tool handler runs) share the
// token split, the header check, the signature check, and the time checks.
// They differ in the claims parse: `jwtVerify` hands the payload to the JS
// JSON parser and returns the claims object without requiring any claim,
// while `verifyHs256` parses with `std.json`, refuses duplicate keys, and
// requires `sub` and the tenant claim. Requiring those in `jwtVerify` would
// change what the export accepts, so the claims step stays separate.
// ---------------------------------------------------------------------------

/// The dot-separated segments of a compact JWS, plus the signing input
/// (`header.payload`) the MAC covers. The signature segment is everything
/// after the second dot; `verifyHs256` additionally refuses a further dot.
pub const TokenParts = struct {
    header_b64: []const u8,
    payload_b64: []const u8,
    signature_b64: []const u8,
    signing_input: []const u8,
};

pub fn splitToken(token: []const u8) ?TokenParts {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return .{
        .header_b64 = token[0..first_dot],
        .payload_b64 = rest[0..second_dot],
        .signature_b64 = rest[second_dot + 1 ..],
        .signing_input = token[0 .. first_dot + 1 + second_dot],
    };
}

pub const SignatureError = error{ InvalidEncoding, InvalidLength, Mismatch };

/// Decode the base64url signature segment and compare it in constant time
/// with the MAC the caller computed over the signing input.
pub fn checkHs256Signature(signature_b64: []const u8, expected_mac: *const [MAC_LEN]u8) SignatureError!void {
    const sig_clean = trimTrailingPadding(signature_b64);
    const sig_decoded_len = base64url.Decoder.calcSizeForSlice(sig_clean) catch return error.InvalidEncoding;
    if (sig_decoded_len != MAC_LEN) return error.InvalidLength;

    var sig_decoded: [MAC_LEN]u8 = undefined;
    base64url.Decoder.decode(&sig_decoded, sig_clean) catch return error.InvalidEncoding;

    if (!constTimeEqlSlice(&sig_decoded, expected_mac)) return error.Mismatch;
}

/// A present `exp` must be a finite number, and the token is expired from
/// the `exp` second on. lossyCast clamps the in-range conversion so a huge
/// value cannot panic.
pub fn checkExp(now_s: i64, exp: f64) error{ InvalidTimeClaim, Expired }!void {
    if (!std.math.isFinite(exp)) return error.InvalidTimeClaim;
    if (isExpired(now_s, std.math.lossyCast(i64, exp))) return error.Expired;
}

/// A present `nbf` must be a finite number, and the token is not valid
/// before the `nbf` second.
pub fn checkNbf(now_s: i64, nbf: f64) error{ InvalidTimeClaim, NotYetValid }!void {
    if (!std.math.isFinite(nbf)) return error.InvalidTimeClaim;
    if (now_s < std.math.lossyCast(i64, nbf)) return error.NotYetValid;
}

// ---------------------------------------------------------------------------
// verifyHs256 - the pure verifier.
//
// It reaches no capability itself. The HMAC comes from the caller through
// `Hs256Mac`: the runtime supplies std's HMAC-SHA256, and module code
// supplies `moduleMac(handle)`, which routes through the capability-checked
// `sdk.hmacSha256`. This keeps the file free of direct crypto, as
// `scripts/check-capability-helpers.sh` requires of every virtual module.
// The clock is the `now_s` argument for the same reason.
// ---------------------------------------------------------------------------

pub const VerifyRefusal = enum {
    malformed,
    unsupported_alg,
    bad_signature,
    expired,
    not_yet_valid,
    missing_sub,
    missing_tenant,
    claim_not_string,
    invalid_time_claim,
};

/// The verified identity. `arena` owns both strings; `deinit` releases them.
pub const Claims = struct {
    arena: std.heap.ArenaAllocator,
    subject: []const u8,
    tenant: []const u8,

    pub fn deinit(self: *Claims) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const VerifyResult = union(enum) {
    ok: Claims,
    refused: VerifyRefusal,
};

pub const MacError = error{MacUnavailable};

/// A caller-supplied HMAC-SHA256. `compute` receives `context` unchanged.
pub const Hs256Mac = struct {
    context: ?*anyopaque,
    compute: *const fn (context: ?*anyopaque, message: []const u8, key: []const u8, out: *[MAC_LEN]u8) MacError!void,
};

/// The HMAC a virtual module supplies: `sdk.hmacSha256` on `handle`, which
/// checks the `crypto` capability first.
pub fn moduleMac(handle: *sdk.ModuleHandle) Hs256Mac {
    return .{ .context = @ptrCast(handle), .compute = moduleMacCompute };
}

fn moduleMacCompute(context: ?*anyopaque, message: []const u8, key: []const u8, out: *[MAC_LEN]u8) MacError!void {
    const handle: *sdk.ModuleHandle = @ptrCast(context orelse return error.MacUnavailable);
    sdk.hmacSha256(handle, message, key, out) catch return error.MacUnavailable;
}

pub const VerifyError = std.mem.Allocator.Error || MacError;

/// Verify a compact HS256 JWT with `key` at `now_s` (Unix seconds) and
/// extract `sub` and the claim that `tenant_claim` names. Every token defect
/// is a `.refused` value; only allocation failure and an unavailable MAC are
/// errors.
pub fn verifyHs256(
    allocator: std.mem.Allocator,
    token: []const u8,
    key: []const u8,
    tenant_claim: []const u8,
    now_s: i64,
    mac: Hs256Mac,
) VerifyError!VerifyResult {
    const parts = splitToken(token) orelse return refuse(.malformed);
    if (std.mem.indexOfScalar(u8, parts.signature_b64, '.') != null) return refuse(.malformed);

    validateHs256Header(allocator, parts.header_b64) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.HeaderTooLong, error.InvalidBase64, error.InvalidJson => refuse(.malformed),
        error.MissingAlg, error.UnsupportedAlg => refuse(.unsupported_alg),
    };

    var expected_mac: [MAC_LEN]u8 = undefined;
    try mac.compute(mac.context, parts.signing_input, key, &expected_mac);
    checkHs256Signature(parts.signature_b64, &expected_mac) catch return refuse(.bad_signature);

    const payload_bytes = decodeBase64url(allocator, parts.payload_b64) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBase64 => refuse(.malformed),
    };
    defer allocator.free(payload_bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => refuse(.malformed),
    };
    defer parsed.deinit();

    const claims = switch (parsed.value) {
        .object => |o| o,
        else => return refuse(.malformed),
    };

    if (claims.get("exp")) |exp_val| {
        const exp_f = jsonNumber(exp_val) orelse return refuse(.invalid_time_claim);
        checkExp(now_s, exp_f) catch |err| return refuse(switch (err) {
            error.InvalidTimeClaim => .invalid_time_claim,
            error.Expired => .expired,
        });
    }
    if (claims.get("nbf")) |nbf_val| {
        const nbf_f = jsonNumber(nbf_val) orelse return refuse(.invalid_time_claim);
        checkNbf(now_s, nbf_f) catch |err| return refuse(switch (err) {
            error.InvalidTimeClaim => .invalid_time_claim,
            error.NotYetValid => .not_yet_valid,
        });
    }

    const subject = switch (requiredString(claims, "sub")) {
        .value => |s| s,
        .absent => return refuse(.missing_sub),
        .not_string => return refuse(.claim_not_string),
    };
    const tenant = switch (requiredString(claims, tenant_claim)) {
        .value => |s| s,
        .absent => return refuse(.missing_tenant),
        .not_string => return refuse(.claim_not_string),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned_subject = try arena.allocator().dupe(u8, subject);
    const owned_tenant = try arena.allocator().dupe(u8, tenant);
    return .{ .ok = .{ .arena = arena, .subject = owned_subject, .tenant = owned_tenant } };
}

fn refuse(reason: VerifyRefusal) VerifyResult {
    return .{ .refused = reason };
}

/// A JSON number as f64, or null for any other value. `std.json` keeps an
/// integer beyond i64 as `number_string`; it is still a number.
fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

const RequiredString = union(enum) { value: []const u8, absent, not_string };

/// A claim that must be a non-empty string. An empty string counts as
/// absent: an empty subject or tenant names no one.
fn requiredString(claims: std.json.ObjectMap, name: []const u8) RequiredString {
    const value = claims.get(name) orelse return .absent;
    return switch (value) {
        .string => |s| if (s.len == 0) .absent else .{ .value = s },
        else => .not_string,
    };
}

const HEADER_HS256_B64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

fn validateCallerAlgorithm(alg: []const u8) error{UnsupportedAlg}!void {
    if (!std.mem.eql(u8, alg, "HS256")) return error.UnsupportedAlg;
}

fn isExpired(now: i64, exp: i64) bool {
    return now >= exp;
}

fn jwtSignImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const claims_json, const secret = sdk.decodeArgs(&.{ .string, .string }, args) orelse return sdk.JSValue.undefined_val;

    const allocator = sdk.getAllocator(handle);

    const payload_b64 = encodeBase64url(allocator, claims_json) catch return sdk.JSValue.undefined_val;
    defer allocator.free(payload_b64);

    const signing_input_len = checkedJoinLen(HEADER_HS256_B64.len, 1, payload_b64.len) orelse
        return sdk.JSValue.undefined_val;
    const signing_input = allocator.alloc(u8, signing_input_len) catch return sdk.JSValue.undefined_val;
    defer allocator.free(signing_input);
    @memcpy(signing_input[0..HEADER_HS256_B64.len], HEADER_HS256_B64);
    signing_input[HEADER_HS256_B64.len] = '.';
    @memcpy(signing_input[HEADER_HS256_B64.len + 1 ..], payload_b64);

    var mac: sdk.HmacSha256Mac = undefined;
    try sdk.hmacSha256(handle, signing_input, secret, &mac);

    const sig_b64 = encodeBase64url(allocator, &mac) catch return sdk.JSValue.undefined_val;
    defer allocator.free(sig_b64);

    const total_len = checkedJoinLen(signing_input_len, 1, sig_b64.len) orelse
        return sdk.JSValue.undefined_val;
    const result = allocator.alloc(u8, total_len) catch return sdk.JSValue.undefined_val;
    defer allocator.free(result);
    @memcpy(result[0..signing_input_len], signing_input);
    result[signing_input_len] = '.';
    @memcpy(result[signing_input_len + 1 ..], sig_b64);

    return sdk.createString(handle, result) catch sdk.JSValue.undefined_val;
}

fn verifyWebhookSignatureImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const payload, const secret, const sig_str = sdk.decodeArgs(&.{ .string, .string, .string }, args) orelse return sdk.JSValue.false_val;

    var expected_mac: sdk.HmacSha256Mac = undefined;
    try sdk.hmacSha256(handle, payload, secret, &expected_mac);
    const expected_hex = std.fmt.bytesToHex(expected_mac, .lower);

    const provided_hex = if (sig_str.len > 7 and std.mem.eql(u8, sig_str[0..7], "sha256="))
        sig_str[7..]
    else
        sig_str;

    if (provided_hex.len != expected_hex.len) return sdk.JSValue.false_val;
    return if (constTimeEqlSlice(provided_hex, &expected_hex)) sdk.JSValue.true_val else sdk.JSValue.false_val;
}

fn timingSafeEqualImpl(_: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const a, const b = sdk.decodeArgs(&.{ .string, .string }, args) orelse return sdk.JSValue.false_val;
    if (a.len != b.len) return sdk.JSValue.false_val;
    return if (constTimeEqlSlice(a, b)) sdk.JSValue.true_val else sdk.JSValue.false_val;
}

fn trimTrailingPadding(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '=') : (end -= 1) {}
    return input[0..end];
}

fn constTimeEqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ab, bb| diff |= ab ^ bb;
    return diff == 0;
}

fn decodeBase64url(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const clean = trimTrailingPadding(encoded);
    const decoded_len = base64url.Decoder.calcSizeForSlice(clean) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);
    base64url.Decoder.decode(buf, clean) catch return error.InvalidBase64;
    return buf;
}

fn encodeBase64url(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = base64url.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = base64url.Encoder.encode(buf, data);
    return buf;
}

fn checkedJoinLen(a: usize, b: usize, c: usize) ?usize {
    const ab = std.math.add(usize, a, b) catch return null;
    return std.math.add(usize, ab, c) catch null;
}

pub const JwtHeaderError = error{
    HeaderTooLong,
    InvalidBase64,
    InvalidJson,
    MissingAlg,
    UnsupportedAlg,
};

/// Largest JWT header we will parse. Real-world JWT headers carry `alg`,
/// `typ`, and occasionally `kid` or `cty` — well under 256 bytes encoded.
/// A 1 KiB ceiling rejects any obvious DoS via attacker-controlled headers
/// while leaving room for legitimate metadata.
const MAX_JWT_HEADER_LEN = 1024;

/// Validate that a base64url-encoded JWT header advertises the algorithm
/// we will verify against (HS256, the only `alg` the matching `jwtSign`
/// emits). Without this check the verifier would HMAC whatever it received
/// and accept tokens whose header claimed `none`, `HS512`, `RS256`, or
/// nothing at all — every classical JWT algorithm-confusion class begins
/// with the verifier failing to enforce the expected `alg`. See RFC 7519
/// §5.1 ("the `alg` Header Parameter") and RFC 8725 §3 ("Perform Algorithm
/// Verification").
///
/// Allocation failure is `error.OutOfMemory`, never a header verdict, so a
/// caller cannot mistake an exhausted allocator for a malformed token.
pub fn validateHs256Header(allocator: std.mem.Allocator, header_b64: []const u8) (JwtHeaderError || std.mem.Allocator.Error)!void {
    if (header_b64.len > MAX_JWT_HEADER_LEN) return error.HeaderTooLong;

    const clean = trimTrailingPadding(header_b64);
    const decoded_len = base64url.Decoder.calcSizeForSlice(clean) catch return error.InvalidBase64;
    if (decoded_len > MAX_JWT_HEADER_LEN) return error.HeaderTooLong;

    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    base64url.Decoder.decode(decoded, clean) catch return error.InvalidBase64;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    const alg_value = obj.get("alg") orelse return error.MissingAlg;
    const alg_str = switch (alg_value) {
        .string => |s| s,
        else => return error.UnsupportedAlg,
    };

    if (!std.mem.eql(u8, alg_str, "HS256")) return error.UnsupportedAlg;
}

// ---------------------------------------------------------------------------
// Tests for the pure helpers. The runtime-coupled paths (jwtVerify,
// jwtSign, parseBearer, etc.) interact with sdk.extractString and
// sdk.parseJson, which are no-op stubs in the test_shim — those need
// handler-level integration coverage, not unit tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "constTimeEqlSlice: equality, inequality, length mismatch" {
    try testing.expect(constTimeEqlSlice("abc", "abc"));
    try testing.expect(!constTimeEqlSlice("abc", "abd"));
    try testing.expect(!constTimeEqlSlice("abc", "ab"));
    try testing.expect(!constTimeEqlSlice("", "x"));
    try testing.expect(constTimeEqlSlice("", ""));

    // Differs only in the last byte — must still return false (catches an
    // accidental early-return optimisation that would re-introduce a
    // timing oracle).
    const a = "0123456789abcdef0123456789abcdee";
    const b = "0123456789abcdef0123456789abcdef";
    try testing.expect(!constTimeEqlSlice(a, b));
}

test "trimTrailingPadding strips one or more `=` characters" {
    try testing.expectEqualStrings("abc", trimTrailingPadding("abc"));
    try testing.expectEqualStrings("abc", trimTrailingPadding("abc="));
    try testing.expectEqualStrings("abc", trimTrailingPadding("abc=="));
    try testing.expectEqualStrings("", trimTrailingPadding("===="));
    try testing.expectEqualStrings("a=b", trimTrailingPadding("a=b"));
    try testing.expectEqualStrings("a=b", trimTrailingPadding("a=b="));
}

test "base64url encode/decode round-trip for arbitrary bytes" {
    const allocator = testing.allocator;
    const inputs = [_][]const u8{
        "",
        "f",
        "fo",
        "foo",
        "foob",
        "fooba",
        "foobar",
        "Many hands make light work.",
    };
    for (inputs) |input| {
        const encoded = try encodeBase64url(allocator, input);
        defer allocator.free(encoded);

        // base64url uses `-` and `_` instead of `+` and `/`, and no `=`.
        for (encoded) |c| {
            try testing.expect(c != '+' and c != '/' and c != '=');
        }

        const decoded = try decodeBase64url(allocator, encoded);
        defer allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }
}

test "checkedJoinLen rejects overflow" {
    try testing.expectEqual(@as(?usize, 6), checkedJoinLen(1, 2, 3));
    try testing.expect(checkedJoinLen(std.math.maxInt(usize), 1, 0) == null);
    try testing.expect(checkedJoinLen(std.math.maxInt(usize) - 1, 1, 1) == null);
}

test "validateCallerAlgorithm accepts only HS256" {
    try validateCallerAlgorithm("HS256");
    try testing.expectError(error.UnsupportedAlg, validateCallerAlgorithm("HS512"));
    try testing.expectError(error.UnsupportedAlg, validateCallerAlgorithm("none"));
    try testing.expectError(error.UnsupportedAlg, validateCallerAlgorithm("hs256"));
}

test "isExpired rejects tokens at exp boundary" {
    try testing.expect(!isExpired(99, 100));
    try testing.expect(isExpired(100, 100));
    try testing.expect(isExpired(101, 100));
}

test "decodeBase64url tolerates trailing `=` padding the encoder never emits" {
    // Some JWT libraries still emit padded base64url. The decoder must
    // accept both forms, otherwise we'd reject valid third-party tokens.
    const allocator = testing.allocator;
    const padded = "Zm9v"; // canonical, no padding
    const decoded = try decodeBase64url(allocator, padded);
    defer allocator.free(decoded);
    try testing.expectEqualStrings("foo", decoded);

    const padded_with_eq = "Zm9v==";
    const decoded2 = try decodeBase64url(allocator, padded_with_eq);
    defer allocator.free(decoded2);
    try testing.expectEqualStrings("foo", decoded2);
}

// ---------------------------------------------------------------------------
// validateHs256Header — guards against JWT algorithm-confusion bugs. The
// previous jwtVerifyImpl never read the header and would HMAC any token
// whose three dot-separated segments parsed, so a forged header that
// claimed `alg=none`, `alg=HS512`, or omitted `alg` slipped through as
// long as the signature happened to match the supplied secret. These
// tests pin the verifier to HS256 explicitly.
// ---------------------------------------------------------------------------

fn headerForTest(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    return encodeBase64url(allocator, json);
}

test "validateHs256Header accepts a real HS256 header" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
    defer allocator.free(header);
    try validateHs256Header(allocator, header);
}

test "validateHs256Header accepts the canonical jwtSign header verbatim" {
    // jwtSign emits HEADER_HS256_B64 verbatim; the verifier must accept it.
    try validateHs256Header(testing.allocator, HEADER_HS256_B64);
}

test "validateHs256Header rejects alg=none" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"alg\":\"none\"}");
    defer allocator.free(header);
    try testing.expectError(error.UnsupportedAlg, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects alg=HS512" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"alg\":\"HS512\"}");
    defer allocator.free(header);
    try testing.expectError(error.UnsupportedAlg, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects alg=RS256 (would otherwise enable HMAC-with-public-key confusion downstream)" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"alg\":\"RS256\"}");
    defer allocator.free(header);
    try testing.expectError(error.UnsupportedAlg, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects missing alg" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"typ\":\"JWT\"}");
    defer allocator.free(header);
    try testing.expectError(error.MissingAlg, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects non-string alg" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"alg\":42}");
    defer allocator.free(header);
    try testing.expectError(error.UnsupportedAlg, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects non-object JSON" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "\"not an object\"");
    defer allocator.free(header);
    try testing.expectError(error.InvalidJson, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects malformed JSON inside the base64" {
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{not json");
    defer allocator.free(header);
    try testing.expectError(error.InvalidJson, validateHs256Header(allocator, header));
}

test "validateHs256Header rejects invalid base64url" {
    // The character `!` is not in the base64url alphabet.
    try testing.expectError(error.InvalidBase64, validateHs256Header(testing.allocator, "!!!!"));
}

test "validateHs256Header rejects oversized headers" {
    // 2 KiB of `A`s — past the 1 KiB ceiling.
    const allocator = testing.allocator;
    const huge = try allocator.alloc(u8, MAX_JWT_HEADER_LEN + 1);
    defer allocator.free(huge);
    @memset(huge, 'A');
    try testing.expectError(error.HeaderTooLong, validateHs256Header(allocator, huge));
}

test "validateHs256Header is case-sensitive on alg value" {
    // RFC 7518 §3.1 defines `alg` values as case-sensitive strings; "hs256"
    // is not a valid alias for "HS256".
    const allocator = testing.allocator;
    const header = try headerForTest(allocator, "{\"alg\":\"hs256\"}");
    defer allocator.free(header);
    try testing.expectError(error.UnsupportedAlg, validateHs256Header(allocator, header));
}

// ---------------------------------------------------------------------------
// verifyHs256. Tokens are signed in the test through `moduleMac`, which
// routes through `sdk.hmacSha256`; the sdk test shim computes a real
// HMAC-SHA256, which the RFC 4231 known-answer test below pins, so a token
// signed with a different key really carries a different signature.
// ---------------------------------------------------------------------------

const test_handle: *sdk.ModuleHandle = @ptrFromInt(8);
const test_key = "test-key-0123456789";
const test_now: i64 = 1_700_000_000;

/// Build `base64url(header).base64url(payload).base64url(hmac)` signed with
/// `key`.
fn signForTest(allocator: std.mem.Allocator, header_json: []const u8, payload_json: []const u8, key: []const u8) ![]u8 {
    const header_b64 = try encodeBase64url(allocator, header_json);
    defer allocator.free(header_b64);
    const payload_b64 = try encodeBase64url(allocator, payload_json);
    defer allocator.free(payload_b64);
    const signing_input = try std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64 });
    defer allocator.free(signing_input);

    var mac: [MAC_LEN]u8 = undefined;
    const m = moduleMac(test_handle);
    try m.compute(m.context, signing_input, key, &mac);
    const sig_b64 = try encodeBase64url(allocator, &mac);
    defer allocator.free(sig_b64);
    return std.mem.concat(allocator, u8, &.{ signing_input, ".", sig_b64 });
}

const hs256_header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

fn verifyForTest(allocator: std.mem.Allocator, token: []const u8) VerifyError!VerifyResult {
    return verifyHs256(allocator, token, test_key, "tid", test_now, moduleMac(test_handle));
}

fn expectRefused(expected: VerifyRefusal, token: []const u8) !void {
    var result = try verifyForTest(testing.allocator, token);
    switch (result) {
        .ok => |*claims| {
            claims.deinit();
            std.debug.print("expected refusal {s}, got ok\n", .{@tagName(expected)});
            return error.TestUnexpectedResult;
        },
        .refused => |reason| try testing.expectEqual(expected, reason),
    }
}

fn expectPayloadRefused(expected: VerifyRefusal, payload_json: []const u8) !void {
    const token = try signForTest(testing.allocator, hs256_header, payload_json, test_key);
    defer testing.allocator.free(token);
    try expectRefused(expected, token);
}

/// One token per refusal. The switch is exhaustive, so a new member does not
/// compile until it has a case.
fn refusalCase(allocator: std.mem.Allocator, reason: VerifyRefusal) ![]u8 {
    return switch (reason) {
        .malformed => allocator.dupe(u8, "only.two"),
        .unsupported_alg => signForTest(allocator, "{\"alg\":\"none\"}", "{\"sub\":\"u1\",\"tid\":\"t1\"}", test_key),
        .bad_signature => signForTest(allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\"}", "another-key"),
        .expired => signForTest(allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":1700000000}", test_key),
        .not_yet_valid => signForTest(allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\",\"nbf\":1700000001}", test_key),
        .missing_sub => signForTest(allocator, hs256_header, "{\"tid\":\"t1\"}", test_key),
        .missing_tenant => signForTest(allocator, hs256_header, "{\"sub\":\"u1\"}", test_key),
        .claim_not_string => signForTest(allocator, hs256_header, "{\"sub\":42,\"tid\":\"t1\"}", test_key),
        .invalid_time_claim => signForTest(allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":\"9999999999\"}", test_key),
    };
}

test "test shim HMAC-SHA256 matches RFC 4231 test case 2" {
    var mac: [MAC_LEN]u8 = undefined;
    const m = moduleMac(test_handle);
    try m.compute(m.context, "what do ya want for nothing?", "Jefe", &mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    try testing.expectEqualStrings("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", &hex);
}

test "verifyHs256 accepts a valid token and returns subject and tenant" {
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"user-7\",\"tid\":\"acme\",\"exp\":1700000001,\"nbf\":1700000000}", test_key);
    defer testing.allocator.free(token);
    var result = try verifyForTest(testing.allocator, token);
    switch (result) {
        .ok => |*claims| {
            defer claims.deinit();
            try testing.expectEqualStrings("user-7", claims.subject);
            try testing.expectEqualStrings("acme", claims.tenant);
        },
        .refused => |reason| {
            std.debug.print("unexpected refusal {s}\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
    }
}

test "verifyHs256 reads the tenant from the claim the caller names" {
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"wrong\",\"org\":\"right\"}", test_key);
    defer testing.allocator.free(token);
    var result = try verifyHs256(testing.allocator, token, test_key, "org", test_now, moduleMac(test_handle));
    switch (result) {
        .ok => |*claims| {
            defer claims.deinit();
            try testing.expectEqualStrings("right", claims.tenant);
        },
        .refused => return error.TestUnexpectedResult,
    }
}

test "verifyHs256 census: every refusal is produced by its case" {
    var seen: usize = 0;
    for (std.meta.tags(VerifyRefusal)) |reason| {
        const token = try refusalCase(testing.allocator, reason);
        defer testing.allocator.free(token);
        try expectRefused(reason, token);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 9), seen);
}

test "verifyHs256 refuses a token that is not exactly three parts as malformed" {
    try expectRefused(.malformed, "");
    try expectRefused(.malformed, "abc");
    try expectRefused(.malformed, "a.b");
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\"}", test_key);
    defer testing.allocator.free(token);
    const four = try std.mem.concat(testing.allocator, u8, &.{ token, ".x" });
    defer testing.allocator.free(four);
    try expectRefused(.malformed, four);
}

test "verifyHs256 refuses a bad header encoding or header JSON as malformed" {
    try expectRefused(.malformed, "!!!!.e30.AAAA");
    const token = try signForTest(testing.allocator, "{not json", "{\"sub\":\"u1\",\"tid\":\"t1\"}", test_key);
    defer testing.allocator.free(token);
    try expectRefused(.malformed, token);
}

test "verifyHs256 refuses alg none, alg HS512, and a missing alg as unsupported_alg" {
    const headers = [_][]const u8{ "{\"alg\":\"none\"}", "{\"alg\":\"HS512\"}", "{\"typ\":\"JWT\"}" };
    for (headers) |header| {
        const token = try signForTest(testing.allocator, header, "{\"sub\":\"u1\",\"tid\":\"t1\"}", test_key);
        defer testing.allocator.free(token);
        try expectRefused(.unsupported_alg, token);
    }
}

test "verifyHs256 refuses a token signed with a different key as bad_signature" {
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\"}", "not-the-test-key");
    defer testing.allocator.free(token);
    try expectRefused(.bad_signature, token);
}

test "verifyHs256 refuses a truncated or undecodable signature as bad_signature" {
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\"}", test_key);
    defer testing.allocator.free(token);
    try expectRefused(.bad_signature, token[0 .. token.len - 4]);
    const last_dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return error.TestUnexpectedResult;
    const bad = try std.mem.concat(testing.allocator, u8, &.{ token[0 .. last_dot + 1], "!!!!" });
    defer testing.allocator.free(bad);
    try expectRefused(.bad_signature, bad);
}

test "verifyHs256 refuses a duplicate sub key as malformed" {
    try expectPayloadRefused(.malformed, "{\"sub\":\"u1\",\"sub\":\"admin\",\"tid\":\"t1\"}");
}

test "verifyHs256 refuses a payload that is not a JSON object as malformed" {
    try expectPayloadRefused(.malformed, "[\"sub\"]");
    try expectPayloadRefused(.malformed, "{\"sub\":");
}

test "verifyHs256 refuses at the exp second and before the nbf second" {
    try expectPayloadRefused(.expired, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":1700000000}");
    try expectPayloadRefused(.expired, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":1.0}");
    try expectPayloadRefused(.not_yet_valid, "{\"sub\":\"u1\",\"tid\":\"t1\",\"nbf\":1700000001}");
}

test "verifyHs256 refuses a non-numeric or non-finite exp or nbf as invalid_time_claim" {
    try expectPayloadRefused(.invalid_time_claim, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":\"9999999999\"}");
    try expectPayloadRefused(.invalid_time_claim, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":null}");
    try expectPayloadRefused(.invalid_time_claim, "{\"sub\":\"u1\",\"tid\":\"t1\",\"exp\":1e999}");
    try expectPayloadRefused(.invalid_time_claim, "{\"sub\":\"u1\",\"tid\":\"t1\",\"nbf\":true}");
}

test "verifyHs256 refuses an absent or empty sub and tenant" {
    try expectPayloadRefused(.missing_sub, "{\"tid\":\"t1\"}");
    try expectPayloadRefused(.missing_sub, "{\"sub\":\"\",\"tid\":\"t1\"}");
    try expectPayloadRefused(.missing_tenant, "{\"sub\":\"u1\"}");
    try expectPayloadRefused(.missing_tenant, "{\"sub\":\"u1\",\"tid\":\"\"}");
}

test "verifyHs256 refuses a non-string sub or tenant as claim_not_string" {
    try expectPayloadRefused(.claim_not_string, "{\"sub\":42,\"tid\":\"t1\"}");
    try expectPayloadRefused(.claim_not_string, "{\"sub\":\"u1\",\"tid\":[\"t1\"]}");
}

test "verifyHs256 propagates a MAC failure as an error, not a verdict" {
    const Failing = struct {
        fn compute(_: ?*anyopaque, _: []const u8, _: []const u8, _: *[MAC_LEN]u8) MacError!void {
            return error.MacUnavailable;
        }
    };
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"u1\",\"tid\":\"t1\"}", test_key);
    defer testing.allocator.free(token);
    try testing.expectError(error.MacUnavailable, verifyHs256(testing.allocator, token, test_key, "tid", test_now, .{ .context = null, .compute = Failing.compute }));
}

fn verifyUnderAllocationFailure(allocator: std.mem.Allocator, token: []const u8) !void {
    var result = try verifyForTest(allocator, token);
    switch (result) {
        .ok => |*claims| claims.deinit(),
        // A refusal here would mean an allocation failure was reported as a
        // token verdict.
        .refused => return error.TestUnexpectedResult,
    }
}

test "verifyHs256 reports every allocation failure as OutOfMemory without leaking" {
    const token = try signForTest(testing.allocator, hs256_header, "{\"sub\":\"user-7\",\"tid\":\"acme\",\"exp\":1700000001}", test_key);
    defer testing.allocator.free(token);
    try testing.checkAllAllocationFailures(testing.allocator, verifyUnderAllocationFailure, .{token});
}
