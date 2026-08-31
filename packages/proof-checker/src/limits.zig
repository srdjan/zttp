//! Resource bounds for the acceptance kernel.
//!
//! Every decoder and checker stage consults these before it reads a count, and
//! before it walks a structure whose size the producer chose. The kernel does
//! not allocate, so the bounds here are about work and recursion rather than
//! about memory, with one exception: `max_certificate_bytes` refuses a blob the
//! caller should never have read into memory in the first place.

const std = @import("std");

pub const Limits = struct {
    /// Largest certificate the kernel will look at.
    max_certificate_bytes: u32 = 4 * 1024 * 1024,
    /// Largest single section inside a certificate.
    max_section_bytes: u32 = 1024 * 1024,
    /// Sections a certificate may carry. Bounded by the closed section
    /// alphabet, so a larger count is already a duplicate or an unknown tag.
    max_sections: u16 = 32,
    /// Executable-graph members.
    max_graph_members: u32 = 4096,
    /// Obligations, both reconstructed and supplied.
    max_obligations: u32 = 4096,
    /// Proof IR nodes.
    max_ir_nodes: u32 = 65_536,
    /// Evidence entries.
    max_evidence: u32 = 65_536,
    /// Translation witnesses.
    max_witnesses: u32 = 65_536,
    /// Optimizer rewrite records.
    max_rewrites: u32 = 65_536,
    /// Declared trusted edges.
    max_trusted_edges: u32 = 4096,
    /// Reconstructed solver queries.
    max_solver_queries: u16 = 64,
    /// Deepest proof-IR walk. The subset has no back edges, so a real handler
    /// is far below this; the bound exists for a producer that lies.
    max_depth: u16 = 256,
    /// Total unit-work budget across decoding and checking.
    max_work: u64 = 8_000_000,

    pub const production: Limits = .{};
};

pub const BudgetError = error{WorkBudgetExhausted};

/// A spend-down work counter. Every loop iteration in the kernel that a
/// producer can lengthen spends from it, so a certificate that is well formed
/// but expensive stops at a bound instead of at a timeout.
pub const Budget = struct {
    remaining: u64,

    pub fn init(limits: Limits) Budget {
        return .{ .remaining = limits.max_work };
    }

    pub fn spend(self: *Budget, units: u64) BudgetError!void {
        if (units > self.remaining) {
            self.remaining = 0;
            return error.WorkBudgetExhausted;
        }
        self.remaining -= units;
    }

    pub fn spent(self: Budget, limits: Limits) u64 {
        return limits.max_work - self.remaining;
    }
};

test "budget refuses more work than it holds" {
    var budget = Budget.init(.{ .max_work = 10 });
    try budget.spend(4);
    try budget.spend(6);
    try std.testing.expectError(error.WorkBudgetExhausted, budget.spend(1));
    try std.testing.expectEqual(@as(u64, 0), budget.remaining);
}

test "budget exhaustion is sticky rather than wrapping" {
    var budget = Budget.init(.{ .max_work = 3 });
    try std.testing.expectError(error.WorkBudgetExhausted, budget.spend(4));
    try std.testing.expectEqual(@as(u64, 0), budget.remaining);
    try std.testing.expectError(error.WorkBudgetExhausted, budget.spend(1));
}

test "production limits are non-zero in every field" {
    const l = Limits.production;
    inline for (@typeInfo(Limits).@"struct".fields) |field| {
        const value = @field(l, field.name);
        try std.testing.expect(value > 0);
    }
}
