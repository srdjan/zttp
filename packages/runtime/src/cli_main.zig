const std = @import("std");
const cli = @import("dev_cli.zig");

pub const panic = std.debug.FullPanic(@import("panic_recovery.zig").handlePanic);

pub fn main(init: std.process.Init.Minimal) !void {
    return cli.main(init);
}

test {
    _ = @import("dev_cli.zig");
    // `dev_cli` imports this, but Zig's lazy analysis only reaches a decl that
    // is actually referenced, and their entry point is referenced solely from
    // a dispatch branch no test calls. Without this explicit anchor its
    // `test` blocks are never collected: measured, adding a test to
    // `pre-rebase:packages/runtime/src/witnesses_cli.zig` moved the collected
    // count by zero.

    // Force-link the proof-review submodules used by the developer CLI.
    // Lazy analysis through the package boundary won't reach decls that
    // are only declared but never referenced; the explicit refs below
    // ensure every relevant proof-review file is compiled and its `test`
    // blocks collected.
    const proof_review = @import("zttp_proof_review");
    _ = proof_review.printer;
    _ = proof_review.review;
    _ = proof_review.state;

    _ = @import("proof_ledger.zig");
    _ = @import("proofs_cli.zig");
    // `proofs_cli` imports the bundle path, which imports this, and neither
    // hop is enough on its own: a deliberate break in its tests left `zig
    // build test` green until this line existed.
    _ = @import("proofs/guard_report.zig");
    _ = @import("proofs/invariant_report.zig");
    _ = @import("proof_card_tui.zig");
}
