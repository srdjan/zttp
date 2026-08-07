//! `zts-engine` - the JavaScript engine: values, memory, bytecode, the
//! interpreter, the parser, the built-ins, and the virtual module
//! implementations.
//!
//! This module holds everything that runs a handler and nothing that decides
//! whether one is proven. Below it sit `zts-contracts` (which it holds at run
//! time) and `zts-base`, both named as `@import("zts-contracts")` and
//! `@import("zts-base")`. Above it sits `zts-compiler`, which it must never
//! name: that direction is the cycle the split exists to prevent.
//!
//! Embedders should import `zts`, the umbrella in `root.zig`, which re-exports
//! this module's surface alongside the other three. This root exists so the
//! four tiers are separate compilation units, and so `-Danalyzer_only` builds
//! can leave the interpreter subtree out of the module graph entirely.
//!
//! Tier membership is recorded in `scripts/zts-tiers.allow`. See
//! docs/plans/2026-08-07-021-zts-three-module-split-plan.md.

const std = @import("std");
const build_options = @import("build_options");

pub const value = @import("value.zig");
pub const heap = @import("heap.zig");
pub const gc = @import("gc.zig");
pub const string = @import("string.zig");
pub const object = @import("object.zig");
pub const context = @import("context.zig");
pub const atom_table = @import("atom_table.zig");
pub const bytecode = @import("bytecode.zig");
pub const interpreter = @import("interpreter.zig");

// JIT C-ABI helpers are referenced from generated machine code via `extern fn`.
// Anchor the module here so the linker emits the symbols. The analyzer-only
// build (wasm/freestanding) never reaches the JIT, so skip the anchor to keep
// the interpreter/JIT/GC subtree out of the module graph.
comptime {
    if (!build_options.analyzer_only) {}
}
pub const builtins = @import("builtins/root.zig");
pub const parser = @import("parser/root.zig");
pub const pool = @import("pool.zig");
pub const http = @import("http.zig");
pub const stripper = @import("stripper.zig");
pub const node_types = @import("node_types.zig");
pub const comptime_eval = @import("comptime.zig");
pub const bytecode_cache = @import("bytecode_cache.zig");
pub const bytecode_opt = @import("bytecode_opt.zig");
pub const bytecode_verifier = @import("bytecode_verifier.zig");
pub const arena = @import("arena.zig");
pub const handler_analyzer = @import("handler_analyzer.zig");
pub const handler_policy = @import("handler_policy.zig");
pub const policy = @import("policy.zig");
pub const trace = @import("trace.zig");
pub const file_io = @import("file_io.zig");
pub const module_binding = @import("module_binding.zig");
pub const module_manifest = @import("module_manifest.zig");
pub const builtin_modules = @import("builtin_modules.zig");
pub const security_events = @import("security_events.zig");
pub const wasm = @import("wasm/root.zig");
pub const sqlite = @import("sqlite.zig");
pub const modules = @import("modules/root.zig");

test {
    std.testing.refAllDecls(@This());
}

// refAllDecls only recurses pub decls, so anchor the (non-pub) parity gate
// explicitly.
test {
    _ = @import("tests/opcode_parity.zig");
}

// modules/internal/compiler.zig is only reached via the `modules` re-export
// above, which container-level laziness never forces the compiler to
// analyze on its own, so its test blocks go uncollected without this anchor.
test {
    _ = @import("modules/internal/compiler.zig");
}
