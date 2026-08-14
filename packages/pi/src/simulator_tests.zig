//! Focused offline test root for full-flow simulator behavior.

comptime {
    _ = @import("simulator/artifact.zig");
    _ = @import("simulator/artifact_test.zig");
    _ = @import("simulator/model_client_test.zig");
    _ = @import("simulator/runner_test.zig");
    _ = @import("simulator/recording_storage_test.zig");
    _ = @import("simulator/recorder_test.zig");
    _ = @import("simulator/workspace.zig");
}
