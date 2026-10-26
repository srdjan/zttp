const std = @import("std");

pub const precompile = @import("precompile.zig");
pub const deploy_manifest = @import("deploy_manifest.zig");
pub const upgrade_verifier = @import("upgrade_verifier.zig");
// Re-exports for the pi package, which consumes shared tool cores through
// the `zts_cli` named module instead of reaching into tools/src/ directly.
pub const agent_identity = @import("agent_identity.zig");
pub const module_graph_record = @import("module_graph_record.zig");
pub const agent_protocol = @import("agent_protocol.zig");
pub const expert_meta = @import("expert_meta.zig");
pub const verify_paths_core = @import("verify_paths_core.zig");
pub const describe_rule = @import("describe_rule.zig");
pub const edit_simulate = @import("edit_simulate.zig");
pub const canonicalize = @import("canonicalize.zig");
pub const module_audit = @import("module_audit.zig");
pub const json_diagnostics = @import("json_diagnostics.zig");
const json_diag = precompile.json_diag;
const writeAllFd = @import("precompile_util.zig").writeAllFd;
const precompile_args = @import("precompile_args.zig");
const search_rules = @import("search_rules.zig");
const prove_behavior = @import("prove_behavior.zig");
const expert = @import("expert.zig");
const semantics_cli = @import("semantics_cli.zig");
const module_spec_cli = @import("module_spec_cli.zig");
const project_config_mod = @import("project_config");
const zts = @import("zts");
const zts_file_io = zts.file_io;
const writeContractJson = zts.writeContractJson;

/// Help-grouping for the canonical analyzer surface. `analyze` commands act on
/// a handler. `machine` commands emit JSON metadata for integrations.
pub const Category = enum { analyze, machine };

/// One dispatchable analyzer command. This table is the single source of truth
/// for the surface shared by the `zts` binary and the `zttp` developer CLI:
/// both dispatch from it (`run` / `isAnalyzerCommand`) and both render help from
/// it (`printHelp` / `writeCommandLines`). `compile` is intentionally absent -
/// it names different operations in each binary (binary output in `zttp`,
/// `.zig` output in `zts`) and stays a per-binary special case.
pub const Command = struct {
    name: []const u8,
    run: *const fn (std.mem.Allocator, []const []const u8) anyerror!void,
    /// Full usage line shown by `zts --help` (without the leading `zts `).
    usage: []const u8,
    /// Short argument hint shown by `zttp help --all`.
    args: []const u8,
    /// One-line description shown by `zttp help --all`.
    blurb: []const u8,
    category: Category,
};

pub const commands = [_]Command{
    .{ .name = "check", .run = runCheckCommand, .category = .analyze, .args = "[handler.ts]", .blurb = "Run the analyzer once", .usage = "check [handler.ts] [--json] [--contract] [--types] [--sql-schema path]" },
    .{ .name = "gen-tests", .run = runGenTestsCommand, .category = .analyze, .args = "[handler.ts]", .blurb = "Generate a starter test fixture", .usage = "gen-tests [handler.ts] [-o output.jsonl]" },
    .{ .name = "prove-behavior", .run = prove_behavior.runWithArgs, .category = .analyze, .args = "<before> <after>", .blurb = "Behavioral-equivalence verdict between two handler versions", .usage = "prove-behavior <before.ts> <after.ts> [--json] [--sql-schema path]" },
    .{ .name = "edit-simulate", .run = edit_simulate.runWithArgs, .category = .analyze, .args = "[handler.ts]", .blurb = "Simulate an edit and report violations", .usage = "edit-simulate [handler.ts] [--before old.ts] [--stdin-json]" },
    .{ .name = "canonicalize", .run = canonicalize.runWithArgs, .category = .analyze, .args = "<file> --json", .blurb = "Canonicalize a handler and report refactors", .usage = "canonicalize <file> --json [--simulate]" },
    .{ .name = "normalize", .run = canonicalize.runNormalizeWithArgs, .category = .analyze, .args = "<file>", .blurb = "Rewrite a handler into Canonical Normal Form", .usage = "normalize <file> [--write] [--check] [--json]" },
    .{ .name = "features", .run = runFeaturesCommand, .category = .machine, .args = "", .blurb = "List supported language features", .usage = "features [--json]" },
    .{ .name = "modules", .run = runModulesCommand, .category = .machine, .args = "", .blurb = "List virtual module exports", .usage = "modules [--json]" },
    .{ .name = "restrictions", .run = runRestrictionsCommand, .category = .machine, .args = "", .blurb = "Show language restrictions and the proofs they unlock", .usage = "restrictions [--json|--markdown] [--by proof|class]" },
    .{ .name = "meta", .run = expert.runMeta, .category = .machine, .args = "", .blurb = "Compiler and policy metadata", .usage = "meta [--json]" },
    .{ .name = "agent", .run = agent_protocol.runWithArgs, .category = .machine, .args = "--stdin-json", .blurb = "Version-2 agent protocol over stdin/stdout", .usage = "agent --stdin-json" },
    .{ .name = "describe-rule", .run = describe_rule.runWithArgs, .category = .machine, .args = "[name|code]", .blurb = "Look up a diagnostic rule", .usage = "describe-rule [rule-name|code] [--json] [--hash]" },
    .{ .name = "search", .run = search_rules.runWithArgs, .category = .machine, .args = "<keyword>", .blurb = "Search rules by keyword", .usage = "search <keyword> [--json]" },
    .{ .name = "spec-check", .run = semantics_cli.runSpecCheckCommand, .category = .machine, .args = "", .blurb = "Check the semantics registry against the IR/bytecode tables", .usage = "spec-check [--json]" },
    .{ .name = "spec-hash", .run = semantics_cli.runSpecHashCommand, .category = .machine, .args = "[--json]", .blurb = "Print the semantics-registry hash", .usage = "spec-hash [--json]" },
    .{ .name = "spec-render", .run = semantics_cli.runSpecRenderCommand, .category = .machine, .args = "[--out path] [--check path]", .blurb = "Render the semantics registry as a readable TypeScript spec", .usage = "spec-render [--out path] [--check path]" },
    .{ .name = "module-spec-render", .run = module_spec_cli.runModuleSpecRenderCommand, .category = .machine, .args = "[--check]", .blurb = "Generate the module spec JSON from the Zig bindings", .usage = "module-spec-render [--check] [--json]" },
    .{ .name = "verify-paths", .run = expert.runVerifyPaths, .category = .machine, .args = "<file>...", .blurb = "Behavior-path verification", .usage = "verify-paths <file>... [--json]" },
    .{ .name = "verify-modules", .run = expert.runVerifyModules, .category = .machine, .args = "<file>...", .blurb = "Module-contract verification", .usage = "verify-modules <file>... [--strict] [--json] | --builtins" },
};

/// True for every command in the shared registry. `compile` is excluded by
/// design (see `Command`), so callers route it separately.
pub fn isAnalyzerCommand(name: []const u8) bool {
    for (commands) |c| {
        if (std.mem.eql(u8, name, c.name)) return true;
    }
    return false;
}

/// Render the `zttp help --all` lines for one category from the registry, so
/// the developer CLI's analyzer/machine sections cannot drift from the surface
/// `zts` actually dispatches. Aligns the description column at byte 41.
pub fn writeCommandLines(w: *std.Io.Writer, category: Category) std.Io.Writer.Error!void {
    const prefix = "  zttp ";
    const desc_col = 41;
    for (commands) |c| {
        if (c.category != category) continue;
        var width: usize = prefix.len + c.name.len;
        try w.writeAll(prefix);
        try w.writeAll(c.name);
        if (c.args.len > 0) {
            try w.writeByte(' ');
            try w.writeAll(c.args);
            width += 1 + c.args.len;
        }
        try w.splatByteAll(' ', if (width < desc_col) desc_col - width else 1);
        try w.writeAll(c.blurb);
        try w.writeByte('\n');
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;
    const argv = try collectArgs(allocator, init.args);
    defer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }
    try run(allocator, argv[1..]);
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    if (argv.len == 0 or std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "help")) {
        try printHelp();
        return;
    }

    const command = argv[0];

    if (std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-v"))
    {
        std.debug.print("zts {s}\n", .{zts.version.string});
        return;
    }

    // Note: `expert`/`ledger` are intercepted with a developer-CLI pointer in
    // zts_main.zig before this runs, so they never reach the dispatch here.

    // `compile` names different operations in `zts` (precompile to .zig) and
    // `zttp` (build a binary), so it stays out of the shared registry.
    if (std.mem.eql(u8, command, "compile")) {
        if (precompile_args.wantsHelp(argv[1..])) {
            try writeAllFd(std.c.STDOUT_FILENO, precompile_args.compile_usage);
            return;
        }
        precompile.runCompileWithArgs(allocator, argv[1..]) catch |err| switch (err) {
            // precompile already printed the file and the plain reason.
            error.HandlerReadFailed, error.PolicyReadFailed => std.process.exit(1),
            error.OutOfMemory,
            error.WriteFailed,
            error.NoProjectConfig,
            error.InvalidArgument,
            error.InvalidArguments,
            error.MissingArgument,
            error.UnknownArgument,
            error.UnknownOption,
            error.UnknownFlag,
            error.TooManyArguments,
            => return err,
            error.SoundModeViolation,
            error.VerificationFailed,
            error.PolicyViolation,
            error.ParseError,
            error.AdmissionRefused,
            error.UnsupportedSourceExtension,
            error.InvalidImportSpecifier,
            error.UnknownVirtualModule,
            error.UnsupportedRuntimeAuthority,
            => std.process.exit(1),
            else => {
                inline for (@typeInfo(zts.PrepareSourceError).error_set.error_names.?) |source_error| {
                    if (std.mem.eql(u8, @errorName(err), source_error)) std.process.exit(1);
                }
                try writeCommandAnalyzerError(allocator, "compile", argv[1..], err);
                std.process.exit(1);
            },
        };
        return;
    }
    for (commands) |c| {
        if (std.mem.eql(u8, command, c.name)) {
            c.run(allocator, argv[1..]) catch |err| switch (err) {
                error.OutOfMemory,
                error.WriteFailed,
                error.NoProjectConfig,
                error.InvalidArgument,
                error.InvalidArguments,
                error.MissingArgument,
                error.UnknownArgument,
                error.UnknownOption,
                error.UnknownFlag,
                error.TooManyArguments,
                => return err,
                else => {
                    if (c.category != .analyze) return err;
                    try writeCommandAnalyzerError(allocator, c.name, argv[1..], err);
                    std.process.exit(1);
                },
            };
            return;
        }
    }

    // Unknown command: a clean message and non-zero exit, not a Zig error trace
    // that IDE/CI integrations parsing stderr cannot read.
    std.debug.print("Unknown command: {s}\nRun `zts --help` for the command list.\n", .{command});
    std.process.exit(1);
}

fn writeCommandAnalyzerError(allocator: std.mem.Allocator, command: []const u8, argv: []const []const u8, err: anyerror) !void {
    var target = command;
    var found_target = false;
    var skip_value = false;
    var json_mode = std.mem.eql(u8, command, "edit-simulate");
    for (argv) |arg| {
        if (skip_value) {
            skip_value = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--stdin-json")) json_mode = true;
        if (std.mem.eql(u8, arg, "--sql-schema") or std.mem.eql(u8, arg, "--before") or
            std.mem.eql(u8, arg, "--policy") or std.mem.eql(u8, arg, "--module-manifest") or
            std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output"))
        {
            skip_value = true;
        } else if (!found_target and !std.mem.startsWith(u8, arg, "-")) {
            target = arg;
            found_target = true;
        }
    }
    try writeUnmappedAnalyzerError(allocator, json_mode, target, err);
}

/// Writes the `check --json` envelope. A writer failure propagates so that the
/// command never reports success with a truncated or empty envelope.
fn writeCheckEnvelope(
    writer: *std.Io.Writer,
    has_errors: bool,
    contract: ?*const zts.HandlerContract,
    diagnostics: []const json_diagnostics.JsonDiagnostic,
    proof_trace_json: ?[]const u8,
) !void {
    if (has_errors) {
        try json_diag.writeErrorJson(writer, contract, diagnostics, proof_trace_json);
    } else {
        try json_diag.writeSuccessJson(writer, contract, diagnostics, proof_trace_json);
    }
}

fn runCheckCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var sql_schema_path: ?[]const u8 = null;
    var handler_path: ?[]const u8 = null;
    var emit_contract = false;
    var emit_types = false;
    var json_mode = false;
    var require_export_capsules = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--sql-schema")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            sql_schema_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--contract")) {
            emit_contract = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--types")) {
            emit_types = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--require-export-capsules")) {
            require_export_capsules = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try printCheckHelp();
            return;
        }
        if (!std.mem.startsWith(u8, arg, "-") and handler_path == null) {
            handler_path = arg;
            continue;
        }
        return error.InvalidArgument;
    }

    const target = if (handler_path) |path|
        path
    else
        try defaultProjectEntry(allocator);
    defer if (handler_path == null) allocator.free(target);

    const policy_source = edit_simulate.discoverProjectPolicySource(
        allocator,
        if (handler_path) |path| path else null,
    ) catch {
        if (json_mode) {
            try writePolicyLoadFailureJson(allocator, target);
        } else {
            try writePolicyLoadFailureText(allocator, target);
        }
        std.process.exit(1);
    };
    defer if (policy_source) |src| allocator.free(src);

    var result = precompile.runCheckOnlyWithOptions(allocator, target, .{
        .sql_schema_path = sql_schema_path,
        .json_mode = json_mode,
        .policy_source = policy_source,
    }) catch |err| switch (err) {
        error.MissingSqlSchema => {
            if (json_mode) try writeMissingSqlSchemaJson(allocator, target);
            std.process.exit(1);
        },
        error.FileNotFound => {
            // precompile already printed `Error reading handler file`.
            std.debug.print("Next: check the handler path, or run `check` with no argument inside a project.\n", .{});
            std.process.exit(1);
        },
        // An error no arm maps becomes one ZTS000, not a Zig error trace; OutOfMemory propagates.
        else => {
            try writeUnmappedAnalyzerError(allocator, json_mode, target, err);
            std.process.exit(1);
        },
    };
    defer result.deinit(allocator);

    // Opt-in docs mode: ask exported helpers to carry an explicit Proof<...>
    // capsule (ZTS508). Warning-only; never changes the exit code. The effects
    // half retired when ZTS610 widened to cover the same helpers.
    if (require_export_capsules) {
        precompile.appendExportCapsuleDiagnostics(allocator, &result, target);
    }

    if (json_mode) {
        // JSON output to stdout
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

        const contract_ptr: ?*const zts.HandlerContract = if (result.contract) |*c| c else null;
        const envelope_written = writeCheckEnvelope(
            &aw.writer,
            result.totalErrors() > 0,
            contract_ptr,
            result.json_diagnostics.items,
            result.proof_trace_json,
        );
        buf = aw.toArrayList();
        try envelope_written;
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);

        if (result.totalErrors() > 0) std.process.exit(1);
        return;
    }

    {
        var card_buf: std.ArrayList(u8) = .empty;
        defer card_buf.deinit(allocator);
        var card_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &card_buf);
        precompile.formatProofCard(&card_aw.writer, &result, target);
        card_buf = card_aw.toArrayList();
        if (card_buf.items.len > 0) {
            _ = std.c.write(std.c.STDERR_FILENO, card_buf.items.ptr, card_buf.items.len);
        }
    }

    if (require_export_capsules) {
        for (result.json_diagnostics.items) |d| {
            if (!std.mem.eql(u8, d.code, "ZTS508")) continue;
            std.debug.print("  {s} (warning) {s}:{d}  {s}\n", .{ d.code, d.file, d.line, d.message });
        }
    }

    if (emit_contract) {
        if (result.contract) |contract| {
            var json_output: std.ArrayList(u8) = .empty;
            defer json_output.deinit(allocator);
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_output);
            writeContractJson(&contract, &aw.writer) catch |err| {
                std.debug.print("Error serializing contract: {}\n", .{err});
                return err;
            };
            json_output = aw.toArrayList();
            zts_file_io.writeFile(allocator, "contract.json", json_output.items) catch |err| {
                std.debug.print("Error writing contract.json: {}\n", .{err});
                return err;
            };
            std.debug.print("Wrote contract.json\n", .{});
        }
    }

    if (emit_types) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
        precompile.generateTypeDefs(&aw.writer);
        buf = aw.toArrayList();
        zts_file_io.writeFile(allocator, "zttp.d.ts", buf.items) catch |err| {
            std.debug.print("Error writing zttp.d.ts: {}\n", .{err});
            return err;
        };
        std.debug.print("Wrote zttp.d.ts\n", .{});
    }

    if (result.totalErrors() > 0) std.process.exit(1);
    if (result.totalWarnings() > 0) std.process.exit(2);
}

fn writeMissingSqlSchemaJson(allocator: std.mem.Allocator, target: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    try writeMissingSqlSchemaJsonToWriter(&aw.writer, target);

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    }
}

fn writePolicyLoadFailureJson(allocator: std.mem.Allocator, target: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    try writePolicyLoadFailureJsonToWriter(&aw.writer, target);

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    }
}

fn writePolicyLoadFailureJsonToWriter(writer: anytype, target: []const u8) !void {
    try writeDriverFailureJson(writer, target, "configured capability policy could not be loaded", "repair the policy entry in zttp.json or restore the policy file");
}

fn writeDriverFailureJson(writer: anytype, target: []const u8, message: []const u8, suggestion: []const u8) !void {
    const diagnostics = [_]json_diag.JsonDiagnostic{.{
        .code = zts.DiagnosticCatalog.driverCode(.compiler_io_failure),
        .severity = "error",
        .message = message,
        .file = target,
        .line = 1,
        .column = 1,
        .suggestion = suggestion,
    }};
    try json_diag.writeErrorJson(writer, null, diagnostics[0..], null);
}

fn writePolicyLoadFailureText(allocator: std.mem.Allocator, target: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    try writePolicyLoadFailureTextToWriter(&aw.writer, target);

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        _ = std.c.write(std.c.STDERR_FILENO, buf.items.ptr, buf.items.len);
    }
}

fn writePolicyLoadFailureTextToWriter(writer: anytype, target: []const u8) !void {
    try writeDriverFailureText(writer, target, "Capability policy diagnostics", "configured capability policy could not be loaded", "repair the policy entry in zttp.json or restore the policy file");
}

fn writeDriverFailureText(writer: anytype, target: []const u8, heading: []const u8, message: []const u8, suggestion: []const u8) !void {
    try writer.print(
        "\ncheck: {s}\n\n  {s}:\n" ++
            "    ZTS000 (error) {s}:1:1  {s}\n" ++
            "      help: {s}\n\n" ++
            "  1 errors, 0 warnings\n",
        .{ target, heading, target, message, suggestion },
    );
}

/// Writes the ZTS000 diagnostic for an analyzer error that no code maps.
/// OutOfMemory is no verdict: it returns before any output.
fn writeUnmappedAnalyzerErrorToWriter(allocator: std.mem.Allocator, writer: anytype, json_mode: bool, target: []const u8, err: anyerror) !void {
    var diagnostic = try json_diagnostics.fromAnalyzerError(allocator, target, err);
    defer diagnostic.deinit(allocator);
    if (json_mode) {
        try json_diag.writeErrorJson(writer, null, &.{diagnostic}, null);
    } else {
        try writeDriverFailureText(writer, target, "Analyzer diagnostics", diagnostic.message, diagnostic.suggestion.?);
    }
}

fn writeUnmappedAnalyzerError(allocator: std.mem.Allocator, json_mode: bool, target: []const u8, err: anyerror) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    try writeUnmappedAnalyzerErrorToWriter(allocator, &aw.writer, json_mode, target, err);
    buf = aw.toArrayList();
    if (json_mode) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    } else {
        _ = std.c.write(std.c.STDERR_FILENO, buf.items.ptr, buf.items.len);
    }
}

fn writeMissingSqlSchemaJsonToWriter(writer: anytype, target: []const u8) !void {
    const diagnostics = [_]json_diag.JsonDiagnostic{.{
        .code = zts.DiagnosticCatalog.driverCode(.missing_sql_schema),
        .severity = "error",
        .message = "zttp:sql queries require --sql-schema <schema.sql|schema.sqlite>",
        .file = target,
        .line = 1,
        .column = 1,
        .suggestion = "pass --sql-schema <schema.sql|schema.sqlite> or configure sqlite in zttp.json",
    }};
    try json_diag.writeErrorJson(writer, null, diagnostics[0..], null);
}

/// A standard help token (`--help`, `-h`, or bare `help`), accepted by the
/// machine commands whose arg loops otherwise reject unknown flags.
fn isHelpToken(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "help");
}

fn runFeaturesCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            // Recognized so it is not rejected; this machine command has no
            // separate help screen, so it falls through to the normal catalog.
        } else {
            // Match restrictions/check: an unknown flag is a loud error, not a
            // silently-ignored arg that yields wrong output for tools and CI.
            return error.InvalidArgument;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    const allocator = std.heap.smp_allocator;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    if (json_mode) {
        try json_diag.writeFeaturesJson(&aw.writer);
    } else {
        try json_diag.writeFeaturesText(&aw.writer);
    }

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    }
}

fn runRestrictionsCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    var markdown_mode = false;
    var group_by: json_diag.RestrictionGrouping = .none;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--markdown")) {
            markdown_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--by")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            const value = argv[i];
            if (std.mem.eql(u8, value, "proof")) {
                group_by = .proof;
            } else if (std.mem.eql(u8, value, "class") or std.mem.eql(u8, value, "failure_class")) {
                group_by = .failure_class;
            } else {
                return error.InvalidArgument;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\zts restrictions - language cuts mapped to the proofs they unlock
                \\
                \\Usage: zts restrictions [--json|--markdown] [--by proof|class]
                \\
                \\Options:
                \\  --json            Emit structured JSON
                \\  --markdown        Emit the generated restrictions reference
                \\  --by proof        Group entries by the proof they unlock
                \\  --by class        Group entries by the failure class they prevent
                \\
            ;
            try writeAllFd(std.c.STDOUT_FILENO, help);
            return;
        }
        return error.InvalidArgument;
    }

    if (json_mode and markdown_mode) return error.InvalidArgument;
    if (markdown_mode and group_by != .none) return error.InvalidArgument;

    var buf: std.ArrayList(u8) = .empty;
    const allocator = std.heap.smp_allocator;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    if (markdown_mode) {
        try json_diag.writeRestrictionsMarkdown(&aw.writer);
    } else if (json_mode) {
        try json_diag.writeRestrictionsJson(&aw.writer);
    } else {
        try json_diag.writeRestrictionsText(&aw.writer, group_by);
    }

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    }
}

fn runModulesCommand(_: std.mem.Allocator, argv: []const []const u8) !void {
    var json_mode = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (isHelpToken(arg)) {
            // Recognized so it is not rejected; this machine command has no
            // separate help screen, so it falls through to the normal catalog.
        } else {
            return error.InvalidArgument;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    const allocator = std.heap.smp_allocator;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);

    if (json_mode) {
        try json_diag.writeModulesJson(&aw.writer);
    } else {
        try json_diag.writeModulesText(&aw.writer);
    }

    buf = aw.toArrayList();
    if (buf.items.len > 0) {
        try writeAllFd(std.c.STDOUT_FILENO, buf.items);
    }
}

fn defaultProjectEntry(allocator: std.mem.Allocator) ![]u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var project = try project_config_mod.discover(allocator, io, null);
    defer if (project) |*p| p.deinit(allocator);

    if (project) |*cfg| {
        return try cfg.resolvedEntry(allocator);
    }
    return error.NoProjectConfig;
}

pub fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var args_iter = std.process.Args.Iterator.init(args_vector);
    defer args_iter.deinit();

    var args = std.ArrayList([]const u8).empty;
    errdefer args.deinit(allocator);
    while (args_iter.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }
    return args.toOwnedSlice(allocator);
}

const help_head =
    \\zts - compiler and analysis tools for zttp handlers
    \\
    \\Usage:
    \\  zts compile [precompile flags] <handler.ts> <output.zig>
    \\
;

const help_tail =
    \\
    \\The interactive `expert` agent and session `ledger` commands live in the
    \\developer CLI: run `zttp expert` / `zttp ledger`.
    \\
;

fn printHelp() !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // The usage lines come from the shared registry so `zts` and `zttp`
    // advertise exactly the surface they dispatch.
    w.writeAll(help_head) catch {};
    for (commands) |c| {
        w.print("  zts {s}\n", .{c.usage}) catch {};
    }
    w.writeAll(help_tail) catch {};
    const out = w.buffered();
    try writeAllFd(std.c.STDOUT_FILENO, out);
}

fn printCheckHelp() !void {
    const help =
        \\zts check - verify handler and show proof card
        \\
        \\Usage: zts check [handler.ts] [options]
        \\
        \\Options:
        \\  --json           Emit structured JSON to stdout (for tool integration)
        \\  --contract       Emit contract.json in current directory
        \\  --types          Emit zttp.d.ts type definitions for IDE autocomplete
        \\  --sql-schema P   SQLite schema file for query validation
        \\  --require-export-capsules
        \\                   Docs mode: warn (ZTS508) when an exported helper
        \\                   carries no Proof<...> capsule
        \\
        \\If no handler is specified, uses the entry from zttp.json.
        \\
        \\Exit codes:
        \\  0  ok (no errors)
        \\  1  one or more errors
        \\  2  warnings only (no errors)
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}

fn runGenTestsCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var handler_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            output_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try printGenTestsHelp();
            return;
        }
        if (!std.mem.startsWith(u8, arg, "-") and handler_path == null) {
            handler_path = arg;
            continue;
        }
        return error.InvalidArgument;
    }

    const target = if (handler_path) |path|
        path
    else
        try defaultProjectEntry(allocator);
    defer if (handler_path == null) allocator.free(target);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const count = precompile.runGenTests(allocator, target, &aw.writer) catch |err| switch (err) {
        error.ParseError, error.AdmissionRefused, error.UnsupportedSourceExtension => std.process.exit(1),
        error.FileNotFound, error.AccessDenied, error.IsDir => {
            // precompile already printed `Error reading handler file`.
            std.debug.print("Next: check the handler path, or run `gen-tests` with no argument inside a project.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    buf = aw.toArrayList();

    if (output_path) |out_path| {
        try zts_file_io.writeFile(allocator, out_path, buf.items);
        const msg = try allocator.print("Wrote {d} test{s} to {s}\n", .{
            count,
            if (count == 1) @as([]const u8, "") else "s",
            out_path,
        });
        defer allocator.free(msg);
        _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
    } else {
        if (buf.items.len > 0) {
            try writeAllFd(std.c.STDOUT_FILENO, buf.items);
        }
    }
}

fn printGenTestsHelp() !void {
    const help =
        \\zts gen-tests - generate JSONL tests from proven behavioral paths
        \\
        \\Usage: zts gen-tests [handler.ts] [-o output.jsonl]
        \\
        \\Options:
        \\  -o, --output <file>  Write tests to file instead of stdout
        \\
        \\Enumerates all execution paths through the handler and emits a
        \\declarative JSONL test case for each path. Output is immediately
        \\runnable via `--test`.
        \\
        \\If no handler is specified, uses the entry from zttp.json.
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}

test "check envelope writer failure propagates" {
    var failing = std.Io.Writer.failing;
    try std.testing.expectError(error.WriteFailed, writeCheckEnvelope(&failing, false, null, &.{}, null));
    try std.testing.expectError(error.WriteFailed, writeCheckEnvelope(&failing, true, null, &.{}, null));
}

test "writeAllFd fails on a closed descriptor and writes a full buffer" {
    try std.testing.expectError(error.WriteFailed, writeAllFd(-1, "x"));
    try writeAllFd(std.c.STDERR_FILENO, "");
}

test "missing sql schema json uses diagnostic envelope" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);

    try writeMissingSqlSchemaJsonToWriter(&aw.writer, "handler.ts");

    buf = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"code\":\"ZTS700\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "--sql-schema") != null);
}

test "policy load failures are actionable in json and text modes" {
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(std.testing.allocator);
    var json_aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &json_buf);
    try writePolicyLoadFailureJsonToWriter(&json_aw.writer, "handler.ts");
    json_buf = json_aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, json_buf.items, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_buf.items, "\"code\":\"ZTS000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_buf.items, "policy entry in zttp.json") != null);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(std.testing.allocator);
    var text_aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text_buf);
    try writePolicyLoadFailureTextToWriter(&text_aw.writer, "handler.ts");
    text_buf = text_aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, text_buf.items, "Capability policy diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_buf.items, "ZTS000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_buf.items, "handler.ts") != null);
}

test "an unmapped analyzer error is one ZTS000 diagnostic" {
    const allocator = std.testing.allocator;

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);
    var json_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_buf);
    try writeUnmappedAnalyzerErrorToWriter(allocator, &json_aw.writer, true, "handler.ts", error.JumpTooFar);
    json_buf = json_aw.toArrayList();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.object.get("success").?.bool);
    const diagnostics = parsed.value.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("ZTS000", diagnostics[0].object.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics[0].object.get("message").?.string, "JumpTooFar") != null);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var text_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &text_buf);
    try writeUnmappedAnalyzerErrorToWriter(allocator, &text_aw.writer, false, "handler.ts", error.JumpTooFar);
    text_buf = text_aw.toArrayList();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text_buf.items, "ZTS000"));
    try std.testing.expect(std.mem.indexOf(u8, text_buf.items, "JumpTooFar") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_buf.items, "1 errors, 0 warnings") != null);

    // Out of memory is not an analyzer verdict: it propagates and writes nothing.
    var none_buf: std.ArrayList(u8) = .empty;
    defer none_buf.deinit(allocator);
    var none_aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &none_buf);
    try std.testing.expectError(error.OutOfMemory, writeUnmappedAnalyzerErrorToWriter(allocator, &none_aw.writer, true, "handler.ts", error.OutOfMemory));
    none_buf = none_aw.toArrayList();
    try std.testing.expectEqual(@as(usize, 0), none_buf.items.len);
}

test {
    // Collect the command modules reached only through this dispatcher. A plain
    // `@import` (above) does not pull a file's `test {}` blocks into the test
    // binary; this explicit reference does. Mirrors dev_cli.zig's anchor block
    // (see MEMORY.md "CLI test-collection closure").
    _ = describe_rule;
    _ = search_rules;
    _ = semantics_cli;
}
