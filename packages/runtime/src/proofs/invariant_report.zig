//! One human-readable rendering of application-invariant status.
//!
//! Coverage is an acceptance result. Runtime readiness is a later result from
//! installing and validating the protected store. The renderer keeps these
//! states separate and states the native adapter trust assumption.

const std = @import("std");
const contract_runtime = @import("../contract_runtime.zig");

pub const InvariantStatus = contract_runtime.InvariantStatus;

pub fn writeSummary(writer: *std.Io.Writer, status: InvariantStatus) std.Io.Writer.Error!void {
    if (!status.configured) {
        try writer.writeAll(
            "not configured; coverage and runtime readiness are not applicable",
        );
        return;
    }

    try writer.print(
        "configured; coverage {d} of {d} ({d} write, {d} read); native adapter {s}; runtime readiness {s}",
        .{
            status.covered,
            status.required,
            status.writes,
            status.reads,
            switch (status.native_adapter_assumption) {
                .not_applicable => "assumption not applicable",
                .trusted => "is a trusted assumption",
            },
            switch (status.runtime_readiness) {
                .not_applicable => "not applicable",
                .not_checked => "not checked",
                .ready => "ready - baseline validated and generation installed",
            },
        },
    );
}

const testing = std.testing;

test "summary separates coverage trust and runtime readiness" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSummary(&writer, .{
        .configured = true,
        .required = 2,
        .covered = 2,
        .writes = 1,
        .reads = 1,
        .native_adapter_assumption = .trusted,
        .runtime_readiness = .not_checked,
    });
    try testing.expectEqualStrings(
        "configured; coverage 2 of 2 (1 write, 1 read); native adapter is a trusted assumption; runtime readiness not checked",
        writer.buffered(),
    );
}

test "summary reports live runtime readiness only when supplied" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeSummary(&writer, .{
        .configured = true,
        .required = 1,
        .covered = 1,
        .writes = 1,
        .native_adapter_assumption = .trusted,
        .runtime_readiness = .ready,
    });
    try testing.expect(std.mem.endsWith(
        u8,
        writer.buffered(),
        "runtime readiness ready - baseline validated and generation installed",
    ));

    var absent_buffer: [128]u8 = undefined;
    var absent_writer = std.Io.Writer.fixed(&absent_buffer);
    try writeSummary(&absent_writer, .{});
    try testing.expectEqualStrings(
        "not configured; coverage and runtime readiness are not applicable",
        absent_writer.buffered(),
    );
}
