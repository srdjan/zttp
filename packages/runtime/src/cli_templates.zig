//! Project starter templates shared across CLI commands.
//!
//! `Template` and `parseTemplate` name the project starters. Template-specific
//! scaffold sources and path mappers stay with `init` since only it scaffolds.

const std = @import("std");

pub const Template = enum { basic, api };

pub fn parseTemplate(name: []const u8) ?Template {
    if (std.mem.eql(u8, name, "basic")) return .basic;
    if (std.mem.eql(u8, name, "api")) return .api;
    return null;
}

test "parseTemplate accepts v1 templates only" {
    try std.testing.expectEqual(Template.basic, parseTemplate("basic").?);
    try std.testing.expectEqual(Template.api, parseTemplate("api").?);
    try std.testing.expect(parseTemplate("unknown") == null);
    try std.testing.expect(parseTemplate("react") == null);
}
