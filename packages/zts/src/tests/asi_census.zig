//! How much tracked source relies on automatic semicolon insertion.
//!
//! Spec 5.5 mandates no ASI. `expectSemicolon` accepts a missing semicolon
//! unconditionally today, so every file in the repository parses whether or not
//! its statements are terminated. Removing the acceptance is a
//! statement-termination change, and the number of statements that rely on it
//! decides whether the removal is a flip or a migration.
//!
//! This census answers that, per file, over the paths handed to it. It is a
//! measurement rather than a gate: it prints and asserts nothing about the
//! count, because a count with a floor under it would be a claim about a number
//! nobody has established yet.

const std = @import("std");
const parser = @import("../parser/root.zig");
const stripper = @import("../stripper.zig");
const file_io = @import("../file_io.zig");

/// Parse `source` and report how many statements it terminated by insertion.
fn insertionsIn(allocator: std.mem.Allocator, source: []const u8, is_ts: bool, is_tsx: bool) !struct {
    insertions: u32,
    after_rbrace: u32,
    first_line: u32,
} {
    var stripped: ?stripper.StripResult = null;
    defer if (stripped) |*sr| sr.deinit();

    var to_parse = source;
    if (is_ts or is_tsx) {
        stripped = stripper.strip(allocator, source, .{
            .tsx_mode = is_tsx,
            .enable_comptime = true,
            .comptime_env = .{},
        }) catch return .{ .insertions = 0, .after_rbrace = 0, .first_line = 0 };
        to_parse = stripped.?.code;
    }

    var p = try parser.JsParser.init(allocator, to_parse);
    defer p.deinit();
    if (is_tsx) p.enableJsx();
    // The census measures what the old acceptance would have accepted, which
    // is a question the refusing parser cannot answer: it stops at the first
    // unterminated statement.
    p.allow_asi = true;
    _ = p.parse() catch 0;
    return .{
        .insertions = p.asi.required(),
        .after_rbrace = p.asi.after_rbrace,
        .first_line = if (p.asi.first) |loc| loc.line else 0,
    };
}

test "census: how many tracked statements rely on automatic semicolon insertion" {
    const allocator = std.testing.allocator;

    // The tracked corpus, listed rather than globbed: a walk that silently
    // found nothing would report zero reliance, which is the answer this
    // census must never invent.
    const paths = [_][]const u8{
        "examples/autoloop/handler.ts",
        "examples/durable/approval.ts",
        "examples/fetch/weather-app.ts",
        "examples/fetch/weather-forecasts.ts",
        "examples/fetch/webhook.ts",
        "examples/handler/effects-capsule.ts",
        "examples/handler/feature-probes.ts",
        "examples/handler/handler-full.tsx",
        "examples/handler/handler-with-imports.ts",
        "examples/handler/handler.ts",
        "examples/handler/handler.tsx",
        "examples/handler/secret-leak.ts",
        "examples/handler/spec-fails-idempotent.ts",
        "examples/handler/spec-guardrails.ts",
        "examples/handler/sugar.ts",
        "examples/handler/utils.ts",
        "examples/hypermedia/order.ts",
        "examples/jsx/jsx-component.tsx",
        "examples/jsx/jsx-simple.tsx",
        "examples/jsx/jsx-ssr.tsx",
        "examples/modules/modules.ts",
        "examples/modules/modules_all.ts",
        "examples/parallel/parallel-simple.ts",
        "examples/parallel/parallel.ts",
        "examples/patterns/annotate-not-assert.ts",
        "examples/patterns/bytes-boundary.ts",
        "examples/patterns/derive-types.ts",
        "examples/patterns/discriminated-union-match.ts",
        "examples/patterns/infer-and-generics.ts",
        "examples/patterns/json-and-dict.ts",
        "examples/patterns/literal-types-no-enum.ts",
        "examples/patterns/recursive-json-value.ts",
        "examples/patterns/result-combinators.ts",
        "examples/patterns/unknown-and-guards.ts",
        "examples/patterns/validate-external.ts",
        "examples/routing/api-surface.ts",
        "examples/routing/guard-flow.ts",
        "examples/routing/match-handler.ts",
        "examples/routing/router.ts",
        "examples/sql/sql-crud.ts",
        "examples/system/gateway-static.ts",
        "examples/system/gateway.ts",
        "examples/system/orders.ts",
        "examples/system/users.ts",
        "examples/workflow/dsl-orchestrator.ts",
        "examples/workflow/durable-orchestrator.ts",
        "examples/workflow/entry-orchestrator.ts",
        "examples/workflow/fanout-orchestrator.ts",
        "examples/workflow/follow-orchestrator.ts",
        "examples/workflow/greet.ts",
        "examples/workflow/inventory.ts",
        "examples/workflow/orchestrator.ts",
        "examples/workflow/queued-fanout-orchestrator.ts",
        "examples/workflow/queued-orchestrator.ts",
        "examples/workflow/saga-orchestrator.ts",
        "examples/workflow/scope-orchestrator.ts",
        "examples/workflow/timeout-orchestrator.ts",
        "examples/workflow/wait-signal-orchestrator.ts",
    };

    var total: u32 = 0;
    var files_with_insertions: u32 = 0;
    var files_read: u32 = 0;

    for (paths) |path| {
        const source = file_io.readFile(allocator, path, 1 << 20) catch continue;
        defer allocator.free(source);
        files_read += 1;

        const is_tsx = std.mem.endsWith(u8, path, ".tsx");
        const measured = try insertionsIn(allocator, source, std.mem.endsWith(u8, path, ".ts"), is_tsx);
        if (measured.insertions > 0) {
            files_with_insertions += 1;
            std.debug.print(
                "[asi-census] {s}: {d} insertion(s), first at line {d}\n",
                .{ path, measured.insertions, measured.first_line },
            );
        }
        total += measured.insertions;
    }

    std.debug.print(
        "[asi-census] {d} files read, {d} rely on insertion, {d} insertions total\n",
        .{ files_read, files_with_insertions, total },
    );

    // Two floors, both on the INPUT rather than on the answer.
    //
    // The corpus: a census that read no files would print zero reliance and
    // mean nothing. 58 files are tracked; the count is asserted low enough to
    // survive a file being added or removed and high enough to catch a walk
    // that stopped finding them.
    try std.testing.expect(files_read >= 50);

    // The instrument: a counter wired to nothing would also print zero. This
    // source terminates no statement with a semicolon, so a working counter
    // must see several.
    const unterminated =
        \\const a = 1
        \\const b = 2
        \\function f() { return a + b }
        \\const c = f()
    ;
    const probe = try insertionsIn(allocator, unterminated, false, false);
    std.debug.print(
        "[asi-census] instrument check: {d} insertions on 4 unterminated statements\n",
        .{probe.insertions},
    );
    if (probe.insertions < 3) {
        std.debug.print("[asi-census] counter is not wired: {d} insertions on 4 unterminated statements\n", .{probe.insertions});
        return error.CensusInstrumentBroken;
    }
}
