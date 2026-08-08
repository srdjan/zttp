//! Fail-closed model client for one validated flow-cassette script.
//!
//! The client borrows its script and request config. It creates the same
//! canonical request snapshot as the production providers, validates the next
//! semantic checkpoint, and only then parses and replays the raw cassette.

const std = @import("std");
const artifact = @import("artifact.zig");
const loop = @import("../loop.zig");
const transcript_mod = @import("../transcript.zig");
const cassette_client = @import("../providers/cassette_client.zig");
const model_request = @import("../providers/model_request.zig");

pub const Script = struct {
    provider: artifact.Provider,
    model: []const u8,
    checkpoints: []const artifact.ModelCheckpoint,
    responses: []const artifact.ResponseFixture,
    fixtures: []const artifact.LoadedFixture,

    pub fn fromFlowCase(flow_case: *const artifact.FlowCase) Script {
        return .{
            .provider = flow_case.manifest.provider,
            .model = flow_case.manifest.model,
            .checkpoints = flow_case.trace.model_calls,
            .responses = flow_case.manifest.model_responses,
            .fixtures = flow_case.fixtures,
        };
    }
};

pub const Client = struct {
    script: Script,
    request_config: model_request.Config,
    cursor: usize = 0,
    last_mismatch: ?artifact.ReplayMismatch = null,

    pub fn init(script: Script, request_config: model_request.Config) Client {
        return .{ .script = script, .request_config = request_config };
    }

    pub fn asModelClient(self: *Client) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }

    pub fn consumedCount(self: *const Client) usize {
        return self.cursor;
    }

    pub fn lastMismatch(self: *const Client) ?artifact.ReplayMismatch {
        return self.last_mismatch;
    }

    pub fn finish(self: *Client) !void {
        if (self.cursor < self.script.checkpoints.len) {
            return self.fail(.{ .unconsumed_checkpoint = self.detail(.trace) });
        }
        if (self.cursor < self.script.responses.len) {
            return self.fail(.{ .response_overflow = self.detail(.response) });
        }
    }

    fn requestFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.request(arena, transcript, extra_user_text);
    }

    fn request(
        self: *Client,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) !loop.ModelCallResult {
        self.last_mismatch = null;
        var snapshot = try model_request.createSnapshot(arena, .{
            .config = self.request_config,
            .transcript = transcript,
            .extra_user_text = extra_user_text,
        });
        defer snapshot.deinit(arena);

        const checkpoint = try self.validateSnapshot(&snapshot);
        const response = try self.responseFor(checkpoint);
        const raw = try self.responseBytes(response);
        const cassette = cassette_client.loadCassetteFromBytes(arena, raw, null) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SidecarNotFound, error.SidecarUnreadable => return self.failResponseFixture(.unreadable),
            else => return self.failResponseFixture(.malformed),
        };
        if (cassette.header.provider != cassetteProvider(self.script.provider)) {
            return self.fail(.{ .response_order_mismatch = self.detail(.response) });
        }

        const result = cassette_client.replay(arena, cassette) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.failResponseFixture(.malformed),
        };
        self.cursor += 1;
        return result;
    }

    fn validateSnapshot(
        self: *Client,
        snapshot: *const model_request.ModelRequestSnapshot,
    ) !*const artifact.ModelCheckpoint {
        if (self.cursor >= self.script.checkpoints.len) {
            return self.fail(.{ .response_underflow = self.detail(.trace) });
        }
        const checkpoint = &self.script.checkpoints[self.cursor];
        if (checkpoint.index != self.cursor) {
            return self.fail(.{ .response_order_mismatch = self.detailFor(.trace, checkpoint) });
        }
        if (artifactProvider(snapshot.config.provider) != self.script.provider or
            !std.mem.eql(u8, snapshot.config.model, self.script.model))
        {
            return self.fail(.{ .provider_request_mismatch = self.detailFor(.trace, checkpoint) });
        }
        if (!std.mem.eql(
            u8,
            snapshot.request_context_sha256.slice(),
            checkpoint.request_context_sha256.slice(),
        )) {
            return self.fail(.{ .model_context_mismatch = self.detailFor(.trace, checkpoint) });
        }
        const item_count: u32 = std.math.cast(u32, snapshot.items.len) orelse
            return self.fail(.{ .transcript_or_transient_prompt_mismatch = self.detailFor(.trace, checkpoint) });
        if (item_count != checkpoint.transcript_prefix_count or
            !std.mem.eql(u8, snapshot.transcript_sha256.slice(), checkpoint.transcript_sha256.slice()) or
            !optionalDigestEql(snapshot.transient_user_text_sha256, checkpoint.transient_user_text_sha256))
        {
            return self.fail(.{ .transcript_or_transient_prompt_mismatch = self.detailFor(.trace, checkpoint) });
        }
        return checkpoint;
    }

    fn responseFor(
        self: *Client,
        checkpoint: *const artifact.ModelCheckpoint,
    ) !*const artifact.ResponseFixture {
        if (self.cursor >= self.script.responses.len) {
            return self.fail(.{ .response_underflow = self.detailFor(.response, checkpoint) });
        }
        const response = &self.script.responses[self.cursor];
        if (response.index != checkpoint.index or response.turn_index != checkpoint.turn_index or
            response.call_index != checkpoint.call_index)
        {
            return self.fail(.{ .response_order_mismatch = self.detailFor(.response, checkpoint) });
        }
        return response;
    }

    fn responseBytes(self: *Client, response: *const artifact.ResponseFixture) ![]const u8 {
        for (self.script.fixtures) |fixture| {
            if (fixture.role != .response or !std.mem.eql(u8, fixture.path, response.path)) continue;
            const actual = artifact.Sha256Hex.fromBytes(fixture.bytes);
            if (!actual.eql(response.sha256)) {
                return self.failResponseFixture(.digest_mismatch);
            }
            return fixture.bytes;
        }
        return self.failResponseFixture(.missing);
    }

    fn failResponseFixture(
        self: *Client,
        kind: artifact.ResponseFixtureFailure,
    ) error{ReplayMismatch} {
        const mismatch_detail = self.detail(.response);
        return self.fail(.{ .response_fixture_mismatch = .{
            .component = mismatch_detail.component,
            .turn_index = mismatch_detail.turn_index,
            .call_index = mismatch_detail.call_index,
            .kind = kind,
        } });
    }

    fn detail(self: *const Client, component: artifact.Component) artifact.MismatchDetail {
        if (self.cursor >= self.script.checkpoints.len) return .{ .component = component };
        return self.detailFor(component, &self.script.checkpoints[self.cursor]);
    }

    fn detailFor(
        self: *const Client,
        component: artifact.Component,
        checkpoint: *const artifact.ModelCheckpoint,
    ) artifact.MismatchDetail {
        _ = self;
        return .{
            .component = component,
            .turn_index = checkpoint.turn_index,
            .call_index = checkpoint.call_index,
        };
    }

    fn fail(self: *Client, mismatch: artifact.ReplayMismatch) error{ReplayMismatch} {
        self.last_mismatch = mismatch;
        return error.ReplayMismatch;
    }
};

fn artifactProvider(provider: model_request.Provider) artifact.Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn cassetteProvider(provider: artifact.Provider) cassette_client.Provider {
    return switch (provider) {
        .anthropic => .anthropic,
        .openai => .openai,
    };
}

fn optionalDigestEql(
    actual: ?model_request.Sha256Hex,
    expected: ?artifact.Sha256Hex,
) bool {
    if (actual == null or expected == null) return actual == null and expected == null;
    return std.mem.eql(u8, actual.?.slice(), expected.?.slice());
}
