//! zttp:crypto - Cryptographic functions
//!
//! Exports:
//!   sha256(data: string) -> string          Hex-encoded SHA-256 hash
//!   hmacSha256(key: string, data: string) -> string  Hex-encoded HMAC-SHA256
//!   base64Encode(data: string) -> string    Base64-encoded string
//!   base64Decode(data: string) -> string    Decoded base64 string

const std = @import("std");
const sdk = @import("zttp-sdk");

// Every export is `derives_from_args`, and `base64Encode` is the one that makes
// the reason plain: its output *is* its input, in another alphabet. Before the
// flag, `base64Encode(env("API_SECRET"))` returned to the response body with
// `no_secret_leakage` PROVEN.
//
// `sha256` and `hmacSha256` are the arguable ones, and they are marked for the
// same reason. A hash is one-way, so the argument that it declassifies is
// available - which is exactly why leaving it undecided is dangerous. This
// registry has no way to say "one-way", the analysis has no way to check one,
// and an unsalted hash of a low-entropy secret is recoverable. A deliberate
// declassification is spelled by an export that declares what it clears, the
// way `mask` does.
pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:crypto",
    .name = "crypto",
    .summary = "hmacSha256 takes the key first and the message second.",
    .required_capabilities = &.{.crypto},
    .exports = &.{
        .{
            .name = "sha256",
            .derives_from_args = true,
            // Reaches sha256Checked through the SDK, which is what `.crypto`
            // gates.
            .required_capabilities = &.{.crypto},
            .module_func = sha256Impl,
            .arg_count = 1,
            .effect = .none,
            .returns = .string,
            .param_types = &.{.string},
            .param_names = &.{"text"},
            .laws = &.{.pure},
        },
        .{
            .name = "hmacSha256",
            .derives_from_args = true,
            .required_capabilities = &.{.crypto},
            .module_func = hmacSha256Impl,
            .arg_count = 2,
            .effect = .none,
            .returns = .string,
            .param_types = &.{ .string, .string },
            .param_names = &.{ "key", "message" },
            .laws = &.{.pure},
        },
        .{
            .name = "base64Encode",
            .derives_from_args = true,
            // Base64 is a transport encoding, not a cryptographic one. The impl
            // is `std.base64` over the module allocator and reaches no gated
            // helper, so charging it `.crypto` made every ceiling over a
            // base64-encoding handler wrong on its face.
            .required_capabilities = &.{},
            .module_func = base64EncodeImpl,
            .arg_count = 1,
            .effect = .none,
            .returns = .string,
            .param_types = &.{.string},
            .param_names = &.{"text"},
            .laws = &.{ .pure, .{ .inverse_of = "base64Decode" } },
        },
        .{
            .name = "base64Decode",
            .derives_from_args = true,
            .required_capabilities = &.{},
            .module_func = base64DecodeImpl,
            .arg_count = 1,
            .effect = .none,
            .returns = .string,
            .param_types = &.{.string},
            .param_names = &.{"text"},
            .laws = &.{ .pure, .{ .inverse_of = "base64Encode" } },
        },
    },
};

fn sha256Impl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const data = (sdk.decodeArgs(&.{.string}, args) orelse return sdk.JSValue.undefined_val)[0];

    var digest: sdk.Sha256Digest = undefined;
    try sdk.sha256(handle, data, &digest);

    const hex = std.fmt.bytesToHex(digest, .lower);
    return sdk.createString(handle, &hex) catch sdk.JSValue.undefined_val;
}

fn hmacSha256Impl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const key, const data = sdk.decodeArgs(&.{ .string, .string }, args) orelse return sdk.JSValue.undefined_val;

    var mac: sdk.HmacSha256Mac = undefined;
    try sdk.hmacSha256(handle, data, key, &mac);

    const hex = std.fmt.bytesToHex(mac, .lower);
    return sdk.createString(handle, &hex) catch sdk.JSValue.undefined_val;
}

fn base64EncodeImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const data = (sdk.decodeArgs(&.{.string}, args) orelse return sdk.JSValue.undefined_val)[0];

    const encoder = std.base64.standard;
    const encoded_len = encoder.Encoder.calcSize(data.len);

    const allocator = sdk.getAllocator(handle);
    const buf = allocator.alloc(u8, encoded_len) catch return sdk.JSValue.undefined_val;
    defer allocator.free(buf);

    const encoded = encoder.Encoder.encode(buf, data);
    return sdk.createString(handle, encoded) catch sdk.JSValue.undefined_val;
}

fn base64DecodeImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    const data = (sdk.decodeArgs(&.{.string}, args) orelse return sdk.JSValue.undefined_val)[0];

    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(data) catch return sdk.JSValue.undefined_val;

    const allocator = sdk.getAllocator(handle);
    const buf = allocator.alloc(u8, decoded_len) catch return sdk.JSValue.undefined_val;
    defer allocator.free(buf);

    decoder.Decoder.decode(buf, data) catch return sdk.JSValue.undefined_val;
    return sdk.createString(handle, buf[0..decoded_len]) catch sdk.JSValue.undefined_val;
}
