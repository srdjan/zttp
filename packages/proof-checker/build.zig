const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Deliberately import-free. The acceptance kernel is a leaf: it may not
    // reach the compiler, the analyzer, the runtime server, the signer, or any
    // ambient capability. `scripts/check-proof-checker-purity.sh` enforces that
    // and fails when this dependency list stops being empty.
    _ = b.addModule("zttp_proof_checker", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
