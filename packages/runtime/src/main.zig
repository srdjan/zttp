const std = @import("std");
const cli = @import("runtime_cli.zig");

pub const panic = std.debug.FullPanic(@import("panic_recovery.zig").handlePanic);

pub fn main(init: std.process.Init.Minimal) !void {
    return cli.main(init);
}

test {
    _ = @import("runtime_cli.zig");
    _ = @import("cli_shared.zig");
    // `zruntime_tests.zig`, the handler-instance test root, is deliberately absent,
    // and importing it here would be worse than useless. It is the root of its
    // own build module, so a file import from this root collects NONE of its
    // test blocks: measured, the aggregate root reports 521 tests with or
    // without that import, against a positive control where adding one test
    // here moves it to 522. It was the only import in this block that is also
    // a module root, which is why it was the only one contributing nothing.
    //
    // Its tests run as a separate process via `zig build test-zruntime`, wired
    // into `scripts/verify.sh`, and that separation is deliberate: parallel
    // duplicate roots have produced intermittent libc/JIT/arena teardown TRAPs
    // on macOS. Compile coverage of the instance itself is unaffected either
    // way, because `edge_server.zig` below imports `handler_instance.zig`.
    _ = @import("server.zig");
    _ = @import("edge_server.zig");
    _ = @import("runtime_features.zig").studio;
    _ = @import("proof_adapter.zig");
}
