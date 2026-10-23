//! Read supported branch predicates without deciding a flow property.
//! The caller supplies exact request-field and I/O-result provenance from the
//! current abstract state. A partial predicate cannot establish a witness.
const std = @import("std");
const engine = @import("zts-engine");
const ir = engine.parser.ir;
const counterexample = @import("counterexample.zig");
const status_check = @import("status_check.zig");

pub const RequestField = enum { method, url, path };
pub const Origin = counterexample.StubInfo;

/// A named defense observed at one exact source operation. This is passing
/// evidence only; the defense lattice independently decides the property.
pub const Guard = struct {
    module: u16,
    node: ir.NodeIndex,
    func: []const u8,

    pub fn eql(a: Guard, b: Guard) bool {
        return a.module == b.module and a.node == b.node and std.mem.eql(u8, a.func, b.func);
    }
};

/// A clean contributor is neutral. Two exposed alternatives need the same
/// named guard; a missing or different name cannot describe every path.
pub fn commonGuard(a: ?Guard, b: ?Guard, a_exposed: bool, b_exposed: bool) ?Guard {
    if (!a_exposed and !b_exposed) return null;
    if (!a_exposed) return b;
    if (!b_exposed) return a;
    const left = a orelse return null;
    const right = b orelse return null;
    return if (left.eql(right)) left else null;
}

pub const Context = struct {
    ir_view: ir.IrView,
    userdata: *anyopaque,
    /// Return a field only when the expression is exactly that request value,
    /// including a proven identity alias, rather than a derived value.
    requestField: *const fn (*anyopaque, ir.NodeIndex) ?RequestField,
    /// Return one call origin only when every possible expression value is
    /// that unmodified call result on the current path. Joined or transformed
    /// origins cannot justify a constructive stub constraint.
    ioOrigin: *const fn (*anyopaque, ir.NodeIndex) ?Origin,
};

pub const Condition = struct {
    constraints: []const counterexample.WitnessConstraint,
    /// The constraints imply the requested branch predicate. This is local
    /// predicate coverage, not proof of an executable whole-program path:
    /// callers must also retain one path's values/I/O and validate the solver
    /// result against the complete accumulated constraint chain.
    complete: bool,

    pub fn deinit(self: Condition, allocator: std.mem.Allocator) void {
        allocator.free(self.constraints);
    }
};

pub fn condition(allocator: std.mem.Allocator, ctx: Context, node: ir.NodeIndex, want_negation: bool) std.mem.Allocator.Error!Condition {
    var constraints: std.ArrayList(counterexample.WitnessConstraint) = .empty;
    errdefer constraints.deinit(allocator);
    const complete = try collect(allocator, ctx, node, want_negation, &constraints, 0);
    return .{ .constraints = try constraints.toOwnedSlice(allocator), .complete = complete };
}

fn collect(
    allocator: std.mem.Allocator,
    ctx: Context,
    node: ir.NodeIndex,
    negated: bool,
    out: *std.ArrayList(counterexample.WitnessConstraint),
    depth: u16,
) std.mem.Allocator.Error!bool {
    if (depth >= 256) return false;
    const view = ctx.ir_view;
    const tag = view.getTag(node) orelse return false;
    if (tag == .lit_bool) return (view.getBoolValue(node) orelse return false) != negated;
    if (tag == .unary_op) {
        const unary = view.getUnary(node) orelse return false;
        if (unary.op != .not) return false;
        return collect(allocator, ctx, unary.operand, !negated, out, depth + 1);
    }
    if (tag == .binary_op) {
        const binary = view.getBinary(node) orelse return false;
        if (binary.op == .and_op) {
            const start = out.items.len;
            const left = try collect(allocator, ctx, binary.left, negated, out, depth + 1);
            const middle = out.items.len;
            const right = try collect(allocator, ctx, binary.right, negated, out, depth + 1);
            if (negated and out.items.len > start) {
                // Keep one whole sufficient child group. A nested negation
                // can make that group a conjunction; choosing one of its
                // leaves would no longer imply that this AND is false.
                const left_group = out.items[start..middle];
                const right_group = out.items[middle..];
                const chosen = if (containsRequest(left_group) or !containsRequest(right_group)) left_group else right_group;
                std.mem.copyForwards(counterexample.WitnessConstraint, out.items[start..][0..chosen.len], chosen);
                out.shrinkRetainingCapacity(start + chosen.len);
            }
            return left and right;
        }
        if (statusComparison(ctx, binary)) |status| {
            // Preserve the exact numeric test. The old fork classifier only
            // compares non-2xx statuses and 200, so it is a candidate preference
            // rather than an equivalence for statuses 201..299.
            if (status.preference) |preferred| try out.append(allocator, if (negated) counterexample.negate(preferred).? else preferred);
            try out.append(allocator, if (negated) counterexample.negate(status.exact).? else status.exact);
            return true;
        }
    }
    const raw = single(ctx, node) orelse return false;
    const final = if (negated) counterexample.negate(raw) orelse return false else raw;
    try out.append(allocator, final);
    return true;
}

fn isRequest(constraint: counterexample.WitnessConstraint) bool {
    return switch (constraint) {
        .req_method, .req_method_not, .req_url, .req_url_not, .req_path, .req_path_not => true,
        else => false,
    };
}

fn containsRequest(constraints: []const counterexample.WitnessConstraint) bool {
    for (constraints) |item| if (isRequest(item)) return true;
    return false;
}

fn single(ctx: Context, node: ir.NodeIndex) ?counterexample.WitnessConstraint {
    const view = ctx.ir_view;
    switch (view.getTag(node) orelse return null) {
        .identifier => {
            const origin = ctx.ioOrigin(ctx.userdata, node) orelse return null;
            if (origin.returns != .boolean) return null;
            return .{ .stub_truthy = origin };
        },
        .member_access => {
            const member = view.getMember(node) orelse return null;
            if (member.property != @backingInt(engine.object.Atom.ok)) return null;
            const origin = ctx.ioOrigin(ctx.userdata, member.object) orelse return null;
            if (origin.returns != .result and !origin.ok_record) return null;
            return .{ .result_ok = origin };
        },
        .binary_op => {
            const binary = view.getBinary(node) orelse return null;
            if (binary.op != .strict_eq and binary.op != .strict_neq) return null;
            const raw = requestComparison(ctx, binary.left, binary.right) orelse
                requestComparison(ctx, binary.right, binary.left) orelse
                absentComparison(ctx, binary.left, binary.right) orelse
                absentComparison(ctx, binary.right, binary.left) orelse return null;
            return if (binary.op == .strict_eq) raw else counterexample.negate(raw);
        },
        else => return null,
    }
}

fn requestComparison(ctx: Context, field_node: ir.NodeIndex, literal: ir.NodeIndex) ?counterexample.WitnessConstraint {
    const view = ctx.ir_view;
    if (view.getTag(literal) != .lit_string) return null;
    const value = view.getString(view.getStringIdx(literal) orelse return null) orelse return null;
    return switch (ctx.requestField(ctx.userdata, field_node) orelse return null) {
        .method => .{ .req_method = value },
        .url => .{ .req_url = value },
        .path => .{ .req_path = value },
    };
}

fn absentComparison(ctx: Context, value_node: ir.NodeIndex, absent: ir.NodeIndex) ?counterexample.WitnessConstraint {
    if (ctx.ir_view.getTag(absent) != .lit_undefined) return null;
    const origin = ctx.ioOrigin(ctx.userdata, value_node) orelse return null;
    switch (origin.returns) {
        .optional_string, .optional_number, .optional_object => return .{ .stub_absent = origin },
        else => return null,
    }
}

const StatusPredicate = struct {
    exact: counterexample.WitnessConstraint,
    preference: ?counterexample.WitnessConstraint,
};

fn statusComparison(ctx: Context, binary: ir.Node.BinaryExpr) ?StatusPredicate {
    for ([_]bool{ true, false }) |member_left| {
        const shape = status_check.shape(ctx.ir_view, binary, member_left) orelse continue;
        if (ctx.ir_view.getTag(shape.member) != .member_access) continue;
        const member = ctx.ir_view.getMember(shape.member) orelse continue;
        if (member.property != @backingInt(engine.object.Atom.status)) continue;
        const origin = ctx.ioOrigin(ctx.userdata, member.object) orelse continue;
        if (!origin.ok_record) continue;
        const classified = status_check.classify(shape.comparison);
        // Constant classifications still carry the exact status predicate.
        return .{
            .exact = .{ .status_is = .{ .stub = origin, .comparison = shape.comparison, .expect = true } },
            .preference = if (classified == .fork)
                (if (classified.fork) .{ .result_not_ok = origin } else .{ .result_ok = origin })
            else
                null,
        };
    }
    return null;
}

/// The legacy solver deliberately chooses a candidate rather than solving
/// arbitrary conjunctions. Recheck that concrete candidate before attaching
/// constructive evidence: last-write-wins request/stub choices can violate an
/// earlier predicate, even when every individual predicate is supported.
pub fn candidateSatisfies(
    allocator: std.mem.Allocator,
    constraints: []const counterexample.WitnessConstraint,
    witness: counterexample.CounterexampleWitness,
) std.mem.Allocator.Error!bool {
    for (constraints) |constraint| {
        const held = switch (constraint) {
            .req_method => |value| std.mem.eql(u8, value, witness.request.method),
            .req_method_not => |value| !std.mem.eql(u8, value, witness.request.method),
            .req_url => |value| std.mem.eql(u8, value, witness.request.url),
            .req_url_not => |value| !std.mem.eql(u8, value, witness.request.url),
            .req_path => |value| std.mem.eql(u8, value, requestPath(witness.request.url)),
            .req_path_not => |value| !std.mem.eql(u8, value, requestPath(witness.request.url)),
            .stub_truthy => |origin| try stubSatisfies(allocator, witness.io_stubs, origin, .truthy, null),
            .stub_falsy => |origin| try stubSatisfies(allocator, witness.io_stubs, origin, .falsy, null),
            .stub_present => |origin| try stubSatisfies(allocator, witness.io_stubs, origin, .present, null),
            .stub_absent => |origin| try stubSatisfies(allocator, witness.io_stubs, origin, .absent, null),
            .result_ok => |origin| try stubSatisfies(allocator, witness.io_stubs, origin, .ok, null),
            .result_not_ok => |origin| try stubSatisfies(allocator, witness.io_stubs, origin, .not_ok, null),
            .status_is => |status| try stubSatisfies(allocator, witness.io_stubs, status.stub, .status, status),
        };
        if (!held) return false;
    }
    return true;
}

fn requestPath(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfScalar(u8, url, '?') orelse url.len];
}

const StubTest = enum { truthy, falsy, present, absent, ok, not_ok, status };

fn stubSatisfies(
    allocator: std.mem.Allocator,
    stubs: []const counterexample.IoStubEntry,
    origin: Origin,
    check: StubTest,
    status_test: ?counterexample.StatusTest,
) std.mem.Allocator.Error!bool {
    var matched: ?counterexample.IoStubEntry = null;
    for (stubs) |stub| {
        if (!std.mem.eql(u8, stub.module, origin.module) or !std.mem.eql(u8, stub.func, origin.func)) continue;
        if (origin.call_index) |index| {
            if (stub.seq != index) continue;
        }
        if (matched != null) return false;
        matched = stub;
    }
    const stub = matched orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stub.result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    const value = parsed.value;
    switch (check) {
        .present, .absent => return (value != .null) == (check == .present),
        .truthy, .falsy => {
            const truthy = switch (value) {
                .null => false,
                .bool => |boolean| boolean,
                .integer => |number| number != 0,
                .float => |number| number != 0 and !std.math.isNan(number),
                .string => |string| string.len != 0,
                .object, .array => true,
                .number_string => return false,
            };
            return truthy == (check == .truthy);
        },
        .ok, .not_ok => {
            const ok = if (origin.ok_record)
                canonicalResponseOk(value) orelse return false
            else blk: {
                if (value != .object) return false;
                const held = value.object.get("ok") orelse return false;
                if (held != .bool) return false;
                break :blk held.bool;
            };
            return ok == (check == .ok);
        },
        .status => {
            const status = responseStatus(value) orelse return false;
            _ = canonicalResponseOk(value) orelse return false;
            const requirement = status_test.?;
            return status_check.holds(requirement.comparison, status) == requirement.expect;
        },
    }
}

fn canonicalResponseOk(value: std.json.Value) ?bool {
    const derived = status_check.isOkStatus(responseStatus(value) orelse return null);
    const declared = value.object.get("ok") orelse return null;
    if (declared != .bool or declared.bool != derived) return null;
    return derived;
}

fn responseStatus(value: std.json.Value) ?u16 {
    if (value != .object) return null;
    const status = value.object.get("status") orelse return null;
    if (status != .integer or status.integer < status_check.min_status or status.integer > status_check.max_status) return null;
    return @intCast(status.integer);
}

const Harness = struct {
    parser: engine.parser.JsParser,
    atoms: engine.context.AtomTable,
    view: ir.IrView,

    fn init(self: *Harness, source: []const u8) !void {
        const allocator = std.testing.allocator;
        self.atoms = .init(allocator);
        errdefer self.atoms.deinit();
        self.parser = try engine.parser.JsParser.init(allocator, source);
        errdefer self.parser.deinit();
        self.parser.setAtomTable(&self.atoms);
        _ = try self.parser.parse();
        self.view = ir.IrView.fromIRStore(&self.parser.nodes, &self.parser.constants);
    }

    fn deinit(self: *Harness) void {
        self.parser.deinit();
        self.atoms.deinit();
    }

    fn name(self: *Harness, atom: u16) ?[]const u8 {
        const value: engine.object.Atom = @fromBackingInt(@intCast(atom));
        return value.toPredefinedName() orelse self.atoms.getName(value);
    }

    fn identifier(self: *Harness, node: ir.NodeIndex, expected: []const u8) bool {
        if (self.view.getTag(node) != .identifier) return false;
        const binding = self.view.getBinding(node) orelse return false;
        return std.mem.eql(u8, self.name(binding.name_atom) orelse return false, expected);
    }

    fn field(raw: *anyopaque, node: ir.NodeIndex) ?RequestField {
        const self: *Harness = @ptrCast(@alignCast(raw));
        if (self.view.getTag(node) != .member_access) return null;
        const member = self.view.getMember(node) orelse return null;
        if (!self.identifier(member.object, "req")) return null;
        const property = self.name(member.property) orelse return null;
        inline for (@typeInfo(RequestField).@"enum".field_names) |entry| {
            if (std.mem.eql(u8, property, entry)) return @fromBackingInt(@intCast(@backingInt(@field(RequestField, entry))));
        }
        return null;
    }

    fn origin(raw: *anyopaque, node: ir.NodeIndex) ?Origin {
        const self: *Harness = @ptrCast(@alignCast(raw));
        if (self.identifier(node, "flag")) return .{ .module = "zttp:crypto", .func = "check", .returns = .boolean, .call_index = 0 };
        if (self.identifier(node, "secret")) return .{ .module = "zttp:env", .func = "env", .returns = .optional_string, .call_index = 1 };
        if (self.identifier(node, "result")) return .{ .module = "zttp:validate", .func = "validateJson", .returns = .result, .call_index = 2 };
        if (self.identifier(node, "remote")) return .{ .module = "zttp:fetch", .func = "fetch", .returns = .object, .call_index = 3, .ok_record = true };
        return null;
    }

    fn read(self: *Harness, allocator: std.mem.Allocator, negated: bool) !Condition {
        for (0..self.view.nodeCount()) |index| {
            const node: ir.NodeIndex = @intCast(index);
            if (self.view.getTag(node) != .if_stmt) continue;
            return condition(allocator, .{ .ir_view = self.view, .userdata = self, .requestField = field, .ioOrigin = origin }, self.view.getIfStmt(node).?.condition, negated);
        }
        return error.MissingCondition;
    }
};

test "flow evidence keeps request conjunctions and negates one sufficient clause" {
    var harness: Harness = undefined;
    try harness.init("function handler(req) { if (req.method === 'POST' && '/leak' === req.path) { return 1; } return 0; }");
    defer harness.deinit();
    const positive = try harness.read(std.testing.allocator, false);
    defer positive.deinit(std.testing.allocator);
    try std.testing.expect(positive.complete);
    try std.testing.expectEqual(@as(usize, 2), positive.constraints.len);
    try std.testing.expectEqualStrings("POST", positive.constraints[0].req_method);
    try std.testing.expectEqualStrings("/leak", positive.constraints[1].req_path);
    const negative = try harness.read(std.testing.allocator, true);
    defer negative.deinit(std.testing.allocator);
    try std.testing.expect(negative.complete);
    try std.testing.expectEqual(@as(usize, 1), negative.constraints.len);
    try std.testing.expectEqualStrings("POST", negative.constraints[0].req_method_not);
}

test "negated conjunction keeps the entire sufficient nested predicate" {
    const allocator = std.testing.allocator;
    var harness: Harness = undefined;
    try harness.init("function handler(req) { if (!(req.method === 'POST' && req.url === '/secret') && flag) { return 1; } return 0; }");
    defer harness.deinit();
    const result = try harness.read(allocator, true);
    defer result.deinit(allocator);
    try std.testing.expect(result.complete);
    var witness: counterexample.CounterexampleWitness = .{
        .property = .no_secret_leakage,
        .origin = .{ .line = 1, .column = 1 },
        .sink = .{ .line = 2, .column = 1 },
        .summary = "candidate",
        .request = .{ .method = "POST", .url = "/other", .has_auth_header = false, .body = null },
        .io_stubs = &.{.{ .seq = 0, .module = "zttp:crypto", .func = "check", .result_json = "true" }},
    };
    // This request takes the true branch, so it cannot witness its negation.
    try std.testing.expect(!try candidateSatisfies(allocator, result.constraints, witness));
    witness.request.url = "/secret";
    try std.testing.expect(try candidateSatisfies(allocator, result.constraints, witness));
}

test "flow evidence preserves call identities through optional boolean and Result predicates" {
    var harness: Harness = undefined;
    try harness.init("function handler(req) { if (secret !== undefined && result.ok && !flag) { return 1; } return 0; }");
    defer harness.deinit();
    const result = try harness.read(std.testing.allocator, false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(usize, 3), result.constraints.len);
    try std.testing.expectEqual(@as(?u32, 1), result.constraints[0].stub_present.call_index);
    try std.testing.expectEqual(@as(?u32, 2), result.constraints[1].result_ok.call_index);
    try std.testing.expectEqual(@as(?u32, 0), result.constraints[2].stub_falsy.call_index);
}

test "flow evidence retains status direction and requested branch polarity" {
    var harness: Harness = undefined;
    try harness.init("function handler(req) { if (404 === remote.status) { return 1; } return 0; }");
    defer harness.deinit();
    const result = try harness.read(std.testing.allocator, true);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.complete);
    const constraint = result.constraints[0].status_is;
    try std.testing.expect(constraint.comparison.literal_left);
    try std.testing.expectEqual(@as(f64, 404), constraint.comparison.literal);
    try std.testing.expect(!constraint.expect);
    try std.testing.expectEqual(@as(?u32, 3), constraint.stub.call_index);
    try std.testing.expect(constraint.stub.ok_record);
}

test "flow evidence declines predicates with unsupported or transformed origins" {
    const conditions = [_][]const u8{
        "req.method === 'POST' && opaque()",
        "flag.ok",
        "(secret + 'suffix') === undefined",
        "opaque() || req.url === '/'",
    };
    for (conditions) |predicate| {
        const source = try std.testing.allocator.print("function handler(req) {{ if ({s}) {{ return 1; }} return 0; }}", .{predicate});
        defer std.testing.allocator.free(source);
        var harness: Harness = undefined;
        try harness.init(source);
        defer harness.deinit();
        const positive = try harness.read(std.testing.allocator, false);
        defer positive.deinit(std.testing.allocator);
        const negative = try harness.read(std.testing.allocator, true);
        defer negative.deinit(std.testing.allocator);
        try std.testing.expect(!positive.complete);
        try std.testing.expect(!negative.complete);
    }
}

test "flow evidence does not suppress allocation failures" {
    var harness: Harness = undefined;
    try harness.init("function handler(req) { if (req.method === 'POST' && req.url === '/leak') { return 1; } return 0; }");
    defer harness.deinit();
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, input: *Harness) !void {
            const result = try input.read(allocator, false);
            defer result.deinit(allocator);
            try std.testing.expect(result.complete);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{&harness});
}

test "flow evidence rejects candidates that violate an earlier request or call constraint" {
    const allocator = std.testing.allocator;
    const call: Origin = .{ .module = "zttp:env", .func = "env", .returns = .optional_string, .call_index = 0 };
    const cases = [_][]const counterexample.WitnessConstraint{
        &.{ .{ .req_method = "POST" }, .{ .req_method = "GET" } },
        &.{ .{ .req_url = "/secret" }, .{ .req_url_not = "/" } },
        &.{ .{ .stub_truthy = call }, .{ .stub_falsy = call } },
    };
    for (cases) |constraints| {
        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 2, .column = 1 },
            .summary = "candidate",
            .constraints = constraints,
            .io_calls = &.{.{ .module = call.module, .func = call.func, .returns = call.returns }},
        });
        defer witness.deinit(allocator);
        try std.testing.expect(!try candidateSatisfies(allocator, constraints, witness));
    }
}

test "flow evidence validates exact call identity and runtime derived response status" {
    const allocator = std.testing.allocator;
    const origin: Origin = .{ .module = "zttp:fetch", .func = "fetch", .returns = .object, .ok_record = true, .call_index = 1 };
    const witness: counterexample.CounterexampleWitness = .{
        .property = .no_secret_leakage,
        .origin = .{ .line = 1, .column = 1 },
        .sink = .{ .line = 2, .column = 1 },
        .summary = "candidate",
        .request = .{ .method = "POST", .url = "/leak", .has_auth_header = false, .body = null },
        .io_stubs = &.{
            .{ .seq = 0, .module = origin.module, .func = origin.func, .result_json = "{\"status\":200,\"ok\":true}" },
            .{ .seq = 1, .module = origin.module, .func = origin.func, .result_json = "{\"status\":503,\"ok\":false}" },
        },
    };
    try std.testing.expect(try candidateSatisfies(allocator, &.{.{ .result_not_ok = origin }}, witness));
    try std.testing.expect(!try candidateSatisfies(allocator, &.{.{ .result_ok = origin }}, witness));
    var ambiguous = origin;
    ambiguous.call_index = null;
    try std.testing.expect(!try candidateSatisfies(allocator, &.{.{ .result_not_ok = ambiguous }}, witness));
    var wrong_module = origin;
    wrong_module.module = "zttp:other";
    try std.testing.expect(!try candidateSatisfies(allocator, &.{.{ .result_not_ok = wrong_module }}, witness));
}

test "flow evidence distinguishes request path from URL and retains exact status equality" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { predicate: []const u8, holds: bool }{
        .{ .predicate = "req.path === '/secret?x=1'", .holds = false },
        .{ .predicate = "req.path !== '/secret' && req.url === '/secret?x=1'", .holds = false },
        .{ .predicate = "req.path === '/secret' && req.url === '/secret?x=1'", .holds = true },
        .{ .predicate = "remote.status === 200 && remote.status === 201", .holds = false },
        .{ .predicate = "remote.status >= 300", .holds = true },
        .{ .predicate = "remote.status >= 100", .holds = true },
        .{ .predicate = "remote.status < 100", .holds = false },
    };
    for (cases) |case| {
        const source = try allocator.print("function handler(req) {{ if ({s}) {{ return 1; }} return 0; }}", .{case.predicate});
        defer allocator.free(source);
        var harness: Harness = undefined;
        try harness.init(source);
        defer harness.deinit();
        const predicate = try harness.read(allocator, false);
        defer predicate.deinit(allocator);
        try std.testing.expect(predicate.complete);
        var witness = try counterexample.solve(allocator, .{
            .property = .no_secret_leakage,
            .origin = .{ .line = 1, .column = 1 },
            .sink = .{ .line = 2, .column = 1 },
            .summary = "candidate",
            .constraints = predicate.constraints,
            .io_calls = &.{
                .{ .module = "zttp:crypto", .func = "check", .returns = .boolean },
                .{ .module = "zttp:env", .func = "env", .returns = .optional_string },
                .{ .module = "zttp:validate", .func = "validateJson", .returns = .result },
                .{ .module = "zttp:fetch", .func = "fetch", .returns = .object },
            },
        });
        defer witness.deinit(allocator);
        try std.testing.expectEqual(case.holds, try candidateSatisfies(allocator, predicate.constraints, witness));
    }
}

test "optional absence is distinct from falsiness and ok record stubs must be consistent" {
    const allocator = std.testing.allocator;
    const optional: Origin = .{ .module = "zttp:env", .func = "env", .returns = .optional_string, .call_index = 0 };
    const witness: counterexample.CounterexampleWitness = .{
        .property = .no_secret_leakage,
        .origin = .{ .line = 1, .column = 1 },
        .sink = .{ .line = 2, .column = 1 },
        .summary = "candidate",
        .request = .{ .method = "GET", .url = "/", .has_auth_header = false, .body = null },
        .io_stubs = &.{.{ .seq = 0, .module = optional.module, .func = optional.func, .result_json = "\"\"" }},
    };
    try std.testing.expect(!try candidateSatisfies(allocator, &.{.{ .stub_absent = optional }}, witness));
    try std.testing.expect(try candidateSatisfies(allocator, &.{.{ .stub_present = optional }}, witness));
    try std.testing.expect(try candidateSatisfies(allocator, &.{.{ .stub_falsy = optional }}, witness));
    const retry: Origin = .{ .module = "zttp:resilience", .func = "fetchWithRetry", .returns = .object, .ok_record = true, .call_index = 0 };
    var malformed = witness;
    malformed.io_stubs = &.{.{ .seq = 0, .module = retry.module, .func = retry.func, .result_json = "{\"status\":503,\"ok\":true}" }};
    try std.testing.expect(!try candidateSatisfies(allocator, &.{.{ .result_not_ok = retry }}, malformed));
    try std.testing.expect(!try candidateSatisfies(allocator, &.{.{ .result_ok = retry }}, malformed));
}

test "named guard evidence survives a clean contributor in either order" {
    const guard: Guard = .{ .module = 1, .node = 42, .func = "escapeHtml" };
    try std.testing.expect(guard.eql(commonGuard(guard, null, true, false).?));
    try std.testing.expect(guard.eql(commonGuard(null, guard, false, true).?));
    try std.testing.expectEqual(@as(?Guard, null), commonGuard(guard, guard, false, false));
}

test "named guard identity includes source module node and function spelling" {
    const guard: Guard = .{ .module = 1, .node = 42, .func = "escapeHtml" };
    var copied_name = "escapeHtml".*;
    const same: Guard = .{ .module = 1, .node = 42, .func = &copied_name };
    try std.testing.expect(guard.eql(commonGuard(guard, same, true, true).?));
    const others = [_]Guard{
        .{ .module = 2, .node = 42, .func = "escapeHtml" },
        .{ .module = 1, .node = 43, .func = "escapeHtml" },
        .{ .module = 1, .node = 42, .func = "validateJson" },
    };
    for (others) |other| try std.testing.expectEqual(@as(?Guard, null), commonGuard(guard, other, true, true));
}

test "an exposed unnamed contributor prevents a named guard claim" {
    const guard: Guard = .{ .module = 1, .node = 42, .func = "escapeHtml" };
    try std.testing.expectEqual(@as(?Guard, null), commonGuard(guard, null, true, true));
    try std.testing.expectEqual(@as(?Guard, null), commonGuard(null, guard, true, true));
}
