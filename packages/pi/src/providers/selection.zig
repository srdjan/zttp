//! Pure launch-time provider and model resolution.
//!
//! Provider selection is independent from credential lookup and transport
//! readiness. This keeps cloud keys from influencing the default and lets a
//! caller inspect persisted session identity before constructing a backend.

const std = @import("std");
const models = @import("models.zig");

pub const Provider = models.Provider;

pub const StoredIdentity = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
};

pub const Input = struct {
    launch_provider: ?Provider = null,
    launch_model: ?[]const u8 = null,
    stored: ?StoredIdentity = null,
};

pub const Resolution = struct {
    provider: Provider,
    model: *const models.Model,
    provider_overridden: bool = false,
    model_overridden: bool = false,
};

pub const ResolveError = models.SelectionError || error{
    InvalidStoredProvider,
    LegacySessionIdentity,
};

pub fn resolve(input: Input) ResolveError!Resolution {
    var stored_provider_invalid = false;
    const stored_provider = if (input.stored) |stored| blk: {
        const name = stored.provider orelse {
            if (input.launch_provider == null) return error.LegacySessionIdentity;
            break :blk null;
        };
        break :blk Provider.parsePublic(name) orelse {
            if (input.launch_provider == null) return error.InvalidStoredProvider;
            stored_provider_invalid = true;
            break :blk null;
        };
    } else null;

    const stored_model = if (input.stored) |stored| stored.model else null;
    if (input.stored != null and stored_model == null and input.launch_provider == null) {
        return error.LegacySessionIdentity;
    }

    const provider = input.launch_provider orelse stored_provider orelse models.default_provider;
    const selected = if (input.launch_model) |id|
        try models.resolveForProvider(provider, id)
    else if (stored_model) |id| blk: {
        const same_provider = if (stored_provider) |stored| stored == provider else false;
        if (!same_provider) {
            break :blk models.defaultForProvider(provider);
        }
        break :blk try models.resolveForProvider(provider, id);
    } else models.defaultForProvider(provider);

    const provider_overridden = if (input.launch_provider) |launch|
        stored_provider_invalid or if (stored_provider) |stored| launch != stored else false
    else
        false;
    const model_overridden = if (input.launch_model) |launch|
        if (stored_model) |stored| !std.mem.eql(u8, launch, stored) else false
    else
        false;

    return .{
        .provider = provider,
        .model = selected,
        .provider_overridden = provider_overridden,
        .model_overridden = model_overridden,
    };
}

test "bare launch resolves through the single global default authority" {
    const result = try resolve(.{});
    try std.testing.expectEqual(models.default_provider, result.provider);
    try std.testing.expectEqualStrings(models.defaultForProvider(models.default_provider).id, result.model.id);
}

test "stored identity wins over the global default" {
    const result = try resolve(.{ .stored = .{
        .provider = "claude",
        .model = "claude-sonnet-4-6",
    } });
    try std.testing.expectEqual(Provider.anthropic, result.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", result.model.id);
}

test "explicit provider and model override stored identity together" {
    const result = try resolve(.{
        .launch_provider = .openai,
        .launch_model = "gpt-4o-mini",
        .stored = .{ .provider = "claude", .model = "claude-sonnet-4-6" },
    });
    try std.testing.expect(result.provider_overridden);
    try std.testing.expect(result.model_overridden);
    try std.testing.expectEqual(Provider.openai, result.provider);
}

test "model never changes or infers provider" {
    try std.testing.expectError(error.ProviderMismatch, resolve(.{
        .launch_model = "LiquidAI/LFM2.5-2.6B-MLX-8bit",
    }));
    try std.testing.expectError(error.ProviderMismatch, resolve(.{
        .launch_provider = .anthropic,
        .launch_model = "gpt-4o-mini",
    }));
}

test "legacy stored identity requires an explicit provider then migrates" {
    try std.testing.expectError(error.LegacySessionIdentity, resolve(.{
        .stored = .{ .provider = null, .model = null },
    }));
    const migrated = try resolve(.{
        .launch_provider = .anthropic,
        .stored = .{ .provider = null, .model = null },
    });
    try std.testing.expectEqualStrings("claude-sonnet-4-6", migrated.model.id);
}

test "explicit provider change without a model uses that provider default" {
    const result = try resolve(.{
        .launch_provider = .openai,
        .stored = .{ .provider = "claude", .model = "claude-opus-4-8" },
    });
    try std.testing.expectEqualStrings("gpt-4o-mini", result.model.id);
}

test "explicit provider recovers an invalid stored provider" {
    const result = try resolve(.{
        .launch_provider = .local,
        .stored = .{ .provider = "removed-provider", .model = "old-model" },
    });
    try std.testing.expect(result.provider_overridden);
    try std.testing.expectEqual(Provider.local, result.provider);
    try std.testing.expectEqualStrings(models.defaultForProvider(.local).id, result.model.id);

    try std.testing.expectError(error.InvalidStoredProvider, resolve(.{
        .stored = .{ .provider = "removed-provider", .model = "old-model" },
    }));
}
