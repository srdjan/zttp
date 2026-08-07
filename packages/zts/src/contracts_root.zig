//! `zts-contracts` - what a handler's contract and its receipts are, and how
//! they are written and read.
//!
//! This tier is data and serialization, never analysis and never execution.
//! `zts` holds contract values at run time and `zts-compiler` produces them at
//! build time, so both depend on this module and it depends on neither. That is
//! why the extraction pass is not here: `contract_builder.zig` reaches the type
//! checker, effect inference and six extractors, and putting it behind the
//! contract type made every holder of a contract import all of it.
//!
//! Below this sits only `zts-base`, named as `@import("zts-base")`.
//!
//! Reach these through the module name, never by relative path. A file in a
//! higher module that writes `@import("handler_contract.zig")` compiles a
//! second copy of it into that module, and a `HandlerContract` from one copy is
//! not a `HandlerContract` from the other.
//! `scripts/check-zts-layering.sh` fails on it, and so does zig.
//!
//! Tier membership is recorded in `scripts/zts-tiers.allow`. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

/// The contract's data types: routes, env vars, egress hosts, capabilities,
/// properties, and the rest of what a build proves about a handler.
pub const contract_types = @import("contract_types.zig");

/// The contract as a whole, with its JSON reader and writer attached.
pub const handler_contract = @import("handler_contract.zig");

/// Writes a `HandlerContract` as contract.json.
pub const contract_json_writer = @import("contract_json_writer.zig");

/// Reads a `HandlerContract` back from contract.json.
pub const contract_json_parser = @import("contract_json_parser.zig");

/// The `system.json` manifest of a linked bundle, and its parser.
pub const system_config = @import("system_config.zig");

/// Types describing a service call's request and response shapes.
pub const service_types = @import("service_types.zig");

/// The signed record of a measured performance claim.
pub const perf_receipt = @import("perf_receipt.zig");

/// The signed record of a proved behavioral equivalence.
pub const equivalence_receipt = @import("equivalence_receipt.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
