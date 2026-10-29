//! pi_goal_check - verify a handler against a set of property goals and
//! surface executable counterexample witnesses for any goal that fails.
//!
//! The tool loads the handler at `path`, runs the FlowChecker, and for each
//! diagnostic whose property tag appears in the requested `goals` set,
//! synthesises a witness using `zts.solveCounterexample`. Each witness
//! carries a concrete Request plus the virtual-module stub sequence needed
//! to drive the handler into the violating state. The same shape feeds the
//! runtime witness-replay path used by the expert loop.
//!
//! The input schema accepts:
//!   { "path": "handler.ts", "goals": ["no_secret_leakage", ...] }
//! `goals` is optional; when absent, every property tag the counterexample
//! surface currently supports is checked.
//!
//! The output is a JSON object:
//!   { "ok": bool,                  // true iff every requested goal is proven
//!     "goals": [property_tag...],  // goals actually checked
//!     "witnesses": [{ property, origin, sink, summary, request, io_stubs }...],
//!     "unproven": [property_tag...] }  // requested goals the check does not prove
//!
//! The bare single-file FlowChecker only synthesises witnesses. The verdict
//! comes from the production check (`unprovenGoals`), which resolves imports:
//! `ok` is false when a requested goal is unproven or the bare checker raised
//! a diagnostic for it. The agent reads the witness list, repairs the handler
//! to close the concrete path, then re-invokes this tool until `ok` is true.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const registry_mod = @import("../registry/registry.zig");
const common = @import("common.zig");
const property_goals = @import("../property_goals.zig");
const counterexample = zts.counterexample;
const flow_checker = zts.flow_checker;
const writeJsonString = zts.writeJsonString;
const name = "pi_goal_check";

pub const tool: registry_mod.ToolDef = .{
    .name = name,
    .label = "goal-check",
    .effect = .read_workspace,
    .context_policy = .exact,
    .model_exposure = .visible,
    .description =
    \\Check a handler against one or more property goals and return
    \\executable counterexample witnesses for the goals that are violated.
    \\
    \\Supported goals:
    \\  - no_secret_leakage    (env values, unless the policy lists the
    \\                          name in env.public, must not reach response bodies,
    \\                          logs, or external egress)
    \\  - no_credential_leakage (Authorization headers and JWT payloads
    \\                          must not reach response bodies or logs)
    \\  - injection_safe       (unvalidated user input must not reach
    \\                          sensitive sinks)
    \\  - input_validated      (user input must pass a validation step
    \\                          before any egress call)
    \\  - pii_contained        (user input must not flow to an external
    \\                          egress host)
    \\
    \\Each witness carries a concrete Request and the virtual-module stub
    \\sequence that drives the handler into the violating path. Use the
    \\returned witness data to close the concrete path before repair.
    \\Repairs should *close the concrete path*, not merely mute the rule.
    ,
    .input_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"goals":{"type":"array","items":{"type":"string"}}},"required":["path"]}
    ,
    .decode_json = decodeJson,
    .execute = execute,
};

/// Pack the JSON input into the argv slice the executor expects:
///   args[0]      = path
///   args[1..]    = goal tags (empty means "check all supported goals")
fn decodeJson(
    allocator: std.mem.Allocator,
    args_json: []const u8,
) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidToolArgsJson;
    const obj = parsed.value.object;

    const path_val = obj.get("path") orelse return error.InvalidToolArgsJson;
    if (path_val != .string) return error.InvalidToolArgsJson;

    var goals_count: usize = 0;
    if (obj.get("goals")) |g| {
        if (g != .array) return error.InvalidToolArgsJson;
        goals_count = g.array.items.len;
    }

    const out = try allocator.alloc([]const u8, 1 + goals_count);
    errdefer allocator.free(out);
    out[0] = try allocator.dupe(u8, path_val.string);

    if (obj.get("goals")) |g| {
        for (g.array.items, 0..) |item, i| {
            if (item != .string) return error.InvalidToolArgsJson;
            out[i + 1] = try allocator.dupe(u8, item.string);
        }
    }
    return out;
}

fn parseGoal(s: []const u8) ?counterexample.PropertyTag {
    return property_goals.parseDriveableGoal(s);
}

fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) anyerror!registry_mod.ToolResult {
    if (args.len == 0) {
        return registry_mod.ToolResult.err(allocator, name ++ ": requires a path\n");
    }

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, args[0]);
    defer allocator.free(absolute);

    const source = zts.file_io.readFile(
        allocator,
        absolute,
        common.default_output_limit,
    ) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": failed to read {s}: {s}\n",
            .{ args[0], @errorName(e) },
        );
    };
    defer allocator.free(source);

    // Resolve the goal set. When the caller omits `goals`, check everything
    // the counterexample surface currently models.
    var goals: std.ArrayListUnmanaged(counterexample.PropertyTag) = .empty;
    defer goals.deinit(allocator);
    if (args.len == 1) {
        try goals.appendSlice(allocator, &property_goals.supported_goals);
    } else {
        for (args[1..]) |g| {
            const tag = parseGoal(g) orelse {
                return registry_mod.ToolResult.errFmt(
                    allocator,
                    name ++ ": unknown goal {s}\n",
                    .{g},
                );
            };
            try goals.append(allocator, tag);
        }
    }

    return evaluateSourceWithTags(allocator, source, args[0], goals.items);
}

/// Evaluate candidate bytes without reading or changing the live workspace.
/// The autoloop uses this before a transaction commit so witness deltas are
/// proof-time evidence rather than a write-then-check authorization step.
pub fn evaluateSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    goal_names: []const []const u8,
) !registry_mod.ToolResult {
    var goals: std.ArrayListUnmanaged(counterexample.PropertyTag) = .empty;
    defer goals.deinit(allocator);
    if (goal_names.len == 0) {
        try goals.appendSlice(allocator, &property_goals.supported_goals);
    } else {
        for (goal_names) |goal_name| {
            const tag = parseGoal(goal_name) orelse return error.UnknownPropertyGoal;
            try goals.append(allocator, tag);
        }
    }
    return evaluateSourceWithTags(allocator, source, path, goals.items);
}

fn evaluateSourceWithTags(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    goals: []const counterexample.PropertyTag,
) !registry_mod.ToolResult {
    const source_kind = common.admitToolSource(allocator, source, path) catch |e| {
        switch (e) {
            error.InvalidSourceObservation => return e,
            else => {},
        }
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": TypeScript strip failed: {s}\n",
            .{@errorName(e)},
        );
    };

    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = if (source_kind.isTyped())
        try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile)
    else
        try zts.parser.JsParser.init(allocator, source);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);

    const program_root = js_parser.parse() catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": parse failed: {s}\n",
            .{@errorName(e)},
        );
    };
    const ir_view = zts.IrView.fromIRStore(&js_parser.nodes, &js_parser.constants);

    const handler_fn = zts.findHandlerFunction(ir_view, program_root) orelse {
        return registry_mod.ToolResult.err(
            allocator,
            name ++ ": no handler function found in file\n",
        );
    };

    var env_public = try common.discoverEnvPublic(allocator, path);
    defer env_public.deinit(allocator);
    var checker = zts.FlowChecker.init(allocator, ir_view, &atoms);
    defer checker.deinit();
    checker.scopes = &js_parser.scopes;
    checker.env_public = env_public.names();
    _ = checker.check(handler_fn) catch |e| {
        return registry_mod.ToolResult.errFmt(
            allocator,
            name ++ ": flow check failed: {s}\n",
            .{@errorName(e)},
        );
    };

    // Emit the JSON envelope.
    var text_buf = registry_mod.helpers.TextBuffer.init(allocator);
    defer text_buf.deinit();
    const w = text_buf.writer();

    try w.writeAll("{\"goals\":[");
    for (goals, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(g.asString());
        try w.writeByte('"');
    }
    try w.writeAll("],\"witnesses\":[");

    // A diagnostic for a requested goal is a violation whether or not a
    // witness can be built for it: a missing location or a solver error omits
    // the witness and keeps the count.
    var violation_count: usize = 0;
    var witness_count: usize = 0;
    for (checker.getDiagnostics()) |diag| {
        const tag = flow_checker.propertyTagForKind(diag.kind) orelse continue;
        if (!goalRequested(goals, tag)) continue;
        violation_count += 1;

        const loc = ir_view.getLoc(diag.node) orelse continue;
        const span: counterexample.SourceSpan = .{
            .line = loc.line,
            .column = loc.column,
        };

        // Diagnostics with no witness still count as a goal violation, but
        // the solver receives empty slices and produces the default witness.
        const constraints: []const counterexample.WitnessConstraint =
            if (diag.witness) |wit| wit.path_constraints else &.{};
        const io_calls: []const counterexample.TrackedIoCall =
            if (diag.witness) |wit| wit.io_calls else &.{};

        var witness = zts.solveCounterexample(allocator, .{
            .property = tag,
            .origin = span,
            .sink = span,
            .summary = diag.message,
            .constraints = constraints,
            .io_calls = io_calls,
        }) catch continue; // the solver fails only on allocation; the violation is already counted
        defer witness.deinit(allocator);

        if (witness_count > 0) try w.writeByte(',');
        witness_count += 1;

        // Each witness is a JSON object rather than the JSONL shape that
        // trace replay consumes. Callers that want replay input can pass
        // individual witnesses through `counterexample.writeJsonl`.
        try w.writeAll("{\"key\":\"");
        try witness.stableKey(w);
        try w.print(
            "\",\"property\":\"{s}\",\"origin\":{{\"line\":{d},\"column\":{d}}},\"sink\":{{\"line\":{d},\"column\":{d}}},\"summary\":",
            .{ tag.asString(), span.line, span.column, span.line, span.column },
        );
        try writeJsonString(w, diag.message);
        try w.print(
            ",\"request\":{{\"method\":\"{s}\",\"url\":",
            .{witness.request.method},
        );
        try writeJsonString(w, witness.request.url);
        try w.writeAll(",\"has_auth_header\":");
        try w.writeAll(if (witness.request.has_auth_header) "true" else "false");
        try w.writeAll("},\"io_stubs\":[");
        for (witness.io_stubs, 0..) |stub, si| {
            if (si > 0) try w.writeByte(',');
            try w.print(
                "{{\"seq\":{d},\"module\":\"{s}\",\"fn\":\"{s}\",\"result\":{s}}}",
                .{ stub.seq, stub.module, stub.func, stub.result_json },
            );
        }
        try w.writeAll("]}");
    }

    const unproven = try unprovenGoals(allocator, source, path, goals);
    defer allocator.free(unproven);
    const ok = violation_count == 0 and unproven.len == 0;

    try w.writeAll("],\"unproven\":[");
    for (unproven, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(g.asString());
        try w.writeByte('"');
    }
    try w.print("],\"ok\":{s}}}\n", .{if (ok) "true" else "false"});
    const llm_text = try text_buf.toOwnedSlice();
    errdefer allocator.free(llm_text);

    return .{
        .ok = ok,
        .llm_text = llm_text,
    };
}

/// The requested goals the production check does not prove for `source`, as an
/// owned slice. A goal counts as proven only when the check ran with imports
/// resolved, left no construct unresolved, and holds the goal's property. An
/// analysis that cannot run proves nothing, so every goal is then unproven.
/// This is the same check `aggregate_proof` gates edits with; the bare
/// single-file FlowChecker cannot see imports and cannot fail `input_validated`
/// or `pii_contained` by its diagnostics alone.
pub fn unprovenGoals(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    goals: []const counterexample.PropertyTag,
) ![]counterexample.PropertyTag {
    var unproven: std.ArrayList(counterexample.PropertyTag) = .empty;
    errdefer unproven.deinit(allocator);

    const root = try common.workspaceRoot(allocator);
    defer allocator.free(root);
    const absolute = try common.resolveInsideWorkspace(allocator, root, path);
    defer allocator.free(absolute);
    var project_paths = try zts_cli.edit_simulate.discoverProjectPaths(allocator, absolute);
    defer project_paths.deinit(allocator);
    const policy_source: ?[]u8 = if (project_paths.policy) |policy_path|
        zts.file_io.readFile(allocator, policy_path, 1024 * 1024) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try unproven.appendSlice(allocator, goals);
                return unproven.toOwnedSlice(allocator);
            },
        }
    else
        null;
    defer if (policy_source) |src| allocator.free(src);

    var check = zts_cli.precompile.runCheckOnlyFromSourceWithOptions(allocator, source, absolute, .{
        .sql_schema_path = project_paths.sqlite,
        .json_mode = true,
        .policy_source = policy_source,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try unproven.appendSlice(allocator, goals);
            return unproven.toOwnedSlice(allocator);
        },
    };
    defer check.deinit(allocator);

    for (goals) |goal| {
        const proven = if (check.properties) |p| check.flow_unresolved == 0 and propertyHolds(p, goal) else false;
        if (!proven) try unproven.append(allocator, goal);
    }
    return unproven.toOwnedSlice(allocator);
}

pub fn propertyHolds(p: zts.HandlerProperties, goal: counterexample.PropertyTag) bool {
    return switch (goal) {
        .no_secret_leakage => p.no_secret_leakage,
        .no_credential_leakage => p.no_credential_leakage,
        .injection_safe => p.injection_safe,
        .input_validated => p.input_validated,
        .pii_contained => p.pii_contained,
    };
}

fn goalRequested(goals: []const counterexample.PropertyTag, tag: counterexample.PropertyTag) bool {
    for (goals) |g| if (g == tag) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "decodeJson accepts path-only payload and checks all goals" {
    const args = try decodeJson(
        testing.allocator,
        "{\"path\":\"handler.ts\"}",
    );
    defer {
        for (args) |a| testing.allocator.free(a);
        testing.allocator.free(args);
    }
    try testing.expectEqual(@as(usize, 1), args.len);
    try testing.expectEqualStrings("handler.ts", args[0]);
}

test "decodeJson picks up goals array" {
    const args = try decodeJson(
        testing.allocator,
        "{\"path\":\"h.ts\",\"goals\":[\"no_secret_leakage\",\"injection_safe\"]}",
    );
    defer {
        for (args) |a| testing.allocator.free(a);
        testing.allocator.free(args);
    }
    try testing.expectEqual(@as(usize, 3), args.len);
    try testing.expectEqualStrings("h.ts", args[0]);
    try testing.expectEqualStrings("no_secret_leakage", args[1]);
    try testing.expectEqualStrings("injection_safe", args[2]);
}

test "parseGoal recognises every supported property tag" {
    try testing.expectEqual(counterexample.PropertyTag.no_secret_leakage, parseGoal("no_secret_leakage").?);
    try testing.expectEqual(counterexample.PropertyTag.no_credential_leakage, parseGoal("no_credential_leakage").?);
    try testing.expectEqual(counterexample.PropertyTag.injection_safe, parseGoal("injection_safe").?);
    try testing.expectEqual(counterexample.PropertyTag.input_validated, parseGoal("input_validated").?);
    try testing.expectEqual(counterexample.PropertyTag.pii_contained, parseGoal("pii_contained").?);
    try testing.expect(parseGoal("totally_not_a_property") == null);
}

test "execute rejects a property the solver does not model" {
    // `deterministic` is a structural fact the compiler computes, not a goal:
    // there is no falsifying input to aim a repair loop at. Driving it would
    // ask the agent to close a path that was never opened.
    var result = try execute(testing.allocator, &.{ "examples/handler/handler.ts", "deterministic" });
    defer result.deinit(testing.allocator);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "unknown goal deterministic") != null);
}

test "tool description names every currently supported goal" {
    try testing.expect(std.mem.indexOf(u8, tool.description, "no_secret_leakage") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "no_credential_leakage") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "injection_safe") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "input_validated") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "pii_contained") != null);
    try testing.expect(std.mem.indexOf(u8, tool.description, "close the concrete path") != null);
}

test "execute emits witness JSON for the secret-leak fixture" {
    // The fixture lives under the repo's examples/ directory. When the
    // test runs from the project root (the default `zig build test`), the
    // relative path resolves. When run outside the workspace the tool
    // returns a PathOutsideWorkspace error and we skip.
    const result = execute(testing.allocator, &.{"examples/handler/secret-leak.ts"}) catch |e| switch (e) {
        error.PathOutsideWorkspace, error.FileNotFound => return,
        else => return e,
    };
    var mut = result;
    defer mut.deinit(testing.allocator);

    // Secret leak present -> tool reports not-ok with at least one witness.
    try testing.expect(!mut.ok);
    try testing.expect(std.mem.indexOf(u8, mut.llm_text, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, mut.llm_text, "\"property\":\"no_secret_leakage\"") != null);
    // The witness request is GET / with no body, and carries an env stub
    // in the io_stubs list.
    try testing.expect(std.mem.indexOf(u8, mut.llm_text, "\"method\":\"GET\"") != null);
    try testing.expect(std.mem.indexOf(u8, mut.llm_text, "\"fn\":\"env\"") != null);
    try testing.expect(std.mem.indexOf(u8, mut.llm_text, "\"module\":\"env\"") != null);
}

const IsolatedTmp = @import("../test_support/tmp.zig").IsolatedTmp;
const cwd_support = @import("../test_support/cwd.zig");

fn goalCheckIn(
    allocator: std.mem.Allocator,
    label: []const u8,
    files: []const [2][]const u8,
    args_json: []const u8,
) !registry_mod.ToolResult {
    var tmp = try IsolatedTmp.init(allocator, label);
    defer tmp.cleanup(allocator);
    for (files) |file| try tmp.writeFile(allocator, file[0], file[1]);

    const saved_cwd = try cwd_support.cwdPathAlloc(allocator);
    defer allocator.free(saved_cwd);
    try std.Io.Threaded.chdir(tmp.abs_path);
    defer std.Io.Threaded.chdir(saved_cwd) catch {};

    const args = try decodeJson(allocator, args_json);
    defer {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    return execute(allocator, args);
}

test "execute fails pii_contained when user input reaches fetchSync" {
    var result = try goalCheckIn(testing.allocator, "goal-pii", &.{.{
        "handler.ts",
        \\function handler(req: Request): Response {
        \\  fetchSync("https://api.example.com", { method: "POST", body: req.body });
        \\  return Response.json({ ok: true });
        \\}
        \\
    }}, "{\"path\":\"handler.ts\",\"goals\":[\"pii_contained\"]}");
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"unproven\":[\"pii_contained\"]") != null);
}

test "execute passes a clean goal through a resolvable sibling import" {
    var result = try goalCheckIn(testing.allocator, "goal-import-ok", &.{
        .{
            "handler.ts",
            \\import { greet } from "./utils.ts";
            \\
            \\function handler(req: Request): Response {
            \\  return Response.json({ message: greet("world") });
            \\}
            \\
        },
        .{
            "utils.ts",
            \\export structural GreetingName = string;
            \\export structural GreetingText = string;
            \\
            \\export function greet(name: GreetingName): GreetingText {
            \\  return ["Hello, ", name, "!"].join("");
            \\}
            \\
        },
    }, "{\"path\":\"handler.ts\",\"goals\":[\"no_secret_leakage\"]}");
    defer result.deinit(testing.allocator);
    try testing.expect(result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"ok\":true") != null);
}

test "execute fails a goal when an import does not resolve" {
    var result = try goalCheckIn(testing.allocator, "goal-import-missing", &.{.{
        "handler.ts",
        \\import { greet } from "./missing.ts";
        \\
        \\function handler(req: Request): Response {
        \\  return Response.json({ message: greet("world") });
        \\}
        \\
    }}, "{\"path\":\"handler.ts\",\"goals\":[\"no_secret_leakage\"]}");
    defer result.deinit(testing.allocator);
    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.llm_text, "\"ok\":false") != null);
}
