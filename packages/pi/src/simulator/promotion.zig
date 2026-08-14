//! Validated promotion of one completed flow recording.
//!
//! The durable case pointer changes only after an identical private generation
//! passes strict loading and full replay through the production Pi loop.

const std = @import("std");
const artifact = @import("artifact.zig");
const recorder_mod = @import("recorder.zig");
const runner_mod = @import("runner.zig");
const model_request = @import("../providers/model_request.zig");
const registry_mod = @import("../registry/registry.zig");
const Workspace = @import("workspace.zig").Workspace;

pub fn validateAndPromote(
    allocator: std.mem.Allocator,
    recorder: *recorder_mod.Recorder,
    durable_case_root_abs: []const u8,
    registry: *const registry_mod.Registry,
    request_config: model_request.Config,
) !artifact.Sha256Hex {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    var validation_workspace = try Workspace.create(allocator, io_backend.io());
    // A validation failure is the one case where the artifact must outlive the
    // run: the recorded responses and trace are the only evidence of why the
    // replay diverged, and deleting them leaves an operator with a category
    // name and nothing to inspect.
    var keep_for_inspection = false;
    defer {
        if (keep_for_inspection) {
            if (validation_workspace.abandon()) |kept_path| {
                std.debug.print(
                    "[promotion] validation failed; kept the artifact at {s}\n",
                    .{kept_path},
                );
                allocator.free(kept_path);
            } else |_| {
                validation_workspace.deinit() catch {};
            }
        } else {
            validation_workspace.deinit() catch {};
        }
    }

    const validated_version = try recorder.promote(validation_workspace.abs_path);
    var loaded = artifact.loadCase(allocator, validation_workspace.abs_path);
    defer loaded.deinit();
    switch (loaded) {
        .failure => {
            keep_for_inspection = true;
            return error.InvalidRecordedFlow;
        },
        .available => |*flow_case| {
            var replay = runner_mod.Runner.init(allocator, flow_case, registry, request_config);
            _ = replay.run() catch |err| {
                keep_for_inspection = true;
                return err;
            };
        },
    }

    const durable_version = try recorder.promote(durable_case_root_abs);
    if (!validated_version.eql(durable_version)) return error.NonDeterministicFlowVersion;
    return durable_version;
}
