//! expert_codegen_record - live baseline recorder for the codegen eval.
//!
//! Recording spends real tokens, so everything here is gated behind
//! `ZTTP_CODEGEN_RECORD=1` and a live ANTHROPIC_API_KEY; without both, every
//! test skips and the default `zig build test-expert-app` never touches the
//! network. The recorder drives real expert turns (full persona + tool
//! registry) through the live Anthropic client, which tees each roundtrip's SSE
//! body to a per-case cassette. Those cassettes are then committed and replayed
//! deterministically (free) by the offline eval. Recorded once, replayed
//! forever.

const std = @import("std");
const zts = @import("zts");
const anthropic = @import("providers/anthropic/client.zig");
const cassette_client = @import("providers/cassette_client.zig");
const transcript_mod = @import("transcript.zig");
const loop = @import("loop.zig");
const app = @import("app.zig");
const agent = @import("agent.zig");
const codegen = @import("expert_codegen_eval.zig");
const request_mod = @import("providers/anthropic/request.zig");
const IsolatedTmp = @import("test_support/tmp.zig").IsolatedTmp;
const cwdPathAlloc = @import("test_support/cwd.zig").cwdPathAlloc;

const testing = std.testing;

/// Replays a recorded multi-roundtrip session: each model request is served the
/// next committed cassette step (step_0, step_1, ...), parsed through the same
/// assembler the live client uses. The transcript is ignored - the recorded
/// responses are authoritative - so the loop re-executes the recorded tool calls
/// and re-vetoes the recorded edit deterministically and offline.
const CassetteSequenceClient = struct {
    steps: []const []const u8,
    index: usize = 0,

    fn requestFn(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        tr: *const transcript_mod.Transcript,
        extra_user_text: ?[]const u8,
    ) anyerror!loop.ModelCallResult {
        const self: *CassetteSequenceClient = @ptrCast(@alignCast(ctx));
        _ = tr;
        _ = extra_user_text;
        if (self.index >= self.steps.len) return error.CassetteSequenceExhausted;
        const cassette = try cassette_client.loadCassetteFromBytes(arena, self.steps[self.index], null);
        self.index += 1;
        return try cassette_client.replay(arena, cassette);
    }

    pub fn asClient(self: *CassetteSequenceClient) loop.ModelClient {
        return .{ .context = self, .request_fn = requestFn };
    }
};

/// Delete a case's cassette directory (`<out_dir_abs>/<name>`) via its absolute
/// parent, so it works regardless of the current working directory. Best-effort.
fn removeCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return;
    defer parent.close(io);
    parent.deleteTree(io, name) catch {};
}

/// Suffix for a case's stashed cassette while a live recording runs.
const stash_suffix = ".recording-backup";

/// Move a case's committed cassette aside before recording over it.
///
/// The recorder used to delete the directory outright, and its failure path
/// deleted the partial too - so a run that failed left nothing where a working
/// cassette had been. That is survivable only because cassettes are committed,
/// and it has cost the whole corpus once: a full run with every turn failing
/// clears all eleven cases. Stashing makes a failed recording a no-op instead.
///
/// Returns true when a stash was taken, so the caller knows whether there is
/// anything to restore.
fn stashCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) bool {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return false;
    defer parent.close(io);

    const stashed = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, stash_suffix }) catch return false;
    defer allocator.free(stashed);

    // A stash left behind by an interrupted run would block the rename.
    parent.deleteTree(io, stashed) catch {};
    parent.rename(name, parent, stashed, io) catch return false;
    return true;
}

/// Put the stashed cassette back, discarding whatever the failed run wrote.
fn restoreCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return;
    defer parent.close(io);

    const stashed = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, stash_suffix }) catch return;
    defer allocator.free(stashed);

    parent.deleteTree(io, name) catch {};
    parent.rename(stashed, parent, name, io) catch {};
}

/// Drop the stash after a recording that succeeded.
fn dropStashedCaseDir(allocator: std.mem.Allocator, out_dir_abs: []const u8, name: []const u8) void {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    var parent = std.Io.Dir.openDirAbsolute(io, out_dir_abs, .{}) catch return;
    defer parent.close(io);

    const stashed = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, stash_suffix }) catch return;
    defer allocator.free(stashed);
    parent.deleteTree(io, stashed) catch {};
}

/// Read step_0.jsonl, step_1.jsonl, ... from an absolute case directory until a
/// step is missing. Returns an empty slice when the case has no cassette yet.
fn readCaseSteps(allocator: std.mem.Allocator, dir_abs: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (true) : (i += 1) {
        const path = try std.fmt.allocPrint(allocator, "{s}/step_{d}.jsonl", .{ dir_abs, i });
        defer allocator.free(path);
        // An absent step ends the sequence (and an absent step_0 means no
        // cassette); any other read error must surface, not masquerade as "missing".
        const bytes = zts.file_io.readFile(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        try list.append(allocator, bytes);
    }
    return list.toOwnedSlice(allocator);
}

/// Where committed cassettes live, relative to the repo root (the cwd when the
/// recorder runs via `zig build`).
pub const cassette_root = "packages/pi/src/providers/testdata/codegen";

/// Borrowed env-var read (no allocation), mirroring agent.zig's `envVar`:
/// std.process env helpers are not the 0.16 path; std.c.getenv is.
fn envValue(name_z: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name_z) orelse return null;
    const v = std.mem.sliceTo(raw, 0);
    return if (v.len == 0) null else v;
}

fn recordingRequested() bool {
    const flag = envValue("ZTTP_CODEGEN_RECORD") orelse return false;
    return std.mem.eql(u8, flag, "1");
}

// Smoke test: prove the live record-tee writes a cassette that replays to the
// same reply, with a single cheap call, before spending tokens on the full
// corpus. Skipped unless ZTTP_CODEGEN_RECORD=1 and a key is present.
test "record-tee captures a faithful anthropic cassette (live, gated)" {
    const allocator = testing.allocator;
    if (!recordingRequested()) return error.SkipZigTest;
    const key = envValue("ANTHROPIC_API_KEY") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var client = anthropic.Client.init(.{
        .api_key = key,
        .system_prompt = "You are a terse assistant. Reply with exactly one word.",
    });
    client.enableRecording(cassette_root, "_smoke");

    var tr: transcript_mod.Transcript = .{};
    defer tr.deinit(allocator);
    try tr.append(allocator, .{ .user_text = "Say OK." });

    const live = client.sendTurn(a, &tr, null) catch |err| {
        std.debug.print("[codegen-smoke] sendTurn failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // Replay the just-written cassette and confirm it round-trips to a reply.
    const path = cassette_root ++ "/_smoke/step_0.jsonl";
    const cassette = try cassette_client.loadCassetteFromPath(a, path);
    const replayed = try cassette_client.replay(a, cassette);

    const live_kind = std.meta.activeTag(live.reply.response);
    const replay_kind = std.meta.activeTag(replayed.reply.response);
    try testing.expectEqual(live_kind, replay_kind);
    std.debug.print("[codegen-smoke] live and replay agree: {s}\n", .{@tagName(replay_kind)});
}

const RecordCase = struct {
    name: []const u8,
    prompt: []const u8,
    seed_files: []const codegen.SeedFile = &.{},
    /// The recorded first-draft outcome, locked in after recording. The offline
    /// ratchet asserts replay reproduces exactly this, so a case the agent
    /// currently fails is a valid, pinned corpus entry (it feeds the gap
    /// histogram) - not a broken test.
    expect_first_draft_pass: bool = true,
    /// Behaviour the produced handler must exhibit for the case to count as
    /// having done the task. Null leaves the case veto-checked but not
    /// intent-checked, which the summary reports separately rather than
    /// counting as a pass.
    intent: ?codegen.IntentCheck = null,
};

/// The headline model for the published convergence number.
///
/// Derived from the product default rather than written down twice, so the
/// number always describes the model a user actually gets. `ZTTP_CODEGEN_MODEL`
/// overrides it for a cheap harness run (e.g. Haiku) or to record a second row
/// against a different tier.
pub const headline_model = request_mod.default_model;

/// Identity of the frozen prompt corpus.
///
/// A published pass rate means nothing without saying which corpus produced it,
/// and a hand-maintained version number rots the moment someone edits a prompt.
/// This hashes the corpus itself - names, prompts, seed files, and the pinned
/// outcomes - so editing any case changes the version by construction. Same
/// mechanism as `rule_registry.policyHash`, for the same reason.
pub fn corpusVersion() [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (&record_corpus) |*rc| {
        hasher.update(rc.name);
        hasher.update("\x00");
        hasher.update(rc.prompt);
        hasher.update("\x00");
        for (rc.seed_files) |sf| {
            hasher.update(sf.path);
            hasher.update("\x00");
            hasher.update(sf.bytes);
            hasher.update("\x00");
        }
        // The pinned outcome is part of the corpus identity: flipping a case
        // from accepted-failure to expected-pass changes what the rate means.
        hasher.update(&[_]u8{@intFromBool(rc.expect_first_draft_pass)});
        hasher.update("\x00");
        // So is the intent spec: loosening what a case must do changes what a
        // published intent-pass rate is a rate of.
        if (rc.intent) |intent| {
            hasher.update(intent.tests_jsonl);
            hasher.update("\x00");
            hasher.update(intent.handler_path);
            hasher.update("\x00");
            if (intent.zttp_json) |cfg| hasher.update(cfg);
            hasher.update("\x00");
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;
    return out;
}

test "corpus version changes when a case changes" {
    const before = corpusVersion();
    // Same input twice is stable - the hash is a function of the corpus, not
    // of call order or allocation.
    try testing.expectEqualSlices(u8, &before, &corpusVersion());
    // A version that is all zeroes or empty would silently pass the equality
    // above, so assert it looks like a real digest.
    try testing.expectEqual(@as(usize, 64), before.len);
    var nonzero = false;
    for (before) |c| {
        if (c != '0') nonzero = true;
    }
    try testing.expect(nonzero);
}

// The corpus spans common tasks the agent handles cleanly and harder ones that
// probe known gap areas (user-input egress, websocket events, durable
// workflows). Each elicits realistic multi-roundtrip behaviour (explore then
// edit) and records as step_0/step_1/...
//
// Ten of the sixteen carry an intent spec. The five durable and workflow cases
// do not: executing them needs the durable store and queue the runtime stands
// up, and `zttp test` has no offline story for either - `saga()` fails with
// NativeFunctionError before any assertion runs, and an io stub does not
// intercept it. Those cases stay veto-checked and report `.not_checked`, which
// the summary counts apart from passes, so the published figure reads 10 of 16
// covered instead of pretending to 16. Closing that gap means giving the test
// runner a durable backend, which is its own piece of work.
//
// `parallel-secret` is the sixth without a spec, for a different reason given
// at the case.
//
// The last five cases were added because eleven could not separate nine
// consecutive builds - every row read 90%, which was the corpus reporting its
// own resolution rather than the compiler holding still. Each targets one fence
// docs/convergence.md names as invisible to the original eleven: none of them
// logged a timestamp, none returned a value read from a store, none wrote the
// shapes the flow-checker fail-opens hid behind. A fence no case stands on
// cannot move a number.
const record_corpus = [_]RecordCase{
    .{
        .name = "health",
        .prompt = "Create a handler in handler.ts that responds to GET /health with " ++
            "Response.json({ ok: true }). Keep it minimal and deterministic.",
        .expect_first_draft_pass = true,
        // Asserts the task the prompt names, not the shape of one recording: a
        // different-but-correct handler must still pass, or the check measures
        // the cassette instead of the model.
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"GET /health reports ok"}
            \\{"type":"request","method":"GET","url":"/health","headers":{},"body":""}
            \\{"type":"expect","status":200,"bodyContains":"\"ok\":true"}
            \\
            ,
        },
    },
    .{
        .name = "validate-body",
        .prompt = "Create a handler in handler.ts that decodes the JSON request body with " ++
            "zttp:validate against a schema named \"item\" requiring a string field \"name\", " ++
            "returns the validated data on success, and returns a 400 with the errors on failure.",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a body missing name is rejected"}
            \\{"type":"request","method":"POST","url":"/","headers":{"content-type":"application/json"},"body":"{}"}
            \\{"type":"expect","status":400}
            \\
            ,
        },
        // The corpus's one accepted failure, and the reason the published
        // first-draft rate reads 10/11 rather than 11/11.
        //
        // The first draft writes `result.value as Item`, and the subset has no
        // `as`: the stripper rejects it as ZTS042, which is what the
        // [codegen-gap] histogram prints. The case still reaches green - the
        // model drops the assertion on retry - so it is a first-draft failure,
        // not a broken case.
        //
        // The teaching gap this ranks is therefore `as`, not the shape of
        // `validateJson().errors`. The draft does also declare
        // `errors: string[]` where the value is statically `unknown`, but the
        // veto reports the assertion first and the model never reaches the
        // type mismatch. An earlier version of this comment named ZTS200 and
        // that second gap; it described a draft this cassette no longer holds.
        .expect_first_draft_pass = true,
    },
    .{
        .name = "jwt-auth",
        .prompt = "Create a handler in handler.ts that requires a bearer JWT using zttp:auth " ++
            "with the secret from env JWT_SECRET, returns 401 when the token is missing or invalid, " ++
            "and otherwise returns the verified claims as JSON. Never use a fallback secret.",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a request with no bearer token is unauthorized"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":401}
            \\
            ,
        },
        // Was ZTS401 (credential in response). The recorded handler had
        // evaded it by round-tripping the claims through
        // JSON.stringify/JSON.parse, which the taint tracker used to treat as
        // laundering the `credential` label. That laundering hole was closed
        // (flow_checker now propagates labels through member/JSON calls), so
        // returning the raw claims correctly flags ZTS401 again. The cassette's
        // applied handler was hand-corrected to return a non-sensitive
        // confirmation (`{ authenticated: true }`) instead of the raw claims;
        // returning any claim field (even `result.value.sub`) stays credential
        // labelled and would leak. Re-record from a live model to refresh.
        .expect_first_draft_pass = false,
    },
    .{
        .name = "weather-egress",
        .prompt = "Create a handler in handler.ts that reads a `city` query parameter and " ++
            "fetches the current weather for that city from https://api.open-meteo.com/v1/forecast " ++
            "using zttp:fetch, returning the JSON response.",
        // The success path needs egress, which the offline replay has no way to
        // serve. The missing-parameter path is the part of the task that can be
        // demonstrated without a network, so that is what this asserts.
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a request with no city is rejected"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":400}
            \\
            ,
        },
        // Was ZTS602 (never converged); closed by the literal-URL + init-query
        // egress teaching.
        .expect_first_draft_pass = true,
    },
    .{
        .name = "websocket-echo",
        // The runtime owns the upgrade, not the handler: server.zig:634-635
        // upgrades only when the request carries an RFC 6455 upgrade and the
        // contract exports onMessage, and it writes the 101 itself
        // (server.zig:1173). A header-less GET never upgrades, so it reaches
        // the handler.
        //
        // This check used to send `"headers":{}` and assert 101, which only a
        // handler hardcoding `{ status: 101 }` could satisfy - claiming a
        // protocol switch on every plain GET. It rewarded a bug, and nothing
        // model-facing taught 101: it appears only in docs/reliability.md and
        // an archived plan, and the websocket example is not among the four
        // vendored under skills/zts-expert/examples. A recorded pass on it was
        // luck.
        //
        // The non-upgrade status is a convention, so the prompt states it
        // rather than leaving the model to guess. 404 matches
        // examples/websocket/chat.ts:48.
        .prompt = "Create a WebSocket echo handler in handler.ts using zttp:websocket that " ++
            "echoes every received message back to the sending client. " ++
            "Return 404 for a request that is not a WebSocket upgrade.",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"a non-upgrade request does not claim a protocol switch"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":404}
            \\
            ,
        },
        .expect_first_draft_pass = true,
    },
    .{
        .name = "durable-order",
        .prompt = "Create a durable handler in handler.ts using zttp:durable that runs a " ++
            "two-step order workflow: a `reserve` step then a `charge` step, via run() and step().",
        // Was ZTS042/narrowing death-spiral (never converged); closed by the
        // "use untyped values directly, never narrow with as/guards" teaching.
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-queued-call",
        .prompt = "Create a durable workflow handler in handler.ts using zttp:durable and " ++
            "zttp:workflow. It should read the Idempotency-Key header, enter run(key), " ++
            "and dispatch a greet child handler with workflow.call at durable depth 0.",
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-nested-dispatch-avoidance",
        .prompt = "Create a durable order workflow in handler.ts. Reserve inventory with a " ++
            "durable step, then dispatch a notify child handler with workflow.call after the " ++
            "step completes. Keep the child dispatch outside the step callback.",
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-saga-compensation",
        .prompt = "Create a handler in handler.ts using zttp:workflow saga() for reserve, " ++
            "charge, and ship steps. Include compensate functions for every non-last static " ++
            "saga step so the saga compensation proof can pass.",
        .expect_first_draft_pass = true,
    },
    .{
        .name = "workflow-wait-signal",
        .prompt = "Create a durable approval workflow in handler.ts using waitSignal and " ++
            "signal. The /wait path should park a run using the Idempotency-Key header, and " ++
            "the /signal path should resume the same key with an approved payload.",
        .expect_first_draft_pass = true,
    },
    .{
        .name = "sql-users",
        .prompt = "Create a handler in handler.ts that returns all users (id and name) from " ++
            "the sqlite database using zttp:sql. The users table has columns id (integer) " ++
            "and name (text).",
        // Seeds the project SQL schema the veto discovers via zttp.json's
        // `sqlite` key (resolved relative to the workspace).
        .seed_files = &.{
            .{ .path = "zttp.json", .bytes = "{\n  \"sqlite\": \"schema.sql\"\n}\n" },
            .{ .path = "schema.sql", .bytes = "CREATE TABLE users (\n  id INTEGER PRIMARY KEY,\n  name TEXT NOT NULL\n);\n" },
        },
        // Supplies its own config: the seeded `sqlite` key is what the veto and
        // the runtime resolve the schema through, and synthesizing a
        // handler-only zttp.json over the top would drop it. The row comes from
        // an io stub rather than a seeded database - the task is to query and
        // shape the response, and stubbing the store is what the spec format is
        // for. Asserting on the stubbed value also proves the rows reach the
        // body, which asserting on the literal "users" would not.
        .intent = .{
            .zttp_json = "{\n  \"entry\": \"handler.ts\",\n  \"sqlite\": \"schema.sql\"\n}\n",
            .tests_jsonl =
            \\{"type":"test","name":"queried rows reach the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"sql","fn":"sqlMany","args":["list_users"],"result":[{"id":1,"name":"ada"}]}
            \\{"type":"expect","status":200,"bodyContains":"ada"}
            \\
            ,
        },
        // Recorded with the best model (Sonnet): writes correct SQL, self-checks
        // cleanly, and first-draft-passes. Previously it failed because the
        // property analysis reported read_only as PROVEN for a SELECT and the
        // agent declared it (then ZTS501 rejected it); the classifier now gates
        // declarable read_only on write-effect imports, so the agent is no
        // longer told to declare a property the import forbids.
        .expect_first_draft_pass = true,
    },
    .{
        // Fence: the `deterministic` loosening. The property moved from "was a
        // varying value read" to "does one reach the response", so a handler
        // that logs a clock read and returns a constant keeps it. No case in the
        // original eleven read a clock at all, so that change was invisible
        // here. Verified against the analyzer before recording: this shape
        // proves `deterministic`.
        //
        // The intent spec asserts the body exactly rather than by substring. The
        // whole point is that the timestamp stays out of it, and `bodyContains`
        // would pass a handler that put the clock read in the response too -
        // which is the failure this case exists to catch.
        .name = "log-timestamp",
        .prompt = "Create a handler in handler.ts that logs when it served the request, " ++
            "including the current time from Date.now(), using logInfo from zttp:log. " ++
            "The response body must be exactly Response.json({ ok: true }) - the " ++
            "timestamp belongs in the log and must never appear in the response.",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the timestamp stays out of the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"expect","status":200,"body":"{\"ok\":true}"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
    },
    .{
        // Fence: a read from mutable module state is its own varying source,
        // which no capability set can express. Before that rule the handler
        // below proved `deterministic` while returning whatever the last write
        // left in the store. The corpus had nothing that read a store into a
        // response, so the tightening moved nothing.
        //
        // The prompt does not mention determinism or Spec. Noticing that a store
        // read costs the default profile and narrowing the Spec accordingly is
        // the model behaviour being measured; saying it in the prompt would
        // measure instruction-following instead.
        .name = "cache-counter",
        .prompt = "Create a handler in handler.ts that reads the \"hits\" counter from the " ++
            "\"counters\" namespace with cacheGet from zttp:cache and returns it as JSON " ++
            "under a \"hits\" key. Treat a missing counter as \"0\".",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the stored counter reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"cache","fn":"cacheGet","args":["counters","hits"],"result":"41"}
            \\{"type":"expect","status":200,"bodyContains":"41"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
    },
    .{
        // Fence: labels crossing a module boundary through a caller's callback.
        // `parallel([() => env("SECRET_KEY")])` used to prove clean, because a
        // module export answers with its declared return labels and those cannot
        // describe what a caller's callback produced. See
        // docs/solutions/security-issues/empty-label-set-claimed-a-value-was-clean.md.
        //
        // Pinned as a first-draft failure, and unlike jwt-auth the cause is not
        // the model. The fix over-approximates in the other direction: the array
        // `parallel` returns carries the union of every callback's labels, and
        // indexing does not narrow back, so returning `values[0]` - the app name
        // - is refused for what `values[1]` read. Isolated before recording:
        // direct `env` reads with the secret held in a local are clean, and two
        // non-secret callbacks are clean, so it is specifically the result
        // array. The polarity is the safe one, and it costs a legitimate
        // program.
        //
        // That makes this the most useful kind of pinned case: it flips the day
        // the indexing narrows, which is a fence the corpus can then see move.
        // No intent spec - the case does not converge to a handler, and a spec
        // with nothing to run against reports `.failed`, which would read as the
        // handler doing the wrong thing rather than never existing.
        .name = "parallel-secret",
        .prompt = "Create a handler in handler.ts that reads the APP_NAME and API_SECRET " ++
            "environment variables concurrently using parallel() from zttp:io. Return 503 " ++
            "when API_SECRET is not set. Otherwise return Response.json with only the app " ++
            "name - the secret must never appear in the response.",
        .expect_first_draft_pass = false,
    },
    .{
        // Fence: the shapes of egress options object the flow checker could not
        // read field by field. `weather-egress` passes its query through the
        // init object, but nothing in the corpus set a method and headers there.
        //
        // It also carries the intent spec `weather-egress` says cannot exist.
        // That comment predates the fetch io stub: runtime_http.zig serves
        // `{"module":"fetch","fn":"fetch"}` from the replay state, so the
        // success path is assertable offline. Checked before recording - a stub
        // with the wrong body fails the assertion, so it is load-bearing.
        .name = "egress-options",
        .prompt = "Create a handler in handler.ts that calls " ++
            "https://api.example.com/v1/status with fetch from zttp:fetch, passing an init " ++
            "object that sets the method to GET and an \"accept: application/json\" header. " ++
            "Return the upstream JSON on success and a 502 when the upstream call fails.",
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the upstream payload reaches the response body"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"fetch","fn":"fetch","args":["https://api.example.com/v1/status"],"result":{"status":200,"body":"{\"state\":\"green\"}"}}
            \\{"type":"expect","status":200,"bodyContains":"green"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
    },
    .{
        // Fence: walking a helper imported from a sibling file. Every other case
        // is a single file, so the cross-file label walk had nothing here to
        // stand on. The seeded helper returns a secret from one export and a
        // plain string from the other, so the walk has to distinguish them
        // rather than tainting the module.
        //
        // Verified before recording: returning `apiToken()` trips ZTS400 through
        // the import, and returning only `displayName()` is clean. The intent
        // spec pins the body exactly, so a handler that also returns the token
        // fails the check even in a build where the label walk does not.
        .name = "sibling-helper",
        .prompt = "The file lib/settings.ts already exists and exports displayName() and " ++
            "apiToken(). Create a handler in handler.ts that imports both from " ++
            "\"./lib/settings.ts\", returns 503 when apiToken() is undefined, and otherwise " ++
            "returns Response.json({ name: displayName() }). The token must never appear " ++
            "in the response.",
        .seed_files = &.{
            .{
                .path = "lib/settings.ts",
                .bytes =
                \\import { env } from "zttp:env";
                \\
                \\export function apiToken(): string | undefined {
                \\  return env("API_TOKEN");
                \\}
                \\
                \\export function displayName(): string {
                \\  return env("APP_NAME") ?? "unnamed";
                \\}
                \\
                ,
            },
        },
        .intent = .{
            .tests_jsonl =
            \\{"type":"test","name":"the configured name crosses the file boundary and the token does not"}
            \\{"type":"request","method":"GET","url":"/","headers":{},"body":""}
            \\{"type":"io","seq":0,"module":"env","fn":"env","args":["API_TOKEN"],"result":"tok-secret-value"}
            \\{"type":"io","seq":1,"module":"env","fn":"env","args":["APP_NAME"],"result":"orders-api"}
            \\{"type":"expect","status":200,"body":"{\"name\":\"orders-api\"}"}
            \\
            ,
        },
        .expect_first_draft_pass = true,
    },
};

// Record the real expert agent against the corpus and report the live baseline.
// Gated: ZTTP_CODEGEN_RECORD=1 + a live key. Each case runs in its own tmp
// workspace with cwd switched to it, so the agent's tools and the edit veto
// resolve the same files; cassettes are written to an absolute repo path so the
// chdir does not misplace them. ZTTP_CODEGEN_LIMIT caps the case count for a
// cheap small-scale validation before the full run.
test "record codegen baseline corpus (live, gated)" {
    if (!recordingRequested()) return error.SkipZigTest;
    if (envValue("ANTHROPIC_API_KEY") == null) return error.SkipZigTest;
    // A live recording driver, not a memory-correctness test: use an arena over
    // the page allocator so the strict test allocator's leak check does not flag
    // the live HTTP/TLS stack (which the deterministic tests never exercise).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try app.buildRegistry(allocator);
    defer registry.deinit(allocator);
    // The published number describes the model a user actually gets, so the
    // corpus records against the product default rather than a hand-picked
    // tier - see `headline_model`. ZTTP_CODEGEN_MODEL overrides it (e.g. Haiku)
    // for cheap harness testing, or to record a second row against another
    // tier. Env strings live for the process, so the borrowed slice is safe.
    const corpus_model = envValue("ZTTP_CODEGEN_MODEL") orelse headline_model;
    var session = try agent.initFromEnvWithSessionConfig(allocator, &registry, .{
        .no_session = true,
        .no_context_files = true,
        .model = corpus_model,
    });
    defer session.deinit(allocator);
    if (session.authKind() != .anthropic_api_key) return error.SkipZigTest;
    // ZTTP_CODEGEN_ONLY=<name> records just one case, leaving the others'
    // committed cassettes untouched.
    const only_case = envValue("ZTTP_CODEGEN_ONLY");

    const repo_root = try cwdPathAlloc(allocator);
    defer allocator.free(repo_root);
    const out_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, cassette_root });
    defer allocator.free(out_dir);

    var limit: usize = record_corpus.len;
    if (envValue("ZTTP_CODEGEN_LIMIT")) |lim| {
        limit = std.fmt.parseInt(usize, lim, 10) catch limit;
    }

    var first_draft_passes: usize = 0;
    var greens: usize = 0;
    var total: usize = 0;
    for (record_corpus, 0..) |rc, i| {
        if (i >= limit) break;
        if (only_case) |only| {
            if (!std.mem.eql(u8, only, rc.name)) continue;
        }
        total += 1;

        var tmp = try IsolatedTmp.init(allocator, "codegen-record");
        defer tmp.cleanup(allocator);
        for (rc.seed_files) |sf| try tmp.writeFile(allocator, sf.path, sf.bytes);

        // Move the committed cassette aside rather than deleting it. A shorter
        // new recording, or a mid-turn failure, must not leave stale trailing
        // steps that would corrupt replay - and a failed run must not leave the
        // case with nothing, which deleting up front used to do.
        const stashed = stashCaseDir(allocator, out_dir, rc.name);
        removeCaseDir(allocator, out_dir, rc.name);

        const saved_cwd = try cwdPathAlloc(allocator);
        defer allocator.free(saved_cwd);
        try std.Io.Threaded.chdir(tmp.abs_path);
        defer std.Io.Threaded.chdir(saved_cwd) catch {};

        session.backend.anthropic.enableRecording(out_dir, rc.name);

        var tr: transcript_mod.Transcript = .{};
        defer tr.deinit(allocator);
        const result = loop.runTurnWith(allocator, session.modelClient(), &registry, &tr, rc.prompt, .{
            .workspace_root = ".",
            .max_attempts = loop.interactive_max_attempts,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        }) catch |err| {
            // A transient live error (e.g. a network ReadFailed) on one case
            // must not abort the whole corpus run; skip and keep recording the
            // rest. Remove the partial cassette so replay never reads a
            // truncated step sequence.
            std.debug.print("[codegen-record] {s}: turn failed: {s} (skipped)\n", .{ rc.name, @errorName(err) });
            removeCaseDir(allocator, out_dir, rc.name);
            if (stashed) {
                restoreCaseDir(allocator, out_dir, rc.name);
                std.debug.print("[codegen-record] {s}: previous cassette restored\n", .{rc.name});
            }
            continue;
        };
        // The turn produced a cassette, so the stash is no longer needed.
        if (stashed) dropStashedCaseDir(allocator, out_dir, rc.name);
        if (result.first_draft_veto_pass) first_draft_passes += 1;
        if (result.applied_edit) greens += 1;
        const fail_code = codegen.firstZtsCode(&tr) orelse "-";
        std.debug.print(
            "[codegen-record] {s}: first_draft_pass={} applied={} compiler_authored={} roundtrips={d} retries={d} tools={d} steps={d} fail={s}\n",
            .{
                rc.name,
                result.first_draft_veto_pass,
                result.applied_edit,
                result.compiler_authored_apply,
                result.roundtrips,
                result.veto_retry_count,
                result.tool_call_count,
                session.backend.anthropic.record_step,
                fail_code,
            },
        );
    }
    std.debug.print(
        "[codegen-record] BASELINE first-draft pass: {d}/{d}; reached-green: {d}/{d}\n",
        .{ first_draft_passes, total, greens, total },
    );
}

// Offline ratchet: replay every committed cassette through the real veto and
// require it still passes on the first draft. Runs in normal CI (no network, no
// key): it reproduces the recorded baseline deterministically and fails if a
// compiler/policy change would make a previously-clean recorded edit regress.
// Uses an arena over the page allocator (the replay executes the full tool +
// veto stack; this is a fidelity check, not a leak test).
test "codegen baseline replays at the committed first-draft pass rate" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const repo_root = try cwdPathAlloc(a);
    const codegen_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ repo_root, cassette_root });

    var registry = try app.buildRegistry(a);
    defer registry.deinit(a);

    // Located before the per-case chdir: the binary lives in the repo, and the
    // cases run in tmp workspaces.
    const zttp_bin = codegen.locateZttpBinary(a, repo_root);

    var passes: usize = 0;
    var intent_passes: usize = 0;
    var intent_checked: usize = 0;
    var results: std.ArrayList(codegen.CaseResult) = .empty;
    defer results.deinit(a);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(a);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(a);
    for (record_corpus) |rc| {
        const dir_abs = try std.fmt.allocPrint(a, "{s}/{s}", .{ codegen_dir, rc.name });
        // Read the cassette steps from the repo (absolute) BEFORE chdir. A real
        // read error propagates; an absent cassette yields no steps and is
        // collected so the whole set is reported at once instead of aborting
        // on the first missing case.
        const steps = try readCaseSteps(a, dir_abs);
        if (steps.len == 0) {
            try missing.append(a, rc.name);
            continue;
        }

        var tmp = try IsolatedTmp.init(a, "codegen-replay");
        defer tmp.cleanup(a);
        for (rc.seed_files) |sf| try tmp.writeFile(a, sf.path, sf.bytes);

        const saved_cwd = try cwdPathAlloc(a);
        try std.Io.Threaded.chdir(tmp.abs_path);
        defer std.Io.Threaded.chdir(saved_cwd) catch {};

        var client: CassetteSequenceClient = .{ .steps = steps };
        var tr: transcript_mod.Transcript = .{};
        // A cassette that no longer covers its turn is collected, not thrown.
        // Returning at the first stale case means a compiler change that
        // invalidates several is discovered one paid recording at a time; the
        // whole re-record list is worth more than the early exit.
        const result = loop.runTurnWith(a, client.asClient(), &registry, &tr, rc.prompt, .{
            .workspace_root = ".",
            .max_attempts = loop.interactive_max_attempts,
            .approval_fn = loop.ApprovalFn.fromFn(loop.autoApprove),
            .replay_mode = false,
            .turn_timeout_ms = 0,
        }) catch |err| {
            try stale.append(a, rc.name);
            std.debug.print(
                "[codegen-replay] {s}: {s} - its {d}-step cassette no longer covers the turn\n",
                .{ rc.name, @errorName(err), steps.len },
            );
            continue;
        };
        // Ratchet: replay must reproduce the recorded first-draft outcome
        // exactly. A regression flips a recorded pass to fail (or vice versa).
        if (result.first_draft_veto_pass != rc.expect_first_draft_pass) {
            std.debug.print(
                "[codegen-replay] {s}: expected first_draft_pass={} got {} (code {s})\n",
                .{ rc.name, rc.expect_first_draft_pass, result.first_draft_veto_pass, codegen.firstZtsCode(&tr) orelse "-" },
            );
            return error.CassetteRatchetMismatch;
        }
        var case_intent: codegen.IntentOutcome = .not_checked;

        // Intent: does the produced handler do what the prompt asked for? Run
        // after the turn, against whatever it actually wrote. A case with no
        // spec, or a run with no built binary, stays `.not_checked` - never a
        // pass, so an unmeasured corpus reads as unmeasured.
        if (rc.intent) |intent| {
            if (zttp_bin) |bin| {
                case_intent = codegen.runIntentCheck(a, intent, tmp.abs_path, bin);
                if (case_intent == .passed) intent_passes += 1 else {
                    std.debug.print("[codegen-intent] {s}: handler did not do the task\n", .{rc.name});
                }
                intent_checked += 1;
            }
        }

        // Gap histogram: the first rule each non-passing case tripped, ranking
        // which teaching gap to close next.
        if (!rc.expect_first_draft_pass) {
            std.debug.print("[codegen-gap] {s}: {s} (green={})\n", .{
                rc.name,
                codegen.firstZtsCode(&tr) orelse "?",
                result.applied_edit,
            });
        }
        try results.append(a, .{
            .name = rc.name,
            .routed = true,
            .first_draft_pass = result.first_draft_veto_pass,
            .applied = result.applied_edit,
            .passed_criterion = result.first_draft_veto_pass,
            .roundtrips = result.roundtrips,
            .tool_calls = result.tool_call_count,
            .proven_guarantees = result.proven_guarantees,
            .intent = case_intent,
        });
        passes += 1;
    }

    if (stale.items.len > 0) {
        std.debug.print("[codegen-replay] {d} cassette(s) need re-recording:\n", .{stale.items.len});
        for (stale.items) |name| std.debug.print("  - {s}\n", .{name});
        std.debug.print(
            "  ZTTP_CODEGEN_RECORD=1 ZTTP_CODEGEN_ONLY=<name> zig build test-expert-app -Dtest-filter=\"record codegen baseline corpus\"\n",
            .{},
        );
        return error.StaleCodegenCassette;
    }

    if (missing.items.len > 0) {
        std.debug.print("[codegen-replay] missing committed cassette(s) for {d} case(s):\n", .{missing.items.len});
        for (missing.items) |name| std.debug.print("  - {s}\n", .{name});
        std.debug.print(
            "  record with: ZTTP_CODEGEN_RECORD=1 zig build test-expert-app -Dtest-filter=\"record codegen baseline corpus\"\n" ++
                "  (the filter is a build option; `-- --test-filter` is dropped and records the whole corpus)\n",
            .{},
        );
        return error.MissingCodegenCassette;
    }
    try testing.expectEqual(record_corpus.len, passes);

    // The publishable record of this run, on one line so
    // scripts/update-convergence.sh can lift it without parsing the rest of the
    // test output. Emitted every run, including when intent checks were
    // skipped - a row that says `intentChecked: 0` is honest; a missing row
    // would just look like the eval was not run.
    const summary = codegen.summarize(results.items);
    const version = corpusVersion();
    std.debug.print(
        "[codegen-convergence] {{\"corpusVersion\":\"{s}\",\"corpusCases\":{d}," ++
            "\"model\":\"{s}\",\"policyHash\":\"{s}\",\"firstDraftPassPercent\":{d}," ++
            "\"firstDraftPasses\":{d},\"medianRoundtrips\":{d},\"intentPassPercent\":{d}," ++
            "\"intentPasses\":{d},\"intentChecked\":{d}}}\n",
        .{
            version[0..],
            summary.total,
            headline_model,
            zts.rule_registry.policyHash()[0..],
            summary.firstDraftPassPercent(),
            summary.first_draft_passes,
            summary.median_roundtrips,
            summary.intentPassPercent(),
            summary.intent_passes,
            summary.intent_checked,
        },
    );

    if (zttp_bin == null) {
        std.debug.print(
            "[codegen-intent] zig-out/bin/zttp is not built; intent checks skipped this run\n",
            .{},
        );
    } else {
        std.debug.print(
            "[codegen-intent] {d}/{d} intent-checked cases did the task\n",
            .{ intent_passes, intent_checked },
        );
        // Every case carrying a spec must satisfy it. The spec asserts the task
        // the prompt asked for, not the shape of one recording, so a failure
        // here means the recorded handler does not do the job - which is the
        // thing the veto cannot tell us and the whole reason this check exists.
        try testing.expectEqual(intent_checked, intent_passes);
    }
}

test "a failed recording restores the previous cassette" {
    // The recorder deletes the case directory before recording over it, and its
    // failure path deletes the partial too. Without a stash a failed run leaves
    // the case with nothing where a working cassette had been - which has
    // wiped the corpus once, recoverable only because cassettes are committed.
    const allocator = testing.allocator;

    var tmp = try IsolatedTmp.init(allocator, "codegen-stash");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "case/step_0.jsonl", "{\"sse\":\"original\"}\n");

    // Stash, then clear, as the recorder does before a live turn.
    try testing.expect(stashCaseDir(allocator, tmp.abs_path, "case"));
    removeCaseDir(allocator, tmp.abs_path, "case");

    const cleared = try tmp.childPath(allocator, "case/step_0.jsonl");
    defer allocator.free(cleared);
    try testing.expect(!zts.file_io.fileExists(allocator, cleared));

    // The turn fails: restore.
    restoreCaseDir(allocator, tmp.abs_path, "case");

    const restored = try zts.file_io.readFile(allocator, cleared, 4096);
    defer allocator.free(restored);
    try testing.expectEqualStrings("{\"sse\":\"original\"}\n", restored);

    // The stash itself is gone, so a later run does not trip over it.
    const leftover = try tmp.childPath(allocator, "case" ++ stash_suffix ++ "/step_0.jsonl");
    defer allocator.free(leftover);
    try testing.expect(!zts.file_io.fileExists(allocator, leftover));
}

test "a successful recording drops the stash" {
    const allocator = testing.allocator;

    var tmp = try IsolatedTmp.init(allocator, "codegen-stash-ok");
    defer tmp.cleanup(allocator);
    try tmp.writeFile(allocator, "case/step_0.jsonl", "{\"sse\":\"old\"}\n");

    try testing.expect(stashCaseDir(allocator, tmp.abs_path, "case"));
    removeCaseDir(allocator, tmp.abs_path, "case");
    // The turn succeeds and writes a new cassette.
    try tmp.writeFile(allocator, "case/step_0.jsonl", "{\"sse\":\"new\"}\n");
    dropStashedCaseDir(allocator, tmp.abs_path, "case");

    const current = try tmp.childPath(allocator, "case/step_0.jsonl");
    defer allocator.free(current);
    const bytes = try zts.file_io.readFile(allocator, current, 4096);
    defer allocator.free(bytes);
    try testing.expectEqualStrings("{\"sse\":\"new\"}\n", bytes);

    const leftover = try tmp.childPath(allocator, "case" ++ stash_suffix ++ "/step_0.jsonl");
    defer allocator.free(leftover);
    try testing.expect(!zts.file_io.fileExists(allocator, leftover));
}
