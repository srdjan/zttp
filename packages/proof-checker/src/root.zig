//! zttp-proof-checker - the consumer-owned acceptance kernel.
//!
//! This package decides whether an exact artifact satisfies a consumer's
//! required static safety properties. It is a leaf on purpose: it imports
//! nothing but `std`, so the authority surface a reader has to audit is this
//! directory and nothing behind it.
//!
//! What it is not: it is not the compiler, it does not search for proofs, it
//! does not sign, and it does not replace any runtime control. A certificate it
//! accepts still has to pass structural bytecode verification, capability
//! enforcement, isolation, and every request-time check.

pub const certificate = @import("certificate.zig");
pub const checker = @import("checker.zig");
pub const executable_graph = @import("executable_graph.zig");
pub const limits = @import("limits.zig");
pub const policy = @import("policy.zig");
pub const proof_system = @import("proof_system.zig");
pub const verdict = @import("verdict.zig");

pub const Assessment = verdict.Assessment;
pub const AssuranceGrade = verdict.AssuranceGrade;
pub const Policy = policy.Policy;
pub const ProvenanceState = verdict.ProvenanceState;
pub const ReasonCode = verdict.ReasonCode;
pub const SemanticState = verdict.SemanticState;
pub const check = checker.check;
