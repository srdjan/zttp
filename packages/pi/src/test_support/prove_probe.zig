//! Test-only probe over `aggregate_proof.prove`, the oracle production uses.
//!
//! A probe writes the baseline and any project context into an isolated
//! workspace, prepares one change, and runs the same capture and proof the loop
//! runs. The result is what the loop would observe: the verdict, the first new
//! rule code, and the bytes that normalization left in the candidate.
//!
//! `prove` returns only the first new diagnostic. A test that needs the count
//! of new diagnostics calls `edit_simulate.simulate` directly.

const std = @import("std");
const aggregate_proof = @import("../aggregate_proof.zig");
const change_set = @import("../change_set.zig");
const workspace_snapshot = @import("../workspace_snapshot.zig");
const IsolatedTmp = @import("tmp.zig").IsolatedTmp;

pub const file_name = "handler.ts";

pub const Probe = struct {
    /// The workspace `handler.ts` before the change. Null means no file, which
    /// `change_set.prepare` records as an absent baseline.
    baseline: ?[]const u8,
    candidate: []const u8,
    /// Capability policy source. Written as `policy.json` and named by
    /// `zttp.json`, the way a project declares it.
    policy_json: ?[]const u8 = null,
    /// SQL schema source. Written as `schema.sql` and named by `zttp.json`.
    sql_schema: ?[]const u8 = null,
};

pub const Observation = struct {
    accepted: bool,
    /// The first new diagnostic code, or the rejection reason. Null when accepted.
    rejection_code: ?[]u8,
    rejection_message: ?[]u8,
    /// The candidate bytes after `prove` normalized them. Owned.
    candidate: []u8,
    rewrite_count: usize,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        if (self.rejection_code) |code| allocator.free(code);
        if (self.rejection_message) |message| allocator.free(message);
        allocator.free(self.candidate);
        self.* = undefined;
    }

    /// True when normalization changed the model-authored bytes and named the
    /// rewrite it applied. This is what the loop reports as a salvaged draft.
    pub fn salvaged(self: *const Observation, authored: []const u8) bool {
        return self.rewrite_count > 0 and !std.mem.eql(u8, self.candidate, authored);
    }
};

pub fn observe(allocator: std.mem.Allocator, probe: Probe) !Observation {
    var tmp = try IsolatedTmp.init(allocator, "prove-probe");
    defer tmp.cleanup(allocator);
    if (probe.baseline) |bytes| try tmp.writeFile(allocator, file_name, bytes);
    try writeProjectContext(allocator, &tmp, probe);

    // The proof allocates freely and the loop never frees it either: the turn
    // arena owns every allocation. Copy out only what the caller keeps.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    var prepared = try change_set.prepare(ta, tmp.abs_path, .{
        .file = file_name,
        .content = probe.candidate,
    });
    var snapshot = try workspace_snapshot.Snapshot.capture(ta, &prepared);
    const result = try aggregate_proof.prove(ta, &prepared, &snapshot);

    const change = prepared.changes[0];
    const candidate = try allocator.dupe(u8, change.candidate);
    errdefer allocator.free(candidate);

    switch (result) {
        .accepted => return .{
            .accepted = true,
            .rejection_code = null,
            .rejection_message = null,
            .candidate = candidate,
            .rewrite_count = change.rewrite_trace.len,
        },
        .rejected => |rejection| {
            const code = try allocator.dupe(u8, rejection.code);
            errdefer allocator.free(code);
            const message = try allocator.dupe(u8, rejection.message);
            return .{
                .accepted = false,
                .rejection_code = code,
                .rejection_message = message,
                .candidate = candidate,
                .rewrite_count = change.rewrite_trace.len,
            };
        },
    }
}

fn writeProjectContext(allocator: std.mem.Allocator, tmp: *const IsolatedTmp, probe: Probe) !void {
    if (probe.policy_json == null and probe.sql_schema == null) return;
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    try manifest.appendSlice(allocator, "{ \"entry\": \"handler.ts\"");
    if (probe.policy_json) |policy| {
        try tmp.writeFile(allocator, "policy.json", policy);
        try manifest.appendSlice(allocator, ", \"policy\": \"policy.json\"");
    }
    if (probe.sql_schema) |schema| {
        try tmp.writeFile(allocator, "schema.sql", schema);
        try manifest.appendSlice(allocator, ", \"sqlite\": \"schema.sql\"");
    }
    try manifest.appendSlice(allocator, " }\n");
    try tmp.writeFile(allocator, "zttp.json", manifest.items);
}

const testing = std.testing;

test "prove probe accepts a clean handler over an absent baseline" {
    var observed = try observe(testing.allocator, .{
        .baseline = null,
        .candidate = "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ ok: true }); }\n",
    });
    defer observed.deinit(testing.allocator);
    try testing.expect(observed.accepted);
    try testing.expectEqual(@as(usize, 0), observed.rewrite_count);
}

test "prove probe reports the first new code for a rejected draft" {
    var observed = try observe(testing.allocator, .{
        .baseline = "function handler(req: Request): Proof<Response, \"deterministic\"> { return Response.json({ ok: true }); }\n",
        .candidate = "function handler(req: Request): Proof<Response, \"deterministic\"> { var x = 1; return Response.json({ ok: x }); }\n",
    });
    defer observed.deinit(testing.allocator);
    try testing.expect(!observed.accepted);
    try testing.expect(observed.rejection_code != null);
}
