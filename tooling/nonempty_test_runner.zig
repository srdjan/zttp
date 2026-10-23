//! Preserve the selected runner and report collection to the suite-level gate.
const std = @import("std");
const selected = @import("selected_test_runner");
pub const std_options: std.Options = if (@hasDecl(selected, "std_options")) selected.std_options else .{};

pub fn main(init: std.process.Init.Minimal) @typeInfo(@TypeOf(selected.main)).@"fn".return_type.? {
    // Zig retains unnamed discovery tests even for an unmatched filter. Count
    // the functions that match the requested selection, not those scaffolds.
    var count: usize = 0;
    for (@import("builtin").test_functions) |test_fn| {
        if (std.mem.find(u8, test_fn.name, @import("selection_runner_options").filter) != null) count += 1;
    }
    const path = @import("selection_runner_options").count_path;
    var buffer: [64]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "{d}", .{count}) catch unreachable;
    std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = bytes }) catch |err|
        std.process.fatal("cannot record test selection: {t}", .{err});
    if (count == 0 and @import("selection_runner_options").simple) return;
    return selected.main(init);
}
