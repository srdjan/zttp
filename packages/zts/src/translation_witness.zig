//! Translation evidence, recorded while it still exists.
//!
//! A certificate that relates a source-level proof to a deployed artifact has
//! to say where each proof-IR member ended up in the final bytecode. That
//! relation is only knowable inside code generation and optimization: once the
//! bytecode is serialized, the IR is gone and the offsets have already moved.
//!
//! This is a recorder, not a checker. It states what the producer did; the
//! consumer decides whether the statement holds together. Nothing here reads a
//! verdict or grants one.
//!
//! Recording is opt-in. `CodeGen.witness` is null on the ordinary compile path
//! and the recorder costs one null check per emitted node when it is.

const std = @import("std");

/// Where one IR member's code ended up, within the code buffer of the function
/// that contains it.
pub const Emission = struct {
    /// Parser IR node index. The proof-IR lowering maps this onto its own node
    /// identity; keeping the parser index here means the recorder does not have
    /// to know about the lowering.
    node: u32,
    code_start: u32,
    code_len: u32,
};

/// A branch that emitted a jump, and where that jump ended up pointing.
pub const Jump = struct {
    /// The innermost IR node open when the jump was emitted.
    node: u32,
    instruction_offset: u32,
    /// Label id, used to resolve `target_offset` after code generation.
    target_label: u32,
    target_offset: u32 = 0,
    resolved: bool = false,
};

/// The closed set of rewrites the optimizer may perform. A rewrite outside this
/// set cannot be recorded, so it cannot be disclosed, so an artifact carrying
/// one cannot produce a certificate.
pub const RewriteKind = enum(u16) {
    get_loc_add = 1,
    get_loc_get_loc_add = 2,
    push_const_call = 3,
    get_field_call = 4,
    if_false_goto = 5,
    drop_goto = 6,
    /// NOP removal, which shifts every later offset.
    compaction = 7,

    pub fn name(self: RewriteKind) []const u8 {
        return @tagName(self);
    }
};

pub const Rewrite = struct {
    kind: RewriteKind,
    /// Byte range the rewrite consumed, in pre-rewrite offsets.
    before_offset: u32,
    before_len: u32,
    /// Byte range it produced, in the same pre-compaction frame.
    after_offset: u32,
    after_len: u32,
    /// Bytes every later offset moves by. Negative for a shrink.
    delta: i32,
};

pub const Error = error{
    OutOfMemory,
    /// A recorder was asked to close a frame it never opened, a span ran
    /// backwards, or something could not be recorded. Either way the evidence
    /// is incomplete, and incomplete evidence must not be emitted as though it
    /// were whole.
    WitnessIncomplete,
};

/// The module's top-level function, which has no parser node of its own.
pub const module_scope: u32 = std.math.maxInt(u32);

/// One function's code buffer.
///
/// Code generation gives every function its own buffer, its own label table,
/// and its own optimization pass, so an offset only means something inside the
/// function it was recorded in. Scoping the records the same way is what keeps
/// a jump witness comparable with the emission witness it targets.
pub const Scope = struct {
    node: u32,
    emissions: std.ArrayList(Emission) = .empty,
    jumps: std.ArrayList(Jump) = .empty,
    rewrites: std.ArrayList(Rewrite) = .empty,
    pre_optimization_len: u32 = 0,
    final_len: u32 = 0,

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.emissions.deinit(allocator);
        self.jumps.deinit(allocator);
        self.rewrites.deinit(allocator);
    }
};

const OpenFrame = struct {
    node: u32,
    code_start: u32,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope) = .empty,
    /// Indices into `scopes`; the last is the function being generated.
    stack: std.ArrayList(usize) = .empty,
    open: std.ArrayList(OpenFrame) = .empty,
    /// Set when something could not be recorded. A recorder that lost a record
    /// still has to say so rather than hand back a shorter, plausible list.
    incomplete: bool = false,

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Recorder) void {
        for (self.scopes.items) |*scope| scope.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.open.deinit(self.allocator);
    }

    fn currentIndex(self: *Recorder) Error!usize {
        if (self.stack.items.len == 0) {
            // The module's own scope, opened lazily so a caller does not have
            // to remember to start it.
            try self.scopes.append(self.allocator, .{ .node = module_scope });
            try self.stack.append(self.allocator, self.scopes.items.len - 1);
        }
        return self.stack.items[self.stack.items.len - 1];
    }

    fn current(self: *Recorder) Error!*Scope {
        return &self.scopes.items[try self.currentIndex()];
    }

    /// Enter a nested function's code buffer.
    pub fn beginFunctionScope(self: *Recorder, node: u32) Error!void {
        _ = try self.currentIndex();
        try self.scopes.append(self.allocator, .{ .node = node });
        try self.stack.append(self.allocator, self.scopes.items.len - 1);
    }

    /// Leave it. Its records stay, scoped to it.
    pub fn endFunctionScope(self: *Recorder) Error!void {
        if (self.stack.items.len <= 1) {
            self.incomplete = true;
            return error.WitnessIncomplete;
        }
        _ = self.stack.pop();
    }

    /// Open a frame for an IR node about to be emitted.
    pub fn beginNode(self: *Recorder, node: u32, code_start: u32) Error!void {
        try self.open.append(self.allocator, .{ .node = node, .code_start = code_start });
    }

    /// Close the innermost frame. `record` is false for a node the proof IR does
    /// not carry, so the frame is still balanced but nothing is emitted.
    pub fn endNode(self: *Recorder, code_end: u32, record: bool) Error!void {
        if (self.open.items.len == 0) {
            self.incomplete = true;
            return error.WitnessIncomplete;
        }
        const frame = self.open.pop().?;
        if (!record) return;
        if (code_end < frame.code_start) {
            // A span that runs backwards means the code buffer moved under the
            // frame. Recording it would describe a range that does not exist.
            self.incomplete = true;
            return error.WitnessIncomplete;
        }
        const scope = try self.current();
        try scope.emissions.append(self.allocator, .{
            .node = frame.node,
            .code_start = frame.code_start,
            .code_len = code_end - frame.code_start,
        });
    }

    /// Record a jump emitted inside the innermost open frame.
    pub fn recordJump(self: *Recorder, instruction_offset: u32, target_label: u32) Error!void {
        const node = if (self.open.items.len == 0)
            0
        else
            self.open.items[self.open.items.len - 1].node;
        const scope = try self.current();
        try scope.jumps.append(self.allocator, .{
            .node = node,
            .instruction_offset = instruction_offset,
            .target_label = target_label,
        });
    }

    /// Fill in the resolved target of every jump recorded in the current scope.
    /// `labelOffset` reads the label table code generation just patched, which
    /// belongs to this function and no other.
    pub fn resolveJumps(
        self: *Recorder,
        context: anytype,
        comptime labelOffset: fn (@TypeOf(context), u32) ?u32,
    ) Error!void {
        const scope = try self.current();
        for (scope.jumps.items) |*jump| {
            if (jump.resolved) continue;
            const offset = labelOffset(context, jump.target_label) orelse {
                self.incomplete = true;
                return error.WitnessIncomplete;
            };
            jump.target_offset = offset;
            jump.resolved = true;
        }
    }

    pub fn recordRewrite(self: *Recorder, rewrite: Rewrite) void {
        const scope = self.current() catch {
            self.incomplete = true;
            return;
        };
        scope.rewrites.append(self.allocator, rewrite) catch {
            // A rewrite that could not be recorded makes the disclosure a lie
            // by omission. Flag it; `check` refuses.
            self.incomplete = true;
        };
    }

    pub fn notePreOptimizationLen(self: *Recorder, len: u32) void {
        const scope = self.current() catch {
            self.incomplete = true;
            return;
        };
        scope.pre_optimization_len = len;
    }

    /// Move the current scope's recorded offsets from the pre-compaction frame
    /// into the final one, using the optimizer's own old-to-new table, so the
    /// witnesses and the emitted jump operands move by the same mapping.
    pub fn applyCompaction(
        self: *Recorder,
        context: anytype,
        comptime remap: fn (@TypeOf(context), u32) u32,
        final_len: u32,
    ) void {
        const scope = self.current() catch {
            self.incomplete = true;
            return;
        };
        for (scope.emissions.items) |*emission| {
            const start = remap(context, emission.code_start);
            const end = remap(context, emission.code_start + emission.code_len);
            emission.code_start = start;
            emission.code_len = if (end >= start) end - start else 0;
        }
        for (scope.jumps.items) |*jump| {
            jump.instruction_offset = remap(context, jump.instruction_offset);
            jump.target_offset = remap(context, jump.target_offset);
        }
        scope.final_len = final_len;
    }

    /// The recording is whole: every function scope closed, every node frame
    /// closed, every jump resolved, nothing dropped. A recording that is not
    /// whole yields no certificate.
    pub fn check(self: *const Recorder) Error!void {
        if (self.incomplete) return error.WitnessIncomplete;
        if (self.open.items.len != 0) return error.WitnessIncomplete;
        if (self.stack.items.len > 1) return error.WitnessIncomplete;
        for (self.scopes.items) |scope| {
            for (scope.jumps.items) |jump| {
                if (!jump.resolved) return error.WitnessIncomplete;
            }
        }
    }

    /// The emission recorded for one parser IR node inside `scope`, if any.
    pub fn emissionFor(self: *const Recorder, scope_index: usize, node: u32) ?Emission {
        for (self.scopes.items[scope_index].emissions.items) |emission| {
            if (emission.node == node) return emission;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeLabels = struct {
    offsets: []const ?u32,

    fn offsetOf(self: FakeLabels, label: u32) ?u32 {
        if (label >= self.offsets.len) return null;
        return self.offsets[label];
    }
};

const FakeRemap = struct {
    shift: u32,

    fn map(self: FakeRemap, offset: u32) u32 {
        return if (offset >= self.shift) offset - self.shift else 0;
    }
};

test "a balanced recording is whole" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    try recorder.beginNode(7, 0);
    try recorder.recordJump(2, 0);
    try recorder.beginNode(8, 5);
    try recorder.endNode(9, true);
    try recorder.endNode(12, true);

    const labels = FakeLabels{ .offsets = &.{9} };
    try recorder.resolveJumps(labels, FakeLabels.offsetOf);
    try recorder.check();

    try testing.expectEqual(@as(usize, 1), recorder.scopes.items.len);
    try testing.expectEqual(@as(u32, module_scope), recorder.scopes.items[0].node);
    try testing.expectEqual(@as(usize, 2), recorder.scopes.items[0].emissions.items.len);
    // The jump was emitted inside node 7, not node 8.
    try testing.expectEqual(@as(u32, 7), recorder.scopes.items[0].jumps.items[0].node);
    try testing.expectEqual(@as(u32, 9), recorder.scopes.items[0].jumps.items[0].target_offset);

    const inner = recorder.emissionFor(0, 8).?;
    try testing.expectEqual(@as(u32, 5), inner.code_start);
    try testing.expectEqual(@as(u32, 4), inner.code_len);
}

test "a nested function's offsets are recorded against its own buffer" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    try recorder.beginNode(1, 0);
    try recorder.beginFunctionScope(1);
    // Inside the nested function the code buffer restarts at zero.
    try recorder.beginNode(2, 0);
    try recorder.recordJump(1, 0);
    try recorder.endNode(6, true);
    const inner_labels = FakeLabels{ .offsets = &.{4} };
    try recorder.resolveJumps(inner_labels, FakeLabels.offsetOf);
    try recorder.endFunctionScope();
    // Back in the module buffer, which never saw those bytes.
    try recorder.endNode(3, true);
    try recorder.check();

    try testing.expectEqual(@as(usize, 2), recorder.scopes.items.len);
    try testing.expectEqual(@as(u32, module_scope), recorder.scopes.items[0].node);
    try testing.expectEqual(@as(u32, 1), recorder.scopes.items[1].node);
    try testing.expectEqual(@as(u32, 0), recorder.emissionFor(1, 2).?.code_start);
    try testing.expectEqual(@as(u32, 6), recorder.emissionFor(1, 2).?.code_len);
    try testing.expectEqual(@as(?Emission, null), recorder.emissionFor(0, 2));
}

test "an unbalanced recording refuses rather than reporting a short list" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    try recorder.beginNode(1, 0);
    try recorder.endNode(4, true);
    // The frame above closed cleanly; a second close has nothing to close, and
    // the recorder must say so instead of silently ignoring it.
    try testing.expectError(error.WitnessIncomplete, recorder.endNode(8, true));
    try testing.expectError(error.WitnessIncomplete, recorder.check());
}

test "a span that runs backwards is refused" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    try recorder.beginNode(1, 10);
    try testing.expectError(error.WitnessIncomplete, recorder.endNode(4, true));
    try testing.expectError(error.WitnessIncomplete, recorder.check());
}

test "an unclosed function scope is not a whole recording" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    try recorder.beginFunctionScope(5);
    try testing.expectError(error.WitnessIncomplete, recorder.check());
    try recorder.endFunctionScope();
    try recorder.check();
    try testing.expectError(error.WitnessIncomplete, recorder.endFunctionScope());
}

test "an open node frame is not a whole recording" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    try recorder.beginNode(1, 0);
    try testing.expectError(error.WitnessIncomplete, recorder.check());
}

test "an unresolvable label makes the recording incomplete" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    try recorder.beginNode(1, 0);
    try recorder.recordJump(0, 3);
    try recorder.endNode(3, true);

    const labels = FakeLabels{ .offsets = &.{ 0, 1 } };
    try testing.expectError(error.WitnessIncomplete, recorder.resolveJumps(labels, FakeLabels.offsetOf));
    try testing.expectError(error.WitnessIncomplete, recorder.check());
}

test "compaction moves witnesses and jumps by the same mapping" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    try recorder.beginNode(1, 4);
    try recorder.recordJump(6, 0);
    try recorder.endNode(12, true);
    const labels = FakeLabels{ .offsets = &.{10} };
    try recorder.resolveJumps(labels, FakeLabels.offsetOf);

    recorder.notePreOptimizationLen(12);
    recorder.applyCompaction(FakeRemap{ .shift = 4 }, FakeRemap.map, 8);
    try recorder.check();

    const emission = recorder.emissionFor(0, 1).?;
    try testing.expectEqual(@as(u32, 0), emission.code_start);
    try testing.expectEqual(@as(u32, 8), emission.code_len);
    try testing.expectEqual(@as(u32, 2), recorder.scopes.items[0].jumps.items[0].instruction_offset);
    try testing.expectEqual(@as(u32, 6), recorder.scopes.items[0].jumps.items[0].target_offset);
    try testing.expectEqual(@as(u32, 8), recorder.scopes.items[0].final_len);
    try testing.expectEqual(@as(u32, 12), recorder.scopes.items[0].pre_optimization_len);
}

test "a node the proof IR does not carry balances without being recorded" {
    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();

    try recorder.beginNode(1, 0);
    try recorder.beginNode(2, 1);
    try recorder.endNode(3, false);
    try recorder.endNode(4, true);
    try recorder.check();

    try testing.expectEqual(@as(usize, 1), recorder.scopes.items[0].emissions.items.len);
    try testing.expectEqual(@as(?Emission, null), recorder.emissionFor(0, 2));
}

test "every rewrite kind names itself" {
    inline for (@typeInfo(RewriteKind).@"enum".fields) |field| {
        const kind: RewriteKind = @enumFromInt(field.value);
        try testing.expect(kind.name().len > 0);
    }
}
