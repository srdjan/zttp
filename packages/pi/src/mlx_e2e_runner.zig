//! Test runner for the explicit real-model MLX gate.
//!
//! The gate is intentionally outside the aggregate test step. Requiring one
//! behavioral test prevents an empty or miswired E2E root from reporting a
//! successful build without executing the flow.

const builtin = @import("builtin");
const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    if (builtin.test_functions.len != 1) {
        std.debug.print(
            "test-expert-mlx-e2e: expected exactly one structural flow, found {d}\n",
            .{builtin.test_functions.len},
        );
        std.process.exit(1);
    }
    try builtin.test_functions[0].func();
}
