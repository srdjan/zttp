//! Virtual module specifier syntax: what a `zttp:` import looks like and how a
//! namespaced export is spelled.
//!
//! Three places need this and only one of them parses manifests. The code
//! generator validates a specifier before rewriting an import, the module
//! resolver builds namespaced export names, and `module_manifest.zig` checks
//! the specifier it read from JSON. Keeping the two declarations in
//! `module_manifest.zig` made the parser import the manifest parser, the module
//! binding registry and the data-label lattice to test whether a string starts
//! with "zttp:". This file has no dependency at all. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");

/// Separates a module specifier from an export name in a namespaced binding,
/// as in `zttp:crypto#sha256`. Chosen because `#` cannot appear in either half.
pub const namespaced_export_separator = "#";

/// Whether a string is a virtual module specifier this runtime resolves.
/// `zttp:` is a built-in module; `zttp-ext:` is an installed extension.
pub fn validSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "zttp:") or
        std.mem.startsWith(u8, specifier, "zttp-ext:");
}

test "validSpecifier accepts both virtual module namespaces" {
    try std.testing.expect(validSpecifier("zttp:crypto"));
    try std.testing.expect(validSpecifier("zttp-ext:my-module"));

    try std.testing.expect(!validSpecifier("crypto"));
    try std.testing.expect(!validSpecifier("./local.ts"));
    try std.testing.expect(!validSpecifier("node:crypto"));
    try std.testing.expect(!validSpecifier(""));
    // The prefix is matched at the start, not anywhere in the string.
    try std.testing.expect(!validSpecifier("./vendor/zttp:crypto"));
}
