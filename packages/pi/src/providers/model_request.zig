//! Provider-neutral authority for one model request.
//!
//! A snapshot owns only its item slice. All strings borrow from the supplied
//! config and transcript, so those inputs must outlive serialization or replay
//! validation. Callers normally allocate the slice in their per-request arena.

const std = @import("std");
const transcript_mod = @import("../transcript.zig");

pub const Provider = enum { anthropic, openai };

pub const Config = struct {
    provider: Provider,
    model: []const u8,
    max_output_tokens: u32,
    stream: bool = true,
    system_prompt: []const u8,
    tools_json: ?[]const u8 = null,
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
};

pub const ItemTag = std.meta.Tag(Item);

pub const Sha256Hex = struct {
    bytes: [64]u8,

    pub fn fromBytes(domain: []const u8, bytes: []const u8) Sha256Hex {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashFrame(&hasher, domain);
        hashFrame(&hasher, bytes);
        return finish(&hasher);
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
    extra_user_text: ?[]const u8,
    request_context_sha256: Sha256Hex,
    transcript_sha256: Sha256Hex,
    transient_user_text_sha256: ?Sha256Hex,

    pub fn deinit(self: *ModelRequestSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const Input = struct {
    config: Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8 = null,
};

pub fn createSnapshot(allocator: std.mem.Allocator, input: Input) !ModelRequestSnapshot {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(allocator);

    for (input.transcript.entries.items) |entry| {
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
    }

    const owned_items = try items.toOwnedSlice(allocator);
    const system_prompt_sha256 = Sha256Hex.fromBytes("zttp-model-request-system-v1", input.config.system_prompt);
    const tools_sha256 = if (input.config.tools_json) |tools|
        Sha256Hex.fromBytes("zttp-model-request-tools-v1", tools)
    else
        null;

    return .{
        .config = input.config,
        .items = owned_items,
        .extra_user_text = input.extra_user_text,
        .request_context_sha256 = hashRequestContext(input.config, system_prompt_sha256, tools_sha256),
        .transcript_sha256 = hashTranscript(owned_items),
        .transient_user_text_sha256 = if (input.extra_user_text) |text|
            Sha256Hex.fromBytes("zttp-model-request-transient-user-v1", text)
        else
            null,
    };
}

fn hashRequestContext(config: Config, system_digest: Sha256Hex, tools_digest: ?Sha256Hex) Sha256Hex {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashFrame(&hasher, "zttp-model-request-context-v1");
    hashFrame(&hasher, @tagName(config.provider));
    hashFrame(&hasher, config.model);
    hashU64(&hasher, config.max_output_tokens);
    hashFrame(&hasher, if (config.stream) "stream" else "non-stream");
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
            .user_text, .model_text, .system_note => |body| hashFrame(&hasher, body),
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
