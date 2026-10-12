//! Focused aggregator for the cassette harness tests so `zig build
//! test-cassette` can exercise the record + replay layer without
//! pulling in the full `pi_app` graph.

comptime {
    _ = @import("providers/cassette_client.zig");
    _ = @import("providers/cassette_record.zig");
    // Replay routes through both provider decoders; pull them in so any
    // compile-time drift here surfaces inside the cassette step.
    _ = @import("providers/propose_change_set.zig");
    _ = @import("providers/deepseek/client.zig");
}
