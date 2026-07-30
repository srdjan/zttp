const std = @import("std");
const sdk = @import("zttp-sdk");
const test_shim = @import("zttp-sdk-test-shim");

test {
    std.testing.refAllDecls(sdk);
    std.testing.refAllDecls(test_shim);
}

test "numberFromF64 folds safe-integer floats to int tag" {
    try std.testing.expect(sdk.numberFromF64(0.0).isInt());
    try std.testing.expectEqual(@as(i32, 0), sdk.numberFromF64(0.0).getInt());
    try std.testing.expectEqual(@as(i32, 42), sdk.numberFromF64(42.0).getInt());
    try std.testing.expectEqual(@as(i32, -1), sdk.numberFromF64(-1.0).getInt());
    try std.testing.expectEqual(@as(i32, 2147483647), sdk.numberFromF64(2147483647.0).getInt());
    try std.testing.expectEqual(@as(i32, -2147483648), sdk.numberFromF64(-2147483648.0).getInt());
}

test "numberFromF64 keeps non-integer and out-of-range as float" {
    try std.testing.expect(!sdk.numberFromF64(0.5).isInt());
    try std.testing.expectEqual(@as(f64, 0.5), sdk.numberFromF64(0.5).toFloat().?);
    try std.testing.expect(!sdk.numberFromF64(2147483648.0).isInt());
    try std.testing.expect(!sdk.numberFromF64(-2147483649.0).isInt());
    try std.testing.expect(!sdk.numberFromF64(std.math.inf(f64)).isInt());
    try std.testing.expect(!sdk.numberFromF64(-std.math.inf(f64)).isInt());
    try std.testing.expect(!sdk.numberFromF64(std.math.nan(f64)).isInt());
}

test "extractInt accepts int tag and whole-number floats" {
    try std.testing.expectEqual(@as(?i32, 7), sdk.extractInt(sdk.JSValue.fromInt(7)));
    try std.testing.expectEqual(@as(?i32, 7), sdk.extractInt(sdk.JSValue.fromFloat(7.0)));
    try std.testing.expectEqual(@as(?i32, -3), sdk.extractInt(sdk.JSValue.fromFloat(-3.0)));
    try std.testing.expectEqual(@as(?i32, null), sdk.extractInt(sdk.JSValue.fromFloat(7.5)));
    try std.testing.expectEqual(@as(?i32, null), sdk.extractInt(sdk.JSValue.undefined_val));
}

test "decodeArgs returns null when a declared argument is missing" {
    const none = [_]sdk.JSValue{};
    try std.testing.expect(sdk.decodeArgs(&.{.string}, &none) == null);

    const one = [_]sdk.JSValue{test_shim.internString("only")};
    defer test_shim.resetStrings();
    try std.testing.expect(sdk.decodeArgs(&.{ .string, .string }, &one) == null);
}

test "decodeArgs returns null when a declared argument is not a string" {
    const args = [_]sdk.JSValue{ sdk.JSValue.fromInt(7), sdk.JSValue.undefined_val };
    try std.testing.expect(sdk.decodeArgs(&.{.string}, &args) == null);
    try std.testing.expect(sdk.decodeArgs(&.{ .string, .string }, &args) == null);
}

test "decodeArgs decodes a declared string list in argument order" {
    defer test_shim.resetStrings();
    const args = [_]sdk.JSValue{
        test_shim.internString("first"),
        test_shim.internString("second"),
        test_shim.internString("third"),
    };
    const decoded = sdk.decodeArgs(&.{ .string, .string, .string }, &args) orelse
        return error.ExpectedDecode;
    try std.testing.expectEqualStrings("first", decoded[0]);
    try std.testing.expectEqualStrings("second", decoded[1]);
    try std.testing.expectEqualStrings("third", decoded[2]);
}

test "decodeArgs ignores arguments past the declared list" {
    defer test_shim.resetStrings();
    const args = [_]sdk.JSValue{ test_shim.internString("kept"), sdk.JSValue.fromInt(7) };
    const decoded = sdk.decodeArgs(&.{.string}, &args) orelse return error.ExpectedDecode;
    try std.testing.expectEqualStrings("kept", decoded[0]);
}

test "decodeArgs on an empty declared list accepts any arguments" {
    const args = [_]sdk.JSValue{sdk.JSValue.fromInt(7)};
    try std.testing.expect(sdk.decodeArgs(&.{}, &args) != null);
}

// Lives here, not in test_shim.zig: test_shim is imported as a separate module,
// so refAllDecls references its decls but does NOT register its `test` blocks -
// a test placed there never runs. test_root.zig is the actual test root.
test "fillRandom surfaces a clean error when the bridge cannot fill the buffer" {
    test_shim.allowAllCapabilities();
    defer test_shim.allowAllCapabilities();
    defer test_shim.allowRandom();

    const fake_handle: *sdk.ModuleHandle = @ptrFromInt(8);
    var buf: [16]u8 = .{0xAA} ** 16;

    // Happy path: capability allowed and the bridge succeeds -> no error.
    try sdk.fillRandom(fake_handle, &buf);

    // Bridge cannot fill (OS entropy unavailable): must return a typed error,
    // NOT silently succeed with the zeroed buffer (which would be a predictable
    // token). This is the regression the void->bool bridge change closes.
    test_shim.failRandom();
    try std.testing.expectError(error.RandomUnavailable, sdk.fillRandom(fake_handle, &buf));
    // The buffer is zeroed on failure so no uninitialized bytes leak; the caller
    // discards it because the error propagates.
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // Capability denial still takes precedence and reports its own error.
    test_shim.allowRandom();
    test_shim.denyCapability(.random);
    try std.testing.expectError(error.MissingModuleCapability, sdk.fillRandom(fake_handle, &buf));
}
