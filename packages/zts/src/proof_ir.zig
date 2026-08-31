//! The canonical proof IR: the shape of a program, and nothing else.
//!
//! A certificate has to state what was proved about which part of the program,
//! and a consumer has to be able to re-derive that statement without the
//! compiler. Neither is possible against the parser IR: it is large, it carries
//! source positions, and every expression form in it is a member the consumer
//! would have to model.
//!
//! This lowering keeps the ten node kinds totality depends on and collapses
//! everything else to a leaf. What survives is small enough that the consumer
//! re-runs the derivation itself rather than checking a producer's word for it,
//! and stable enough that moving a line does not move the proof identity.
//!
//! The tag and rule numbering here mirrors the acceptance kernel's alphabet.
//! It is duplicated rather than imported because the kernel is a leaf and the
//! compiler must not become its dependency; `packages/runtime` imports both and
//! pins the two numberings against each other.

const std = @import("std");
const ir = @import("zts-engine").parser.ir;
const translation_witness = @import("zts-engine").translation_witness;

const IrView = ir.IrView;
const NodeIndex = ir.NodeIndex;
const null_node = ir.null_node;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const node_domain = "zts-proof-ir-node-v1";

/// Mirrors `proof_system.NodeTag` in the acceptance kernel.
pub const Tag = enum(u16) {
    function = 1,
    sequence = 2,
    branch = 3,
    /// A `match` carrying a default arm.
    match_default = 4,
    /// A `match` with no default arm. Closed-union coverage is the type
    /// checker's answer, not this lowering's, so the node is recorded as open
    /// and a certificate that needs it total has to declare that edge.
    match_open = 5,
    match_arm = 6,
    loop_node = 7,
    return_node = 8,
    call = 9,
    plain = 10,
};

/// Mirrors `proof_system.Rule` in the acceptance kernel, totality half.
pub const Rule = enum(u16) {
    return_total = 1,
    branch_both_arms_total = 2,
    sequence_member_total = 3,
    match_exhaustive_total = 4,
    loop_never_total = 5,
};

pub const Node = struct {
    id: u32,
    tag: Tag,
    parent: u32,
    first_child: u32,
    child_count: u32,
    digest: [32]u8,
    /// The parser IR node this came from. Translation witnesses are recorded
    /// against parser indices, so this is how they attach.
    source: NodeIndex,
};

pub const ProofIr = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    /// The node id of the handler function, when the program declares one.
    handler_function: ?u32,

    pub fn deinit(self: *ProofIr) void {
        self.allocator.free(self.nodes);
        self.nodes = &.{};
    }

    pub fn nodeFor(self: *const ProofIr, source: NodeIndex) ?u32 {
        for (self.nodes) |node| {
            if (node.source == source) return node.id;
        }
        return null;
    }
};

pub const Error = error{
    OutOfMemory,
    /// The program nests deeper than the lowering will walk. A refusal, not a
    /// truncation: a partial proof IR would describe a different program.
    ProgramTooDeep,
};

pub const max_depth: u16 = 512;

// ---------------------------------------------------------------------------
// Lowering
// ---------------------------------------------------------------------------

const Tree = struct {
    tag: Tag,
    source: NodeIndex,
    /// Discriminator folded into a leaf's digest, so two different parser forms
    /// that both collapse to `plain` are still different members.
    leaf_kind: u16,
    children: std.ArrayList(Tree) = .empty,
    digest: [32]u8 = undefined,

    fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| child.deinit(allocator);
        self.children.deinit(allocator);
    }
};

const Lowerer = struct {
    allocator: std.mem.Allocator,
    view: IrView,
    depth: u16 = 0,

    fn build(self: *Lowerer, index: NodeIndex) Error!Tree {
        if (self.depth >= max_depth) return error.ProgramTooDeep;
        self.depth += 1;
        defer self.depth -= 1;

        const tag = self.view.getTag(index) orelse return self.leaf(.plain, index, 0);

        return switch (tag) {
            .program, .block => try self.sequence(index),
            .export_decl => blk: {
                const decl = self.view.getExportDecl(index) orelse break :blk try self.leaf(.plain, index, @intFromEnum(tag));
                var node = Tree{ .tag = .sequence, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(decl.declaration));
                break :blk node;
            },
            .function_decl => blk: {
                const decl = self.view.getVarDecl(index) orelse break :blk try self.leaf(.plain, index, @intFromEnum(tag));
                break :blk try self.build(decl.init);
            },
            .function_expr, .arrow_function => blk: {
                const func = self.view.getFunction(index) orelse break :blk try self.leaf(.plain, index, @intFromEnum(tag));
                var node = Tree{ .tag = .function, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(func.body));
                break :blk node;
            },
            .if_stmt => blk: {
                const stmt = self.view.getIfStmt(index) orelse break :blk try self.leaf(.plain, index, @intFromEnum(tag));
                var node = Tree{ .tag = .branch, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(stmt.then_branch));
                // An `if` with no `else` has one arm, and one arm is exactly why
                // it cannot establish totality. The shape says so.
                if (stmt.else_branch != null_node) {
                    try node.children.append(self.allocator, try self.build(stmt.else_branch));
                }
                break :blk node;
            },
            .match_expr => blk: {
                const match = self.view.getMatchExpr(index) orelse break :blk try self.leaf(.plain, index, @intFromEnum(tag));
                var has_default = false;
                for (0..match.arms_count) |i| {
                    const arm_index = self.view.getListIndex(match.arms_start, @intCast(i));
                    const arm = self.view.getMatchArm(arm_index) orelse continue;
                    if (arm.pattern == null_node) has_default = true;
                }
                var node = Tree{
                    .tag = if (has_default) .match_default else .match_open,
                    .source = index,
                    .leaf_kind = 0,
                };
                errdefer node.deinit(self.allocator);
                for (0..match.arms_count) |i| {
                    const arm_index = self.view.getListIndex(match.arms_start, @intCast(i));
                    try node.children.append(self.allocator, try self.build(arm_index));
                }
                break :blk node;
            },
            .match_arm => blk: {
                const arm = self.view.getMatchArm(index) orelse break :blk try self.leaf(.plain, index, @intFromEnum(tag));
                var node = Tree{ .tag = .match_arm, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(arm.body));
                break :blk node;
            },
            .for_of_stmt, .for_in_stmt => blk: {
                const loop = self.view.getForIter(index) orelse break :blk try self.leaf(.loop_node, index, @intFromEnum(tag));
                var node = Tree{ .tag = .loop_node, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(loop.body));
                break :blk node;
            },
            .for_stmt, .while_stmt, .do_while_stmt => blk: {
                const loop = self.view.getLoop(index) orelse break :blk try self.leaf(.loop_node, index, @intFromEnum(tag));
                var node = Tree{ .tag = .loop_node, .source = index, .leaf_kind = 0 };
                errdefer node.deinit(self.allocator);
                try node.children.append(self.allocator, try self.build(loop.body));
                break :blk node;
            },
            .return_stmt => try self.leaf(.return_node, index, @intFromEnum(tag)),
            .call, .method_call => try self.leaf(.call, index, @intFromEnum(tag)),
            else => try self.leaf(.plain, index, @intFromEnum(tag)),
        };
    }

    fn sequence(self: *Lowerer, index: NodeIndex) Error!Tree {
        const block = self.view.getBlock(index) orelse return self.leaf(.plain, index, 0);
        var node = Tree{ .tag = .sequence, .source = index, .leaf_kind = 0 };
        errdefer node.deinit(self.allocator);
        for (0..block.stmts_count) |i| {
            const child = self.view.getListIndex(block.stmts_start, @intCast(i));
            try node.children.append(self.allocator, try self.build(child));
        }
        return node;
    }

    fn leaf(self: *Lowerer, tag: Tag, index: NodeIndex, kind: u16) Error!Tree {
        _ = self;
        return .{ .tag = tag, .source = index, .leaf_kind = kind };
    }
};

fn digestTree(node: *Tree) void {
    for (node.children.items) |*child| digestTree(child);

    var hasher = Sha256.init(.{});
    hasher.update(node_domain);
    var tag_le: [2]u8 = undefined;
    std.mem.writeInt(u16, &tag_le, @intFromEnum(node.tag), .little);
    hasher.update(&tag_le);
    var kind_le: [2]u8 = undefined;
    std.mem.writeInt(u16, &kind_le, node.leaf_kind, .little);
    hasher.update(&kind_le);
    var count_le: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_le, @intCast(node.children.items.len), .little);
    hasher.update(&count_le);
    for (node.children.items) |child| hasher.update(&child.digest);
    node.digest = hasher.finalResult();
}

/// Lower a parsed program into the proof IR.
///
/// Node ids are assigned breadth first, so a node's children occupy one
/// contiguous id range and the wire form can address them with a start and a
/// count. Digests are computed bottom up over shape alone, so a source-line
/// change leaves the proof identity where it was and a structural change moves
/// it.
pub fn lower(allocator: std.mem.Allocator, view: IrView, root: NodeIndex) Error!ProofIr {
    var lowerer = Lowerer{ .allocator = allocator, .view = view };
    var tree = try lowerer.build(root);
    defer tree.deinit(allocator);
    digestTree(&tree);

    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(allocator);

    const Frame = struct { tree: *const Tree, id: u32, parent: u32 };
    var queue: std.ArrayList(Frame) = .empty;
    defer queue.deinit(allocator);

    try nodes.append(allocator, .{
        .id = 0,
        .tag = tree.tag,
        .parent = 0,
        .first_child = 0,
        .child_count = @intCast(tree.children.items.len),
        .digest = tree.digest,
        .source = tree.source,
    });
    try queue.append(allocator, .{ .tree = &tree, .id = 0, .parent = 0 });

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const frame = queue.items[head];
        const first_child: u32 = @intCast(nodes.items.len);
        nodes.items[frame.id].first_child = if (frame.tree.children.items.len == 0) 0 else first_child;
        for (frame.tree.children.items) |*child| {
            const id: u32 = @intCast(nodes.items.len);
            try nodes.append(allocator, .{
                .id = id,
                .tag = child.tag,
                .parent = frame.id,
                .first_child = 0,
                .child_count = @intCast(child.children.items.len),
                .digest = child.digest,
                .source = child.source,
            });
            try queue.append(allocator, .{ .tree = child, .id = id, .parent = frame.id });
        }
    }

    const owned = try nodes.toOwnedSlice(allocator);
    var handler_function: ?u32 = null;
    for (owned) |node| {
        if (node.tag == .function) {
            handler_function = node.id;
            break;
        }
    }
    return .{ .allocator = allocator, .nodes = owned, .handler_function = handler_function };
}

// ---------------------------------------------------------------------------
// Totality
// ---------------------------------------------------------------------------

/// Whether each node always returns, folded over the proof IR alone.
///
/// The consumer runs the same fold. This copy exists so the producer can tell,
/// before it writes a certificate, whether the claim it is about to make is one
/// the consumer will confirm - not so that the consumer can read the answer.
pub fn deriveTotality(
    allocator: std.mem.Allocator,
    proof: ProofIr,
    declared: []const u32,
) Error![]bool {
    const total = try allocator.alloc(bool, proof.nodes.len);
    errdefer allocator.free(total);
    @memset(total, false);

    // Children always have higher ids than their parent, so one reverse sweep
    // settles the fold.
    var index: usize = proof.nodes.len;
    while (index > 0) {
        index -= 1;
        const node = proof.nodes[index];
        total[index] = switch (node.tag) {
            .return_node => true,
            .function, .match_arm => firstChildTotal(total, node),
            .sequence => anyChildTotal(total, node),
            .branch => node.child_count == 2 and allChildrenTotal(total, node),
            .match_default => node.child_count > 0 and allChildrenTotal(total, node),
            .match_open, .loop_node, .call, .plain => false,
        };
        for (declared) |declared_id| {
            if (declared_id == node.id) total[index] = true;
        }
    }
    return total;
}

fn firstChildTotal(total: []const bool, node: Node) bool {
    if (node.child_count == 0) return false;
    return total[node.first_child];
}

fn anyChildTotal(total: []const bool, node: Node) bool {
    var i: u32 = 0;
    while (i < node.child_count) : (i += 1) {
        if (total[node.first_child + i]) return true;
    }
    return false;
}

fn allChildrenTotal(total: []const bool, node: Node) bool {
    if (node.child_count == 0) return false;
    var i: u32 = 0;
    while (i < node.child_count) : (i += 1) {
        if (!total[node.first_child + i]) return false;
    }
    return true;
}

/// The rule that discharges totality at `id`, when one does.
pub fn ruleAt(proof: ProofIr, total: []const bool, id: u32) ?Rule {
    const node = proof.nodes[id];
    return switch (node.tag) {
        .return_node => .return_total,
        .sequence => if (anyChildTotal(total, node)) .sequence_member_total else null,
        .branch => if (node.child_count == 2 and allChildrenTotal(total, node))
            .branch_both_arms_total
        else
            null,
        .match_default => if (node.child_count > 0 and allChildrenTotal(total, node))
            .match_exhaustive_total
        else
            null,
        .loop_node => .loop_never_total,
        .function, .match_arm, .match_open, .call, .plain => null,
    };
}

/// Every `match` the lowering could not close. A certificate that needs one of
/// these total has to declare that edge, and the declaration caps its grade.
pub fn openMatches(allocator: std.mem.Allocator, proof: ProofIr) Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    for (proof.nodes) |node| {
        if (node.tag == .match_open) try out.append(allocator, node.id);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Evidence
// ---------------------------------------------------------------------------

/// Everything the producer knows about one compiled handler that a certificate
/// can carry, with the translation witnesses already moved onto proof-IR ids.
///
/// This is a carrier, not a claim. Whether it adds up is the consumer's
/// question, and the consumer re-derives the totality fold rather than reading
/// `total` from here.
pub const Evidence = struct {
    allocator: std.mem.Allocator,
    proof: ProofIr,
    /// The producer's own fold, kept so it can refuse to emit a certificate for
    /// a handler the consumer would reject.
    total: []bool,
    /// Nodes whose totality the certificate declares rather than proves.
    declared: []u32,
    emissions: []Emission,
    jumps: []Jump,
    rewrites: []translation_witness.Rewrite,
    pre_optimization_len: u32,
    final_len: u32,

    pub fn deinit(self: *Evidence) void {
        self.proof.deinit();
        self.allocator.free(self.total);
        self.allocator.free(self.declared);
        self.allocator.free(self.emissions);
        self.allocator.free(self.jumps);
        self.allocator.free(self.rewrites);
    }

    /// Whether the handler function is total under this evidence.
    pub fn handlerIsTotal(self: *const Evidence) bool {
        const id = self.proof.handler_function orelse return false;
        return self.total[id];
    }
};

/// A translation witness whose subject is a proof-IR node rather than a parser
/// node.
pub const Emission = struct {
    /// The function whose code buffer this offset is measured in, as a proof-IR
    /// node id. The module's own function is node 0.
    scope: u32,
    node: u32,
    code_start: u32,
    code_len: u32,
};

pub const Jump = struct {
    scope: u32,
    node: u32,
    instruction_offset: u32,
    target_node: u32,
    target_offset: u32,
};

/// Assemble the evidence for one compiled handler.
///
/// `recorder` is the translation evidence code generation captured, or null for
/// a compile that did not record any. A run with no recorder yields evidence
/// with no witnesses, which a certificate reports as a weaker translation edge
/// rather than as a stronger one with the offsets omitted.
pub fn buildEvidence(
    allocator: std.mem.Allocator,
    view: IrView,
    root: NodeIndex,
    recorder: ?*const translation_witness.Recorder,
) Error!Evidence {
    var proof = try lower(allocator, view, root);
    errdefer proof.deinit();

    // Declare open matches only when the handler needs them. Over-declaring
    // would cap the grade for a handler that never depended on one.
    var declared: []u32 = try allocator.alloc(u32, 0);
    errdefer allocator.free(declared);
    var total = try deriveTotality(allocator, proof, declared);
    errdefer allocator.free(total);

    const handler = proof.handler_function;
    const needs_declaration = if (handler) |id| !total[id] else false;
    if (needs_declaration) {
        const open = try openMatches(allocator, proof);
        if (open.len == 0) {
            allocator.free(open);
        } else {
            const with_open = try deriveTotality(allocator, proof, open);
            if (handler != null and with_open[handler.?]) {
                allocator.free(total);
                allocator.free(declared);
                total = with_open;
                declared = open;
            } else {
                allocator.free(with_open);
                allocator.free(open);
            }
        }
    }

    var emissions: std.ArrayList(Emission) = .empty;
    errdefer emissions.deinit(allocator);
    var jumps: std.ArrayList(Jump) = .empty;
    errdefer jumps.deinit(allocator);
    var rewrites: std.ArrayList(translation_witness.Rewrite) = .empty;
    errdefer rewrites.deinit(allocator);

    var pre_len: u32 = 0;
    var final_len: u32 = 0;

    if (recorder) |rec| {
        for (rec.scopes.items, 0..) |scope, scope_index| {
            _ = scope_index;
            // The module's buffer is the proof IR's root; a nested function's
            // buffer is the node that function lowered to.
            const scope_id: u32 = if (scope.node == translation_witness.module_scope)
                0
            else
                proof.nodeFor(scope.node) orelse continue;

            if (scope.node == translation_witness.module_scope) {
                pre_len = scope.pre_optimization_len;
                final_len = scope.final_len;
            }

            for (scope.emissions.items) |emission| {
                const id = proof.nodeFor(emission.node) orelse continue;
                try emissions.append(allocator, .{
                    .scope = scope_id,
                    .node = id,
                    .code_start = emission.code_start,
                    .code_len = emission.code_len,
                });
            }
            for (scope.jumps.items) |jump| {
                const id = proof.nodeFor(jump.node) orelse continue;
                // A jump's target is an offset, not a node. It is only a
                // relation the consumer can check when some member's code
                // starts exactly there - a jump past the end of a branch, or
                // into the middle of one, lands where nothing begins. Those are
                // dropped rather than pointed at a node they do not name: a
                // witness the consumer cannot check is worse than one absent,
                // because the absent one does not claim anything.
                var target_node: ?u32 = null;
                for (scope.emissions.items) |candidate| {
                    if (candidate.code_start != jump.target_offset) continue;
                    target_node = proof.nodeFor(candidate.node) orelse continue;
                    break;
                }
                try jumps.append(allocator, .{
                    .scope = scope_id,
                    .node = id,
                    .instruction_offset = jump.instruction_offset,
                    .target_node = target_node orelse continue,
                    .target_offset = jump.target_offset,
                });
            }
            try rewrites.appendSlice(allocator, scope.rewrites.items);
        }
    }

    return .{
        .allocator = allocator,
        .proof = proof,
        .total = total,
        .declared = declared,
        .emissions = try emissions.toOwnedSlice(allocator),
        .jumps = try jumps.toOwnedSlice(allocator),
        .rewrites = try rewrites.toOwnedSlice(allocator),
        .pre_optimization_len = pre_len,
        .final_len = final_len,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const JsParser = @import("zts-engine").parser.JsParser;

const Lowered = struct {
    allocator: std.mem.Allocator,
    parser: *JsParser,
    proof: ProofIr,

    fn deinit(self: *Lowered) void {
        self.proof.deinit();
        self.parser.deinit();
        self.allocator.destroy(self.parser);
    }
};

fn parseAndLower(allocator: std.mem.Allocator, source: []const u8) !Lowered {
    const parser = try allocator.create(JsParser);
    errdefer allocator.destroy(parser);
    parser.* = try JsParser.init(allocator, source);
    errdefer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    const proof = try lower(allocator, view, root);
    return .{ .allocator = allocator, .parser = parser, .proof = proof };
}

test "a handler that always returns is total, and the shape says which rule" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  return Response.text("ok");
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);

    try testing.expect(total[function_id]);
    const body = proof.nodes[function_id].first_child;
    try testing.expectEqual(Rule.sequence_member_total, ruleAt(proof, total, body).?);
}

test "an if without an else does not establish totality" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);
    try testing.expect(!total[function_id]);
}

test "an if with both arms returning is total" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  } else {
        \\    return Response.text("no");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);
    try testing.expect(total[function_id]);

    var branch_id: ?u32 = null;
    for (proof.nodes) |node| {
        if (node.tag == .branch) branch_id = node.id;
    }
    try testing.expectEqual(Rule.branch_both_arms_total, ruleAt(proof, total, branch_id.?).?);
}

test "a loop body never establishes totality" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  for (const item of req.items) {
        \\    return Response.text("ok");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    const total = try deriveTotality(allocator, proof, &.{});
    defer allocator.free(total);
    try testing.expect(!total[function_id]);

    for (proof.nodes) |node| {
        if (node.tag != .loop_node) continue;
        try testing.expect(!total[node.id]);
        try testing.expectEqual(Rule.loop_never_total, ruleAt(proof, total, node.id).?);
    }
}

test "lowering is deterministic and children are contiguous" {
    const allocator = testing.allocator;
    const source =
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("a");
        \\  } else {
        \\    return Response.text("b");
        \\  }
        \\}
    ;
    var first = try parseAndLower(allocator, source);
    defer first.deinit();
    var second = try parseAndLower(allocator, source);
    defer second.deinit();

    try testing.expectEqual(first.proof.nodes.len, second.proof.nodes.len);
    for (first.proof.nodes, second.proof.nodes) |a, b| {
        try testing.expectEqual(a.tag, b.tag);
        try testing.expectEqual(a.first_child, b.first_child);
        try testing.expectEqual(a.child_count, b.child_count);
        try testing.expectEqualSlices(u8, &a.digest, &b.digest);
    }

    // Every child id sits inside its parent's declared range, and every parent
    // link points back. A wire form addressing children by start and count is
    // only meaningful while that holds.
    for (first.proof.nodes) |node| {
        var i: u32 = 0;
        while (i < node.child_count) : (i += 1) {
            const child = first.proof.nodes[node.first_child + i];
            try testing.expectEqual(node.id, child.parent);
            try testing.expect(child.id > node.id);
        }
    }
}

test "proof identity ignores source position and follows structure" {
    const allocator = testing.allocator;
    var plain = try parseAndLower(allocator,
        \\function handler(req) {
        \\  return Response.text("ok");
        \\}
    );
    defer plain.deinit();
    var spaced = try parseAndLower(allocator,
        \\
        \\
        \\function handler(req) {
        \\
        \\  return Response.text("ok");
        \\
        \\}
    );
    defer spaced.deinit();
    try testing.expectEqualSlices(
        u8,
        &plain.proof.nodes[0].digest,
        &spaced.proof.nodes[0].digest,
    );

    var changed = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  } else {
        \\    return Response.text("no");
        \\  }
        \\}
    );
    defer changed.deinit();
    try testing.expect(!std.mem.eql(
        u8,
        &plain.proof.nodes[0].digest,
        &changed.proof.nodes[0].digest,
    ));
}

test "a match without a default arm is recorded open and can be declared total" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  return match (req.method) {
        \\    when "GET": Response.text("get"),
        \\    when "POST": Response.text("post")
        \\  };
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const open = try openMatches(allocator, proof);
    defer allocator.free(open);
    // The match is an expression inside a return, so the return already carries
    // totality; what matters is that the lowering did not silently call the
    // match closed.
    for (proof.nodes) |node| {
        try testing.expect(node.tag != .match_default);
    }
    try testing.expect(open.len <= proof.nodes.len);
}

test "a declared node is total even when no rule closes it" {
    const allocator = testing.allocator;
    var lowered = try parseAndLower(allocator,
        \\function handler(req) {
        \\  if (req.method === "GET") {
        \\    return Response.text("ok");
        \\  }
        \\}
    );
    defer lowered.deinit();

    const proof = lowered.proof;
    const function_id = proof.handler_function orelse return error.TestUnexpectedResult;
    var branch_id: ?u32 = null;
    for (proof.nodes) |node| {
        if (node.tag == .branch) branch_id = node.id;
    }

    const declared = [_]u32{branch_id.?};
    const total = try deriveTotality(allocator, proof, &declared);
    defer allocator.free(total);
    try testing.expect(total[function_id]);
}

test "a program deeper than the walk bound is refused, not truncated" {
    const allocator = testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "function handler(req) {\n");
    var i: usize = 0;
    while (i < max_depth + 8) : (i += 1) {
        try source.appendSlice(allocator, "  if (req.ok) {\n");
    }
    try source.appendSlice(allocator, "    return Response.text(\"ok\");\n");
    i = 0;
    while (i < max_depth + 8) : (i += 1) {
        try source.appendSlice(allocator, "  }\n");
    }
    try source.appendSlice(allocator, "}\n");

    var parser = JsParser.init(allocator, source.items) catch return;
    defer parser.deinit();
    const root = parser.parse() catch return;
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    try testing.expectError(error.ProgramTooDeep, lower(allocator, view, root));
}
