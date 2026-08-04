//! Handler skeletons with typed holes, and the expression that fills each.
//!
//! The hole loop is the constructive half of convergence: with a whole file in
//! play the emittable set is every program the model might write and the fence
//! rejects, while a hole fixes the program apart from one expression in a known
//! context. The stand-in drives the same publisher, fill tool, apply boundary,
//! and next-turn re-analysis as the live agent, without asking a model to choose
//! the expression.

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
    /// One expression per hole, in source order. The arm applies one per turn,
    /// then re-reads and republishes the remaining frame on the next turn.
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
        // Two holes on separate lines so the gate proves that one-fill turns
        // compose after each accepted proposal is written.
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
        .ask = "Fill both remaining holes in handler.ts",
    },
};

/// The unique seed whose next expression accepts `source` as an exact reachable
/// state. A foreign, stale, or ambiguous source returns null.
pub fn findBySource(
    allocator: std.mem.Allocator,
    source: []const u8,
) !?*const HoleSeed {
    var selected: ?*const HoleSeed = null;
    for (&seeds) |*seed| {
        if (try nextExpressionForSource(allocator, seed, source)) |_| {
            if (selected != null) return null;
            selected = seed;
        }
    }
    return selected;
}

pub fn findById(id: []const u8) ?*const HoleSeed {
    for (&seeds) |*seed| {
        if (std.mem.eql(u8, seed.id, id)) return seed;
    }
    return null;
}

pub fn countHoles(source: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, hole_call)) |pos| : (i = pos + hole_call.len) {
        n += 1;
    }
    return n;
}

/// The next declared expression when `source` is an exact state reachable by
/// applying this seed's earlier expressions one at a time. A foreign or stale
/// source returns null instead of receiving a scripted edit.
pub fn nextExpressionForSource(
    allocator: std.mem.Allocator,
    seed: *const HoleSeed,
    source: []const u8,
) !?[]const u8 {
    const remaining = countHoles(source);
    if (remaining == 0 or remaining > seed.holes) return null;
    const filled = seed.holes - remaining;
    if (filled >= seed.expressions.len) return null;

    var expected = try allocator.dupe(u8, seed.source);
    defer allocator.free(expected);
    for (seed.expressions[0..filled]) |expression| {
        const next = try replaceFirstHole(allocator, expected, expression);
        allocator.free(expected);
        expected = next;
    }
    if (!std.mem.eql(u8, source, expected)) return null;
    return seed.expressions[filled];
}

fn replaceFirstHole(
    allocator: std.mem.Allocator,
    source: []const u8,
    expression: []const u8,
) ![]u8 {
    const at = std.mem.indexOf(u8, source, hole_call) orelse return error.NoHole;
    return std.mem.concat(allocator, u8, &.{
        source[0..at],
        expression,
        source[at + hole_call.len ..],
    });
}
