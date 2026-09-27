//! Release probe for the acceptance kernel's safety. `check` proves
//! safety.check survives ReleaseFast, which @panic alone would also pass.
//! `index` proves the mechanism the gate enforces: a function that begins
//! with @setRuntimeSafety(true), in a module imported by a ReleaseFast root,
//! still panics on an out-of-bounds index instead of reading past the slice.

const std = @import("std");
const proof_checker = @import("zttp_proof_checker");
const probe_dep = @import("kernel_safety_probe_dep");

pub fn main(init: std.process.Init.Minimal) void {
    var args = init.args.iterate();
    _ = args.next();
    const mode = args.next() orelse "check";
    if (std.mem.eql(u8, mode, "index")) {
        const bytes = [_]u8{ 1, 2, 3 };
        // Derived from the argument so the optimizer cannot fold the bound.
        const index = mode.len + 4;
        const byte = @call(.never_inline, probe_dep.indexAt, .{ &bytes, index });
        std.debug.print("index probe read {d} without a panic\n", .{byte});
        return;
    }
    proof_checker.safety.check(false);
}
