//! Provider-neutral authority for one model request.
//!
//! A snapshot owns only its item slice. All strings borrow from the supplied
//! config and transcript, so those inputs must outlive serialization or replay
//! validation. Callers normally allocate the slice in their per-request arena.

const std = @import("std");
const context_budget = @import("../context_budget.zig");
const transcript_mod = @import("../transcript.zig");
const models = @import("models.zig");

pub const Provider = models.Provider;
pub const Purpose = enum { normal, summarization };
pub const CachePolicy = enum { enabled, disabled };
pub const compaction_summary_marker = "[zttp compaction summary v1]";

pub const Config = struct {
    provider: Provider,
    model: []const u8,
    max_output_tokens: u32,
    stream: bool = true,
    system_prompt: []const u8,
    tools_json: ?[]const u8 = null,
    reserve_tokens: u64 = context_budget.default_reserve_tokens,
    purpose: Purpose = .normal,
    cache_policy: CachePolicy = .enabled,
};

pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
};

pub const ToolResult = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    ok: bool,
    llm_text: []const u8,
};

pub const Item = union(enum) {
    user_text: []const u8,
    model_text: []const u8,
    tool_use: ToolUse,
    tool_result: ToolResult,
    system_note: []const u8,
    compaction_summary: []const u8,
};

pub const ItemTag = std.meta.Tag(Item);

/// One model-visible transcript entry. Multi-tool assistant entries span more
/// than one flattened item; preserving that boundary lets serializers consume
/// the snapshot without changing their existing wire grouping.
pub const ItemGroup = struct {
    start: usize,
    len: usize,
};

pub const Sha256Hex = struct {
    bytes: [64]u8,

    pub fn fromBytes(domain: []const u8, bytes: []const u8) Sha256Hex {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashFrame(&hasher, domain);
        hashFrame(&hasher, bytes);
        return finish(&hasher);
    }

    pub fn fromRawBytes(bytes: []const u8) Sha256Hex {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return .{ .bytes = std.fmt.bytesToHex(digest, .lower) };
    }

    pub fn eql(a: Sha256Hex, b: Sha256Hex) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn slice(self: *const Sha256Hex) []const u8 {
        return &self.bytes;
    }
};

pub const ModelRequestSnapshot = struct {
    config: Config,
    items: []const Item,
    item_groups: []const ItemGroup,
    extra_user_text: ?[]const u8,
    component_bytes: context_budget.ComponentBytes,
    /// Present once the provider serializer has supplied the exact wire body.
    /// Transport and capture happen only after this preparation step.
    budget: ?context_budget.RequestBudget = null,
    request_context_sha256: Sha256Hex,
    transcript_sha256: Sha256Hex,
    transient_user_text_sha256: ?Sha256Hex,
    /// Stable identity of the first raw entry retained by an active
    /// compaction projection. Null means this request uses the raw transcript
    /// from its first entry.
    projection_first_kept_entry_id: ?transcript_mod.EntryId,
    /// Hash of the exact provider wire body when the transport supplies one.
    /// Semantic-only clients and historical recordings leave it null.
    wire_request_sha256: ?Sha256Hex = null,

    pub fn deinit(self: *ModelRequestSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        allocator.free(self.item_groups);
        self.* = undefined;
    }

    pub fn completePreparation(self: *ModelRequestSnapshot, wire_body: []const u8) !void {
        const wire_bytes = std.math.cast(u64, wire_body.len) orelse return error.RequestSizeOverflow;
        self.budget = try context_budget.estimate(
            self.component_bytes,
            wire_bytes,
            modelLimits(self.config),
        );
    }

    pub fn requireHardAdmission(self: *const ModelRequestSnapshot) !void {
        const budget = self.budget orelse return error.RequestNotPrepared;
        if (context_budget.relation(budget.tokens.total, budget.limits.hard_input_tokens) == .exceeded) {
            return error.RequestTooLarge;
        }
    }

    /// Clamp generation to the capacity left after the prepared input. Returns
    /// true when the provider body must be rebuilt with the smaller value.
    pub fn clampOutputToRemainingContext(self: *ModelRequestSnapshot) !bool {
        const budget = self.budget orelse return error.RequestNotPrepared;
        const limits = modelLimits(self.config);
        if (budget.tokens.total >= limits.context_window_tokens) return error.RequestTooLarge;
        const remaining = limits.context_window_tokens - budget.tokens.total;
        const clamped_u64 = @min(@as(u64, self.config.max_output_tokens), remaining);
        const clamped = std.math.cast(u32, clamped_u64) orelse return error.RequestSizeOverflow;
        if (clamped == self.config.max_output_tokens) return false;
        self.config.max_output_tokens = clamped;
        self.request_context_sha256 = hashRequestContext(
            self.config,
            Sha256Hex.fromRawBytes(self.config.system_prompt),
            if (self.config.tools_json) |tools| Sha256Hex.fromRawBytes(tools) else null,
        );
        self.budget = null;
        self.wire_request_sha256 = null;
        return true;
    }
};

fn modelLimits(config: Config) context_budget.ModelLimits {
    var limits = context_budget.limitsForModel(config.provider, config.model);
    limits.reserve_tokens = config.reserve_tokens;
    return limits;
}

pub const Input = struct {
    config: Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8 = null,
    projection_override: ?ProjectionOverride = null,
    use_projection_override: bool = false,
};

pub const ProjectionOverride = struct {
    summary: []const u8,
    first_kept_entry_id: transcript_mod.EntryId,
};

pub fn createSnapshot(allocator: std.mem.Allocator, input: Input) !ModelRequestSnapshot {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(allocator);
    var item_groups: std.ArrayListUnmanaged(ItemGroup) = .empty;
    errdefer item_groups.deinit(allocator);

    const projection = if (input.use_projection_override)
        input.projection_override
    else if (input.transcript.projection) |current|
        ProjectionOverride{
            .summary = current.summary,
            .first_kept_entry_id = current.first_kept_entry_id,
        }
    else
        null;
    if (projection) |active_projection| {
        try items.append(allocator, .{ .compaction_summary = active_projection.summary });
        try item_groups.append(allocator, .{ .start = 0, .len = 1 });
    }

    const active_start = if (projection) |active_projection|
        try projectionStartIndex(input.transcript, active_projection.first_kept_entry_id)
    else
        0;
    for (input.transcript.entries.items[active_start..]) |entry| {
        const start = items.items.len;
        switch (entry) {
            .user_text => |body| try items.append(allocator, .{ .user_text = body }),
            .model_text => |body| try items.append(allocator, .{ .model_text = body }),
            .assistant_tool_use => |calls| for (calls) |call| {
                try items.append(allocator, .{ .tool_use = .{
                    .id = call.id,
                    .name = call.name,
                    .args_json = call.args_json,
                } });
            },
            .tool_result => |result| try items.append(allocator, .{ .tool_result = .{
                .tool_use_id = result.tool_use_id,
                .tool_name = result.tool_name,
                .ok = result.ok,
                .llm_text = result.llm_text,
            } }),
            .system_note => |body| try items.append(allocator, .{ .system_note = body }),
            .proof_card, .diagnostic_box, .verified_patch => {},
        }
        if (items.items.len > start) {
            try item_groups.append(allocator, .{
                .start = start,
                .len = items.items.len - start,
            });
        }
    }

    const owned_items = try items.toOwnedSlice(allocator);
    errdefer allocator.free(owned_items);
    const owned_groups = try item_groups.toOwnedSlice(allocator);
    errdefer allocator.free(owned_groups);
    const system_prompt_sha256 = Sha256Hex.fromBytes("zttp-model-request-system-v1", input.config.system_prompt);
    const tools_sha256 = if (input.config.tools_json) |tools|
        Sha256Hex.fromBytes("zttp-model-request-tools-v1", tools)
    else
        null;

    return .{
        .config = input.config,
        .items = owned_items,
        .item_groups = owned_groups,
        .extra_user_text = input.extra_user_text,
        .component_bytes = .{
            .system = try byteLen(input.config.system_prompt),
            .tools = if (input.config.tools_json) |tools| try byteLen(tools) else 0,
            .history = try historyBytes(owned_items),
            .transient = if (input.extra_user_text) |text| try byteLen(text) else 0,
        },
        .request_context_sha256 = hashRequestContext(input.config, system_prompt_sha256, tools_sha256),
        .transcript_sha256 = hashTranscript(owned_items),
        .transient_user_text_sha256 = if (input.extra_user_text) |text|
            Sha256Hex.fromBytes("zttp-model-request-transient-user-v1", text)
        else
            null,
        .projection_first_kept_entry_id = if (projection) |active_projection|
            active_projection.first_kept_entry_id
        else
            null,
    };
}

fn projectionStartIndex(
    transcript: *const transcript_mod.Transcript,
    first_kept_entry_id: transcript_mod.EntryId,
) !usize {
    if (first_kept_entry_id == 0 or first_kept_entry_id > transcript.nextEntryId()) {
        return error.InvalidProjectionCut;
    }
    return @intCast(first_kept_entry_id - 1);
}

fn historyBytes(items: []const Item) !u64 {
    var total: u64 = 0;
    for (items) |item| switch (item) {
        .user_text, .model_text, .system_note => |body| try addBytes(&total, body),
        .compaction_summary => |body| {
            try addBytes(&total, compaction_summary_marker);
            try addBytes(&total, body);
        },
        .tool_use => |call| {
            try addBytes(&total, call.id);
            try addBytes(&total, call.name);
            try addBytes(&total, call.args_json);
        },
        .tool_result => |result| {
            try addBytes(&total, result.tool_use_id);
            try addBytes(&total, result.tool_name);
            try addBytes(&total, result.llm_text);
        },
    };
    return total;
}

fn addBytes(total: *u64, bytes: []const u8) !void {
    const len = try byteLen(bytes);
    const sum, const overflow = @addWithOverflow(total.*, len);
    if (overflow != 0) return error.RequestSizeOverflow;
    total.* = sum;
}

fn byteLen(bytes: []const u8) !u64 {
    return std.math.cast(u64, bytes.len) orelse error.RequestSizeOverflow;
}

fn hashRequestContext(config: Config, system_digest: Sha256Hex, tools_digest: ?Sha256Hex) Sha256Hex {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashFrame(&hasher, "zttp-model-request-context-v1");
    hashFrame(&hasher, @tagName(config.provider));
    hashFrame(&hasher, config.model);
    hashU64(&hasher, config.max_output_tokens);
    hashU64(&hasher, config.reserve_tokens);
    hashFrame(&hasher, if (config.stream) "stream" else "non-stream");
    hashFrame(&hasher, @tagName(config.purpose));
    hashFrame(&hasher, @tagName(config.cache_policy));
    hashFrame(&hasher, system_digest.slice());
    if (tools_digest) |digest| {
        hashFrame(&hasher, "tools-present");
        hashFrame(&hasher, digest.slice());
    } else {
        hashFrame(&hasher, "tools-absent");
    }
    return finish(&hasher);
}

fn hashTranscript(items: []const Item) Sha256Hex {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashFrame(&hasher, "zttp-model-visible-transcript-v1");
    hashU64(&hasher, items.len);
    for (items) |item| {
        hashFrame(&hasher, @tagName(std.meta.activeTag(item)));
        switch (item) {
            .user_text, .model_text, .system_note, .compaction_summary => |body| hashFrame(&hasher, body),
            .tool_use => |call| {
                hashFrame(&hasher, call.id);
                hashFrame(&hasher, call.name);
                hashFrame(&hasher, call.args_json);
            },
            .tool_result => |result| {
                hashFrame(&hasher, result.tool_use_id);
                hashFrame(&hasher, result.tool_name);
                hashFrame(&hasher, if (result.ok) "ok" else "error");
                hashFrame(&hasher, result.llm_text);
            },
        }
    }
    return finish(&hasher);
}

fn hashFrame(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashU64(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hasher.update(&bytes);
}

fn finish(hasher: *std.crypto.hash.sha2.Sha256) Sha256Hex {
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .bytes = std.fmt.bytesToHex(digest, .lower) };
}

test "snapshot uses checkpoint summary and retained suffix without mutating raw history" {
    const testing = std.testing;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    try transcript.append(testing.allocator, .{ .user_text = "old request" });
    try transcript.append(testing.allocator, .{ .model_text = "old answer" });
    try transcript.append(testing.allocator, .{ .user_text = "retained request" });
    try transcript.replaceProjection(testing.allocator, "durable summary", 3);

    var snapshot = try createSnapshot(testing.allocator, .{
        .config = .{
            .provider = .deepseek,
            .model = "deepseek-chat",
            .max_output_tokens = 1024,
            .system_prompt = "system",
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), transcript.len());
    try testing.expectEqual(@as(usize, 2), snapshot.items.len);
    switch (snapshot.items[0]) {
        .compaction_summary => |body| try testing.expectEqualStrings("durable summary", body),
        else => return error.TestExpectedSummary,
    }
    switch (snapshot.items[1]) {
        .user_text => |body| try testing.expectEqualStrings("retained request", body),
        else => return error.TestExpectedSuffix,
    }
}

test "prepared snapshot clamps output to the model capacity left after input" {
    const testing = std.testing;
    const system_prompt = try testing.allocator.alloc(u8, 560_000);
    defer testing.allocator.free(system_prompt);
    @memset(system_prompt, 'x');
    const wire_body = try testing.allocator.alloc(u8, system_prompt.len + 100);
    defer testing.allocator.free(wire_body);
    @memset(wire_body, 'x');
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(testing.allocator);
    var snapshot = try createSnapshot(testing.allocator, .{
        .config = .{
            .provider = .anthropic,
            .model = "claude-sonnet-5",
            .max_output_tokens = 64_000,
            .system_prompt = system_prompt,
        },
        .transcript = &transcript,
    });
    defer snapshot.deinit(testing.allocator);
    const before_hash = snapshot.request_context_sha256;
    try snapshot.completePreparation(wire_body);

    try testing.expect(try snapshot.clampOutputToRemainingContext());
    try testing.expect(snapshot.config.max_output_tokens < 64_000);
    try testing.expect(snapshot.config.max_output_tokens > 0);
    try testing.expect(snapshot.budget == null);
    try testing.expect(!before_hash.eql(snapshot.request_context_sha256));
}
