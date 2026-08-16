//! Closed value types shared by expert codegen inputs, evaluation, and evidence.

pub const SeedFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const InputMode = enum { whole_file, holes };

pub const IntentOutcome = enum {
    not_checked,
    passed,
    failed,
    compiler_veto_only,
};
