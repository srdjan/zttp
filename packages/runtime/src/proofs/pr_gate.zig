//! `zttp proofs gate` — the pull-request proof gate.
//!
//! A proof's value is realized at a trust boundary: a reviewer who did not
//! write the code. Every other proof surface (terminal HUD, badge)
//! is author-facing on the author's own machine. This command carries the
//! verdict to where review happens. Given a git range, for every changed
//! handler it compiles the before and after versions, runs the same
//! `contract_diff` the expert loop and `prove-behavior` compute, aggregates a
//! repo-level behavioral verdict, and emits a PR-ready Markdown report (or a
//! machine JSON object) plus a process exit code.
//!
//!   exit 0 = safe (equivalent / equivalent_modulo_laws / additive)
//!   exit 1 = breaking (a response on an existing path changed or was removed,
//!            a route/capability was removed, or a critical proven property
//!            was lost: see `contract_diff.propertyLossSeverity`)
//!   exit 2 = usage or git error
//!
//! The analysis is entirely reused: `diffContracts` + `behavioralVerdict` for
//! the per-handler verdict, the lost-property table of `contract_diff` for the
//! critical-loss rule (every lost monotonic proven boolean is listed; only a
//! critical one makes the handler breaking). The gate writes no ledger row;
//! `--no-sign` is still accepted so CI scripts that pass it keep working.
//! Only the git-range discovery, multi-handler aggregation, and the
//! PR-oriented rendering are new here.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const shared = @import("../cli_shared.zig");

const contract_diff = zts.contract_diff;
const file_io = zts.file_io;
const Classification = contract_diff.Classification;

const max_source_bytes = 4 * 1024 * 1024;
/// The largest `git archive` of one side's `.ts` files that the gate reads.
const max_archive_bytes = 256 * 1024 * 1024;

pub const json_schema = "zttp.proof-gate.v1";

pub const Format = enum { md, json };

pub const Options = struct {
    /// Explicit base ref, or null to resolve the default (origin/main → main).
    base: ?[]const u8 = null,
    /// Explicit head ref, or null to diff the base against the working tree.
    head: ?[]const u8 = null,
    format: Format = .md,
    /// Write the report to this file instead of stdout.
    out: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Pure data model (no git, no compile) — the unit-tested core.
// ---------------------------------------------------------------------------

pub const BehaviorCounts = struct {
    preserved: u32 = 0,
    response_changed: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
};

pub const Counterexample = struct {
    method: []const u8,
    pattern: []const u8,
    /// The status of the path as the contract holds it. `unknown` when the
    /// analysis could not read it, and for a route change that carries none.
    /// The JSON writes `null` for `unknown`.
    status: zts.handler_contract.ResponseStatus,
    /// `.removed` or `.response_changed`.
    change: contract_diff.BehaviorChangeKind,
};

pub const SurfaceDelta = struct {
    added_routes: []const []const u8 = &.{},
    removed_routes: []const []const u8 = &.{},
    added_env: []const []const u8 = &.{},
    removed_env: []const []const u8 = &.{},
    added_egress: []const []const u8 = &.{},
    removed_egress: []const []const u8 = &.{},
    added_cache: []const []const u8 = &.{},
    removed_cache: []const []const u8 = &.{},
    capabilities_widened: bool = false,
    capabilities_narrowed: bool = false,

    /// One category of surface change. `noun` is the singular prose form
    /// ("route") and `json` is the JSON field name ("routes"); the renderers
    /// and the serializer all iterate this list so a new category is added in
    /// one place.
    const Category = struct {
        noun: []const u8,
        json: []const u8,
        added: []const []const u8,
        removed: []const []const u8,
    };

    fn categories(self: *const SurfaceDelta) [4]Category {
        return .{
            .{ .noun = "route", .json = "routes", .added = self.added_routes, .removed = self.removed_routes },
            .{ .noun = "env", .json = "env", .added = self.added_env, .removed = self.removed_env },
            .{ .noun = "egress", .json = "egress", .added = self.added_egress, .removed = self.removed_egress },
            .{ .noun = "cache", .json = "cache", .added = self.added_cache, .removed = self.removed_cache },
        };
    }

    fn isEmpty(self: *const SurfaceDelta) bool {
        for (self.categories()) |c| {
            if (c.added.len > 0 or c.removed.len > 0) return false;
        }
        return !self.capabilities_widened and !self.capabilities_narrowed;
    }
};

/// A proven property the edit turned from true to false. `severity` comes
/// from `contract_diff.propertyLossSeverity`, the table the upgrade verifier
/// also uses. Only a `.critical` loss changes the handler's verdict.
pub const LostProperty = struct {
    field: []const u8,
    severity: contract_diff.Severity,
};

/// True when any lost property is critical, i.e. the loss fails the gate.
pub fn hasCriticalLoss(lost: []const LostProperty) bool {
    for (lost) |l| {
        if (l.severity == .critical) return true;
    }
    return false;
}

pub const HandlerResult = struct {
    path: []const u8,
    verdict: Classification,
    behavior: BehaviorCounts = .{},
    surface: SurfaceDelta = .{},
    counterexamples: []const Counterexample = &.{},
    /// Every monotonic proven boolean the edit lost, in `effect_changes` order.
    lost_properties: []const LostProperty = &.{},
    /// The handler declares no `Proof<...>` capsule, so the default profile
    /// applies and its undischarged properties did not stop the comparison.
    implicit_capsule: bool = false,
};

pub const Skipped = struct {
    path: []const u8,
    /// "unreferenced_helper": a changed file with no handler, and no handler
    /// imports it. "no_contract": a handler function that exposes no route.
    reason: []const u8,
};

/// Repo verdict = worst per-handler verdict. One breaking handler makes the
/// whole pull request breaking. Empty (no handler changes) reads as
/// `.equivalent`, i.e. safe.
pub fn worstVerdict(results: []const HandlerResult) Classification {
    var worst: Classification = .equivalent;
    for (results) |r| {
        if (rank(r.verdict) > rank(worst)) worst = r.verdict;
    }
    return worst;
}

fn rank(c: Classification) u8 {
    return switch (c) {
        .equivalent => 0,
        .equivalent_modulo_laws => 1,
        .additive => 2,
        .breaking => 3,
    };
}

fn isSafe(c: Classification) bool {
    return c != .breaking;
}

// ---------------------------------------------------------------------------
// Rendering (pure: operates on the data model only)
// ---------------------------------------------------------------------------

/// Marker the GitHub Action's sticky-comment step keys on to update in place.
pub const sticky_marker = "<!-- zttp-proof -->";

pub fn renderMarkdown(
    w: *std.Io.Writer,
    base_label: []const u8,
    head_label: []const u8,
    results: []const HandlerResult,
    skipped: []const Skipped,
    verdict: Classification,
) !void {
    try w.writeAll(sticky_marker);
    try w.writeAll("\n## zttp proof gate\n\n");
    try w.print("**Verdict: `{s}`**", .{verdict.toString()});
    try w.print("  ·  base `{s}` → head `{s}`", .{ base_label, head_label });
    try w.print("  ·  {d} handler{s} checked\n\n", .{ results.len, plural(results.len) });

    if (results.len == 0) {
        try w.writeAll("_No changed handlers in this range._\n");
    } else {
        try w.writeAll("| Handler | Verdict | Δ behavior | Δ surface |\n");
        try w.writeAll("|---|---|---|---|\n");
        for (results) |r| {
            try w.print("| `{s}` | `{s}` | ", .{ r.path, r.verdict.toString() });
            try writeBehaviorCell(w, r.behavior, r.lost_properties.len);
            try w.writeAll(" | ");
            try writeSurfaceCell(w, r.surface);
            try w.writeAll(" |\n");
        }

        for (results) |r| {
            if (!r.implicit_capsule) continue;
            try w.print("\n`{s}`: no declared capsule. The gate compared its behavior; the default proof profile is not fully held.\n", .{r.path});
        }

        for (results) |r| {
            if (r.verdict.isSafeNoOp() and r.lost_properties.len == 0) continue;
            try w.print("\n### `{s}` — {s}\n", .{ r.path, r.verdict.toString() });
            if (!r.surface.isEmpty()) {
                try w.writeAll("\n**Surface changes**\n\n");
                try writeSurfaceLines(w, r.surface);
            }
            if (r.lost_properties.len > 0) {
                try w.writeAll("\n**Lost proofs**\n\n");
                for (r.lost_properties) |l| {
                    try w.print("- `{s}`: proven → not proven ({s})\n", .{ l.field, l.severity.toString() });
                }
                if (hasCriticalLoss(r.lost_properties)) {
                    try w.writeAll("\nA critical proof was lost, so the gate fails this handler.\n");
                } else {
                    try w.writeAll("\nNo lost proof is critical, so the verdict is unchanged.\n");
                }
            }
            if (r.verdict == .breaking and r.counterexamples.len > 0) {
                try w.writeAll("\n**Counterexample** — behavior changed on an existing path:\n\n");
                for (r.counterexamples) |c| {
                    switch (c.change) {
                        .removed => try w.print("- `{s} {s}` removed\n", .{ c.method, c.pattern }),
                        else => switch (c.status) {
                            .known => |code| try w.print("- `{s} {s}` status {d} → response changed\n", .{ c.method, c.pattern, code }),
                            .unknown => try w.print("- `{s} {s}` status unknown → response changed\n", .{ c.method, c.pattern }),
                        },
                    }
                }
            }
        }
    }

    if (skipped.len > 0) {
        try w.print("\n<details><summary>{d} file{s} skipped (not a handler)</summary>\n\n", .{ skipped.len, plural(skipped.len) });
        for (skipped) |s| try w.print("- `{s}`\n", .{s.path});
        try w.writeAll("\n</details>\n");
    }
}

fn writeBehaviorCell(w: *std.Io.Writer, b: BehaviorCounts, lost: usize) !void {
    var first = true;
    if (b.response_changed > 0) {
        try w.print("{d} response changed", .{b.response_changed});
        first = false;
    }
    if (b.added > 0) {
        if (!first) try w.writeAll(", ");
        try w.print("{d} added", .{b.added});
        first = false;
    }
    if (b.removed > 0) {
        if (!first) try w.writeAll(", ");
        try w.print("{d} removed", .{b.removed});
        first = false;
    }
    if (lost > 0) {
        if (!first) try w.writeAll(", ");
        try w.print("{d} proof{s} lost", .{ lost, plural(lost) });
        first = false;
    }
    if (first) try w.writeAll("—");
}

fn writeSurfaceCell(w: *std.Io.Writer, s: SurfaceDelta) !void {
    var first = true;
    for (s.categories()) |c| {
        first = try writeCount(w, first, c.added.len, "+", c.noun);
        first = try writeCount(w, first, c.removed.len, "-", c.noun);
    }
    if (s.capabilities_widened) {
        if (!first) try w.writeAll(", ");
        try w.writeAll("caps widened");
        first = false;
    }
    if (s.capabilities_narrowed) {
        if (!first) try w.writeAll(", ");
        try w.writeAll("caps narrowed");
        first = false;
    }
    if (first) try w.writeAll("—");
}

fn writeCount(w: *std.Io.Writer, first: bool, n: usize, sign: []const u8, label: []const u8) !bool {
    if (n == 0) return first;
    if (!first) try w.writeAll(", ");
    try w.print("{s}{d} {s}", .{ sign, n, label });
    return false;
}

fn writeSurfaceLines(w: *std.Io.Writer, s: SurfaceDelta) !void {
    for (s.categories()) |c| {
        for (c.added) |v| try w.print("- `+ {s} {s}`\n", .{ c.noun, v });
        for (c.removed) |v| try w.print("- `- {s} {s}`\n", .{ c.noun, v });
    }
    if (s.capabilities_widened) try w.writeAll("- `capabilities widened`\n");
    if (s.capabilities_narrowed) try w.writeAll("- `capabilities narrowed`\n");
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

pub fn renderJson(
    w: *std.Io.Writer,
    base_label: []const u8,
    head_label: []const u8,
    results: []const HandlerResult,
    skipped: []const Skipped,
    verdict: Classification,
) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    try json.objectField("schema");
    try json.write(json_schema);
    try json.objectField("base");
    try json.write(base_label);
    try json.objectField("head");
    try json.write(head_label);
    try json.objectField("verdict");
    try json.write(verdict.toString());
    try json.objectField("safe");
    try json.write(isSafe(verdict));
    try json.objectField("handlersChecked");
    try json.write(results.len);

    try json.objectField("handlers");
    try json.beginArray();
    for (results) |r| {
        try json.beginObject();
        try json.objectField("path");
        try json.write(r.path);
        try json.objectField("verdict");
        try json.write(r.verdict.toString());
        try json.objectField("capsule");
        try json.write(if (r.implicit_capsule) "implicit" else "declared");
        try json.objectField("behaviorDiff");
        try json.beginObject();
        try json.objectField("preserved");
        try json.write(r.behavior.preserved);
        try json.objectField("responseChanged");
        try json.write(r.behavior.response_changed);
        try json.objectField("added");
        try json.write(r.behavior.added);
        try json.objectField("removed");
        try json.write(r.behavior.removed);
        try json.endObject();
        try json.objectField("surface");
        try json.beginObject();
        for (r.surface.categories()) |c| {
            try writeJsonStringPair(&json, c.json, c.added, c.removed);
        }
        try json.objectField("capabilitiesWidened");
        try json.write(r.surface.capabilities_widened);
        try json.objectField("capabilitiesNarrowed");
        try json.write(r.surface.capabilities_narrowed);
        try json.endObject();
        try json.objectField("counterexamples");
        try json.beginArray();
        for (r.counterexamples) |c| {
            try json.beginObject();
            try json.objectField("method");
            try json.write(c.method);
            try json.objectField("pattern");
            try json.write(c.pattern);
            try json.objectField("status");
            switch (c.status) {
                .known => |code| try json.write(code),
                .unknown => try json.write(null),
            }
            try json.objectField("change");
            try json.write(@tagName(c.change));
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("lostProperties");
        try json.beginArray();
        for (r.lost_properties) |l| {
            try json.beginObject();
            try json.objectField("property");
            try json.write(l.field);
            try json.objectField("severity");
            try json.write(l.severity.toString());
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("skipped");
    try json.beginArray();
    for (skipped) |s| {
        try json.beginObject();
        try json.objectField("path");
        try json.write(s.path);
        try json.objectField("reason");
        try json.write(s.reason);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try w.writeByte('\n');
}

fn writeJsonStringPair(
    json: *std.json.Stringify,
    field: []const u8,
    added: []const []const u8,
    removed: []const []const u8,
) !void {
    try json.objectField(field);
    try json.beginObject();
    try json.objectField("added");
    try json.beginArray();
    for (added) |v| try json.write(v);
    try json.endArray();
    try json.objectField("removed");
    try json.beginArray();
    for (removed) |v| try json.write(v);
    try json.endArray();
    try json.endObject();
}

// ---------------------------------------------------------------------------
// Extraction from a ContractDiff into the arena-owned data model
// ---------------------------------------------------------------------------

fn collectItems(
    arena: std.mem.Allocator,
    changes: []const contract_diff.ItemChange,
    want: contract_diff.ChangeStatus,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (changes) |c| {
        if (c.status == want) try list.append(arena, try arena.dupe(u8, c.value));
    }
    return try list.toOwnedSlice(arena);
}

/// Route changes arrive in two shapes: bare `routes` (static route table) and
/// `api_route_changes` (method+path, the form `routerMatch` handlers produce).
/// Both are surfaced under one list so the report does not silently drop a
/// route added or removed through `routerMatch`.
fn collectRoutes(
    arena: std.mem.Allocator,
    diff: *const contract_diff.ContractDiff,
    want: contract_diff.ChangeStatus,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (diff.routes.items) |c| {
        if (c.status == want) try list.append(arena, try arena.dupe(u8, c.pattern));
    }
    for (diff.api_route_changes.items) |c| {
        if (c.status == want) try list.append(arena, try arena.print("{s} {s}", .{ c.method, c.path }));
    }
    return try list.toOwnedSlice(arena);
}

fn extractSurface(arena: std.mem.Allocator, diff: *const contract_diff.ContractDiff) !SurfaceDelta {
    return .{
        .added_routes = try collectRoutes(arena, diff, .added),
        .removed_routes = try collectRoutes(arena, diff, .removed),
        .added_env = try collectItems(arena, diff.env_changes.items, .added),
        .removed_env = try collectItems(arena, diff.env_changes.items, .removed),
        .added_egress = try collectItems(arena, diff.egress_changes.items, .added),
        .removed_egress = try collectItems(arena, diff.egress_changes.items, .removed),
        .added_cache = try collectItems(arena, diff.cache_changes.items, .added),
        .removed_cache = try collectItems(arena, diff.cache_changes.items, .removed),
        .capabilities_widened = diff.capabilitiesWidened(),
        .capabilities_narrowed = diff.capabilitiesNarrowed(),
    };
}

/// The breaking paths, deduped by (method, pattern). Sourced from the
/// per-path behavior diff when present, and from `api_route_changes` for
/// route removals/response breaks that the behavior diff does not carry
/// (a removed `routerMatch` route shows up only here).
fn extractCounterexamples(arena: std.mem.Allocator, diff: *const contract_diff.ContractDiff) ![]const Counterexample {
    var list: std.ArrayList(Counterexample) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;

    if (diff.behavior_diff) |bd| {
        for (bd.changes.items) |c| {
            switch (c.change) {
                .removed, .response_changed => {},
                else => continue,
            }
            try appendCounterexample(arena, &list, &seen, c.method, c.pattern, c.status, c.change);
        }
    }
    for (diff.api_route_changes.items) |c| {
        const change: contract_diff.BehaviorChangeKind = if (c.status == .removed)
            .removed
        else if (c.response == .breaking)
            .response_changed
        else
            continue;
        try appendCounterexample(arena, &list, &seen, c.method, c.path, .unknown, change);
    }
    return try list.toOwnedSlice(arena);
}

fn appendCounterexample(
    arena: std.mem.Allocator,
    list: *std.ArrayList(Counterexample),
    seen: *std.ArrayList([]const u8),
    method: []const u8,
    pattern: []const u8,
    status: zts.handler_contract.ResponseStatus,
    change: contract_diff.BehaviorChangeKind,
) !void {
    const key = try arena.print("{s} {s}", .{ method, pattern });
    for (seen.items) |s| {
        if (std.mem.eql(u8, s, key)) return;
    }
    try seen.append(arena, key);
    try list.append(arena, .{
        .method = try arena.dupe(u8, method),
        .pattern = try arena.dupe(u8, pattern),
        .status = status,
        .change = change,
    });
}

fn isHandlerContract(contract: *const zts.HandlerContract) bool {
    return contract.routes.items.len > 0 or
        contract.api.routes.items.len > 0 or
        contract.behaviors.items.len > 0;
}

/// The monotonic proven booleans the edit lost (true to false). The
/// `max_io_depth` and `cost_class` rows that `diffContracts` also records
/// carry presence bits, not proofs, so they are not lost properties here.
fn lostProperties(arena: std.mem.Allocator, diff: *const contract_diff.ContractDiff) ![]const LostProperty {
    var list: std.ArrayList(LostProperty) = .empty;
    for (diff.effect_changes.items) |change| {
        if (!(change.old_value and !change.new_value)) continue;
        if (!zts.handler_contract.HandlerProperties.isMonotonicProvenSpecName(change.field)) continue;
        try list.append(arena, .{
            .field = try arena.dupe(u8, change.field),
            .severity = contract_diff.propertyLossSeverity(change.field) orelse .critical,
        });
    }
    return try list.toOwnedSlice(arena);
}

fn behaviorCounts(diff: *const contract_diff.ContractDiff) BehaviorCounts {
    const bd = diff.behavior_diff orelse return .{};
    return .{
        .preserved = bd.preserved,
        .response_changed = bd.response_changed,
        .added = bd.added,
        .removed = bd.removed,
    };
}

// ---------------------------------------------------------------------------
// Git helpers (local std.process.run wrapper — the only new I/O here)
// ---------------------------------------------------------------------------

const GitResult = struct {
    ok: bool,
    /// Owned by the caller's allocator.
    stdout: []u8,
};

fn runGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !GitResult {
    return runGitLimit(allocator, cwd, args, 8 * 1024 * 1024);
}

fn runGitLimit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8, stdout_limit: usize) !GitResult {
    var io_backend = shared.threadedIo(allocator);
    defer io_backend.deinit();
    const r = std.process.run(allocator, io_backend.io(), .{
        .argv = args,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(256 * 1024),
    }) catch return error.GitSpawnFailed;
    allocator.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout };
}

fn refExists(allocator: std.mem.Allocator, cwd: []const u8, ref: []const u8) bool {
    const res = runGit(allocator, cwd, &.{ "git", "rev-parse", "--verify", "--quiet", ref }) catch return false;
    defer allocator.free(res.stdout);
    return res.ok;
}

fn isHandlerCandidate(path: []const u8) bool {
    if (!zts.classifySourcePath(path).isSupportedFile()) return false;
    if (std.mem.indexOf(u8, path, ".test.") != null) return false;
    if (std.mem.indexOf(u8, path, ".spec.") != null) return false;
    if (std.mem.startsWith(u8, path, "tests/") or std.mem.indexOf(u8, path, "/tests/") != null) return false;
    if (std.mem.startsWith(u8, path, "test/") or std.mem.indexOf(u8, path, "/test/") != null) return false;
    if (std.mem.indexOf(u8, path, "fixtures/") != null) return false;
    return true;
}

fn changedSources(
    arena: std.mem.Allocator,
    cwd: []const u8,
    base: []const u8,
    head: ?[]const u8,
) ![]const []const u8 {
    // Include D (deleted): removing a handler file removes all of its routes
    // and is a breaking change the gate must catch, not silently drop.
    // `--no-renames` lists a renamed file under both paths: the old path is a
    // deletion and the new path an addition, so a handler that still imports
    // the old path reaches a changed file.
    const res = if (head) |h| blk: {
        const range = try arena.print("{s}...{s}", .{ base, h });
        break :blk try runGit(arena, cwd, &.{ "git", "diff", "--name-only", "--no-renames", "--diff-filter=ACMRD", range });
    } else try runGit(arena, cwd, &.{ "git", "diff", "--name-only", "--no-renames", "--diff-filter=ACMRD", base });
    defer arena.free(res.stdout);
    if (!res.ok) return error.BadGitRef;

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        if (!zts.classifySourcePath(path).isSupportedFile()) continue;
        try list.append(arena, try arena.dupe(u8, path));
    }
    return try list.toOwnedSlice(arena);
}

/// Read a path at a git ref. Returns null when the path did not exist there
/// (a newly added handler), which `git show` reports as a non-zero exit.
fn readAtRef(arena: std.mem.Allocator, cwd: []const u8, ref: []const u8, path: []const u8) !?[]u8 {
    const spec = try arena.print("{s}:{s}", .{ ref, path });
    const res = try runGit(arena, cwd, &.{ "git", "show", spec });
    if (!res.ok) {
        arena.free(res.stdout);
        return null;
    }
    return res.stdout;
}

/// The path of an imported file relative to `cwd`, for `git show <ref>:./<rel>`.
/// A relative path is already relative to `cwd` (the analyzer resolves it
/// without the filesystem, so it stays relative); an absolute path is made
/// relative to `cwd`. A path that leaves `cwd`, or names `cwd` itself, is
/// `OutsideRepo`: the gate runs from the repository root, and `git show` has
/// no revision of a file above it.
fn repoRelativePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) error{ OutOfMemory, OutsideRepo }![]u8 {
    const rel = if (std.fs.path.isAbsolute(path))
        try std.fs.path.relative(allocator, cwd, null, cwd, path)
    else
        try std.fs.path.resolve(allocator, &.{path});
    errdefer allocator.free(rel);
    if (rel.len == 0 or std.fs.path.isAbsolute(rel) or
        std.mem.eql(u8, rel, "..") or std.mem.startsWith(u8, rel, "../"))
    {
        return error.OutsideRepo;
    }
    return rel;
}

/// Serves the files a handler imports from one git revision, so the analyzer
/// reads a helper at the same revision as the handler that imports it. Without
/// it the analyzer reads every helper from the working tree and a pull request
/// that changes only a helper changes neither side's contract.
const RevisionReader = struct {
    cwd: []const u8,
    ref: []const u8,

    fn importReader(self: *RevisionReader) zts_cli.precompile.ImportReader {
        return .{ .context = self, .read = read };
    }

    /// Any failure (a path outside the repository, a file that does not exist
    /// at the revision, git failing) reads as an unreadable file, which the
    /// analyzer already answers with its blocked or unresolved verdict.
    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *RevisionReader = @ptrCast(@alignCast(context));
        const rel = try repoRelativePath(allocator, self.cwd, path);
        defer allocator.free(rel);
        const spec = try allocator.print("{s}:./{s}", .{ self.ref, rel });
        defer allocator.free(spec);
        const res = try runGit(allocator, self.cwd, &.{ "git", "show", spec });
        if (!res.ok) {
            allocator.free(res.stdout);
            return error.FileNotFound;
        }
        return res.stdout;
    }
};

// ---------------------------------------------------------------------------
// Reverse import graph: which files reach a changed file
// ---------------------------------------------------------------------------

/// One tracked `.ts` file as one side (the base or the head) sees it.
const SideFile = struct {
    /// False when the file did not parse: its imports are unknown.
    parsed: bool,
    /// The file defines a top-level `handler` function. Meaningful when `parsed`.
    has_handler: bool,
    /// Repo-relative paths of the files it imports, resolved the way CHECK
    /// resolves them. Empty when the file did not parse.
    imports: []const []const u8,
    /// An unparsed handler candidate whose text names a changed file.
    may_import_changed: bool,
    /// The bytes that were parsed, so the other side can reuse the scan of an
    /// identical file.
    source: []const u8,
};

const SideGraph = std.StringHashMapUnmanaged(SideFile);

const SourceEntry = struct { path: []const u8, source: []const u8 };

/// Every tracked `.ts` source of one side. `ref` null is the working tree: the
/// tracked paths come from the index and the bytes from disk, so a file that is
/// tracked and deleted in the working tree is absent. A ref is read with one
/// `git archive`, so the cost does not grow with a process per file.
fn listSideSources(arena: std.mem.Allocator, cwd: []const u8, ref: ?[]const u8) ![]const SourceEntry {
    var list: std.ArrayList(SourceEntry) = .empty;
    if (ref) |r| {
        const tree = try runGit(arena, cwd, &.{ "git", "ls-tree", "-r", "--name-only", r });
        if (!tree.ok) return error.GitReadFailed;
        var any = false;
        var lines = std.mem.tokenizeScalar(u8, tree.stdout, '\n');
        while (lines.next()) |line| {
            if (zts.classifySourcePath(line).isSupportedFile()) any = true;
        }
        if (!any) return &.{};
        const archive = try runGitLimit(arena, cwd, &.{ "git", "archive", "--format=tar", r, "--", "*.ts" }, max_archive_bytes);
        if (!archive.ok) return error.GitReadFailed;
        var reader: std.Io.Reader = .fixed(archive.stdout);
        var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
        while (try it.next()) |file| {
            if (file.kind != .file) continue;
            if (!zts.classifySourcePath(file.name).isSupportedFile()) continue;
            var body: std.Io.Writer.Allocating = .init(arena);
            try it.streamRemaining(file, &body.writer);
            try list.append(arena, .{ .path = try arena.dupe(u8, file.name), .source = body.writer.buffered() });
        }
    } else {
        const files = try runGit(arena, cwd, &.{ "git", "ls-files", "-z", "--", "*.ts" });
        if (!files.ok) return error.GitReadFailed;
        var names = std.mem.tokenizeScalar(u8, files.stdout, 0);
        while (names.next()) |name| {
            if (!zts.classifySourcePath(name).isSupportedFile()) continue;
            const source = file_io.readFile(arena, name, max_source_bytes) catch continue;
            try list.append(arena, .{ .path = name, .source = source });
        }
    }
    return list.toOwnedSlice(arena);
}

fn mentionsAny(source: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (needle.len > 0 and std.mem.indexOf(u8, source, needle) != null) return true;
    }
    return false;
}

/// The imports of every file that can matter on one side. A relative import
/// specifier always contains `./`, so a file without that text has no edge. It
/// is parsed only when it is itself changed, for `has_handler`. The parse is
/// `scanSource`: no type check and no CHECK.
fn scanSide(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cwd: []const u8,
    ref: ?[]const u8,
    changed: []const []const u8,
    stems: []const []const u8,
    /// The other side, already scanned. A file with the same path and bytes has
    /// the same scan, and most files are unchanged, so it is not parsed twice.
    other: ?*const SideGraph,
) !SideGraph {
    var graph: SideGraph = .empty;
    for (try listSideSources(arena, cwd, ref)) |entry| {
        const is_changed = containsPath(changed, entry.path);
        if (!is_changed and std.mem.indexOf(u8, entry.source, "./") == null) continue;
        if (other) |o| {
            if (o.get(entry.path)) |known| {
                if (std.mem.eql(u8, known.source, entry.source)) {
                    try graph.put(arena, entry.path, known);
                    continue;
                }
            }
        }
        var scan = zts_cli.precompile.scanSource(gpa, entry.source, entry.path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Unparseable => {
                try graph.put(arena, entry.path, .{
                    .parsed = false,
                    .has_handler = false,
                    .imports = &.{},
                    .may_import_changed = isHandlerCandidate(entry.path) and mentionsAny(entry.source, stems),
                    .source = entry.source,
                });
                continue;
            },
        };
        defer scan.deinit(gpa);
        var edges: std.ArrayList([]const u8) = .empty;
        for (scan.imports) |target| {
            // A target outside the repository is not a tracked file, so no
            // changed file can sit behind it.
            const rel = repoRelativePath(arena, cwd, target) catch |err| switch (err) {
                error.OutsideRepo => continue,
                error.OutOfMemory => return err,
            };
            try edges.append(arena, rel);
        }
        try graph.put(arena, entry.path, .{
            .parsed = true,
            .has_handler = scan.has_handler,
            .imports = try edges.toOwnedSlice(arena),
            .may_import_changed = false,
            .source = entry.source,
        });
    }
    return graph;
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The file name of each path without its directory and extension.
fn pathStems(arena: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    var stems: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        try stems.append(arena, std.fs.path.stem(path));
    }
    return stems.toOwnedSlice(arena);
}

/// Importers of a file, over the union of the two sides.
const ReverseGraph = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

fn addReverseEdges(arena: std.mem.Allocator, reverse: *ReverseGraph, side: *const SideGraph) !void {
    var it = side.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.imports) |target| {
            const slot = try reverse.getOrPut(arena, target);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            if (!containsPath(slot.value_ptr.items, entry.key_ptr.*)) {
                try slot.value_ptr.append(arena, entry.key_ptr.*);
            }
        }
    }
}

/// The handler candidates that reach `seed` through relative imports on either
/// side, sorted. Depth is not bounded here: CHECK stops at `max_import_depth`
/// and marks the side incomplete, and `isComparable` turns that into exit 2.
fn handlersReaching(
    arena: std.mem.Allocator,
    reverse: *const ReverseGraph,
    base: *const SideGraph,
    head: *const SideGraph,
    seed: []const u8,
) ![]const []const u8 {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    var handlers: std.ArrayList([]const u8) = .empty;
    try visited.put(arena, seed, {});
    try queue.append(arena, seed);
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const importers = reverse.get(queue.items[next]) orelse continue;
        for (importers.items) |importer| {
            if (visited.contains(importer)) continue;
            try visited.put(arena, importer, {});
            try queue.append(arena, importer);
            const in_base = if (base.get(importer)) |f| f.parsed and f.has_handler else false;
            const in_head = if (head.get(importer)) |f| f.parsed and f.has_handler else false;
            if ((in_base or in_head) and isHandlerCandidate(importer)) try handlers.append(arena, importer);
        }
    }
    std.mem.sort([]const u8, handlers.items, {}, pathLess);
    return handlers.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

/// Entry point. Returns the process exit code (0 safe, 1 breaking, 2 error).
/// Allocation failures propagate; git/usage failures are reported on stderr
/// and folded into exit code 2.
pub fn run(
    gpa: std.mem.Allocator,
    opts: Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = shared.realCwd(arena) catch {
        try stderr.writeAll("zttp proofs gate: cannot resolve the working directory\n");
        return 2;
    };

    if (!refExists(arena, cwd, "HEAD")) {
        try stderr.writeAll("zttp proofs gate: not a git repository (no HEAD)\n");
        return 2;
    }

    const base = resolveBase(arena, cwd, opts) catch {
        try stderr.writeAll("zttp proofs gate: base ref does not resolve (tried --base / origin/main / main)\n");
        return 2;
    };
    const head_label: []const u8 = opts.head orelse "working tree";

    const changed = changedSources(arena, cwd, base, opts.head) catch |err| switch (err) {
        error.BadGitRef => {
            try stderr.print("zttp proofs gate: cannot diff `{s}` against `{s}`\n", .{ base, head_label });
            return 2;
        },
        else => return err,
    };

    var results: std.ArrayList(HandlerResult) = .empty;
    var skipped: std.ArrayList(Skipped) = .empty;

    // The import graph of each side. A handler that reaches a changed file
    // through relative imports is compared like a changed handler, because the
    // changed file can change what the handler does.
    const stems = try pathStems(arena, changed);
    const scan_failed = "zttp proofs gate: cannot read the tracked TypeScript files to find the handlers that import a changed file\n";
    const base_graph = scanSide(gpa, arena, cwd, base, changed, stems, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try stderr.writeAll(scan_failed);
            return 2;
        },
    };
    const head_graph = scanSide(gpa, arena, cwd, opts.head, changed, stems, &base_graph) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try stderr.writeAll(scan_failed);
            return 2;
        },
    };
    if (changed.len > 0) {
        // A file that does not parse has unknown imports. When it is a handler
        // candidate that names a changed file and is not changed itself, it may
        // import that file, so the gate cannot say which handlers are affected.
        for ([_]*const SideGraph{ &base_graph, &head_graph }) |side| {
            var unknown = side.iterator();
            while (unknown.next()) |entry| {
                if (!entry.value_ptr.may_import_changed) continue;
                if (containsPath(changed, entry.key_ptr.*)) continue;
                try stderr.print(
                    "zttp proofs gate: cannot read the imports of `{s}`, which may import a changed file\n",
                    .{entry.key_ptr.*},
                );
                return 2;
            }
        }
    }
    var reverse: ReverseGraph = .empty;
    try addReverseEdges(arena, &reverse, &base_graph);
    try addReverseEdges(arena, &reverse, &head_graph);

    var work: std.ArrayList([]const u8) = .empty;
    var referenced: std.StringHashMapUnmanaged(void) = .empty;
    for (changed) |path| {
        if (isHandlerCandidate(path)) try work.append(arena, path);
    }
    const direct_count = work.items.len;
    var reached: std.ArrayList([]const u8) = .empty;
    for (changed) |seed| {
        const handlers = try handlersReaching(arena, &reverse, &base_graph, &head_graph, seed);
        if (handlers.len > 0) try referenced.put(arena, seed, {});
        for (handlers) |handler_path| {
            if (containsPath(changed, handler_path) or containsPath(reached.items, handler_path)) continue;
            try reached.append(arena, handler_path);
        }
    }
    std.mem.sort([]const u8, reached.items, {}, pathLess);
    try work.appendSlice(arena, reached.items);

    for (work.items, 0..) |path, index| {
        const direct = index < direct_count;
        const before = try readAtRef(arena, cwd, base, path);
        const after = try readAfter(arena, cwd, opts.head, path);
        if (!direct and (before == null or after == null)) {
            try stderr.print("zttp proofs gate: cannot read `{s}`, which imports a changed file\n", .{path});
            return 2;
        }
        // A changed file that holds no handler is not analyzed as a root. The
        // handlers that import it are compared instead, and a file that no
        // handler imports has nothing to compare.
        if (direct and sideHoldsNoHandler(before, base_graph.get(path)) and
            sideHoldsNoHandler(after, head_graph.get(path)))
        {
            if (!referenced.contains(path)) {
                try skipped.append(arena, .{ .path = path, .reason = "unreferenced_helper" });
            }
            continue;
        }
        if (after == null) {
            // File removed at head. If it was a request handler at base, the
            // deletion removed all of its routes -> breaking (must land in
            // results, which worstVerdict ranks). A deleted non-handler is noise.
            if (before) |before_src| {
                const source_kind = classifySource(gpa, before_src, path) catch |err| {
                    try stderr.print(
                        "zttp proofs gate: analysis failed for deleted `{s}`: {s}\n",
                        .{ path, @errorName(err) },
                    );
                    return 2;
                };
                switch (source_kind) {
                    .handler, .implicit_handler => try results.append(arena, .{
                        .path = try arena.dupe(u8, path),
                        .verdict = .breaking,
                        .implicit_capsule = source_kind == .implicit_handler,
                    }),
                    .non_handler => try skipped.append(arena, .{
                        .path = path,
                        .reason = "deleted_non_handler",
                    }),
                }
            } else {
                try skipped.append(arena, .{ .path = path, .reason = "unreadable" });
            }
            continue;
        }

        if (before == null) {
            // A new file is additive only after the analyzer proves it is a
            // valid handler. Treating every added TypeScript file as additive
            // lets malformed source bypass the same fail-closed boundary used
            // for modified and deleted files.
            const source_kind = classifySource(gpa, after.?, path) catch |err| {
                try stderr.print(
                    "zttp proofs gate: analysis failed for added `{s}`: {s}\n",
                    .{ path, @errorName(err) },
                );
                return 2;
            };
            switch (source_kind) {
                .handler, .implicit_handler => try results.append(arena, .{
                    .path = path,
                    .verdict = .additive,
                    .implicit_capsule = source_kind == .implicit_handler,
                }),
                .non_handler => try skipped.append(arena, .{ .path = path, .reason = "no_contract" }),
            }
            continue;
        }

        const result = analyzeHandler(gpa, arena, cwd, base, opts.head, path, before.?, after.?) catch |err| {
            // analyzeHandler returns null (handled below) for genuine
            // non-handler / no-contract files; reaching here means an analysis
            // or allocation failure. Swallowing it as `no_contract` drops the
            // handler from worstVerdict, so a breaking change could pass the
            // gate. Fail closed with the tooling-failure exit code.
            try stderr.print("zttp proofs gate: analysis failed for `{s}`: {s}\n", .{ path, @errorName(err) });
            return 2;
        };
        const hr = result orelse {
            if (direct) try skipped.append(arena, .{ .path = path, .reason = "no_contract" });
            continue;
        };
        try results.append(arena, hr);
    }

    const verdict = worstVerdict(results.items);

    var report: std.Io.Writer.Allocating = .init(arena);
    switch (opts.format) {
        .md => try renderMarkdown(&report.writer, base, head_label, results.items, skipped.items, verdict),
        .json => try renderJson(&report.writer, base, head_label, results.items, skipped.items, verdict),
    }
    const bytes = report.writer.buffered();

    if (opts.out) |out_path| {
        file_io.writeFile(arena, out_path, bytes) catch {
            try stderr.print("zttp proofs gate: cannot write report to `{s}`\n", .{out_path});
            return 2;
        };
    } else {
        try stdout.writeAll(bytes);
    }

    return if (isSafe(verdict)) 0 else 1;
}

/// True when one side of a changed file defines no handler: the file is absent
/// there, or it parsed and has no top-level `handler` function. A file that
/// did not parse, or that was not scanned, is not known to hold none.
fn sideHoldsNoHandler(source: ?[]const u8, info: ?SideFile) bool {
    if (source == null) return true;
    const side = info orelse return false;
    return side.parsed and !side.has_handler;
}

fn resolveBase(arena: std.mem.Allocator, cwd: []const u8, opts: Options) ![]const u8 {
    if (opts.base) |b| {
        if (!refExists(arena, cwd, b)) return error.BadGitRef;
        return b;
    }
    if (refExists(arena, cwd, "origin/main")) return "origin/main";
    if (refExists(arena, cwd, "main")) return "main";
    return error.BadGitRef;
}

fn readAfter(arena: std.mem.Allocator, cwd: []const u8, head: ?[]const u8, path: []const u8) !?[]u8 {
    if (head) |h| return readAtRef(arena, cwd, h, path);
    return file_io.readFile(arena, path, max_source_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

const SourceKind = enum { handler, implicit_handler, non_handler };

/// True when every spec error of the check is an implicit-default diagnostic:
/// the handler declared no `Proof<...>` capsule and misses a property of the
/// default profile. The caller has already ruled out `hasAnalysisErrors`, so
/// spec errors are the only errors left. The test reads the
/// `SpecDiagnostic.implicit_default` flag and never a diagnostic code, so a
/// declared capsule failure, a helper capsule failure, ZTS606, and the Effects
/// errors all keep the answer false. Total: a null contract returns false.
fn onlyImplicitDefaultSpecErrors(result: *const zts_cli.precompile.CheckResult) bool {
    const contract = if (result.contract) |*c| c else return false;
    for (contract.spec_diagnostics.items) |d| {
        if (d.kind.severity() == .err and !d.implicit_default) return false;
    }
    return true;
}

/// Whether a check is clean enough to compare. Clean means no errors, or only
/// implicit-default spec errors. `hasAnalysisErrors` stays fail-closed.
fn isComparable(result: *const zts_cli.precompile.CheckResult) bool {
    if (hasAnalysisErrors(result)) return false;
    // A side whose relative imports were not all followed has effects the
    // analysis never saw, so its contract cannot stand in for its behavior.
    // A declared capsule usually fails on such a side; an implicit one only
    // adds implicit-default errors, which the rule below would accept.
    if (!result.imports_complete) return false;
    return result.totalErrors() == 0 or onlyImplicitDefaultSpecErrors(result);
}

fn isImplicitCapsule(result: *const zts_cli.precompile.CheckResult) bool {
    const contract = if (result.contract) |*c| c else return false;
    return contract.declared_specs_implicit;
}

/// Classify only successfully analyzed source. A compiler failure must not be
/// mistaken for a library module because that would make a deleted handler look
/// safe to the gate.
fn classifySource(gpa: std.mem.Allocator, src: []const u8, path: []const u8) !SourceKind {
    var result = zts_cli.precompile.runCheckOnlyFromSourceWithOptions(gpa, src, path, .{
        .json_mode = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.UnanalysableSource,
    };
    defer result.deinit(gpa);
    if (hasAnalysisErrors(&result)) return error.UnanalysableSource;
    if (result.contract) |*contract| {
        if (!isHandlerContract(contract)) return .non_handler;
        if (!isComparable(&result)) return error.UnanalysableSource;
        return if (isImplicitCapsule(&result)) .implicit_handler else .handler;
    }
    return .non_handler;
}

fn hasAnalysisErrors(result: *const zts_cli.precompile.CheckResult) bool {
    return result.parse_errors > 0 or
        result.bool_errors > 0 or
        result.type_errors > 0 or
        result.strict_errors > 0 or
        result.verify_errors > 0 or
        result.flow_errors > 0 or
        result.canonical_errors > 0 or
        result.policy_errors > 0;
}

/// The check results of the two sides of one handler. Each side reads the
/// helpers it imports at its own revision: the base side at `base`, and the
/// after side at `head` when `--head` names a ref. With no `--head` the after
/// side is the working tree, which is where the analyzer reads by default.
const CheckedSides = struct {
    before: zts_cli.precompile.CheckResult,
    after: zts_cli.precompile.CheckResult,

    fn deinit(self: *CheckedSides, gpa: std.mem.Allocator) void {
        self.before.deinit(gpa);
        self.after.deinit(gpa);
    }
};

fn checkSides(
    gpa: std.mem.Allocator,
    cwd: []const u8,
    base: []const u8,
    head: ?[]const u8,
    path: []const u8,
    before_src: []const u8,
    after_src: []const u8,
) !CheckedSides {
    var before_reader: RevisionReader = .{ .cwd = cwd, .ref = base };
    var before = try zts_cli.precompile.runCheckOnlyFromSourceWithOptions(gpa, before_src, path, .{
        .json_mode = true,
        .import_reader = before_reader.importReader(),
    });
    errdefer before.deinit(gpa);

    var after_reader: RevisionReader = undefined;
    var after_import: ?zts_cli.precompile.ImportReader = null;
    if (head) |head_ref| {
        after_reader = .{ .cwd = cwd, .ref = head_ref };
        after_import = after_reader.importReader();
    }
    var after = try zts_cli.precompile.runCheckOnlyFromSourceWithOptions(gpa, after_src, path, .{
        .json_mode = true,
        .import_reader = after_import,
    });
    errdefer after.deinit(gpa);

    return .{ .before = before, .after = after };
}

/// Compile before/after to contracts, diff them, and project the result into
/// the arena-owned data model. Returns null when either side has no contract
/// (not a handler). The ContractDiff and compile results live only for the
/// duration of this call; everything kept is copied into the arena.
fn analyzeHandler(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cwd: []const u8,
    base: []const u8,
    head: ?[]const u8,
    path: []const u8,
    before_src: []const u8,
    after_src: []const u8,
) !?HandlerResult {
    var sides = try checkSides(gpa, cwd, base, head, path, before_src, after_src);
    defer sides.deinit(gpa);
    const before_result = &sides.before;
    const after_result = &sides.after;

    if (hasAnalysisErrors(before_result) or hasAnalysisErrors(after_result)) {
        return error.UnanalysableSource;
    }

    const before_contract: ?*const zts.HandlerContract = if (before_result.contract) |*c| c else null;
    const after_contract: ?*const zts.HandlerContract = if (after_result.contract) |*c| c else null;

    const before_is_handler = before_contract != null and isHandlerContract(before_contract.?);
    const after_is_handler = after_contract != null and isHandlerContract(after_contract.?);

    if ((before_is_handler and !isComparable(before_result)) or
        (after_is_handler and !isComparable(after_result)))
    {
        return error.UnanalysableSource;
    }
    const implicit = (after_is_handler and isImplicitCapsule(after_result)) or
        (!after_is_handler and before_is_handler and isImplicitCapsule(before_result));

    // A `.ts`/`.tsx` file that exposes no routes/behaviors on EITHER side is a
    // library/config module, not a request handler. Skip it (only adds
    // equivalent-verdict noise to the report).
    if (!before_is_handler and !after_is_handler) return null;

    // Was a handler, now exposes nothing (all routes removed, or rewritten to a
    // still-compiling non-handler): every existing caller breaks. This must
    // land in `results` as .breaking, not in `skipped` -- worstVerdict only
    // ranks results, so otherwise the removal would pass the gate as safe.
    if (before_is_handler and !after_is_handler) {
        return .{ .path = try arena.dupe(u8, path), .verdict = .breaking, .implicit_capsule = implicit };
    }

    // Newly became a handler: no prior routes to break -> additive.
    if (!before_is_handler and after_is_handler) {
        return .{ .path = try arena.dupe(u8, path), .verdict = .additive, .implicit_capsule = implicit };
    }

    var diff = try contract_diff.diffContractsFromSources(gpa, before_contract.?, after_contract.?, before_src, after_src);
    defer diff.deinit(gpa);

    // A critical lost proof makes the handler breaking, whatever
    // `behavioralVerdict()` says about the behavior alone.
    const lost = try lostProperties(arena, &diff);
    const critical_loss = hasCriticalLoss(lost);

    return .{
        .path = try arena.dupe(u8, path),
        .verdict = if (critical_loss) .breaking else diff.behavioralVerdict(),
        .behavior = behaviorCounts(&diff),
        .surface = try extractSurface(arena, &diff),
        .counterexamples = try extractCounterexamples(arena, &diff),
        .lost_properties = lost,
        .implicit_capsule = implicit,
    };
}

// ---------------------------------------------------------------------------
// Tests — the pure aggregation + rendering core (no git, no compile).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifySource distinguishes handlers, libraries, and failed analysis" {
    try testing.expectEqual(
        SourceKind.handler,
        try classifySource(
            testing.allocator,
            "function handler(req: Request): Proof<Response, \"pure\"> { return Response.text('ok'); }",
            "handler.ts",
        ),
    );
    try testing.expectEqual(
        SourceKind.non_handler,
        try classifySource(testing.allocator, "export const answer: number = 42;", "library.ts"),
    );
    try testing.expectError(
        error.UnanalysableSource,
        classifySource(testing.allocator, "function handler(", "broken.ts"),
    );
}

test "gate fails closed when a deleted TypeScript file cannot be analyzed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];

    const commands = [_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "add", "handler.ts" },
        &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" },
    };
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "handler.ts",
        .data = "function handler(",
    });
    for (commands) |command| {
        const git = try runGit(testing.allocator, repo_path, command);
        defer testing.allocator.free(git.stdout);
        try testing.expect(git.ok);
    }
    try tmp.dir.deleteFile(testing.io, "handler.ts");

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(testing.allocator);
    defer err.deinit();
    const code = try run(
        testing.allocator,
        .{ .base = "HEAD", .format = .json },
        &out.writer,
        &err.writer,
    );

    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqual(@as(usize, 0), out.writer.buffered().len);
    try testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "analysis failed for deleted `handler.ts`") != null);
    try testing.expect(std.mem.indexOf(u8, err.writer.buffered(), "UnanalysableSource") != null);
}

test "gate analyzes newly added TypeScript before classifying it" {
    const Case = struct {
        source: []const u8,
        expected_code: u8,
        expected_output: []const u8,
        expected_error: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{
            .source = "function handler(",
            .expected_code = 2,
            .expected_output = "",
            .expected_error = "analysis failed for added `candidate.ts`",
        },
        .{
            .source = "function handler(req: Request): Proof<Response, \"pure\"> { return Response.text('ok'); }",
            .expected_code = 0,
            .expected_output = "\"verdict\":\"additive\"",
        },
        .{
            .source = "export const answer: number = 42;",
            .expected_code = 0,
            .expected_output = "\"handlersChecked\":0",
        },
    };

    for (cases) |case| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const repo_path = path_buf[0..path_len];
        const setup_commands = [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{
                "git",
                "-c",
                "user.name=zttp test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "--allow-empty",
                "-qm",
                "base",
            },
        };
        for (setup_commands) |command| {
            const git = try runGit(testing.allocator, repo_path, command);
            defer testing.allocator.free(git.stdout);
            try testing.expect(git.ok);
        }
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "candidate.ts", .data = case.source });
        const add = try runGit(testing.allocator, repo_path, &.{ "git", "add", "candidate.ts" });
        defer testing.allocator.free(add.stdout);
        try testing.expect(add.ok);

        const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
        defer testing.allocator.free(old_cwd);
        defer std.Io.Threaded.chdir(old_cwd) catch {};

        var out = std.Io.Writer.Allocating.init(testing.allocator);
        defer out.deinit();
        var err = std.Io.Writer.Allocating.init(testing.allocator);
        defer err.deinit();
        const code = try run(
            testing.allocator,
            .{ .base = "HEAD", .format = .json },
            &out.writer,
            &err.writer,
        );
        try testing.expectEqual(case.expected_code, code);
        if (case.expected_output.len == 0) {
            try testing.expectEqual(@as(usize, 0), out.writer.buffered().len);
        } else {
            try testing.expect(std.mem.indexOf(u8, out.writer.buffered(), case.expected_output) != null);
        }
        if (case.expected_error) |needle| {
            try testing.expect(std.mem.indexOf(u8, err.writer.buffered(), needle) != null);
        }
    }
}

test "worstVerdict: one breaking handler makes the repo breaking" {
    const results = [_]HandlerResult{
        .{ .path = "a.ts", .verdict = .equivalent },
        .{ .path = "b.ts", .verdict = .additive },
        .{ .path = "c.ts", .verdict = .breaking },
    };
    try testing.expectEqual(Classification.breaking, worstVerdict(&results));
}

test "worstVerdict: all equivalent stays equivalent (safe)" {
    const results = [_]HandlerResult{
        .{ .path = "a.ts", .verdict = .equivalent },
        .{ .path = "b.ts", .verdict = .equivalent_modulo_laws },
    };
    const v = worstVerdict(&results);
    try testing.expectEqual(Classification.equivalent_modulo_laws, v);
    try testing.expect(isSafe(v));
}

test "worstVerdict: empty range is safe" {
    try testing.expectEqual(Classification.equivalent, worstVerdict(&.{}));
    try testing.expect(isSafe(worstVerdict(&.{})));
}

test "renderMarkdown: breaking report carries header, table, and counterexample" {
    const cex = [_]Counterexample{
        .{ .method = "GET", .pattern = "/users/:id", .status = .{ .known = 200 }, .change = .response_changed },
        .{ .method = "DELETE", .pattern = "/users/:id", .status = .unknown, .change = .removed },
    };
    const removed_routes = [_][]const u8{"/users/:id"};
    const results = [_]HandlerResult{
        .{
            .path = "api/users.ts",
            .verdict = .breaking,
            .behavior = .{ .preserved = 4, .response_changed = 1, .removed = 1 },
            .surface = .{ .removed_routes = &removed_routes },
            .counterexamples = &cex,
        },
        .{ .path = "api/health.ts", .verdict = .equivalent },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderMarkdown(&aw.writer, "origin/main", "working tree", &results, &.{}, .breaking);
    const out = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, sticky_marker) != null);
    try testing.expect(std.mem.indexOf(u8, out, "**Verdict: `breaking`**") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| `api/users.ts` | `breaking` |") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 response changed, 1 removed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`- route /users/:id`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`DELETE /users/:id` removed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`GET /users/:id` status 200 → response changed") != null);
}

test "renderMarkdown: empty range states no changed handlers" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderMarkdown(&aw.writer, "origin/main", "working tree", &.{}, &.{}, .equivalent);
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "_No changed handlers in this range._") != null);
}

test "renderJson: shape carries schema, verdict, safe, and behaviorDiff keys" {
    const added_routes = [_][]const u8{"/v2/orders"};
    const results = [_]HandlerResult{
        .{
            .path = "api/orders.ts",
            .verdict = .additive,
            .behavior = .{ .preserved = 2, .added = 2 },
            .surface = .{ .added_routes = &added_routes },
        },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderJson(&aw.writer, "origin/main", "feature/x", &results, &.{}, .additive);
    const out = aw.writer.buffered();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings(json_schema, root.get("schema").?.string);
    try testing.expectEqualStrings("additive", root.get("verdict").?.string);
    try testing.expect(root.get("safe").?.bool);
    try testing.expectEqual(@as(i64, 1), root.get("handlersChecked").?.integer);

    const handler = root.get("handlers").?.array.items[0].object;
    try testing.expectEqualStrings("api/orders.ts", handler.get("path").?.string);
    const bd = handler.get("behaviorDiff").?.object;
    try testing.expectEqual(@as(i64, 2), bd.get("added").?.integer);
    const surface_routes = handler.get("surface").?.object.get("routes").?.object;
    try testing.expectEqualStrings("/v2/orders", surface_routes.get("added").?.array.items[0].string);
}

// ---------------------------------------------------------------------------
// Imported helpers are read at the revision under analysis
// ---------------------------------------------------------------------------

const helper_handler_base =
    \\import { fetch } from "zttp:fetch";
    \\import { enrich } from "./lib.ts";
    \\function handler(req: Request): Response {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) {
    \\    return Response.json({ error: "upstream" }, { status: 502 });
    \\  }
    \\  return Response.json({ a: res.body, b: enrich() });
    \\}
    \\
;

const helper_handler_head =
    \\import { fetch } from "zttp:fetch";
    \\import { enrich } from "./lib.ts";
    \\function handler(req: Request): Response {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) {
    \\    return Response.json({ error: "upstream" }, { status: 502 });
    \\  }
    \\  return Response.json({ a: res.body, c: enrich() });
    \\}
    \\
;

const helper_pure =
    \\export function enrich(): string {
    \\  return "pure".toUpperCase();
    \\}
    \\
;

const helper_unchecked_fetch =
    \\import { fetch } from "zttp:fetch";
    \\export function enrich(): string {
    \\  const res = fetch("https://api.example.com/b");
    \\  return res.body;
    \\}
    \\
;

fn expectGit(repo_path: []const u8, command: []const []const u8) !void {
    const git = try runGit(testing.allocator, repo_path, command);
    defer testing.allocator.free(git.stdout);
    try testing.expect(git.ok);
}

/// A repository whose base commit holds a handler and a pure helper.
fn initHelperRepo(tmp: *testing.TmpDir, repo_path: []const u8) !void {
    try expectGit(repo_path, &.{ "git", "init", "-q" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = helper_handler_base });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.ts", .data = helper_pure });
    try expectGit(repo_path, &.{ "git", "add", "handler.ts", "lib.ts" });
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" });
}

fn faultCoveredOf(result: *const zts_cli.precompile.CheckResult) !bool {
    const contract = result.contract orelse return error.TestUnexpectedResult;
    return (contract.properties orelse return error.TestUnexpectedResult).fault_covered;
}

test "a helper that gains an unchecked fetch flips fault_covered between base and the working tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];
    try initHelperRepo(&tmp, repo_path);

    // The working tree: the helper gains an unchecked fetch, and the handler changes.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.ts", .data = helper_unchecked_fetch });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = helper_handler_head });

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    const cwd = try shared.realCwd(testing.allocator);
    defer testing.allocator.free(cwd);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const before_src = (try readAtRef(arena_state.allocator(), cwd, "HEAD", "handler.ts")) orelse return error.TestUnexpectedResult;
    const after_src = (try readAfter(arena_state.allocator(), cwd, null, "handler.ts")) orelse return error.TestUnexpectedResult;

    var sides = try checkSides(testing.allocator, cwd, "HEAD", null, "handler.ts", before_src, after_src);
    defer sides.deinit(testing.allocator);

    // The base handler imports the pure helper as committed; reading the working
    // tree instead would give both sides the unchecked fetch.
    try testing.expect(try faultCoveredOf(&sides.before));
    try testing.expect(!try faultCoveredOf(&sides.after));
}

test "with --head the after side reads the helper at head, not the working tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];
    try initHelperRepo(&tmp, repo_path);

    // Head commit: the helper gains an unchecked fetch, and the handler changes.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.ts", .data = helper_unchecked_fetch });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = helper_handler_head });
    try expectGit(repo_path, &.{ "git", "add", "handler.ts", "lib.ts" });
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "head" });
    // The working tree then drifts back to the pure helper.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.ts", .data = helper_pure });

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    const cwd = try shared.realCwd(testing.allocator);
    defer testing.allocator.free(cwd);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const before_src = (try readAtRef(arena_state.allocator(), cwd, "HEAD~1", "handler.ts")) orelse return error.TestUnexpectedResult;
    const after_src = (try readAfter(arena_state.allocator(), cwd, "HEAD", "handler.ts")) orelse return error.TestUnexpectedResult;

    var sides = try checkSides(testing.allocator, cwd, "HEAD~1", "HEAD", "handler.ts", before_src, after_src);
    defer sides.deinit(testing.allocator);

    try testing.expect(try faultCoveredOf(&sides.before));
    try testing.expect(!try faultCoveredOf(&sides.after));
}

test "a helper missing at the base revision is unresolved, not read from the working tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];

    // The base commit holds the handler only. The working tree adds a pure helper.
    try expectGit(repo_path, &.{ "git", "init", "-q" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = helper_handler_base });
    try expectGit(repo_path, &.{ "git", "add", "handler.ts" });
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.ts", .data = helper_pure });

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    const cwd = try shared.realCwd(testing.allocator);
    defer testing.allocator.free(cwd);

    var sides = try checkSides(testing.allocator, cwd, "HEAD", null, "handler.ts", helper_handler_base, helper_handler_base);
    defer sides.deinit(testing.allocator);

    // The helper did not exist at base: the answer is unresolved, which fails closed.
    try testing.expect(!try faultCoveredOf(&sides.before));
    // The working-tree side finds the pure helper.
    try testing.expect(try faultCoveredOf(&sides.after));
}

// ---------------------------------------------------------------------------
// A lost proven property: the projection, the renderers, and the gate
// ---------------------------------------------------------------------------

fn emptyDiff() contract_diff.ContractDiff {
    return .{
        .routes = .empty,
        .api_route_changes = .empty,
        .env_changes = .empty,
        .egress_changes = .empty,
        .cache_changes = .empty,
        .sql_changes = .empty,
        .dynamic_changes = .empty,
    };
}

test "lostProperties: keeps true-to-false monotonic booleans with their severity and drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var diff = emptyDiff();
    defer diff.deinit(testing.allocator);
    try diff.effect_changes.appendSlice(testing.allocator, &.{
        // A critical loss.
        .{ .field = "fault_covered", .old_value = true, .new_value = false },
        // A gain.
        .{ .field = "retry_safe", .old_value = false, .new_value = true },
        // A non-critical loss.
        .{ .field = "pure", .old_value = true, .new_value = false },
        // `has_egress` is an inverse fact, not a monotonic proof.
        .{ .field = "has_egress", .old_value = true, .new_value = false },
        // max_io_depth and cost_class carry presence bits, not proofs. The
        // cost_class row asserts the projection only: `diffContracts` appends
        // it with presence bits, and a class that disappears is not a lost
        // property here (`cost_bounded` carries the cost proof).
        .{ .field = "max_io_depth", .old_value = true, .new_value = false },
        .{ .field = "cost_class", .old_value = true, .new_value = false, .old_label = "constant", .new_label = null },
    });

    const lost = try lostProperties(arena_state.allocator(), &diff);
    try testing.expectEqual(@as(usize, 2), lost.len);
    try testing.expectEqualStrings("fault_covered", lost[0].field);
    try testing.expectEqual(contract_diff.Severity.critical, lost[0].severity);
    try testing.expectEqualStrings("pure", lost[1].field);
    try testing.expectEqual(contract_diff.Severity.info, lost[1].severity);
    try testing.expect(hasCriticalLoss(lost));
    try testing.expect(!hasCriticalLoss(lost[1..]));
}

test "lostProperties: a gain, max_io_depth, and cost_class alone lose nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var diff = emptyDiff();
    defer diff.deinit(testing.allocator);
    try diff.effect_changes.appendSlice(testing.allocator, &.{
        .{ .field = "no_secret_leakage", .old_value = false, .new_value = true },
        .{ .field = "max_io_depth", .old_value = true, .new_value = false },
        .{ .field = "cost_class", .old_value = true, .new_value = false },
    });
    const lost = try lostProperties(arena_state.allocator(), &diff);
    try testing.expectEqual(@as(usize, 0), lost.len);
}

test "renderMarkdown: a lost proof is listed, counted in the table, and named as the reason" {
    const lost = [_]LostProperty{
        .{ .field = "fault_covered", .severity = .critical },
        .{ .field = "pure", .severity = .info },
    };
    const results = [_]HandlerResult{
        .{ .path = "api/users.ts", .verdict = .breaking, .lost_properties = &lost },
        // A non-critical loss keeps its verdict and still gets a section.
        .{ .path = "api/health.ts", .verdict = .equivalent, .lost_properties = lost[1..] },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderMarkdown(&aw.writer, "origin/main", "working tree", &results, &.{}, .breaking);
    const out = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "| `api/users.ts` | `breaking` | 2 proofs lost |") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| `api/health.ts` | `equivalent` | 1 proof lost |") != null);
    try testing.expect(std.mem.indexOf(u8, out, "**Lost proofs**") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `fault_covered`: proven → not proven (critical)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `pure`: proven → not proven (info)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "No lost proof is critical, so the verdict is unchanged.") != null);
    // The health section exists although its verdict is a safe no-op.
    try testing.expect(std.mem.indexOf(u8, out, "### `api/health.ts` — equivalent") != null);
}

test "renderJson: lostProperties is always present and lists property and severity" {
    const lost = [_]LostProperty{.{ .field = "no_secret_leakage", .severity = .critical }};
    const results = [_]HandlerResult{
        .{ .path = "a.ts", .verdict = .breaking, .lost_properties = &lost },
        .{ .path = "b.ts", .verdict = .equivalent },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderJson(&aw.writer, "origin/main", "feature/x", &results, &.{}, .breaking);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.writer.buffered(), .{});
    defer parsed.deinit();
    const handlers = parsed.value.object.get("handlers").?.array.items;
    const a = handlers[0].object.get("lostProperties").?.array.items;
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("no_secret_leakage", a[0].object.get("property").?.string);
    try testing.expectEqualStrings("critical", a[0].object.get("severity").?.string);
    try testing.expectEqual(@as(usize, 0), handlers[1].object.get("lostProperties").?.array.items.len);
    try testing.expectEqualStrings(json_schema, parsed.value.object.get("schema").?.string);
}

// A handler with a `Proof<...>` capsule that does not name the lost property.
// `canonical` holds on both sides, so the capsule discharges before and after.
// The head changes the handler and its helper gains an unchecked fetch, so
// `fault_covered` is lost while every response path is unchanged. The helper
// sits under `fixtures/`, a path the gate does not list as a handler: a changed
// helper that reaches a capability is otherwise analyzed alone, lacks its own
// `Effects<...>` and `Proof<...>` declarations, and ends the run with exit 2.
const capsule_handler_base =
    \\import { fetch } from "zttp:fetch";
    \\import { enrich } from "./fixtures/lib.ts";
    \\function handler(req: Request): Proof<Response, "canonical"> {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) {
    \\    return Response.json({ error: "upstream" }, { status: 502 });
    \\  }
    \\  return Response.json({ a: res.body, b: enrich() });
    \\}
    \\
;

const capsule_handler_head =
    \\import { fetch } from "zttp:fetch";
    \\import { enrich } from "./fixtures/lib.ts";
    \\function handler(req: Request): Proof<Response, "canonical"> {
    \\  const res = fetch("https://api.example.com/a");
    \\  if (!res.ok) {
    \\    return Response.json({ error: "upstream" }, { status: 502 });
    \\  }
    \\  return Response.json({ a: res.body, c: enrich() });
    \\}
    \\
;

// Pure on both sides except that the head reads the clock: `deterministic` and
// `idempotent` are lost, `retry_safe` is kept.
const clock_handler_base =
    \\function handler(req: Request): Proof<Response, "canonical"> {
    \\  return Response.json({ ok: true, t: 1 });
    \\}
    \\
;

const clock_handler_head =
    \\function handler(req: Request): Proof<Response, "canonical"> {
    \\  return Response.json({ ok: true, t: Date.now() });
    \\}
    \\
;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Points HOME at the temporary repository so a signing key, if the gate
/// wrongly creates one, lands there and not in the developer's home.
const HomeOverride = struct {
    previous: ?[:0]u8,

    fn set(path: []const u8) !HomeOverride {
        const previous: ?[:0]u8 = if (std.c.getenv("HOME")) |h|
            try testing.allocator.dupeSentinel(u8, std.mem.sliceTo(h, 0), 0)
        else
            null;
        errdefer if (previous) |p| testing.allocator.free(p);
        const path_z = try testing.allocator.dupeSentinel(u8, path, 0);
        defer testing.allocator.free(path_z);
        if (setenv("HOME", path_z.ptr, 1) != 0) return error.TestUnexpectedResult;
        return .{ .previous = previous };
    }

    fn restore(self: *HomeOverride) void {
        if (self.previous) |p| {
            _ = setenv("HOME", p.ptr, 1);
            testing.allocator.free(p);
        }
    }
};

test "run: a critical lost proof fails the gate, lists the loss, and writes no ledger row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];

    try expectGit(repo_path, &.{ "git", "init", "-q" });
    try tmp.dir.createDirPath(testing.io, "fixtures");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = capsule_handler_base });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fixtures/lib.ts", .data = helper_pure });
    try expectGit(repo_path, &.{ "git", "add", "handler.ts", "fixtures/lib.ts" });
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" });

    // The working tree: the helper gains an unchecked fetch, and the handler changes.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fixtures/lib.ts", .data = helper_unchecked_fetch });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = capsule_handler_head });

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};
    var home = try HomeOverride.set(repo_path);
    defer home.restore();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const code = try run(testing.allocator, .{ .base = "HEAD", .format = .md }, &out.writer, &err.writer);
    const report = out.writer.buffered();

    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, report, "**Verdict: `breaking`**") != null);
    try testing.expect(std.mem.indexOf(u8, report, "**Lost proofs**") != null);
    try testing.expect(std.mem.indexOf(u8, report, "- `fault_covered`: proven → not proven (critical)") != null);
    // The gate writes no ledger row, with signing left on or off.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".zttp/proofs.jsonl", .{}));
    try testing.expectEqualStrings("", err.writer.buffered());
}

test "run: a loss of only non-critical proofs is listed and does not fail the gate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];

    try expectGit(repo_path, &.{ "git", "init", "-q" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = clock_handler_base });
    try expectGit(repo_path, &.{ "git", "add", "handler.ts" });
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = clock_handler_head });

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const code = try run(testing.allocator, .{ .base = "HEAD", .format = .json }, &out.writer, &err.writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer parsed.deinit();
    const handler = parsed.value.object.get("handlers").?.array.items[0].object;
    const lost = handler.get("lostProperties").?.array.items;
    try testing.expect(lost.len > 0);
    var saw_deterministic = false;
    for (lost) |l| {
        try testing.expect(!std.mem.eql(u8, l.object.get("severity").?.string, "critical"));
        if (std.mem.eql(u8, l.object.get("property").?.string, "deterministic")) saw_deterministic = true;
    }
    try testing.expect(saw_deterministic);
    try testing.expect(!std.mem.eql(u8, handler.get("verdict").?.string, "breaking"));
    try testing.expectEqual(@as(u8, 0), code);
}

test "repoRelativePath keeps a relative path, relativizes an absolute one, and refuses an outside path" {
    const a = testing.allocator;

    const kept = try repoRelativePath(a, "/repo", "src/lib.ts");
    defer a.free(kept);
    try testing.expectEqualStrings("src/lib.ts", kept);

    const normalized = try repoRelativePath(a, "/repo", "src/./deep/../lib.ts");
    defer a.free(normalized);
    try testing.expectEqualStrings("src/lib.ts", normalized);

    const absolute = try repoRelativePath(a, "/repo", "/repo/src/lib.ts");
    defer a.free(absolute);
    try testing.expectEqualStrings("src/lib.ts", absolute);

    try testing.expectError(error.OutsideRepo, repoRelativePath(a, "/repo", "../outside.ts"));
    try testing.expectError(error.OutsideRepo, repoRelativePath(a, "/repo", "src/../../outside.ts"));
    try testing.expectError(error.OutsideRepo, repoRelativePath(a, "/repo", "/elsewhere/lib.ts"));
    try testing.expectError(error.OutsideRepo, repoRelativePath(a, "/repo", "/repo"));
}

// A handler with no `Proof<...>` return type. It writes to the cache, so the
// implicit default profile demands `pure`, `read_only`, and others that it does
// not hold: every spec error on each side has `implicit_default` set.
const implicit_handler_base =
    \\import { cacheSet } from "zttp:cache";
    \\function handler(req: Request): Response {
    \\  if (req.path === "/a") {
    \\    cacheSet("ns", "k", "v", 60);
    \\    return Response.text("ok", { status: 200 });
    \\  }
    \\  return Response.text("none", { status: 404 });
    \\}
    \\
;

const implicit_handler_status_changed =
    \\import { cacheSet } from "zttp:cache";
    \\function handler(req: Request): Response {
    \\  if (req.path === "/a") {
    \\    cacheSet("ns", "k", "v", 60);
    \\    return Response.text("ok", { status: 404 });
    \\  }
    \\  return Response.text("none", { status: 404 });
    \\}
    \\
;

const implicit_handler_comment_only =
    \\import { cacheSet } from "zttp:cache";
    \\// A comment that changes no behavior.
    \\function handler(req: Request): Response {
    \\  if (req.path === "/a") {
    \\    cacheSet("ns", "k", "v", 60);
    \\    return Response.text("ok", { status: 200 });
    \\  }
    \\  return Response.text("none", { status: 404 });
    \\}
    \\
;

// A declared capsule that the handler does not hold: ZTS500 with
// `implicit_default` false.
const declared_failing_base =
    \\import { cacheSet } from "zttp:cache";
    \\function handler(req: Request): Proof<Response, "pure"> {
    \\  if (req.path === "/a") {
    \\    cacheSet("ns", "k", "v", 60);
    \\    return Response.text("ok", { status: 200 });
    \\  }
    \\  return Response.text("none", { status: 404 });
    \\}
    \\
;

const declared_failing_head =
    \\import { cacheSet } from "zttp:cache";
    \\function handler(req: Request): Proof<Response, "pure"> {
    \\  if (req.path === "/a") {
    \\    cacheSet("ns", "k", "v", 60);
    \\    return Response.text("ok", { status: 404 });
    \\  }
    \\  return Response.text("none", { status: 404 });
    \\}
    \\
;

const GateRun = struct {
    code: u8,
    report: []u8,
    stderr: []u8,

    fn deinit(self: GateRun) void {
        testing.allocator.free(self.report);
        testing.allocator.free(self.stderr);
    }
};

/// Commit `base_src` as handler.ts in a temporary repository, write `head_src`
/// to the working tree, and run the gate against HEAD.
fn gateOverEdit(base_src: []const u8, head_src: []const u8, format: Format) !GateRun {
    return gateOverEditWithHelpers(&.{}, base_src, head_src, format);
}

const RepoFile = struct { path: []const u8, data: []const u8 };

/// As `gateOverEdit`, with `helpers` committed beside handler.ts and left
/// unchanged in the working tree.
fn gateOverEditWithHelpers(helpers: []const RepoFile, base_src: []const u8, head_src: []const u8, format: Format) !GateRun {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];

    try expectGit(repo_path, &.{ "git", "init", "-q" });
    for (helpers) |helper| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = helper.path, .data = helper.data });
        try expectGit(repo_path, &.{ "git", "add", helper.path });
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = base_src });
    try expectGit(repo_path, &.{ "git", "add", "handler.ts" });
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "handler.ts", .data = head_src });

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const code = try run(testing.allocator, .{ .base = "HEAD", .format = format }, &out.writer, &err.writer);
    const report = try testing.allocator.dupe(u8, out.writer.buffered());
    errdefer testing.allocator.free(report);
    const stderr = try testing.allocator.dupe(u8, err.writer.buffered());
    return .{ .code = code, .report = report, .stderr = stderr };
}

test "run: an implicit-default handler whose status changes gets a breaking verdict marked implicit" {
    const g = try gateOverEdit(implicit_handler_base, implicit_handler_status_changed, .json);
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expectEqualStrings("", g.stderr);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"verdict\":\"breaking\"") != null);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"capsule\":\"implicit\"") != null);
}

test "run: an implicit-default handler marks the markdown report with no declared capsule" {
    const g = try gateOverEdit(implicit_handler_base, implicit_handler_status_changed, .md);
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "no declared capsule") != null);
}

test "run: an implicit-default handler with an unchanged behavior is safe" {
    const g = try gateOverEdit(implicit_handler_base, implicit_handler_comment_only, .json);
    defer g.deinit();
    try testing.expectEqual(@as(u8, 0), g.code);
    try testing.expectEqualStrings("", g.stderr);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"capsule\":\"implicit\"") != null);
}

test "run: a declared capsule that fails on both sides still exits 2" {
    const g = try gateOverEdit(declared_failing_base, declared_failing_head, .json);
    defer g.deinit();
    try testing.expectEqual(@as(u8, 2), g.code);
    try testing.expectEqual(@as(usize, 0), g.report.len);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "UnanalysableSource") != null);
}

// helper.ts fails its own type check, so CHECK does not follow its import
// of deep.ts, and the write behind `loud` is never seen on either side.
const incomplete_closure_helpers = [_]RepoFile{
    .{ .path = "deep.ts", .data =
    \\import { cacheSet } from "zttp:cache";
    \\export function deepQuiet(): string {
    \\  return "q";
    \\}
    \\export function deepLoud(): string {
    \\  cacheSet("ns", "k", "v", 60);
    \\  return "l";
    \\}
    \\
    },
    .{ .path = "helper.ts", .data =
    \\import { deepQuiet, deepLoud } from "./deep.ts";
    \\export function quiet(): string {
    \\  const n: string = 1;
    \\  return deepQuiet();
    \\}
    \\export function loud(): string {
    \\  return deepLoud();
    \\}
    \\
    },
};

const incomplete_closure_base =
    \\import { quiet } from "./helper.ts";
    \\function handler(req: Request): Response {
    \\  return Response.text(quiet(), { status: 200 });
    \\}
    \\
;

const incomplete_closure_head =
    \\import { loud } from "./helper.ts";
    \\function handler(req: Request): Response {
    \\  return Response.text(loud(), { status: 200 });
    \\}
    \\
;

test "run: an implicit-default handler whose imports were not all followed exits 2" {
    const g = try gateOverEditWithHelpers(&incomplete_closure_helpers, incomplete_closure_base, incomplete_closure_head, .json);
    defer g.deinit();
    try testing.expectEqual(@as(u8, 2), g.code);
    try testing.expectEqual(@as(usize, 0), g.report.len);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "UnanalysableSource") != null);
}

test "classifySource: an implicit-default handler is a handler and a failing declared capsule is not analyzable" {
    try testing.expectEqual(
        SourceKind.implicit_handler,
        try classifySource(testing.allocator, implicit_handler_base, "handler.ts"),
    );
    try testing.expectError(
        error.UnanalysableSource,
        classifySource(testing.allocator, declared_failing_base, "handler.ts"),
    );
}

// ---------------------------------------------------------------------------
// A changed helper reaches the handlers that import it
// ---------------------------------------------------------------------------

/// Commit `base_files`, then make the working tree `head_files` (written and
/// staged, over any base file of the same path) minus `removed`, and run the
/// gate against HEAD.
fn gateOverRepos(base_files: []const RepoFile, head_files: []const RepoFile, removed: []const []const u8, format: Format) !GateRun {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const repo_path = path_buf[0..path_len];

    try expectGit(repo_path, &.{ "git", "init", "-q" });
    for (base_files) |file| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file.path, .data = file.data });
        try expectGit(repo_path, &.{ "git", "add", file.path });
    }
    try expectGit(repo_path, &.{ "git", "-c", "user.name=zttp test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base" });
    for (head_files) |file| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file.path, .data = file.data });
        try expectGit(repo_path, &.{ "git", "add", file.path });
    }
    for (removed) |path| try tmp.dir.deleteFile(testing.io, path);

    const old_cwd = try @import("../proof_ledger.zig").chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const code = try run(testing.allocator, .{ .base = "HEAD", .format = format }, &out.writer, &err.writer);
    const report = try testing.allocator.dupe(u8, out.writer.buffered());
    errdefer testing.allocator.free(report);
    const stderr = try testing.allocator.dupe(u8, err.writer.buffered());
    return .{ .code = code, .report = report, .stderr = stderr };
}

const lib_importer =
    \\import { enrich } from "./lib.ts";
    \\function handler(req: Request): Response {
    \\  return Response.text(enrich(), { status: 200 });
    \\}
    \\
;

const lib_pure_upper =
    \\export function enrich(): Proof<string, "injection_safe"> {
    \\  return "pure".toUpperCase();
    \\}
    \\
;

const lib_pure_literal =
    \\export function enrich(): Proof<string, "injection_safe"> {
    \\  return "PURE";
    \\}
    \\
;

const lib_cache_write =
    \\import { cacheSet } from "zttp:cache";
    \\export function enrich(): Proof<string, "injection_safe"> {
    \\  cacheSet("ns", "k", "v", 60);
    \\  return "PURE";
    \\}
    \\
;

const probe_file =
    \\export function probe(n: number): number {
    \\  return n;
    \\}
    \\function handler(req: Request): Response {
    \\  return Response.text("probe", { status: 200 });
    \\}
    \\
;

test "run: a pure helper that gains a cache write breaks the handler that imports it" {
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = lib_importer }, .{ .path = "lib.ts", .data = lib_pure_upper } },
        &.{.{ .path = "lib.ts", .data = lib_cache_write }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"verdict\":\"breaking\"") != null);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"path\":\"handler.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"property\":\"retry_safe\"") != null);
}

test "run: a helper that fails its own analysis is not a root and its importer is compared" {
    const handler =
        \\import { count } from "./lib.ts";
        \\function handler(req: Request): Response {
        \\  return Response.text(String(count()), { status: 200 });
        \\}
        \\
    ;
    const lib_base =
        \\export function count(): number {
        \\  return 1;
        \\}
        \\
    ;
    const lib_head =
        \\import { cacheSet } from "zttp:cache";
        \\export function count(): number {
        \\  cacheSet("ns", "k", "v", 60);
        \\  return 1;
        \\}
        \\
    ;
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = handler }, .{ .path = "lib.ts", .data = lib_base } },
        &.{.{ .path = "lib.ts", .data = lib_head }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "analysis failed for") == null);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"path\":\"handler.ts\"") != null);
}

test "run: a changed helper that no handler imports is skipped as unreferenced" {
    const orphan_base =
        \\export function orphan(): string {
        \\  return "a";
        \\}
        \\
    ;
    const orphan_head =
        \\import { cacheSet } from "zttp:cache";
        \\export function orphan(): string {
        \\  cacheSet("ns", "k", "v", 60);
        \\  return "a";
        \\}
        \\
    ;
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = lib_importer }, .{ .path = "lib.ts", .data = lib_pure_upper }, .{ .path = "orphan.ts", .data = orphan_base } },
        &.{.{ .path = "orphan.ts", .data = orphan_head }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 0), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"handlersChecked\":0") != null);
    try testing.expect(std.mem.indexOf(u8, g.report, "{\"path\":\"orphan.ts\",\"reason\":\"unreferenced_helper\"}") != null);
}

test "run: a change two imports away from a handler reaches the handler" {
    const handler =
        \\import { outer } from "./a.ts";
        \\function handler(req: Request): Response {
        \\  return Response.text(outer(), { status: 200 });
        \\}
        \\
    ;
    const a =
        \\import { inner } from "./b.ts";
        \\export function outer(): string {
        \\  return inner();
        \\}
        \\
    ;
    const b_base =
        \\export function inner(): string {
        \\  return "b";
        \\}
        \\
    ;
    const b_head =
        \\import { cacheSet } from "zttp:cache";
        \\export function inner(): string {
        \\  cacheSet("ns", "k", "v", 60);
        \\  return "b";
        \\}
        \\
    ;
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = handler }, .{ .path = "a.ts", .data = a }, .{ .path = "b.ts", .data = b_base } },
        &.{.{ .path = "b.ts", .data = b_head }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"path\":\"handler.ts\"") != null);
}

test "run: a renamed helper that an importer still names by the old path exits 2" {
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = lib_importer }, .{ .path = "lib.ts", .data = lib_pure_upper } },
        &.{.{ .path = "renamed.ts", .data = lib_pure_upper }},
        &.{"lib.ts"},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 2), g.code);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "analysis failed for `handler.ts`") != null);
}

test "run: a deleted helper that a handler still imports exits 2" {
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = lib_importer }, .{ .path = "lib.ts", .data = lib_pure_upper } },
        &.{},
        &.{"lib.ts"},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 2), g.code);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "analysis failed for `handler.ts`") != null);
}

test "run: a helper change with no effect change lists the importer as compared and exits 0" {
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = lib_importer }, .{ .path = "lib.ts", .data = lib_pure_upper } },
        &.{.{ .path = "lib.ts", .data = lib_pure_literal }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 0), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"handlersChecked\":1") != null);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"path\":\"handler.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"verdict\":\"equivalent\"") != null);
}

test "run: an unchanged file that fails strict checks and imports nothing does not affect a helper verdict" {
    const g = try gateOverRepos(
        &.{
            .{ .path = "handler.ts", .data = lib_importer },
            .{ .path = "lib.ts", .data = lib_pure_upper },
            .{ .path = "probe.ts", .data = probe_file },
        },
        &.{.{ .path = "lib.ts", .data = lib_cache_write }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "probe.ts") == null);
}

test "run: a handler that reaches a changed helper through a chain deeper than the import limit exits 2" {
    const h0 =
        \\import { f1 } from "./c1.ts";
        \\function handler(req: Request): Response {
        \\  return Response.text(f1(), { status: 200 });
        \\}
        \\
    ;
    const c1 = "import { f2 } from \"./c2.ts\";\nexport function f1(): string {\n  return f2();\n}\n";
    const c2 = "import { f3 } from \"./c3.ts\";\nexport function f2(): string {\n  return f3();\n}\n";
    const c3 = "import { f4 } from \"./c4.ts\";\nexport function f3(): string {\n  return f4();\n}\n";
    const c4 = "import { f5 } from \"./c5.ts\";\nexport function f4(): string {\n  return f5();\n}\n";
    const c5 = "import { f6 } from \"./c6.ts\";\nexport function f5(): string {\n  return f6();\n}\n";
    const c6 = "import { f7 } from \"./c7.ts\";\nexport function f6(): string {\n  return f7();\n}\n";
    const c7 = "import { f8 } from \"./c8.ts\";\nexport function f7(): string {\n  return f8();\n}\n";
    const c8 = "import { f9 } from \"./c9.ts\";\nexport function f8(): string {\n  return f9();\n}\n";
    const c9_base = "export function f9(): string {\n  return \"a\";\n}\n";
    const c9_head = "import { cacheSet } from \"zttp:cache\";\nexport function f9(): string {\n  cacheSet(\"ns\", \"k\", \"v\", 60);\n  return \"a\";\n}\n";
    const g = try gateOverRepos(
        &.{
            .{ .path = "handler.ts", .data = h0 },
            .{ .path = "c1.ts", .data = c1 },
            .{ .path = "c2.ts", .data = c2 },
            .{ .path = "c3.ts", .data = c3 },
            .{ .path = "c4.ts", .data = c4 },
            .{ .path = "c5.ts", .data = c5 },
            .{ .path = "c6.ts", .data = c6 },
            .{ .path = "c7.ts", .data = c7 },
            .{ .path = "c8.ts", .data = c8 },
            .{ .path = "c9.ts", .data = c9_base },
        },
        &.{.{ .path = "c9.ts", .data = c9_head }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 2), g.code);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "analysis failed for `handler.ts`") != null);
}

test "run: an unparseable file that names a changed helper stops the gate" {
    const broken = "import { enrich } from \"./lib.ts\";\nfunction handler(\n";
    const g = try gateOverRepos(
        &.{ .{ .path = "lib.ts", .data = lib_pure_upper }, .{ .path = "broken.ts", .data = broken } },
        &.{.{ .path = "lib.ts", .data = lib_cache_write }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 2), g.code);
    try testing.expect(std.mem.indexOf(u8, g.stderr, "cannot read the imports of `broken.ts`") != null);
}

test "run: an unparseable file that names no changed helper does not stop the gate" {
    const broken = "import { other } from \"./other.ts\";\nfunction handler(\n";
    const g = try gateOverRepos(
        &.{ .{ .path = "lib.ts", .data = lib_pure_upper }, .{ .path = "broken.ts", .data = broken } },
        &.{.{ .path = "lib.ts", .data = lib_cache_write }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 0), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "{\"path\":\"lib.ts\",\"reason\":\"unreferenced_helper\"}") != null);
}

test "run: a handler that imports a changed helper without an extension is followed and breaking" {
    const handler =
        \\import { enrich } from "./lib";
        \\function handler(req: Request): Response {
        \\  return Response.text(enrich(), { status: 200 });
        \\}
        \\
    ;
    const g = try gateOverRepos(
        &.{ .{ .path = "handler.ts", .data = handler }, .{ .path = "lib.ts", .data = lib_pure_upper } },
        &.{.{ .path = "lib.ts", .data = lib_cache_write }},
        &.{},
        .json,
    );
    defer g.deinit();
    try testing.expectEqual(@as(u8, 1), g.code);
    try testing.expect(std.mem.indexOf(u8, g.report, "\"path\":\"handler.ts\"") != null);
}
