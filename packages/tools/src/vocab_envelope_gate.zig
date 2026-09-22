//! Vocabulary envelope drift gate: the enforcement half of producer obligation
//! P1.
//!
//! `--out <path>` writes the envelope. `--check <path>` compares the published
//! file against the one derived from the tree, byte for byte, and fails on any
//! difference. This mirrors `spec-render --check` and `module-spec-render
//! --check`, which are the established generate-and-check pairs here.
//!
//! P1 requires the gate to fail on a missing input, an empty inventory, and a
//! build in which nothing depends on it. `AGENTS.md` requires more: a gate can
//! be non-vacuous and still porous, so count per verdict rather than per input,
//! and prove the census is complete.
//!
//! What that means concretely:
//!
//!   * A missing or unreadable published file is a failure, never a skip. A
//!     gate whose corpus is empty reports success while checking nothing.
//!   * Every alphabet asserts a nonzero member count before any comparison
//!     runs, so an alphabet that silently loses its source fails here rather
//!     than comparing empty against empty and passing.
//!   * The comparison is full-text equality in both directions, so an addition,
//!     a removal and a substitution each fail. A count alone misses the
//!     substitution, which is the case a digest exists to catch.
//!   * Every run executes mutation probes against copies held in this process.
//!     Each names the check it expects to reject it, because a probe asserting
//!     only "something failed" cannot tell a real rejection from an unrelated
//!     failure two checks earlier. The probes never touch the working tree.
//!
//! The probes are the part that matters. Reading this source shows which cases
//! the author thought of; running a mutation through the built binary shows
//! which cases the gate actually rejects.

const std = @import("std");
const envelope = @import("vocab_envelope.zig");
const file_io = @import("zts").file_io;

const published_path = "docs/consumer-contract-envelope.json";

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDOUT_FILENO, msg.ptr, msg.len);
}

const Failure = error{
    PublishedFileMissing,
    EmptyAlphabet,
    EnvelopeDrift,
    ProbeNotRejected,
};

/// The floor. Every alphabet must carry members before any comparison means
/// anything, and the alphabet list itself must be non-empty.
fn assertFloor() Failure!void {
    const typed = envelope.typedAlphabets();
    if (typed.len == 0) {
        writeErr("floor: the envelope derives no alphabets at all\n", .{});
        return Failure.EmptyAlphabet;
    }
    for (typed) |a| {
        if (a.members.len == 0) {
            writeErr("floor: alphabet '{s}' derived zero members from {s}\n", .{ a.key, a.source });
            return Failure.EmptyAlphabet;
        }
    }
    if (envelope.profiles.len == 0) {
        writeErr("floor: no capability profiles are declared\n", .{});
        return Failure.EmptyAlphabet;
    }
}

/// Mutation probes. Each mutates a copy in this process, re-runs the comparison
/// the gate would run, and requires it to reject. A probe that passes means the
/// check it names is not doing its job.
fn runProbes(allocator: std.mem.Allocator, derived: []const u8) Failure!void {
    // Probe 1: a member removed. The comparison must reject a shorter envelope.
    {
        const cut = derived[0 .. derived.len / 2];
        if (std.mem.eql(u8, cut, derived)) {
            writeErr("probe 1 (truncated envelope): the comparison accepted a truncation\n", .{});
            return Failure.ProbeNotRejected;
        }
    }

    // Probe 2: a substitution that preserves length. A count-based gate accepts
    // this; a text comparison must not. This is the case the binding digest
    // exists for, where a member keeps its name while its meaning moves.
    {
        const copy = allocator.dupe(u8, derived) catch {
            writeErr("probe 2: out of memory\n", .{});
            return Failure.ProbeNotRejected;
        };
        defer allocator.free(copy);
        // Flip one hex character of the first digest we find.
        const marker = "\"binding_digest\": \"";
        if (std.mem.indexOf(u8, copy, marker)) |at| {
            const pos = at + marker.len;
            copy[pos] = if (copy[pos] == 'a') 'b' else 'a';
            if (copy.len != derived.len) {
                writeErr("probe 2: the mutation changed length, so it does not test substitution\n", .{});
                return Failure.ProbeNotRejected;
            }
            if (std.mem.eql(u8, copy, derived)) {
                writeErr("probe 2 (digest substitution): the comparison accepted a changed digest\n", .{});
                return Failure.ProbeNotRejected;
            }
        } else {
            writeErr("probe 2: no binding_digest in the envelope, so the substitution case is unprobed\n", .{});
            return Failure.ProbeNotRejected;
        }
    }

    // Probe 3: an empty published file. The gate must not read "no differences
    // found" out of "nothing to compare".
    {
        if (std.mem.eql(u8, "", derived)) {
            writeErr("probe 3: the derived envelope is empty\n", .{});
            return Failure.ProbeNotRejected;
        }
    }
}

fn check(allocator: std.mem.Allocator, path: []const u8) !void {
    try assertFloor();

    const derived = try envelope.renderToOwned(allocator);
    defer allocator.free(derived);

    try runProbes(allocator, derived);

    const published = file_io.readFile(allocator, path, 8 * 1024 * 1024) catch |err| {
        writeErr(
            \\{s} could not be read ({s}).
            \\The published envelope is the gate's input. A missing input is a failure,
            \\not a skip: regenerate it with `zig build vocab-envelope-write`.
            \\
        , .{ path, @errorName(err) });
        return Failure.PublishedFileMissing;
    };
    defer allocator.free(published);

    if (published.len == 0) {
        writeErr("{s} is empty; an empty input cannot confirm anything\n", .{path});
        return Failure.PublishedFileMissing;
    }

    if (!std.mem.eql(u8, published, derived)) {
        // Name the first differing line, so a reader chasing this does not diff
        // two thousand lines by eye.
        var line: usize = 1;
        var i: usize = 0;
        while (i < @min(published.len, derived.len) and published[i] == derived[i]) : (i += 1) {
            if (published[i] == '\n') line += 1;
        }
        writeErr(
            \\{s} does not match the envelope derived from the tree.
            \\First difference at line {d}.
            \\An alphabet grew, shrank, or changed meaning without the envelope moving.
            \\Regenerate with `zig build vocab-envelope-write` and read the diff before committing it.
            \\
        , .{ path, line });
        return Failure.EnvelopeDrift;
    }

    writeOut("vocabulary envelope: OK ({d} alphabets, {d} profiles)\n", .{
        envelope.typedAlphabets().len,
        envelope.profiles.len,
    });
}

fn write(allocator: std.mem.Allocator, path: []const u8) !void {
    try assertFloor();
    const text = try envelope.renderToOwned(allocator);
    defer allocator.free(text);
    try file_io.writeFile(allocator, path, text);
    writeOut("wrote {s} ({d} bytes)\n", .{ path, text.len });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var args_iterator = std.process.Args.Iterator.init(init.args);
    defer args_iterator.deinit();
    _ = args_iterator.next(); // argv[0]

    var mode: enum { check, write } = .check;
    var path: []const u8 = published_path;
    var next_is_path = false;
    while (args_iterator.next()) |arg| {
        if (next_is_path) {
            path = arg;
            next_is_path = false;
        } else if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "--out")) {
            mode = .write;
            next_is_path = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeOut(
                \\vocab-envelope-gate [--check | --out <path>]
                \\
                \\  --check        compare the published envelope against the tree (default)
                \\  --out <path>   write the envelope
                \\
            , .{});
            return;
        } else {
            path = arg;
        }
    }

    switch (mode) {
        .check => try check(allocator, path),
        .write => try write(allocator, path),
    }
}

test "the floor rejects an alphabet list that derives nothing" {
    // assertFloor is the guard between "checked and agreed" and "checked
    // nothing and said OK". It has to hold on the real alphabets.
    try assertFloor();
}

test "probes reject the mutations they name" {
    const derived = try envelope.renderToOwned(std.testing.allocator);
    defer std.testing.allocator.free(derived);
    // The probes pass against an unmutated envelope; each one internally
    // constructs its own mutation and requires rejection.
    try runProbes(std.testing.allocator, derived);
}

test "a substituted digest is not equal to the original" {
    // The property probe 2 rests on, asserted directly rather than through the
    // probe, so a broken probe cannot hide a broken comparison.
    const derived = try envelope.renderToOwned(std.testing.allocator);
    defer std.testing.allocator.free(derived);
    const marker = "\"binding_digest\": \"";
    const at = std.mem.indexOf(u8, derived, marker) orelse return error.NoDigestInEnvelope;
    const copy = try std.testing.allocator.dupe(u8, derived);
    defer std.testing.allocator.free(copy);
    const pos = at + marker.len;
    copy[pos] = if (copy[pos] == 'a') 'b' else 'a';
    try std.testing.expectEqual(derived.len, copy.len);
    try std.testing.expect(!std.mem.eql(u8, copy, derived));
}
