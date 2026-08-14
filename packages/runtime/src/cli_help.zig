//! Top-level `zttp` help surfaces: the default five-verb screen, the full
//! `help --all` advanced listing, and the `expert` help. Split out of
//! dev_cli.zig; dev_cli.main calls these and the per-command help printers
//! live with their own command modules.

const std = @import("std");
const zts_cli = @import("zts_cli");

/// One `zttp`-owned command, as both the dispatcher and the `help --all`
/// listing see it. The analyzer commands are not here: they live in
/// `zts_cli.commands`, which both binaries already share.
///
/// `run` is what makes this a dispatch table rather than a second copy of the
/// help text. Each entry's wrapper owns that command's argument handling, its
/// error-to-exit-code mapping, and its own `--help`, because measured, no two
/// of them agree on any of the three.
pub const Command = struct {
    name: []const u8,
    /// A second spelling that dispatches to the same wrapper (`--version`).
    alias: ?[]const u8 = null,
    run: *const fn (Ctx) anyerror!void,
    section: Section,
    /// Argument hint in the listing. Empty for a bare verb.
    args: []const u8 = "",
    /// One-line description in the listing.
    blurb: []const u8 = "",
    /// Stored provider keys are injected into the environment before this
    /// command runs. The expert agent is the only consumer; handler execution
    /// paths must see the caller's explicit environment.
    injects_stored_providers: bool = false,
};

/// What a command wrapper is handed. A struct rather than three parameters so
/// adding a fourth does not churn every entry.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    /// Arguments after the command name.
    args: []const []const u8,
    environ: std.process.Environ,
    /// The name as typed, for diagnostics that quote it back.
    command: []const u8,
    /// argv[0], which `dev`, `studio`, and `demo` re-exec.
    argv0: []const u8,
};

pub const Section = enum {
    core,
    run_and_inspect,
    package,
    proof_ledger,
    credentials,
    advanced,
    /// Dispatchable, never listed.
    unlisted,
};

pub fn hasAllFlag(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "all")) return true;
    }
    return false;
}

/// The default `zttp --help` surface: only the five core verbs. Everything
/// else lives behind `zttp help --all` (`core_help_all`).
const core_help =
    \\zttp - serverless JavaScript runtime
    \\
    \\Commands:
    \\  zttp init <name>     Create a project
    \\  zttp dev             Run locally, watch and prove on every save
    \\  zttp test            Run handler tests
    \\  zttp expert          Interactive compiler-in-the-loop agent
    \\  zttp deploy          Build, prove, and deploy (local by default)
    \\
    \\Get started:
    \\  zttp init my-app && cd my-app
    \\  zttp dev
    \\
    \\Run `zttp help --all` for advanced commands.
    \\
;

pub fn printHelp() void {
    _ = std.c.write(std.c.STDOUT_FILENO, core_help.ptr, core_help.len);
}

// `help --all` is rendered in three static spans with the two analyzer
// sections generated from `zts_cli.commands` between them, so the developer
// CLI advertises exactly the surface `zts` dispatches (no hand-maintained
// duplicate list to drift). The `.analyze` lines follow `help_all_head`; the
// `.machine` lines follow `help_all_mid`.
const help_all_head =
    \\zttp - serverless JavaScript runtime
    \\
    \\Core commands:
    \\  zttp init <name> [--template basic|api|htmx]  Create a project
    \\  zttp dev [handler.ts]                Run locally, watch and prove on save
    \\  zttp test [tests.jsonl]              Run handler tests
    \\  zttp expert                          Interactive compiler-in-the-loop agent
    \\  zttp deploy                          Build, prove, deploy (local default)
    \\
    \\Analyze:
    \\
;

const help_all_mid =
    \\
    \\Run and inspect:
    \\  zttp serve [handler.ts]              Run a handler without watch or proof
    \\  zttp doctor [path]                   Check project readiness
    \\  zttp studio [handler.ts]             Optional browser proof workbench
    \\  zttp demo                            Guided local proof theater
    \\  zttp edge [--config FILE]            Optional in-process edge runtime (-Dedge)
    \\  zttp workflow-queue [list|show|replay|discard] --durable <DIR>
    \\                                            Inspect workflow queue dead letters
    \\  zttp durable dead-runs [list|show|replay|discard] --durable <DIR>
    \\                                            Inspect durable runs that permanently failed recovery
    \\
    \\Package:
    \\  zttp build [-o <bin>]                Emit a self-contained binary
    \\  zttp compile <handler.ts> -o <bin>   Build a binary from an explicit path
    \\
    \\Proof ledger:
    \\  zttp proofs [list|show|diff|watch|export|badge|bundle|verify|gate|replay]
    \\  zttp proofs replay <capsule>         Replay a recorded capsule against the current handler
    \\  zttp ledger [export|replay]          Export or replay an expert-session verified-patch ledger
    \\  zttp verify <url>                    Verify a deployed proof receipt
    \\
    \\Credentials:
    \\  zttp auth deepseek                   Store the default DeepSeek API key
    \\  zttp auth claude                     Store an optional Anthropic API key
    \\  zttp auth openai                     Store an optional OpenAI API key
    \\  zttp auth status                     Show which provider keys are configured
    \\  zttp auth revoke <provider>          Remove a stored key (claude | openai | deepseek)
    \\
    \\Machine tools (JSON output for IDE and review-bot integrations):
    \\
;

const help_all_tail =
    \\
    \\Advanced:
    \\  zttp ratchet show <handler.ts>       Print declared vs proven spec sets
    \\  zttp witnesses [list|pin|unpin|prune|synthesize]  Falsifying-input corpus
    \\  zttp version                         Show version
    \\
    \\Every command keeps its own `--help`.
    \\
;

/// Upper bound on the rendered `help --all` text: the three static spans plus
/// the widest line each registry entry can produce. A comptime bound rather
/// than a round number, because a round number is what silently truncated the
/// Advanced section: the buffer was 4 KB, the text had grown past it, and every
/// write went through `catch {}`.
const help_all_capacity = blk: {
    var total = help_all_head.len + help_all_mid.len + help_all_tail.len;
    for (zts_cli.commands) |c| {
        // "  zttp " + name + " " + args, padded to the description column,
        // then the blurb and a newline.
        total += 8 + c.name.len + c.args.len + 41 + c.blurb.len + 1;
    }
    break :blk total;
};

/// Render the full `help --all` text into `buf` (static spans plus the two
/// registry-generated sections). A short write is a bug, not a formatting
/// detail, so it is not swallowed.
fn renderHelpAll(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    renderHelpAllInner(&w) catch unreachable; // buf is help_all_capacity
    return w.buffered();
}

fn renderHelpAllInner(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(help_all_head);
    try zts_cli.writeCommandLines(w, .analyze);
    try w.writeAll(help_all_mid);
    try zts_cli.writeCommandLines(w, .machine);
    try w.writeAll(help_all_tail);
}

/// The rendered `help --all` text, for the drift gate in dev_cli.zig. Exposed
/// rather than duplicated so the gate reads the bytes users see.
pub fn renderHelpAllForTest(buf: []u8) []const u8 {
    std.debug.assert(buf.len >= help_all_capacity);
    return renderHelpAll(buf);
}

/// The buffer size a caller must provide to `renderHelpAllForTest`.
pub const help_all_buffer_size = help_all_capacity;

pub fn printHelpAll() void {
    var buf: [help_all_capacity]u8 = undefined;
    const out = renderHelpAll(&buf);
    _ = std.c.write(std.c.STDOUT_FILENO, out.ptr, out.len);
}

const expert_help =
    \\zttp expert - interactive compiler-in-the-loop agent
    \\
    \\Usage:
    \\  zttp expert [--yes | --no-edit] [--no-session] [--no-persist-tool-output]
    \\                [--session-id <id> | --resume | --continue | --fork <id>]
    \\                [--provider local|claude|openai|deepseek] [--model <id>]
    \\                [--tools minimal|full] [--no-context-files]
    \\  zttp expert --print <prompt> [--mode json]
    \\  zttp expert --mode rpc
    \\  zttp expert --handler <handler.ts> --goal <goals> [--max-iters N]
    \\
    \\Flags:
    \\  --yes                      auto-approve every verified edit
    \\  --no-edit                  auto-reject every verified edit
    \\  --no-session               disable session persistence for this run
    \\  --no-persist-tool-output   omit tool output bodies from persisted session
    \\  --no-context-files         skip AGENTS.md / CLAUDE.md project context
    \\  --no-perf-receipt          do not sign a perf receipt on applied edits
    \\  --no-equivalence-receipt   do not sign an equivalence receipt on applied edits
    \\  --session-id <id>          resume or create a session with this id
    \\  --resume, --continue       resume the newest session for this cwd
    \\  --fork <session-id>        branch from an existing session
    \\  --provider <name>          select local, claude, openai, or deepseek for this launch
    \\  --model <id>               select a model within the active provider
    \\  --tools minimal|full       select workspace-read-only or full tool preset
    \\  --print <prompt>           run a single non-interactive turn and exit
    \\  --mode json                with --print, emit NDJSON transcript events
    \\  --mode rpc                 run line-delimited JSON-RPC 2.0 over stdio
    \\  --handler <path>           handler path for autoloop repair
    \\  --goal <csv>               property goals for autoloop repair
    \\  --max-iters <N>            autoloop iteration budget
    \\
    \\Inside the session, type /help for slash commands
    \\  (/model, /status, /compact, /resume, /tree, ...).
    \\
    \\Examples:
    \\  zttp expert --resume
    \\  zttp expert --print "add a GET /health route" --mode json
    \\  zttp expert --provider claude
    \\  zttp expert --handler handler.ts --goal no_secret_leakage
    \\
    \\Model backend:
    \\  The current default is DeepSeek. Configure its key with
    \\  `zttp auth deepseek` or DEEPSEEK_API_KEY.
    \\  DEEPSEEK_BASE_URL selects another HTTPS root; plain HTTP is refused.
    \\  To use the local LFM provider explicitly, start MLX-LM separately:
    \\    mlx_lm.server --model LiquidAI/LFM2.5-2.6B-MLX-8bit --host 127.0.0.1 --port 8080
    \\    zttp expert --provider local
    \\  ZTTP_MLX_BASE_URL can select another credential-free HTTP loopback root.
    \\  Zttp checks readiness but never starts, stops, or replaces the server.
    \\  Claude and OpenAI require explicit --provider and their own keys.
    \\  --goal is compiler-only and rejects --provider and --model.
    \\
    \\For machine-facing compiler tooling, use direct commands such as:
    \\  zttp meta
    \\  zttp verify-paths <file>...
    \\  zttp verify-modules --builtins --strict --json
    \\  zttp proofs export --session <id> --out <path>
    \\
;

pub fn printExpertHelp() void {
    _ = std.c.write(std.c.STDOUT_FILENO, expert_help.ptr, expert_help.len);
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "default help advertises only the five core commands" {
    inline for (.{
        "zttp init", "zttp dev", "zttp test", "zttp expert", "zttp deploy",
    }) |verb| {
        try std.testing.expect(has(core_help, verb));
    }
    inline for (.{
        "zttp check", "zttp serve", "zttp compile", "zttp proofs", "zttp doctor",
    }) |hidden| {
        try std.testing.expect(!has(core_help, hidden));
    }
}

test "help --all surfaces the advanced commands" {
    var buf: [help_all_capacity]u8 = undefined;
    const help_all = renderHelpAll(&buf);
    inline for (.{
        "zttp serve",        "zttp build",          "zttp compile",
        "zttp doctor",       "zttp proofs",         "zttp check",
        "zttp prove",        "zttp features",       "zttp modules",
        "zttp restrictions", "zttp meta",           "zttp describe-rule",
        "zttp verify-paths", "zttp verify-modules", "zttp edit-simulate",
        "zttp review-patch", "zttp rollout",        "zttp workflow-queue",
        "zttp durable",
    }) |cmd| {
        try std.testing.expect(has(help_all, cmd));
    }
}

test "help --all advertises every shared analyzer command" {
    // Anti-drift guard: the developer CLI must list the full surface `zts`
    // dispatches. New entries in `zts_cli.commands` fail here until added.
    var buf: [help_all_capacity]u8 = undefined;
    const help_all = renderHelpAll(&buf);
    for (zts_cli.commands) |c| {
        var needle_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "zttp {s}", .{c.name}) catch unreachable;
        try std.testing.expect(has(help_all, needle));
    }
}

test "help --all surfaces the optional browser studio workbench" {
    var buf: [help_all_capacity]u8 = undefined;
    try std.testing.expect(has(renderHelpAll(&buf), "zttp studio"));
}

test "hasAllFlag detects the --all escape hatch" {
    try std.testing.expect(hasAllFlag(&.{"--all"}));
    try std.testing.expect(hasAllFlag(&.{ "foo", "all" }));
    try std.testing.expect(!hasAllFlag(&.{"--help"}));
    try std.testing.expect(!hasAllFlag(&.{}));
}

test "expert help advertises documented modes" {
    inline for (.{
        "zttp expert --resume",
        "zttp expert --print <prompt> [--mode json]",
        "zttp expert --mode rpc",
        "zttp expert --handler <handler.ts> --goal <goals>",
        "--tools minimal|full",
        "--no-context-files",
        "--provider local|claude|openai|deepseek",
        "zttp expert --provider local",
        "--goal is compiler-only",
    }) |needle| {
        try std.testing.expect(has(expert_help, needle));
    }
}

test "help --all no longer advertises hosted cloud deploy" {
    // Trailing space avoids spurious substring matches with longer
    // command names (e.g. `zttp review` would otherwise match
    // `zttp review-patch`).
    var buf: [help_all_capacity]u8 = undefined;
    const help_all = renderHelpAll(&buf);
    inline for (.{
        "zttp login ",  "zttp logout ",       "zttp review ",
        "zttp grants ", "zttp revoke-grant ", "zttp assert-intent ",
        "--cloud",
    }) |hidden| {
        try std.testing.expect(!has(help_all, hidden));
    }
}
