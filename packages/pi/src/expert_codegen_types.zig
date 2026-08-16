//! Closed value types shared by expert codegen inputs, evaluation, and evidence.

pub const SeedFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const InputMode = enum { whole_file, holes };

/// How attempt one reached, or failed to reach, a green compiler verdict.
/// Keeping the cause as one closed value makes `raw pass => first-attempt
/// green` unrepresentable as an invalid pair of booleans.
pub const DraftQuality = enum {
    not_green,
    normalized,
    compiler_repaired,
    raw_veto_pass,

    pub fn rawFirstDraftVetoPass(self: DraftQuality) bool {
        return self == .raw_veto_pass;
    }

    pub fn firstAttemptGreen(self: DraftQuality) bool {
        return self != .not_green;
    }
};

pub const IntentOutcome = enum {
    not_checked,
    passed,
    failed,
    compiler_veto_only,
};

test "draft quality derives consistent public metrics" {
    const testing = @import("std").testing;
    const cases = [_]struct {
        quality: DraftQuality,
        raw: bool,
        first_attempt: bool,
    }{
        .{ .quality = .not_green, .raw = false, .first_attempt = false },
        .{ .quality = .normalized, .raw = false, .first_attempt = true },
        .{ .quality = .compiler_repaired, .raw = false, .first_attempt = true },
        .{ .quality = .raw_veto_pass, .raw = true, .first_attempt = true },
    };
    for (cases) |case| {
        try testing.expectEqual(case.raw, case.quality.rawFirstDraftVetoPass());
        try testing.expectEqual(case.first_attempt, case.quality.firstAttemptGreen());
    }
}
