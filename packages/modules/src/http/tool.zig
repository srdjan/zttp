//! zttp:tool - the tool catalog declaration
//!
//! `toolCatalog(entries)` declares which routes of the handler's `routerMatch`
//! table are tools, with the description, the input and output schema names,
//! and the input byte ceiling of each. The compiler reads the literal argument
//! into the contract's tool catalog and refuses a handler whose catalog it
//! cannot read. At runtime the call does nothing: the catalog is a build fact,
//! and the runtime serves it from the accepted artifact, never from this call.

const sdk = @import("zttp-sdk");

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:tool",
    .name = "tool",
    .summary = "Call toolCatalog({...}) once at module scope with an object literal; each entry names a routerMatch route key and two schemaCompile names, and every route in the table must have an entry.",
    .exports = &.{
        .{
            .name = "toolCatalog",
            .module_func = toolCatalogImpl,
            .arg_count = 1,
            .effect = .none,
            .returns = .undefined,
            .param_types = &.{.object},
            .param_names = &.{"entries"},
            .traceable = false,
            .contract_extractions = &.{.{ .category = .tool_catalog }},
            .laws = &.{.pure},
            .replay_pure = true,
        },
    },
};

fn toolCatalogImpl(_: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
    return sdk.JSValue.undefined_val;
}

test "toolCatalog is inert at runtime" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), binding.exports.len);
    try std.testing.expectEqual(sdk.EffectClass.none, binding.exports[0].effect);
    try std.testing.expectEqual(sdk.ReturnKind.undefined, binding.exports[0].returns);
}
