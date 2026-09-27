//! zttp:tool - the tool catalog declaration and request readers
//!
//! `toolCatalog(entries)` declares which routes of the handler's `routerMatch`
//! table are tools, with the description, the input and output schema names,
//! and the input byte ceiling of each. The compiler reads the literal argument
//! into the contract's tool catalog and refuses a handler whose catalog it
//! cannot read. At runtime the call does nothing: the catalog is a build fact,
//! and the runtime serves it from the accepted artifact, never from this call.
//!
//! `toolInput(name, req)` hands a tool its input (M4 T7). The tool gate has
//! already validated the request body against the catalog's input schema, with
//! the catalog's closed rules, before the handler runs; this export parses
//! those bytes and returns them as the `ok` arm of a `Result` whose value type
//! the compiler derives from the schema `name`, as it does for `validateJson`.
//! It answers `ok` only when the current request is a tool request that the
//! gate validated against exactly `name`, so the type never claims more than
//! the gate checked. The build refuses a `name` that is not the calling
//! route's catalog input.
//!
//! `agentPrompt()` reads the prompt that the agent gate admitted. The runtime
//! wires the admitted bytes in M5 A1 U3. Until then, the export refuses every
//! call. `callTool(callId, name, argsJson)` has its final public signature but
//! stays inert until M5 A4 implements tool dispatch.

const std = @import("std");
const sdk = @import("zttp-sdk");

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:tool",
    .name = "tool",
    .summary = "Call toolCatalog({...}) once at module scope with an object literal; each entry names a routerMatch route key. A tool reads its validated input with toolInput(inputSchemaName, req), and an agent reads its admitted prompt with agentPrompt(). callTool(callId, name, argsJson) is reserved for agent routes.",
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
        .{
            .name = "toolInput",
            .module_func = toolInputImpl,
            .arg_count = 2,
            .effect = .none,
            .returns = .result,
            .param_types = &.{ .string, .object },
            .param_names = &.{ "name", "request" },
            .failure_severity = .critical,
            .contract_extractions = &.{.{ .category = .request_schema }},
            .return_labels = .{ .validated = true },
        },
        .{
            .name = "agentPrompt",
            .module_func = agentPromptImpl,
            .arg_count = 0,
            .effect = .read,
            .returns = .result,
            .failure_severity = .critical,
            .return_labels = .{ .user_input = true },
        },
        .{
            .name = "callTool",
            .module_func = callToolImpl,
            .arg_count = 3,
            .effect = .write,
            .returns = .result,
            .param_types = &.{ .string, .string, .string },
            .param_names = &.{ "callId", "name", "argsJson" },
            .derives_from_args = true,
        },
    },
};

fn toolCatalogImpl(_: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
    return sdk.JSValue.undefined_val;
}

/// Why a `zttp:tool` export answered its error arm. The name is the error value.
pub const Refusal = enum {
    /// The current request is not a tool request, so no gate validated it.
    not_a_tool_request,
    /// The current request is not an admitted agent request.
    not_an_agent_request,
    /// The export has its final signature but no runtime behavior yet.
    not_implemented,
    /// The gate validated the request against another input schema.
    schema_mismatch,
    /// The arguments are not a schema name and the handler's request.
    invalid_arguments,
    /// The request carries no body text.
    no_body,
    /// The body does not parse. The gate validated it, so this does not occur
    /// on a tool request.
    invalid_json,
};

fn toolInputImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    if (args.len < 2 or !sdk.isObject(args[1])) return refuse(handle, .invalid_arguments);
    const name = sdk.extractString(args[0]) orelse return refuse(handle, .invalid_arguments);
    const validated = sdk.activeToolInputSchema(handle) orelse return refuse(handle, .not_a_tool_request);
    if (!std.mem.eql(u8, validated, name)) return refuse(handle, .schema_mismatch);
    const body = sdk.objectGet(handle, args[1], "body") orelse return refuse(handle, .no_body);
    const text = sdk.extractString(body) orelse return refuse(handle, .no_body);
    const value = sdk.parseJson(handle, text) catch return refuse(handle, .invalid_json);
    return sdk.resultOk(handle, value);
}

fn agentPromptImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
    return refuse(handle, .not_an_agent_request);
}

fn callToolImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, _: []const sdk.JSValue) anyerror!sdk.JSValue {
    return refuse(handle, .not_implemented);
}

fn refuse(handle: *sdk.ModuleHandle, reason: Refusal) anyerror!sdk.JSValue {
    return sdk.resultErr(handle, @tagName(reason));
}

test "toolCatalog is inert at runtime" {
    try std.testing.expectEqual(@as(usize, 4), binding.exports.len);
    try std.testing.expectEqual(sdk.EffectClass.none, binding.exports[0].effect);
    try std.testing.expectEqual(sdk.ReturnKind.undefined, binding.exports[0].returns);
}

test "toolInput is a critical, validating Result reader" {
    const input = binding.exports[1];
    try std.testing.expectEqualStrings("toolInput", input.name);
    try std.testing.expectEqual(sdk.ReturnKind.result, input.returns);
    try std.testing.expect(input.return_labels.validated);
}

test "agentPrompt keeps admitted prompt input labelled" {
    const prompt = binding.exports[2];
    try std.testing.expectEqualStrings("agentPrompt", prompt.name);
    try std.testing.expectEqual(@as(u8, 0), prompt.arg_count);
    try std.testing.expectEqual(sdk.ReturnKind.result, prompt.returns);
    try std.testing.expectEqual(sdk.FailureSeverity.critical, prompt.failure_severity);
    try std.testing.expectEqual(
        @as(sdk.LabelSet, .{ .user_input = true }),
        prompt.return_labels,
    );
}

test "callTool has its final pass-through signature" {
    const call_tool = binding.exports[3];
    try std.testing.expectEqualStrings("callTool", call_tool.name);
    try std.testing.expectEqual(@as(u8, 3), call_tool.arg_count);
    try std.testing.expectEqual(sdk.EffectClass.write, call_tool.effect);
    try std.testing.expectEqual(sdk.ReturnKind.result, call_tool.returns);
    try std.testing.expectEqualSlices(sdk.ReturnKind, &.{ .string, .string, .string }, call_tool.param_types);
    try std.testing.expect(call_tool.derives_from_args);
    try std.testing.expectEqual(@as(sdk.LabelSet, .{}), call_tool.return_labels);
}
