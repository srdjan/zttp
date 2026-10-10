//! Owns provider request configuration and transport state for one session.

const std = @import("std");
const loop = @import("../loop.zig");
const transcript_mod = @import("../transcript.zig");
const capture_sink = @import("capture_sink.zig");
const model_request = @import("model_request.zig");
const models = @import("models.zig");
const local_client = @import("local/client.zig");
const anthropic_client = @import("anthropic/client.zig");
const openai_client = @import("openai/client.zig");
const deepseek_client = @import("deepseek/client.zig");

const anthropic_endpoint = (anthropic_client.Config{
    .api_key = "",
    .system_prompt = "",
}).base_url;

const LocalTransport = struct {
    endpoint: []u8,
    request_timeout_ms: ?u64 = null,
    capture: ?*capture_sink.CaptureSink = null,
};

const AuthenticatedTransport = struct {
    auth: []u8,
    endpoint: []u8,
    request_timeout_ms: ?u64 = null,
    capture: ?*capture_sink.CaptureSink = null,
};

const DeepSeekTransport = struct {
    auth: []u8,
    endpoint: []u8,
    request_timeout_ms: ?u64 = null,
    stall_timeout_ms: ?u64 = null,
    capture: ?*capture_sink.CaptureSink = null,
};

const Transport = union(enum) {
    local: LocalTransport,
    anthropic: AuthenticatedTransport,
    openai: AuthenticatedTransport,
    deepseek: DeepSeekTransport,
};

pub const Init = struct {
    provider: model_request.Provider,
    auth: ?[]const u8 = null,
    system_prompt: []const u8,
    tools_json: ?[]const u8,
    endpoint: ?[]const u8 = null,
};

pub const ProviderBackend = struct {
    request_config: model_request.Config,
    transport: Transport,

    pub fn init(allocator: std.mem.Allocator, options: Init) !ProviderBackend {
        const prompt_owned = try allocator.dupe(u8, options.system_prompt);
        errdefer allocator.free(prompt_owned);
        const tools_owned = if (options.tools_json) |json| try allocator.dupe(u8, json) else null;
        errdefer if (tools_owned) |json| allocator.free(json);
        const endpoint_owned = try allocator.dupe(
            u8,
            options.endpoint orelse defaultEndpoint(options.provider),
        );
        errdefer allocator.free(endpoint_owned);
        const auth_owned: ?[]u8 = switch (options.provider) {
            .local => null,
            .anthropic, .openai, .deepseek => try allocator.dupe(
                u8,
                options.auth orelse unreachable,
            ),
        };
        errdefer if (auth_owned) |owned_auth| allocator.free(owned_auth);

        const model = models.defaultForProvider(options.provider);
        return .{
            .request_config = .{
                .provider = options.provider,
                .model = model.id,
                .max_output_tokens = model.request_policy.max_output_tokens,
                .stream = switch (options.provider) {
                    .local, .deepseek => false,
                    .anthropic, .openai => true,
                },
                .system_prompt = prompt_owned,
                .tools_json = tools_owned,
            },
            .transport = switch (options.provider) {
                .local => .{ .local = .{ .endpoint = endpoint_owned } },
                .anthropic => .{ .anthropic = .{
                    .auth = auth_owned orelse unreachable,
                    .endpoint = endpoint_owned,
                } },
                .openai => .{ .openai = .{
                    .auth = auth_owned orelse unreachable,
                    .endpoint = endpoint_owned,
                } },
                .deepseek => .{ .deepseek = .{
                    .auth = auth_owned orelse unreachable,
                    .endpoint = endpoint_owned,
                } },
            },
        };
    }

    fn defaultEndpoint(provider: model_request.Provider) []const u8 {
        return switch (provider) {
            .local => local_client.default_base_url,
            .anthropic => anthropic_endpoint,
            .openai => openai_client.default_base_url,
            .deepseek => deepseek_client.default_base_url,
        };
    }

    pub fn deinit(self: *ProviderBackend, allocator: std.mem.Allocator) void {
        allocator.free(self.request_config.system_prompt);
        if (self.request_config.tools_json) |json| allocator.free(json);
        switch (self.transport) {
            .local => |transport| allocator.free(transport.endpoint),
            .anthropic, .openai => |transport| {
                allocator.free(transport.auth);
                allocator.free(transport.endpoint);
            },
            .deepseek => |transport| {
                allocator.free(transport.auth);
                allocator.free(transport.endpoint);
            },
        }
        self.* = undefined;
    }

    pub fn requestConfig(self: *const ProviderBackend) model_request.Config {
        return self.request_config;
    }

    pub fn commitModel(
        self: *ProviderBackend,
        model: []const u8,
        max_output_tokens: u32,
    ) void {
        self.request_config.model = model;
        self.request_config.max_output_tokens = max_output_tokens;
    }

    pub fn setReserveTokens(self: *ProviderBackend, reserve_tokens: u64) void {
        self.request_config.reserve_tokens = reserve_tokens;
    }

    pub fn endpoint(self: *const ProviderBackend) []const u8 {
        return switch (self.transport) {
            inline else => |transport| transport.endpoint,
        };
    }

    pub fn auth(self: *const ProviderBackend) ?[]const u8 {
        return switch (self.transport) {
            .local => null,
            .anthropic, .openai => |transport| transport.auth,
            .deepseek => |transport| transport.auth,
        };
    }

    pub fn authLabel(self: *const ProviderBackend) []const u8 {
        return if (self.request_config.provider == .local) "none" else "api-key";
    }

    pub fn captureSink(self: *const ProviderBackend) ?*capture_sink.CaptureSink {
        return switch (self.transport) {
            inline else => |transport| transport.capture,
        };
    }

    pub fn setCaptureSink(
        self: *ProviderBackend,
        sink: ?*capture_sink.CaptureSink,
    ) void {
        switch (self.transport) {
            inline else => |*transport| transport.capture = sink,
        }
    }

    pub fn requestTimeout(self: *const ProviderBackend) ?u64 {
        return switch (self.transport) {
            inline else => |transport| transport.request_timeout_ms,
        };
    }

    pub fn setRequestTimeout(self: *ProviderBackend, timeout_ms: ?u64) void {
        switch (self.transport) {
            inline else => |*transport| transport.request_timeout_ms = timeout_ms,
        }
    }

    pub fn stallTimeout(self: *const ProviderBackend) ?u64 {
        return switch (self.transport) {
            .deepseek => |transport| transport.stall_timeout_ms,
            .local, .anthropic, .openai => null,
        };
    }

    pub fn setStallTimeout(self: *ProviderBackend, timeout_ms: ?u64) void {
        switch (self.transport) {
            .deepseek => |*transport| transport.stall_timeout_ms = timeout_ms,
            .local, .anthropic, .openai => {},
        }
    }

    pub fn asModelClient(self: *ProviderBackend) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }

    fn requestFn(
        context: *anyopaque,
        arena: std.mem.Allocator,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *ProviderBackend = @ptrCast(@alignCast(context));
        return self.sendWithConfig(arena, self.request_config, transcript, extra_user_text);
    }

    pub fn sendWithConfig(
        self: *ProviderBackend,
        arena: std.mem.Allocator,
        config: model_request.Config,
        transcript: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) !loop.ModelCallResult {
        std.debug.assert(config.provider == self.request_config.provider);
        return switch (self.transport) {
            inline else => |transport, tag| sendWithTransport(
                switch (tag) {
                    .local => local_client.Client,
                    .anthropic => anthropic_client.Client,
                    .openai => openai_client.Client,
                    .deepseek => deepseek_client.Client,
                },
                transport,
                arena,
                config,
                transcript,
                extra_user_text,
            ),
        };
    }
};

fn sendWithTransport(
    comptime Client: type,
    transport: anytype,
    arena: std.mem.Allocator,
    config: model_request.Config,
    transcript: *const transcript_mod.Transcript,
    extra_user_text: ?[]const u8,
) !loop.ModelCallResult {
    const ClientConfig = @FieldType(Client, "config");
    var client_config: ClientConfig = if (@hasField(ClientConfig, "api_key"))
        .{ .api_key = transport.auth, .system_prompt = config.system_prompt }
    else
        .{ .system_prompt = config.system_prompt };
    client_config.model = config.model;
    client_config.max_tokens = config.max_output_tokens;
    client_config.tools_json = config.tools_json;
    client_config.reserve_tokens = config.reserve_tokens;
    client_config.base_url = transport.endpoint;
    client_config.purpose = config.purpose;
    client_config.cache_policy = config.cache_policy;
    client_config.request_timeout_ms = transport.request_timeout_ms;
    if (@hasField(ClientConfig, "stall_timeout_ms")) {
        client_config.stall_timeout_ms = transport.stall_timeout_ms;
    }

    var client = Client.init(client_config);
    client.capture = transport.capture;
    return client.sendTurn(arena, transcript, extra_user_text);
}
