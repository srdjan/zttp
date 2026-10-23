//! Cycle-neutral vocabulary for Context-owned module authorization.

const std = @import("std");

/// Capabilities consumed by a virtual module's Zig implementation.
/// These are governance metadata for module internals; they do not affect
/// handler-level effect classification or RuntimePolicy derivation.
pub const ModuleCapability = @import("zttp-sdk").ModuleCapability;

/// Borrowed authorization metadata for the module call currently executing in
/// one Context. Wrappers restore the previous value for nested and reentrant
/// calls; the Context owns the storage and lifetime.
pub const ActiveModuleScope = struct {
    specifier: []const u8,
    required_capabilities: []const ModuleCapability,
};

pub const capability_count: usize = @typeInfo(ModuleCapability).@"enum".field_names.len;

/// SHA-256 over a canonical capability list. Tag names are hashed in the
/// order given, newline-separated, so equal sets produce equal digests.
pub fn capabilityHash(caps: []const ModuleCapability) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (caps) |c| {
        hasher.update(@tagName(c));
        hasher.update("\n");
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}
