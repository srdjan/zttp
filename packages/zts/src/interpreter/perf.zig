//! Interpreter performance counters and opcode histogram.

const std = @import("std");
const build_options = @import("build_options");

pub const enable_opcode_histogram = build_options.perf_histogram;

pub const PerfStats = struct {
    backedge_count: u32 = 0,
    pic_hits: u32 = 0,
    pic_misses: u32 = 0,
    mega_recoveries: u32 = 0,
    opcode_histogram_enabled: bool = enable_opcode_histogram,
    opcode_histogram_nonzero: u32 = 0,
    opcode_histogram: [256]u32 = [_]u32{0} ** 256,
};

pub fn countNonZeroHistogramEntries(histogram: []const u32) u32 {
    var count: u32 = 0;
    for (histogram) |entry| {
        if (entry > 0) count +|= 1;
    }
    return count;
}
