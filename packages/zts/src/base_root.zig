//! `zts-base` - the bottom of the zts module graph.
//!
//! Vocabulary and pure helpers that every other tier names and that name
//! nothing themselves. Each file here imports `std` and nothing else in this
//! package, which is what makes the tier a leaf: `zts-contracts`, `zts` and
//! `zts-compiler` may all depend on it without any of them depending on each
//! other through it.
//!
//! Reach these through the module name, never by relative path. A file in a
//! higher module that writes `@import("json_utils.zig")` compiles a second copy
//! of it into that module, and the two copies' types are not interchangeable -
//! that is the failure the split exists to prevent, and
//! `scripts/check-zts-layering.sh` fails on it.
//!
//! Tier membership is recorded in `scripts/zts-tiers.allow`. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

/// Monotonic and wall clocks, and the platform shims around them.
pub const compat = @import("compat.zig");

/// JSON string escaping, hex output, and the small helpers every hand-written
/// JSON writer in this repository reached for.
pub const json_utils = @import("json_utils.zig");

/// Typed JSON reading: the wire structs and the parser that fills them.
pub const json_wire = @import("json_wire.zig");

/// Closed source-profile identifiers shared by contracts and compiler code.
pub const profile_identity = @import("profile_identity.zig");

/// The JavaScript global names the analyzer treats as known.
pub const known_globals = @import("known_globals.zig");

/// The capability enum a virtual module declares, and its canonical hash.
pub const module_authorization = @import("module_authorization.zig");

/// Which `Context.module_state` slot each subsystem owns.
pub const module_slots = @import("module_slots.zig");

/// Virtual module specifier syntax: `zttp:` and `zttp-ext:`, and the separator
/// for a namespaced export.
pub const module_specifier = @import("module_specifier.zig");

/// The canonical egress endpoint - `scheme://host:port` - and the resolved
/// address scopes a connection may land in.
pub const endpoint = @import("endpoint.zig");

/// Whether a request path matches a route pattern, parameter segments included.
pub const route_match = @import("route_match.zig");

/// The type annotations the TypeScript stripper records as it removes them.
pub const type_map = @import("type_map.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
