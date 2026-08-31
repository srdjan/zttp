//! Test root for the acceptance kernel.
//!
//! Every source file in `src/` is referenced here. `scripts/check-proof-checker.sh`
//! fails when one is missing, so a file cannot be added to the kernel and left
//! outside the suite that is later cited as evidence for it.

comptime {
    _ = @import("certificate.zig");
    _ = @import("checker.zig");
    _ = @import("executable_graph.zig");
    _ = @import("limits.zig");
    _ = @import("policy.zig");
    _ = @import("proof_system.zig");
    _ = @import("root.zig");
    _ = @import("verdict.zig");
}
