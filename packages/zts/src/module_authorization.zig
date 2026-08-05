//! Cycle-neutral vocabulary for Context-owned module authorization.

/// Capabilities consumed by a virtual module's Zig implementation.
/// These are governance metadata for module internals; they do not affect
/// handler-level effect classification or RuntimePolicy derivation.
pub const ModuleCapability = enum {
    env,
    clock,
    random,
    crypto,
    stderr,
    runtime_callback,
    sqlite,
    filesystem,
    network,
    policy_check,
    websocket,
};

/// Borrowed authorization metadata for the module call currently executing in
/// one Context. Wrappers restore the previous value for nested and reentrant
/// calls; the Context owns the storage and lifetime.
pub const ActiveModuleScope = struct {
    specifier: []const u8,
    required_capabilities: []const ModuleCapability,
};
