//! Provider-neutral model tool catalog.
//!
//! Providers own their wire serialization. This module owns the ordered
//! `{name, description, input_schema}` inventory that every provider sees.

const registry_mod = @import("../registry/registry.zig");

pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub const apply_edit: Definition = .{
    .name = "apply_edit",
    .description = "Propose a complete file edit. The zttp compiler runs edit-simulate " ++
        "on the content before it reaches the user; if new violations appear, " ++
        "you will be re-prompted with the diagnostic and must try again.",
    .input_schema = "{\"type\":\"object\"," ++
        "\"additionalProperties\":false," ++
        "\"properties\":{" ++
        "\"file\":{\"type\":\"string\",\"description\":\"Handler file path (e.g. handler.ts).\"}," ++
        "\"content\":{\"type\":\"string\",\"description\":\"Full file content after the edit.\"}" ++
        "}," ++
        "\"required\":[\"file\",\"content\"]}",
};

pub const Iterator = struct {
    registry: *const registry_mod.Registry,
    emitted_apply_edit: bool = false,
    registry_index: usize = 0,

    pub fn next(self: *Iterator) ?Definition {
        if (!self.emitted_apply_edit) {
            self.emitted_apply_edit = true;
            return apply_edit;
        }
        const entries = self.registry.list();
        while (self.registry_index < entries.len) {
            const entry = entries[self.registry_index];
            self.registry_index += 1;
            if (!entry.allowedOn(.model)) continue;
            return .{
                .name = entry.name,
                .description = entry.description,
                .input_schema = entry.input_schema,
            };
        }
        return null;
    }
};

pub fn iterator(registry: *const registry_mod.Registry) Iterator {
    return .{ .registry = registry };
}

pub fn count(registry: *const registry_mod.Registry) usize {
    var total: usize = 1;
    for (registry.list()) |entry| {
        if (entry.allowedOn(.model)) total += 1;
    }
    return total;
}
