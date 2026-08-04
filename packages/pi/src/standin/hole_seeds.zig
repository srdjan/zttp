//! Handler skeletons with typed holes, and the expression that fills each.
//!
//! The hole loop is the constructive half of convergence: with a whole file in
//! play the emittable set is every program the model might write and the fence
//! rejects, while a hole fixes the program apart from one expression in a known
//! context. Exercising that loop has cost live model turns, because the tool
//! that enforces it is only reachable through an agent that chooses to call it.
//!
//! Note what the arm does NOT use. `zts_expert_holes` publishes the frame, and
//! it shells out to `zig build cli -- check`, which cannot run inside the
//! isolated tmp workspace these tests use. The arm therefore locates a hole by
//! the same exact six-byte match `zts_expert_fill_hole` enforces on the
//! coordinates it is handed, and calls only the fill tool, which is in-process.
//! That means the arm proves the fill mechanism and the apply path, and says
//! nothing about the frame publisher.

const std = @import("std");

/// The exact source text of a hole. Mirrors `zts_expert_fill_hole.hole_call`:
/// `hole()` is a builtin taking no arguments, so the call site is these six
/// bytes and a scan can be exact rather than a search for a name and a paren.
pub const hole_call = "hole()";

pub const HoleSeed = struct {
    id: []const u8,
    /// A handler whose response expression is a hole. Not veto-clean by
    /// construction and not required to be: a hole is a well-typed `never`, so
    /// the skeleton checks, but nothing here depends on that.
    source: []const u8,
    /// How many holes `source` carries. Declared so the gate can hold it against
    /// an actual scan; a seed edited from two holes to one would otherwise
    /// quietly stop testing what its name says.
    holes: usize,
    /// One expression per hole, in source order. The arm spends its turn on the
    /// first; the composition pin needs the second.
    expressions: []const []const u8,
    ask: []const u8,
};

pub const seeds = [_]HoleSeed{
    .{
        .id = "single-hole",
        .source =
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\  const total = 1;
        \\  return hole();
        \\}
        \\
        ,
        .holes = 1,
        .expressions = &.{"Response.json({ total })"},
        .ask = "Fill the remaining hole in handler.ts",
    },
    .{
        // Two holes on separate lines, for the composition pin. One fill per
        // turn is the documented shape of this loop, and this seed is what makes
        // the reason observable offline instead of only in a solution note.
        .id = "two-holes",
        .source =
        \\function handler(req: Request): Response & Spec<"deterministic"> {
        \\  const total = 1;
        \\  const label = hole();
        \\  return hole();
        \\}
        \\
        ,
        .holes = 2,
        .expressions = &.{ "\"count\"", "Response.json({ label, total })" },
        .ask = "Fill the remaining hole in handler.ts",
    },
};

/// The seed an ask selects.
///
/// Every seed shares the canonical ask today, so this returns the first. It
/// exists as a function rather than an index so the arm has one place to grow a
/// real selector when the seeds stop sharing a prompt.
pub fn findByAsk(ask: []const u8) ?*const HoleSeed {
    if (seeds.len == 0) return null;
    _ = ask;
    return &seeds[0];
}

pub fn findById(id: []const u8) ?*const HoleSeed {
    for (&seeds) |*seed| {
        if (std.mem.eql(u8, seed.id, id)) return seed;
    }
    return null;
}

/// 1-based line and column of the first hole in `source`, or null when there is
/// none.
///
/// The same coordinate convention `zts_expert_fill_hole` decodes, computed the
/// same way, because the tool refuses anything that does not land exactly on
/// the six bytes. A stale coordinate is the expected failure in this loop and
/// the useful answer to it is a refusal, so there is no nearest-match fallback
/// on either side.
pub fn firstHole(source: []const u8) ?struct { line: u32, column: u32 } {
    const at = std.mem.indexOf(u8, source, hole_call) orelse return null;
    var line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < at) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .column = @intCast(at - line_start + 1) };
}

pub fn countHoles(source: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, hole_call)) |pos| : (i = pos + hole_call.len) {
        n += 1;
    }
    return n;
}
