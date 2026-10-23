/// Centralized registry of module_state slot indices.
/// Context.module_state is a fixed-size [16]?ModuleStateEntry array.
/// Each slot is reserved for a specific subsystem to avoid collisions.
pub const Slot = enum(u4) {
    sql = 2,
    replay = 3,
    validate = 4,
    cache = 5,
    trace = 7,
    ratelimit = 8,
    fetch = 11,
};

pub fn ownerSpecifier(slot: usize) ?[]const u8 {
    return switch (slot) {
        @backingInt(Slot.sql) => "zttp:sql",
        @backingInt(Slot.validate) => "zttp:validate",
        @backingInt(Slot.cache) => "zttp:cache",
        @backingInt(Slot.ratelimit) => "zttp:ratelimit",
        @backingInt(Slot.fetch) => "zttp:fetch",
        else => null,
    };
}

pub fn isOwnedBySpecifier(slot: usize, specifier: []const u8) bool {
    const std = @import("std");
    const owner = ownerSpecifier(slot) orelse return false;
    if (std.mem.eql(u8, owner, specifier)) return true;
    // `zttp:decode` is a thin facade over `zttp:validate`: decodeJson /
    // decodeForm / decodeQuery / decodeFormMultipart delegate to the shared
    // schema registry stored in the validate slot. Grant decode access to that
    // one slot so a decode call can reach the registry that schemaCompile
    // (zttp:validate) populated; without this the module-state ownership guard
    // makes setModuleState/getModuleState fail and every schema-based decode
    // returns an "internal error" Result (and schemaCompile silently no-ops).
    if (slot == @backingInt(Slot.validate) and std.mem.eql(u8, specifier, "zttp:decode")) return true;
    return false;
}

test "module state slots are owned by one active module specifier" {
    const testing = @import("std").testing;

    try testing.expect(isOwnedBySpecifier(@backingInt(Slot.sql), "zttp:sql"));
    try testing.expect(!isOwnedBySpecifier(@backingInt(Slot.sql), "zttp:cache"));
    try testing.expect(isOwnedBySpecifier(@backingInt(Slot.validate), "zttp:validate"));
    // zttp:decode co-owns the validate slot (shared schema registry), but no other.
    try testing.expect(isOwnedBySpecifier(@backingInt(Slot.validate), "zttp:decode"));
    try testing.expect(!isOwnedBySpecifier(@backingInt(Slot.sql), "zttp:decode"));
    try testing.expect(!isOwnedBySpecifier(@backingInt(Slot.cache), "zttp:decode"));
    try testing.expect(ownerSpecifier(@backingInt(Slot.replay)) == null);
    try testing.expect(ownerSpecifier(0) == null);
    try testing.expect(ownerSpecifier(1) == null);
    try testing.expect(ownerSpecifier(6) == null);
    try testing.expect(ownerSpecifier(9) == null);
    try testing.expect(ownerSpecifier(10) == null);
    try testing.expect(ownerSpecifier(12) == null);
    try testing.expect(ownerSpecifier(13) == null);
    try testing.expect(ownerSpecifier(14) == null);
    try testing.expect(ownerSpecifier(15) == null);
}
