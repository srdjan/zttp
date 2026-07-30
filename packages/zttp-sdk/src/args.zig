//! Argument decoding driven by a binding's declared `param_types`.
//!
//! `param_types` is what the type checker enforces at the call site. Before
//! this, every implementation re-derived the same information by hand with a
//! run of `extractString(args[i]) orelse return ...`, so the declared signature
//! and the executed one could drift (and did: three entries read an argument
//! position they did not declare - see
//! docs/archive/plans/2026-07-30-008-wave4-item6-arg-decode-plan.md).
//!
//! Decoding here makes the declared list the one that runs. The caller keeps
//! its own failure value, because the failure vocabulary is per function
//! (`undefined_val`, `false_val`, `resultErr`, a thrown TypeError) and is not
//! declared in the binding.

const std = @import("std");
const binding = @import("binding.zig");
const string = @import("string.zig");
const value = @import("value.zig");

const JSValue = value.JSValue;
const ReturnKind = binding.ReturnKind;

/// Zig type a declared parameter kind decodes to.
///
/// Only `.string` is implemented: every implementation converted so far
/// declares string parameters only. Add a kind here when a conversion needs
/// it, rather than carrying decode paths no caller reaches.
fn ParamType(comptime kind: ReturnKind) type {
    return switch (kind) {
        .string => []const u8,
        else => @compileError(
            "argument decoding for '" ++ @tagName(kind) ++
                "' parameters is not implemented; add it to sdk args.zig when a conversion needs it",
        ),
    };
}

/// Tuple of decoded arguments for a declared parameter list.
pub fn DecodedArgs(comptime param_types: []const ReturnKind) type {
    var field_types: [param_types.len]type = undefined;
    for (param_types, 0..) |kind, i| field_types[i] = ParamType(kind);
    return @Tuple(&field_types);
}

/// Decode `args` against a declared parameter list.
///
/// Returns null when an argument is missing or is not the declared type - the
/// same two conditions the hand-written prologues checked, in the same order,
/// so a converted implementation returns its existing failure value on exactly
/// the inputs it did before.
pub fn decodeArgs(
    comptime param_types: []const ReturnKind,
    args: []const JSValue,
) ?DecodedArgs(param_types) {
    if (args.len < param_types.len) return null;
    var out: DecodedArgs(param_types) = undefined;
    inline for (param_types, 0..) |kind, i| {
        out[i] = switch (kind) {
            .string => string.extractString(args[i]) orelse return null,
            else => comptime unreachable, // ParamType already rejected the kind
        };
    }
    return out;
}

// Tests for this file live in `test_root.zig`, not here: the SDK is a separate
// module from its test root, so a `test` block in any src/*.zig file is never
// collected. Every other file in this package follows the same rule.
