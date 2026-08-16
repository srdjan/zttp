//! CheckResult data type plus presentation/codegen helpers
//! (formatProofCard, generateTypeDefs). The orchestrators that produce
//! CheckResult values live in precompile.zig.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const diagnostic_catalog = zts.DiagnosticCatalog;

const handler_contract = zts.handler_contract;
const HandlerContract = zts.HandlerContract;
const SpecDiagnostic = zts.SpecDiagnostic;
const json_diag = @import("json_diagnostics.zig");

pub const CheckResult = struct {
    line_count: u32 = 0,
    parse_errors: u32 = 0,
    bool_specializations: u32 = 0,
    bool_errors: u32 = 0,
    bool_warnings: u32 = 0,
    type_errors: u32 = 0,
    strict_errors: u32 = 0,
    strict_warnings: u32 = 0,
    /// Idiom-channel diagnostics: a better spelling for code that is already
    /// correct. Counted apart from warnings and reported apart from them,
    /// because a warning sets a non-zero exit code and spec 4.2.1 says a
    /// non-idiomatic spelling never fails a build.
    strict_advisories: u32 = 0,
    is_typescript: bool = false,
    verify_ran: bool = false,
    verify_errors: u32 = 0,
    verify_warnings: u32 = 0,
    flow_errors: u32 = 0,
    flow_warnings: u32 = 0,
    canonical_errors: u32 = 0,
    exhaustive_returns: bool = false,
    results_safe: bool = false,
    optionals_safe: bool = false,
    state_isolated: bool = true,
    no_unreachable: bool = true,
    paths_enumerated: u32 = 0,
    paths_exhaustive: bool = false,
    /// Why coverage is or is not complete. A static string, so nothing owns it.
    paths_coverage_note: []const u8 = "exhaustive",
    max_io_depth: ?u32 = null,
    fault_total: u32 = 0,
    fault_covered: u32 = 0,
    properties: ?handler_contract.HandlerProperties = null,
    contract: ?HandlerContract = null,
    /// Structured diagnostics for JSON output mode.
    json_diagnostics: std.ArrayList(json_diag.JsonDiagnostic) = .empty,
    /// Count of pinned-witness regressions re-fired by this build. Surfaced
    /// by `--watch --prove` as a HUD-adjacent toast so authors notice when
    /// a defended-against pattern reappears.
    pinned_witness_regressions: usize = 0,
    /// Pre-rendered `proofTrace` JSON object: per-property reasoning for the
    /// proof card (how each proof was discharged, or the counterexample that
    /// broke it). Null when no contract was produced. Owned by CheckResult.
    proof_trace_json: ?[]u8 = null,

    pub fn totalErrors(self: *const CheckResult) u32 {
        return self.parse_errors + self.bool_errors + self.type_errors + self.strict_errors + self.verify_errors + self.flow_errors + self.canonical_errors + self.specErrors();
    }

    pub fn totalWarnings(self: *const CheckResult) u32 {
        return self.bool_warnings + self.strict_warnings + self.verify_warnings + self.flow_warnings + self.specWarnings();
    }

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        if (self.contract) |*c| c.deinit(allocator);
        // Checker diagnostics own a heap copy of their message (duped at
        // capture so it outlives the checker allocator); free those here.
        // Static-string messages keep `message_owned` false and are skipped.
        for (self.json_diagnostics.items) |*d| d.deinit(allocator);
        self.json_diagnostics.deinit(allocator);
        if (self.proof_trace_json) |ptj| allocator.free(ptj);
    }

    /// Error-severity spec diagnostics: handler Spec ZTS500/501/502, helper
    /// capsule ZTS500/502, ZTS606, and the error-level Effects diagnostics
    /// (ZTS503/504/506/607). Warning-level entries are excluded so an
    /// over-declared `Effects<...>` ceiling never fails a build.
    fn specErrors(self: *const CheckResult) u32 {
        const contract = if (self.contract) |*c| c else return 0;
        var n: u32 = 0;
        for (contract.spec_diagnostics.items) |d| {
            if (d.kind.severity() == .err) n += 1;
        }
        return n;
    }

    /// Warning-severity spec diagnostics: ZTS505 over-declaration and the
    /// docs-mode ZTS508 missing-capsule prompt.
    fn specWarnings(self: *const CheckResult) u32 {
        const contract = if (self.contract) |*c| c else return 0;
        var n: u32 = 0;
        for (contract.spec_diagnostics.items) |d| {
            if (d.kind.severity() == .warn) n += 1;
        }
        return n;
    }
};

/// Walk borrowed flow-witness projections, materialise a counterexample witness
/// for each one that maps to a tracked PropertyTag, and persist it to
/// `.zttp/witnesses/<short_hash>/`. Failures here never block the
/// analysis result; the corpus is best-effort persistence. Returns the
/// number of pinned witnesses re-fired by this build, which the live
/// reload HUD surfaces as a regression toast.
///
/// The corpus is filesystem state, so freestanding/wasm analyzer builds skip
/// it: `persistFlowWitnessesNative` is referenced only inside the comptime
/// branch below, keeping the `witness_corpus` subtree out of the module graph.
pub fn persistFlowWitnesses(
    allocator: std.mem.Allocator,
    flow_witnesses: []const zts.DiagnosticProjection.FlowWitness,
    handler_path: []const u8,
) usize {
    if (comptime builtin.target.os.tag != .freestanding) {
        return persistFlowWitnessesNative(allocator, flow_witnesses, handler_path);
    }
    return 0;
}

fn persistFlowWitnessesNative(
    allocator: std.mem.Allocator,
    flow_witnesses: []const zts.DiagnosticProjection.FlowWitness,
    handler_path: []const u8,
) usize {
    if (flow_witnesses.len == 0) return 0;

    const corpus_dir = zts.witness_corpus.corpusDir(allocator, handler_path) catch return 0;
    defer allocator.free(corpus_dir);
    zts.witness_corpus.ensureCorpusDir(allocator, corpus_dir, handler_path) catch return 0;

    var pinned_regressions: usize = 0;
    for (flow_witnesses) |projection| {
        var witness = zts.solveCounterexample(allocator, .{
            .property = projection.property,
            .origin = .{ .line = projection.line, .column = projection.column },
            .sink = .{ .line = projection.line, .column = projection.column },
            .summary = projection.summary,
            .constraints = projection.constraints,
            .io_calls = projection.io_calls,
        }) catch continue;
        defer witness.deinit(allocator);

        if (zts.witness_corpus.persist(allocator, corpus_dir, witness)) |pres| {
            var owned = pres;
            defer owned.deinit(allocator);
            // .refreshed means the witness was already persisted on a prior
            // build. If the author had pinned it, this build re-fires a
            // regression they explicitly chose to defend against.
            if (owned.outcome == .refreshed and
                zts.witness_corpus.isPinned(allocator, corpus_dir, owned.key))
            {
                pinned_regressions += 1;
            }
        } else |_| {}
    }
    return pinned_regressions;
}

pub fn syncCheckResultProperties(result: *CheckResult) void {
    if (result.contract) |*contract| {
        result.properties = contract.properties;
    } else {
        result.properties = null;
    }
}

pub fn appendSpecDiagnosticsJson(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    handler_path: []const u8,
) void {
    const contract = if (result.contract) |*c| c else return;
    for (contract.spec_diagnostics.items) |diag| {
        const code = diagnostic_catalog.specCode(diag.kind);
        // Single source of truth shared with the human card (formatProofCard)
        // so the two surfaces cannot drift.
        const message: []const u8 = specDiagnosticMessage(diag);
        result.json_diagnostics.append(allocator, .{
            .code = code,
            .severity = if (diag.kind.severity() == .warn) "warning" else "error",
            .message = message,
            .file = handler_path,
            .line = contract.handler.line,
            .column = @intCast(@min(contract.handler.column, std.math.maxInt(u16))),
            .suggestion = diag.suggestion,
        }) catch {};
    }
}

/// Opt-in docs mode: ask every exported helper to carry an explicit
/// `Proof<...>` capsule (ZTS508). Off by default and warning-only - it never
/// fails a build. Diagnostics are appended to `result.json_diagnostics`;
/// non-exported helpers are untouched.
///
/// The effects half is gone. It asked for a ceiling on exactly the helpers
/// ZTS610 already refuses - exported, undeclared, nonempty inferred row - once
/// `handler_reachable` came off ZTS610, so it added a warning behind a flag
/// where an unconditional error already stood. The proof half stays because
/// ZTS611 fires only when the handler declares a proof-supported `Proof<T, P>`
/// and this fires whether or not it does.
pub fn appendExportCapsuleDiagnostics(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    handler_path: []const u8,
) void {
    const contract = if (result.contract) |*c| c else return;
    for (contract.function_capsules.items) |cap| {
        if (!cap.exported or cap.declared.items.len > 0) continue;
        var proven_buf: [4][]const u8 = undefined;
        // Same rule: a helper with nothing proved about it has no capsule to
        // write down.
        const repair = computedCapsuleRepair(allocator, "Proof", provenPropertyNames(cap, &proven_buf)) orelse continue;
        result.json_diagnostics.append(allocator, .{
            .code = diagnostic_catalog.specCode(.missing_proof_capsule_export),
            .severity = "warning",
            .message = "exported helper carries no Proof<...> capsule",
            .file = handler_path,
            .line = cap.line,
            .column = 0,
            .suggestion = repair,
            .suggestion_owned = true,
        }) catch allocator.free(repair);
    }
}

/// Build the exact annotation an author should write, from the set the
/// compiler already inferred. D2 5 asks for a repair "computed from the
/// inferred row": `Effects<T, "clock" | "crypto">` tells the author (and the
/// agent) what to type, where a `"..."` placeholder makes them re-derive what
/// the compiler just worked out. Caller owns the result.
fn computedCapsuleRepair(
    allocator: std.mem.Allocator,
    comptime capsule: []const u8,
    names: []const []const u8,
) ?[]u8 {
    if (names.len == 0) return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    buf.appendSlice(allocator, "annotate the exported helper's return type with `" ++ capsule ++ "<T, ") catch return null;
    for (names, 0..) |name, i| {
        if (i > 0) buf.appendSlice(allocator, " | ") catch return null;
        buf.append(allocator, '"') catch return null;
        buf.appendSlice(allocator, name) catch return null;
        buf.append(allocator, '"') catch return null;
    }
    buf.appendSlice(allocator, ">`.") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// The capsule properties the compiler proved for a helper, in the order the
/// v1 set declares them.
fn provenPropertyNames(cap: anytype, out: *[4][]const u8) []const []const u8 {
    var n: usize = 0;
    if (cap.proven_total) {
        out[n] = "total";
        n += 1;
    }
    if (cap.proven_pure) {
        out[n] = "pure";
        n += 1;
    }
    if (cap.proven_read_only) {
        out[n] = "read_only";
        n += 1;
    }
    if (cap.proven_deterministic) {
        out[n] = "deterministic";
        n += 1;
    }
    return out[0..n];
}

/// Default canonical profile: public helpers that participate in capability
/// or declared-proof paths carry explicit capsules.
pub fn appendCanonicalPublicHelperDiagnostics(
    allocator: std.mem.Allocator,
    result: *CheckResult,
    handler_path: []const u8,
) void {
    const contract = if (result.contract) |*c| c else return;

    // Spec 5.7 conditions this on export and a nonempty inferred row, and on
    // nothing else. A `handler_reachable` qualifier used to stand here, which
    // let an exported helper the handler never calls declare nothing and report
    // nothing - the export is the promise, and who happens to call it today
    // does not change what the module's public surface owes its callers.
    for (contract.function_effect_capsules.items) |cap| {
        if (!cap.exported or cap.declared.items.len > 0 or cap.inferred.items.len == 0) continue;
        const repair = computedCapsuleRepair(allocator, "Effects", cap.inferred.items);
        result.json_diagnostics.append(allocator, .{
            .code = zts.DiagnosticProjection.code(.strict, .canonical_public_helper_effects),
            .severity = "error",
            .message = "public helper reaches capabilities and should declare Effects<...>",
            .file = handler_path,
            .line = cap.line,
            .column = 0,
            .suggestion = repair,
            .suggestion_owned = repair != null,
        }) catch {
            if (repair) |r| allocator.free(r);
        };
        result.canonical_errors += 1;
    }

    // Spec 5.7's other half. An internal ceiling proves nothing the compiler
    // does not already infer, and the handler's budget already bounds every
    // helper it reaches (ZTS607) - so this costs no safety and buys one right
    // answer for where an annotation goes.
    for (contract.function_effect_capsules.items) |cap| {
        if (cap.exported or cap.declared.items.len == 0) continue;
        result.json_diagnostics.append(allocator, .{
            .code = zts.DiagnosticProjection.code(.strict, .canonical_internal_helper_effects),
            .severity = "error",
            .message = "module-internal helper declares an Effects<...> ceiling",
            .file = handler_path,
            .line = cap.line,
            .column = 0,
            .suggestion = "remove the `Effects<...>` ceiling: the compiler infers the row for a module-internal function, and the handler's budget already bounds it. Export the helper if the ceiling is meant to be part of the module's public surface.",
        }) catch {};
        result.canonical_errors += 1;
    }

    if (!declaresProofSupportedSpec(contract.declared_specs.items)) return;
    // Same reading as the effects half above: export is the condition, not
    // reachability from this handler.
    for (contract.function_capsules.items) |cap| {
        if (!cap.exported or cap.declared.items.len > 0) continue;
        var proven_buf: [4][]const u8 = undefined;
        const repair = computedCapsuleRepair(allocator, "Proof", provenPropertyNames(cap, &proven_buf));
        result.json_diagnostics.append(allocator, .{
            .code = zts.DiagnosticProjection.code(.strict, .canonical_public_helper_proof),
            .severity = "error",
            .message = "public helper participates in declared specs and should declare Proof<...>",
            .file = handler_path,
            .line = cap.line,
            .column = 0,
            .suggestion = repair,
            .suggestion_owned = repair != null,
        }) catch {
            if (repair) |r| allocator.free(r);
        };
        result.canonical_errors += 1;
    }
}

fn declaresProofSupportedSpec(specs: []const []const u8) bool {
    for (specs) |name| {
        if (std.mem.eql(u8, name, "total") or
            std.mem.eql(u8, name, "pure") or
            std.mem.eql(u8, name, "read_only") or
            std.mem.eql(u8, name, "deterministic"))
        {
            return true;
        }
    }
    return false;
}

pub fn refreshSpecDiagnostics(allocator: std.mem.Allocator, result: *CheckResult) !void {
    const contract = if (result.contract) |*c| c else return;

    // Re-discharge the handler's Proof<T, P> obligations against the freshly
    // classified properties. Capsule diagnostics - those carrying a
    // `function` - come from proof-carrying-function discharge, which this
    // refresh does not re-run; handler-level Effects diagnostics also come
    // from the capability-budget pass. Clone them across so helper
    // ZTS500/ZTS502/ZTS606 and handler ZTS504/ZTS506 entries survive. The
    // clone (rather than a move) keeps `contract.spec_diagnostics` intact
    // until the swap, so an OOM mid-loop leaves both lists individually
    // consistent.
    var refreshed = try zts.spec_discharge.dischargeSpecs(
        allocator,
        contract.declared_specs.items,
        contract.properties,
        contract.modules.items,
        contract.declared_specs_implicit,
    );
    errdefer {
        for (refreshed.items) |*d| d.deinit(allocator);
        refreshed.deinit(allocator);
    }
    for (contract.spec_diagnostics.items) |*diag| {
        if (preserveDuringSpecRefresh(diag.*)) {
            try refreshed.append(allocator, try diag.clone(allocator));
        }
    }
    for (contract.spec_diagnostics.items) |*diag| diag.deinit(allocator);
    contract.spec_diagnostics.deinit(allocator);
    contract.spec_diagnostics = refreshed;
}

fn preserveDuringSpecRefresh(diag: zts.SpecDiagnostic) bool {
    if (diag.function != null) return true;
    return switch (diag.kind) {
        .not_discharged,
        .incompatible_with_import,
        .unknown_name,
        => false,
        else => true,
    };
}

/// Format a structured proof card showing what the compiler proved.
pub fn formatProofCard(writer: anytype, r: *const CheckResult, filename: []const u8) void {
    writer.print("\ncheck: {s}\n\n", .{filename}) catch return;

    // Parse
    writeDotted(writer, "Parse", 24);
    if (r.parse_errors > 0) {
        writer.print("FAIL ({d} errors)\n", .{r.parse_errors}) catch return;
    } else {
        writer.print("OK ({d} lines)\n", .{r.line_count}) catch return;
    }

    // Types
    if (r.is_typescript) {
        writeDotted(writer, "Types", 24);
        if (r.type_errors > 0) {
            writer.print("FAIL ({d} errors)\n", .{r.type_errors}) catch return;
        } else {
            writer.print("OK\n", .{}) catch return;
        }
    }

    // Sound mode
    writeDotted(writer, "Sound mode", 24);
    if (r.bool_errors > 0) {
        writer.print("FAIL ({d} errors)\n", .{r.bool_errors}) catch return;
    } else if (r.bool_specializations > 0) {
        writer.print("OK ({d} specializations)\n", .{r.bool_specializations}) catch return;
    } else {
        writer.print("OK\n", .{}) catch return;
    }

    // Strict profile
    writeDotted(writer, "Strict ZigTS", 24);
    if (r.strict_errors > 0) {
        writer.print("FAIL ({d} errors)\n", .{r.strict_errors}) catch return;
    } else {
        writer.print("OK\n", .{}) catch return;
    }

    // Verification
    if (r.verify_ran) {
        writer.print("\n  Verification:\n", .{}) catch return;
        writeProven(writer, "exhaustive_returns", r.verify_errors == 0 and r.exhaustive_returns);
        writeProven(writer, "results_safe", r.results_safe);
        writeProven(writer, "optionals_safe", r.optionals_safe);
        writeProven(writer, "state_isolated", r.state_isolated);
        writeProven(writer, "no_unreachable", r.no_unreachable);
    }

    // Properties
    if (r.properties) |props| {
        writer.print("\n  Properties:\n", .{}) catch return;
        writeProven(writer, "retry_safe", props.retry_safe);
        writeProven(writer, "idempotent", props.idempotent);
        writeProven(writer, "injection_safe", props.injection_safe);
        writeProven(writer, "deterministic", props.deterministic);
        writeProven(writer, "read_only", props.read_only);
        writeProven(writer, "cost_bounded", props.cost_bounded);

        writer.print("\n  Security:\n", .{}) catch return;
        writeProven(writer, "no_secret_leakage", props.no_secret_leakage);
        writeProven(writer, "no_credential_leak", props.no_credential_leakage);
        writeProven(writer, "input_validated", props.input_validated);
    }

    // Summary stats
    writer.print("\n", .{}) catch return;
    if (r.fault_total > 0) {
        writer.print("  Fault coverage: {d}/{d} paths covered\n", .{ r.fault_covered, r.fault_total }) catch return;
    }
    if (r.paths_enumerated > 0) {
        // The note names the actual cause. A single bool made every cause read
        // as whichever one this line happened to name, which was "limit
        // reached" for a handler nowhere near the limit.
        writer.print("  Execution paths: {d} ({s})\n", .{ r.paths_enumerated, r.paths_coverage_note }) catch return;
    }
    if (r.max_io_depth) |depth| {
        writer.print("  Max I/O depth: {d}\n", .{depth}) catch return;
    }
    writeCostBound(writer, r);

    if (hasCanonicalDiagnostic(r.json_diagnostics.items)) {
        writer.print("\n  Canonical diagnostics:\n", .{}) catch return;
        for (r.json_diagnostics.items) |d| {
            if (!isCanonicalDiagnostic(d.code)) continue;
            writer.print(
                "    {s} ({s}) {s}:{d}:{d}  {s}\n",
                .{ d.code, d.severity, d.file, d.line, d.column, d.message },
            ) catch return;
            if (d.suggestion) |suggestion| {
                writer.print("      help: {s}\n", .{suggestion}) catch return;
            }
        }
    }

    // Spec/Effects diagnostics live in contract.spec_diagnostics, not in
    // json_diagnostics, so the human card must render them here or the printed
    // error lines fall short of the footer count (e.g. a Spec-less handler
    // trips ZTS500 in `specErrors()` but otherwise prints nothing).
    if (r.contract) |*contract| {
        if (r.specErrors() > 0) {
            writer.print("\n  Spec diagnostics:\n", .{}) catch return;
            for (contract.spec_diagnostics.items) |d| {
                if (d.kind.severity() != .err) continue;
                writer.print(
                    "    {s} (error) {s}:{d}:{d}  {s}\n",
                    .{ diagnostic_catalog.specCode(d.kind), filename, contract.handler.line, contract.handler.column, specDiagnosticMessage(d) },
                ) catch return;
                if (d.suggestion) |suggestion| {
                    writer.print("      help: {s}\n", .{suggestion}) catch return;
                }
            }
        }
    }

    if (r.strict_advisories > 0) {
        writer.print(
            "\n  {d} errors, {d} warnings, {d} advisories\n",
            .{ r.totalErrors(), r.totalWarnings(), r.strict_advisories },
        ) catch return;
    } else {
        writer.print("\n  {d} errors, {d} warnings\n", .{ r.totalErrors(), r.totalWarnings() }) catch return;
    }
}

/// Human-readable message for a spec/Effects diagnostic, mirroring the JSON
/// text in `appendSpecDiagnosticsJson` so the card and `--json` agree.
fn specDiagnosticMessage(diag: zts.SpecDiagnostic) []const u8 {
    if (diag.implicit_default) {
        switch (diag.kind) {
            .not_discharged => return "handler returns no Proof<T, P> capsule; the default proof profile demands a property this handler does not hold",
            .incompatible_with_import => return "handler returns no Proof<T, P> capsule; the default profile's read_only conflicts with a stateful module import",
            else => {},
        }
    }
    return switch (diag.kind) {
        .not_discharged => "declared Proof capsule was not discharged by handler proof",
        .incompatible_with_import => "declared Proof capsule is incompatible with imported module",
        .unknown_name => "declared Proof capsule name is not recognized",
        .missing_capsule => "helper breaks a handler-demanded property and carries no Proof<...> capsule",
        .effect_undeclared => "function reaches a capability outside its declared Effects<...> ceiling",
        .effect_unknown_capability => "Effects<...> names an unknown capability",
        .effect_over_declared => "declared capability is never reached by the function",
        .budget_exceeded => "handler reaches a capability outside its declared Effects<...> budget",
        .helper_budget_exceeded => "helper reaches a capability outside the handler's Effects<...> budget",
        .missing_proof_capsule_export => "exported helper carries no Proof<...> capsule",
        .workflow_call_in_step => "workflow.call/saga/fanout/follow used inside a step() callback silently loses durability",
        .saga_step_missing_compensate => "a non-last saga step has no compensate, leaving a partial-rollback hole",
        .effect_ceiling_not_literal => "Effects<...> names its capabilities with something other than a closed union of string literals, so no ceiling was read",
        .effect_row_lower_bound => "function calls through a value the compiler cannot resolve, so its effect row is a lower bound and cannot discharge a ceiling",
    };
}

fn isCanonicalDiagnostic(code: []const u8) bool {
    return zts.PolicyCatalog.isCanonicalProfileCode(code);
}

fn hasCanonicalDiagnostic(diagnostics: []const json_diag.JsonDiagnostic) bool {
    for (diagnostics) |d| {
        if (isCanonicalDiagnostic(d.code)) return true;
    }
    return false;
}

const dots = "." ** 32;

fn writeDotted(writer: anytype, label: []const u8, width: usize) void {
    writer.print("  {s} ", .{label}) catch return;
    const pad = @min(width -| (label.len + 1), dots.len);
    writer.writeAll(dots[0..pad]) catch return;
    writer.writeAll(" ") catch return;
}

fn writeProven(writer: anytype, label: []const u8, proven: bool) void {
    writer.print("    {s} ", .{label}) catch return;
    const pad = @min(20 -| label.len, dots.len);
    writer.writeAll(dots[0..pad]) catch return;
    writer.writeAll(if (proven) " PROVEN\n" else " ---\n") catch return;
}

fn writeCostBound(writer: anytype, r: *const CheckResult) void {
    const contract = if (r.contract) |*c| c else return;
    const envelope = contract.cost_envelope orelse return;
    switch (envelope.total) {
        .constant => {},
        .linear => |linear| {
            writer.print(
                "  Cost bound: {d}+{d}*|source| (line {d})\n",
                .{ linear.base, linear.coefficient, linear.source.line },
            ) catch return;
        },
        .unbounded => |source| {
            writer.print(
                "  Cost bound: unbounded (line {d}) - see cost_bounded\n",
                .{source.line},
            ) catch return;
        },
    }
}

/// Generate TypeScript type definitions for all virtual modules.
pub fn generateTypeDefs(writer: anytype) void {
    writer.print("// Generated by: zts check --types\n// Do not edit manually.\n\n", .{}) catch return;

    // The ABI types the signatures below name. Every one of them is emitted
    // by `returnKindToTs` or by a declared signature, and none was declared
    // here - so a `zttp.d.ts` fed to `tsc` reported "Cannot find name 'Dict'"
    // for a file the zts checker accepts. The declarations are opaque on
    // purpose: this file describes the surface to an external tool, and the
    // zts checker has its own, real definitions.
    writer.writeAll(
        \\type Dict<K, V> = { readonly __dict: unique symbol };
        \\type Bytes = { readonly __bytes: unique symbol };
        \\type MessageId = string & { readonly __messageId: unique symbol };
        \\
        \\interface FetchOptions {
        \\  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS";
        \\  headers?: Record<string, string>;
        \\  body?: string | Bytes;
        \\  query?: Record<string, string>;
        \\  maxResponseBytes?: number;
        \\  durable?: Record<string, unknown>;
        \\}
        \\
        \\
    ) catch return;

    // Request and Response globals
    writer.print(
        \\interface RequestInit {{
        \\  method?: string;
        \\  headers?: Record<string, string>;
        \\  body?: string;
        \\}}
        \\
        \\interface ResponseInit {{
        \\  status?: number;
        \\  statusText?: string;
        \\  headers?: Record<string, string>;
        \\}}
        \\
        \\declare class Request {{
        \\  readonly method: string;
        \\  readonly url: string;
        \\  readonly path: string;
        \\  readonly query: string;
        \\  readonly body: string | undefined;
        \\  readonly headers: Record<string, string>;
        \\}}
        \\
        \\declare class Response {{
        \\  readonly body: string;
        \\  readonly status: number;
        \\  readonly statusText: string;
        \\  readonly ok: boolean;
        \\  readonly headers: Record<string, string>;
        \\  static json(data: unknown, init?: ResponseInit): Response;
        \\  static text(text: string, init?: ResponseInit): Response;
        \\  static html(html: string, init?: ResponseInit): Response;
        \\  static redirect(url: string, status?: number): Response;
        \\}}
        \\
        \\
    , .{}) catch return;

    const modules = @import("zts").builtin_modules;
    for (modules.all) |binding| {
        writer.print("declare module \"{s}\" {{\n", .{binding.specifier}) catch return;
        for (binding.exports) |func| {
            writer.print("  export function {s}(", .{func.name}) catch return;
            const required_arg_count = func.required_arg_count orelse @as(u8, @intCast(@min(func.param_types.len, 255)));
            for (func.param_types, 0..) |pt, i| {
                if (i > 0) writer.print(", ", .{}) catch return;
                const optional_marker: []const u8 = if (i >= required_arg_count) "?" else "";
                writer.print("arg{d}{s}: {s}", .{ i, optional_marker, paramTypeText(func, i, pt) }) catch return;
            }
            writer.print("): {s};\n", .{returnTypeText(func)}) catch return;
        }
        writer.print("}}\n\n", .{}) catch return;
    }
}

/// The text for parameter `index`: the binding's declared signature when it
/// has one, and the coarse kind otherwise. Every consumer that turns a
/// signature into text goes through this pair, so a declared signature cannot
/// reach one surface and miss another.
fn paramTypeText(
    func: @import("zts").module_binding.FunctionBinding,
    index: usize,
    kind: @import("zts").module_binding.ReturnKind,
) []const u8 {
    if (func.signature) |sig| {
        if (index < sig.params.len) return sig.params[index];
    }
    return returnKindToTs(kind);
}

fn returnTypeText(func: @import("zts").module_binding.FunctionBinding) []const u8 {
    if (func.signature) |sig| return sig.returns;
    return returnKindToTs(func.returns);
}

fn returnKindToTs(kind: @import("zts").module_binding.ReturnKind) []const u8 {
    return switch (kind) {
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .object => "Record<string, unknown>",
        .undefined => "undefined",
        .unknown => "unknown",
        .optional_string => "string | undefined",
        .optional_object => "Record<string, unknown> | undefined",
        .optional_number => "number | undefined",
        .result => "{ ok: boolean; value?: unknown; error?: string; errors?: unknown }",
        .dict => "Dict<unknown, unknown>",
        .bytes => "Bytes",
    };
}

// ---------------------------------------------------------------------------
// Frozen signature corpus (phase 2 exit gate)
//
// The corpus is the `.d.ts` surface `generateTypeDefs` writes from
// `builtin_modules.all`, so it covers every virtual-module export by
// construction and cannot drift from the bindings: adding an export adds a row
// here in the same commit that adds the binding.
// ---------------------------------------------------------------------------

/// Every signature member of every export, as the emitter spells it.
fn forEachSignatureType(
    comptime Ctx: type,
    ctx: *Ctx,
    visit: fn (*Ctx, module: []const u8, export_name: []const u8, position: usize, text: []const u8) anyerror!void,
) !usize {
    var count: usize = 0;
    for (zts.builtinModules) |binding| {
        for (binding.exports) |func| {
            for (func.param_types, 0..) |pt, i| {
                try visit(ctx, binding.specifier, func.name, i, paramTypeText(func, i, pt));
                count += 1;
            }
            try visit(ctx, binding.specifier, func.name, func.param_types.len, returnTypeText(func));
            count += 1;
        }
    }
    return count;
}

/// Digest every signature member into one rolling hash. Two runs of this over
/// an unchanged binding set must agree, and any signature change moves it - so
/// the pin below is what makes such a change visible in the diff rather than
/// silent.
fn signatureCorpusDigest(allocator: std.mem.Allocator, out_members: *usize) ![32]u8 {
    var pool = zts.TypePool.init(allocator);
    defer pool.deinit(allocator);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const Ctx = struct {
        pool: *zts.TypePool,
        allocator: std.mem.Allocator,
        hasher: *std.crypto.hash.sha2.Sha256,
        /// Duped: `firstUnresolvedName` points into the pool's name storage,
        /// which the next `parseTypeExpr` may reallocate, so keeping the slice
        /// as a hash key crashes on the next compare.
        unresolved: std.ArrayListUnmanaged([]u8) = .empty,
        fallback_unknown: usize = 0,
        unparsed: usize = 0,
    };
    var ctx: Ctx = .{ .pool = &pool, .allocator = allocator, .hasher = &hasher };
    defer {
        for (ctx.unresolved.items) |name| allocator.free(name);
        ctx.unresolved.deinit(allocator);
    }

    const visit = struct {
        fn f(c: *Ctx, module: []const u8, export_name: []const u8, position: usize, text: []const u8) anyerror!void {
            const idx = zts.parseTypeExpr(c.pool, c.allocator, text);
            if (idx == zts.null_type_idx) {
                c.unparsed += 1;
                return;
            }
            // `unknown` is a type a binding may declare. `unknown` arrived at
            // any other way is the parser giving up, and a signature that gives
            // up is the fallback this gate exists to refuse.
            if (c.pool.getTag(idx) == .t_unknown_type and !std.mem.eql(u8, text, "unknown")) {
                c.fallback_unknown += 1;
            }
            if (c.pool.firstUnresolvedName(idx)) |name| {
                var known = false;
                for (c.unresolved.items) |seen| {
                    if (std.mem.eql(u8, seen, name)) {
                        known = true;
                        break;
                    }
                }
                if (!known) try c.unresolved.append(c.allocator, try c.allocator.dupe(u8, name));
            }
            const digest = try zts.typeDigest(c.pool, c.allocator, idx);
            c.hasher.update(module);
            c.hasher.update(export_name);
            c.hasher.update(std.mem.asBytes(&position));
            c.hasher.update(&digest);
        }
    }.f;

    out_members.* = try forEachSignatureType(Ctx, &ctx, visit);
    try std.testing.expectEqual(@as(usize, 0), ctx.unparsed);
    try std.testing.expectEqual(@as(usize, 0), ctx.fallback_unknown);

    // Three names in the corpus do not resolve *in this pool*, pinned by
    // exact set rather than tolerated: a fourth appearing in the surface
    // fails here.
    //
    // `Record`, which `.object` and `.optional_object` emit as
    // `Record<string, unknown>`. The pool has no index-signature type, so the
    // application stays over an unresolved base.
    //
    // `object`, from a declared signature that spells the coarse object type
    // by its own name. It is unresolved only here: this gate parses each text
    // in a fresh pool with no environment, and `TypePool.assignableStep` gives
    // `object` a rule of its own, so the checker resolves it where it matters.
    //
    // `FetchOptions` and `MessageId`, for the same reason and one step
    // further: each is a real registered alias that
    // `module_types.populateModuleTypes` builds before the export loop, so
    // both resolve everywhere the checker runs and nowhere in this
    // environment-free pool. The gap between the two pipelines is why this set
    // is asserted exactly rather than counted.
    const expected_unresolved = [_][]const u8{ "Record", "object", "FetchOptions", "MessageId" };
    try std.testing.expectEqual(expected_unresolved.len, ctx.unresolved.items.len);
    for (expected_unresolved) |want| {
        var seen = false;
        for (ctx.unresolved.items) |name| {
            if (std.mem.eql(u8, name, want)) seen = true;
        }
        try std.testing.expect(seen);
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// The committed digest of the whole signature surface. Regenerate deliberately:
/// a diff here is a change to what every handler sees from `zttp:*`.
///
/// Moved 2026-08-17 by exactly one export. `zttp:durable.signal` declared two
/// parameters while `signalNative` reads `args[2]` and hands it to the runtime
/// callback, so the payload argument was real and undeclared; it is now
/// `arg_count = 3` with `required_arg_count = 2`. Nothing else in the surface
/// changed - the parameter names added in the same commit are not part of this
/// digest, which covers arity and types.
const frozen_signature_digest = "e143fe92f3656a48d504cdeaed6cf7aafc81a26ffc28288c84fd8fd71a57eb9f";

test "frozen signature corpus: the gate has an input before it has a verdict" {
    // The floor. A corpus that is empty, or an emitter that writes nothing,
    // satisfies every assertion below over nothing at all - and then gets cited
    // as evidence that every export types.
    try std.testing.expect(zts.builtinModules.len > 0);

    var exports: usize = 0;
    for (zts.builtinModules) |binding| exports += binding.exports.len;
    try std.testing.expect(exports > 0);

    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    generateTypeDefs(&aw.writer);
    const emitted = aw.written();
    try std.testing.expect(emitted.len > 0);

    // Every type name the signatures use is declared in the same file. The
    // emitted surface named `Dict`, `Bytes`, `FetchOptions`, and `MessageId`
    // while the preamble declared none of them, so a `zttp.d.ts` handed to
    // `tsc` reported "Cannot find name 'Dict'" for a handler the zts checker
    // accepts. Asserted by construction rather than by a fixed list: a name
    // that reaches a signature and not the preamble fails here.
    {
        const names = [_][]const u8{ "Dict", "Bytes", "FetchOptions", "MessageId" };
        for (names) |name| {
            if (std.mem.indexOf(u8, emitted, name) == null) continue;
            const declared_type = try std.fmt.allocPrint(allocator, "type {s}", .{name});
            defer allocator.free(declared_type);
            const declared_iface = try std.fmt.allocPrint(allocator, "interface {s}", .{name});
            defer allocator.free(declared_iface);
            try std.testing.expect(std.mem.indexOf(u8, emitted, declared_type) != null or
                std.mem.indexOf(u8, emitted, declared_iface) != null);
        }
    }

    // Coverage, not mere presence: one `declare module` per module and one
    // `export function` per export, so an emitter that silently dropped a
    // module fails here rather than shrinking the corpus in silence.
    try std.testing.expectEqual(zts.builtinModules.len, std.mem.count(u8, emitted, "declare module \""));
    try std.testing.expectEqual(exports, std.mem.count(u8, emitted, "  export function "));
    for (zts.builtinModules) |binding| {
        try std.testing.expect(std.mem.indexOf(u8, emitted, binding.specifier) != null);
    }
}

test "every ReturnKind spells a type the pool parses" {
    // The gate over the corpus can only see kinds some export declares. This
    // one runs over the enum itself, so a kind added without a `returnKindToTs`
    // row that parses is caught at the moment it is added rather than at the
    // moment an export first uses it - which is the window `.bytes` sits in
    // until `zttp:bytes` lands.
    const allocator = std.testing.allocator;
    var pool = zts.TypePool.init(allocator);
    defer pool.deinit(allocator);

    const kinds = std.enums.values(@import("zts").module_binding.ReturnKind);
    try std.testing.expect(kinds.len > 0);
    for (kinds) |kind| {
        const text = returnKindToTs(kind);
        const idx = zts.parseTypeExpr(&pool, allocator, text);
        try std.testing.expect(idx != zts.null_type_idx);
        if (kind != .unknown) {
            try std.testing.expect(pool.getTag(idx) != .t_unknown_type);
        }
    }

    // `.bytes` in particular resolves to the primitive rather than to a name
    // the checker would then have to look up and fail to find.
    const bytes_idx = zts.parseTypeExpr(&pool, allocator, returnKindToTs(.bytes));
    try std.testing.expectEqual(pool.idx_bytes, bytes_idx);
    try std.testing.expect(pool.firstUnresolvedName(bytes_idx) == null);
}

test "frozen signature corpus: every export types, with no fallback to unknown" {
    const allocator = std.testing.allocator;
    var members: usize = 0;
    _ = try signatureCorpusDigest(allocator, &members);
    // The floor again, on the unit this test actually iterates: a member count
    // of zero would pass the assertions inside for the same empty reason.
    try std.testing.expect(members > 0);
}

test "frozen signature corpus: digests are stable and match the committed pin" {
    const allocator = std.testing.allocator;
    var first_members: usize = 0;
    var second_members: usize = 0;
    const first = try signatureCorpusDigest(allocator, &first_members);
    const second = try signatureCorpusDigest(allocator, &second_members);
    try std.testing.expectEqual(first_members, second_members);
    try std.testing.expectEqualSlices(u8, &first, &second);

    var hex: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (first, 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0x0f];
    }
    try std.testing.expectEqualStrings(frozen_signature_digest, &hex);
}
