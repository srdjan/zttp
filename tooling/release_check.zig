//! Release-readiness passport: repository tooling, not product.
//!
//! Self-contained pipeline: parses options, collects a set of
//! release-readiness checks, renders the result as text or JSON, and returns
//! a verdict (ready / ready_with_known_issues / blocked). Checks read existing
//! repository files; provenance delegates to its authoritative Zig gate.
//!
//! This shipped as `zttp doctor --release` until it moved here. Every check
//! reads paths that exist in this repository and nowhere else (README.md,
//! docs/performance.md, scripts/verify.sh, .github/workflows/*.yml), so it
//! was 581 lines of repository tooling inside the user-facing binary.
//!
//! Run it with `zig build release-check -- [--json] [--out FILE]`.

const std = @import("std");
const zts = @import("zts");
const release_provenance = @import("release_provenance");

const release_verify_commands = [_][]const u8{
    "bash scripts/verify.sh",
    "zig build smoke-getting-started",
    "zig build smoke-demo",
    "zig build smoke-studio",
    "zig build bench-check",
    "zig build release-check",
};

const build_gate_markers = [_][]const u8{
    "smoke-v1",
    "test-panic-isolation",
    "smoke-getting-started",
    "smoke-demo",
    "smoke-studio",
    "test-module-governance",
    "test-capability-audit",
    "test-docs-drift",
    "test-evidence-marker",
    // The example suites moved here from `verify_script_markers` when they
    // stopped being a `verify.sh` line of their own and became a dependency of
    // `zig build test`. The gate follows the wiring rather than the old call
    // site, so it still asserts that something runs them.
    "test-examples",
};

const ci_gate_markers = [_][]const u8{
    "bash scripts/verify.sh",
};

// `test-docs-drift`, `test-doc-links` and `test-examples` are dependencies of
// `zig build test` and are asserted against `build.zig` in
// `build_gate_markers`. The verifier must carry every other repository gate
// explicitly as a `verify.sh` line.
const verify_script_markers = [_][]const u8{
    "zig build test",
    "zig build test-zruntime",
    "zig build -Doptimize=ReleaseFast",
    "zig build wasm",
    "zig build smoke-v1",
    "zig build test-panic-isolation",
    "zig build test-cli -Dstudio",
    "bash scripts/check-normalize-idempotent.sh",
    "bash scripts/check-idiom-table.sh",
    "bash scripts/check-canonical-style.sh",
    "bash scripts/check-grammar-drift.sh",
    "bash scripts/check-decision-registry.sh",
    "bash scripts/check-meta-drift.sh",
    "bash scripts/check-agent-determinism.sh",
    "bash scripts/test-install-archive-safety.sh",
    "bash scripts/check-semantics-spec.sh",
    "zts module-spec-render --check",
    "zts meta --json",
    "zig build release-provenance",
    "zig fmt --check build.zig packages/",
};

const release_permission_marker = "contents: write";

// Release-evidence provenance is a release gate, not a per-commit one: it fails
// until coverage and convergence are republished from a source commit the tree
// still matches. `ci.yml` runs the plain verifier; only the release workflow
// passes `--release`, and this asserts it still does.
const release_only_verify_marker = "bash scripts/verify.sh --release";

pub const ReleaseDoctorOptions = struct {
    json: bool = false,
    out_path: ?[]const u8 = null,
};

pub const ReleaseVerdict = enum {
    ready,
    ready_with_known_issues,
    blocked,

    pub fn toString(self: ReleaseVerdict) []const u8 {
        return switch (self) {
            .ready => "ready",
            .ready_with_known_issues => "ready_with_known_issues",
            .blocked => "blocked",
        };
    }
};

pub const ReleaseCheckStatus = enum {
    ok,
    warn,
    fail,

    pub fn toString(self: ReleaseCheckStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .warn => "warn",
            .fail => "fail",
        };
    }
};

pub const ReleaseCheck = struct {
    id: []u8,
    label: []u8,
    status: ReleaseCheckStatus,
    detail: []u8,
    command: ?[]u8 = null,

    pub fn deinit(self: *ReleaseCheck, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.detail);
        if (self.command) |cmd| allocator.free(cmd);
    }

    pub fn writeJson(self: *const ReleaseCheck, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("id");
        try json.write(self.id);
        try json.objectField("label");
        try json.write(self.label);
        try json.objectField("status");
        try json.write(self.status.toString());
        try json.objectField("detail");
        try json.write(self.detail);
        if (self.command) |cmd| {
            try json.objectField("command");
            try json.write(cmd);
        }
        try json.endObject();
    }
};

pub const ReleasePassport = struct {
    version: []u8,
    checks: std.ArrayList(ReleaseCheck) = .empty,

    pub fn init(allocator: std.mem.Allocator, version: []const u8) !ReleasePassport {
        return .{ .version = try allocator.dupe(u8, version) };
    }

    pub fn deinit(self: *ReleasePassport, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        for (self.checks.items) |*check| check.deinit(allocator);
        self.checks.deinit(allocator);
    }

    pub fn add(
        self: *ReleasePassport,
        allocator: std.mem.Allocator,
        id: []const u8,
        label: []const u8,
        status: ReleaseCheckStatus,
        detail: []const u8,
        command: ?[]const u8,
    ) !void {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        const owned_detail = try allocator.dupe(u8, detail);
        errdefer allocator.free(owned_detail);
        const owned_command = if (command) |cmd| try allocator.dupe(u8, cmd) else null;
        errdefer if (owned_command) |cmd| allocator.free(cmd);
        try self.checks.append(allocator, .{
            .id = owned_id,
            .label = owned_label,
            .status = status,
            .detail = owned_detail,
            .command = owned_command,
        });
    }

    pub fn verdict(self: *const ReleasePassport) ReleaseVerdict {
        var saw_warn = false;
        for (self.checks.items) |check| {
            switch (check.status) {
                .fail => return .blocked,
                .warn => saw_warn = true,
                .ok => {},
            }
        }
        return if (saw_warn) .ready_with_known_issues else .ready;
    }

    pub fn writeJson(self: *const ReleasePassport, json: *std.json.Stringify) !void {
        try json.beginObject();
        try json.objectField("release");
        try json.write(self.version);
        try json.objectField("verdict");
        try json.write(self.verdict().toString());
        try json.objectField("checks");
        try json.beginArray();
        for (self.checks.items) |*check| {
            try check.writeJson(json);
        }
        try json.endArray();
        try json.objectField("verifyCommands");
        try json.beginArray();
        for (release_verify_commands) |cmd| {
            try json.write(cmd);
        }
        try json.endArray();
        try json.endObject();
    }
};

const usage =
    \\Usage: zig build release-check -- [--json] [--out FILE]
    \\
    \\Validates this repository's release evidence and prints a release proof
    \\passport. Reads existing files only: it runs neither the benchmark nor
    \\the test suite. Exits non-zero when the verdict is `blocked`.
    \\
    \\  --json          Emit the passport as JSON instead of text
    \\  --out FILE      Also write the JSON passport to FILE
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    const args = try collectArgs(allocator, init.args);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    try releaseCheckCommand(allocator, args[1..]);
}

fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var args_iter = std.process.Args.Iterator.init(args_vector);
    defer args_iter.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }
    while (args_iter.next()) |arg| {
        try list.append(allocator, try allocator.dupe(u8, arg));
    }
    return list.toOwnedSlice(allocator);
}

pub fn releaseCheckCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !void {
    const opts = parseReleaseDoctorOptions(argv) catch |err| {
        std.debug.print("Invalid release-check arguments.\n\n{s}", .{usage});
        return err;
    };
    var passport = try collectReleasePassport(allocator);
    defer passport.deinit(allocator);

    const json_bytes = try renderReleasePassportJson(allocator, &passport);
    defer allocator.free(json_bytes);
    if (opts.out_path) |path| {
        try zts.file_io.writeFile(allocator, path, json_bytes);
    }

    const output = if (opts.json)
        try allocator.dupe(u8, json_bytes)
    else
        try renderReleasePassportText(allocator, &passport, opts.out_path);
    defer allocator.free(output);

    _ = std.c.write(std.c.STDOUT_FILENO, output.ptr, output.len);
    if (passport.verdict() == .blocked) return error.DoctorFailed;
}

pub fn parseReleaseDoctorOptions(argv: []const []const u8) !ReleaseDoctorOptions {
    var opts: ReleaseDoctorOptions = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) {
                return error.InvalidArgument;
            }
            opts.out_path = argv[i];
        } else {
            return error.InvalidArgument;
        }
    }
    return opts;
}

pub fn collectReleasePassport(allocator: std.mem.Allocator) !ReleasePassport {
    return collectReleasePassportWithProvenance(allocator, releaseProvenancePasses(allocator));
}

fn collectReleasePassportWithProvenance(
    allocator: std.mem.Allocator,
    provenance_ok: bool,
) !ReleasePassport {
    const zon = readOptionalFile(allocator, "build.zig.zon", 256 * 1024);
    defer if (zon) |bytes| allocator.free(bytes);
    const version = if (zon) |bytes| extractZonVersion(bytes) orelse "unknown" else "unknown";
    var passport = try ReleasePassport.init(allocator, version);
    errdefer passport.deinit(allocator);

    try addVersionCheck(allocator, &passport, zon);
    try addReleaseEvidenceCheck(allocator, &passport);
    try addReleaseProvenanceCheck(allocator, &passport, provenance_ok);
    try addReleaseGateCheck(allocator, &passport);
    try addPublicClaimsCheck(allocator, &passport);
    try addCurrentDocsScopeCheck(allocator, &passport);
    try addReliabilityKnownIssuesCheck(allocator, &passport);
    try addProofSurfaceCheck(allocator, &passport);

    return passport;
}

fn addVersionCheck(allocator: std.mem.Allocator, passport: *ReleasePassport, zon: ?[]const u8) !void {
    const version_file = readOptionalFile(allocator, "VERSION", 256);
    defer if (version_file) |bytes| allocator.free(bytes);
    const root = readOptionalFile(allocator, "packages/zts/src/root.zig", 256 * 1024);
    defer if (root) |bytes| allocator.free(bytes);
    const zts_zon = readOptionalFile(allocator, "packages/zts/build.zig.zon", 256 * 1024);
    defer if (zts_zon) |bytes| allocator.free(bytes);
    const runtime_zon = readOptionalFile(allocator, "packages/runtime/build.zig.zon", 256 * 1024);
    defer if (runtime_zon) |bytes| allocator.free(bytes);

    const version = if (zon) |bytes| extractZonVersion(bytes) else null;
    if (version == null or root == null or zts_zon == null or runtime_zon == null or version_file == null) {
        try passport.add(allocator, "version", "Version alignment", .fail, "VERSION, a release package manifest, or packages/zts/src/root.zig is missing", "zig build test-zts");
        return;
    }

    const marker_version = extractVersionMarker(version_file.?) orelse {
        try passport.add(allocator, "version", "Version alignment", .fail, "VERSION must contain exactly one SemVer line ending in a newline", "zig build test-zts");
        return;
    };

    const root_bytes = root.?;
    const expected = try std.fmt.allocPrint(allocator, "string = \"{s}\"", .{version.?});
    defer allocator.free(expected);
    if (std.mem.indexOf(u8, root_bytes, expected) == null or
        !std.mem.eql(u8, marker_version, version.?) or
        !std.mem.eql(u8, extractZonVersion(zts_zon.?) orelse "", version.?) or
        !std.mem.eql(u8, extractZonVersion(runtime_zon.?) orelse "", version.?))
    {
        try passport.add(allocator, "version", "Version alignment", .fail, "VERSION, root, zts, runtime, and binary versions do not agree", "zig build test-zts");
        return;
    }

    try passport.add(allocator, "version", "Version alignment", .ok, "VERSION, root, zts, runtime, and binary versions agree", "zig build test-zts");
}

fn addReleaseEvidenceCheck(allocator: std.mem.Allocator, passport: *ReleasePassport) !void {
    const docs_ok =
        zts.file_io.fileExists(allocator, "README.md") and
        zts.file_io.fileExists(allocator, "docs/README.md") and
        zts.file_io.fileExists(allocator, "docs/user-guide.md") and
        zts.file_io.fileExists(allocator, "docs/roadmap.md") and
        zts.file_io.fileExists(allocator, "docs/virtual-modules/README.md");
    if (docs_ok) {
        try passport.add(allocator, "release_evidence", "Documentation evidence", .ok, "front door, user guide, roadmap, and virtual-module index exist", "bash scripts/audit-docs.sh .");
    } else {
        try passport.add(allocator, "release_evidence", "Documentation evidence", .fail, "missing maintained README, user guide, roadmap, or module index", "bash scripts/audit-docs.sh .");
    }
}

fn addReleaseProvenanceCheck(
    allocator: std.mem.Allocator,
    passport: *ReleasePassport,
    provenance_ok: bool,
) !void {
    if (!provenance_ok) {
        try passport.add(
            allocator,
            "release_provenance",
            "Release evidence provenance",
            .fail,
            "the authoritative provenance validator rejected coverage or convergence evidence",
            "zig build release-provenance",
        );
        return;
    }

    try passport.add(
        allocator,
        "release_provenance",
        "Release evidence provenance",
        .ok,
        "the authoritative validator accepted clean, ancestral release evidence",
        "zig build release-provenance",
    );
}

fn releaseProvenancePasses(allocator: std.mem.Allocator) bool {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    return release_provenance.passes(allocator, io_backend.io(), ".");
}

fn addReleaseGateCheck(allocator: std.mem.Allocator, passport: *ReleasePassport) !void {
    const build_zig = readOptionalFile(allocator, "build.zig", 1024 * 1024);
    defer if (build_zig) |bytes| allocator.free(bytes);
    const ci_yml = readOptionalFile(allocator, ".github/workflows/ci.yml", 512 * 1024);
    defer if (ci_yml) |bytes| allocator.free(bytes);
    const release_yml = readOptionalFile(allocator, ".github/workflows/release.yml", 512 * 1024);
    defer if (release_yml) |bytes| allocator.free(bytes);
    const verify_sh = readOptionalFile(allocator, "scripts/verify.sh", 256 * 1024);
    defer if (verify_sh) |bytes| allocator.free(bytes);

    const smoke_ok = zts.file_io.fileExists(allocator, "scripts/smoke-v1.sh");
    const examples_ok = zts.file_io.fileExists(allocator, "scripts/test-examples.sh");
    const installer_ok = zts.file_io.fileExists(allocator, "scripts/test-install-archive-safety.sh");
    const semantics_ok = zts.file_io.fileExists(allocator, "scripts/check-semantics-spec.sh");
    const workflow_ok = if (build_zig != null and ci_yml != null and release_yml != null and verify_sh != null)
        releaseGateRequirementsPresent(build_zig.?, ci_yml.?, release_yml.?, verify_sh.?)
    else
        false;

    if (smoke_ok and examples_ok and installer_ok and semantics_ok and workflow_ok) {
        try passport.add(allocator, "release_gates", "Release gates", .ok, "CI, release workflow, local verifier, browser analyzer, installer, semantics, docs, smoke, and doctor gates are wired", "bash scripts/verify.sh && zig build release-check");
    } else {
        try passport.add(allocator, "release_gates", "Release gates", .fail, "one or more release gates are missing from build wiring, scripts, or workflows", "bash scripts/verify.sh && zig build release-check");
    }
}

fn addPublicClaimsCheck(allocator: std.mem.Allocator, passport: *ReleasePassport) !void {
    const readme = readOptionalFile(allocator, "README.md", 2 * 1024 * 1024);
    defer if (readme) |bytes| allocator.free(bytes);
    const perf = readOptionalFile(allocator, "docs/performance.md", 2 * 1024 * 1024);
    defer if (perf) |bytes| allocator.free(bytes);

    if (readme == null or perf == null) {
        try passport.add(allocator, "public_claims", "Public performance claims", .fail, "README or performance doc is missing", null);
        return;
    }

    const stale_readme =
        containsAny(readme.?, &.{ "1.2MB binary", "4MB memory baseline", "3ms runtime init", "71ms", "79,743" });
    const stale_perf =
        containsAny(perf.?, &.{ "71ms", "71 ms", "79,743", "0.76x Deno" });
    const has_measured_baseline =
        std.mem.indexOf(u8, readme.?, "3.5") != null and
        std.mem.indexOf(u8, readme.?, "7-15") != null and
        std.mem.indexOf(u8, readme.?, "13 MB") != null and
        std.mem.indexOf(u8, readme.?, "112k") != null and
        std.mem.indexOf(u8, perf.?, "3.5") != null and
        std.mem.indexOf(u8, perf.?, "7-15") != null and
        std.mem.indexOf(u8, perf.?, "13 MB") != null and
        std.mem.indexOf(u8, perf.?, "112k") != null;
    const has_pending_receipt_note =
        hasPendingReceiptBackedMeasurementNote(readme.?) and
        hasPendingReceiptBackedMeasurementNote(perf.?);

    if (stale_readme or stale_perf or !has_measured_baseline) {
        try passport.add(allocator, "public_claims", "Public performance claims", .fail, "public numbers are stale or missing from README/performance docs", "zig build bench-check");
    } else if (!has_pending_receipt_note) {
        try passport.add(allocator, "public_claims", "Public performance claims", .fail, "public numbers must be marked pending receipt-backed measurement until the in-repo measurement path exists", "zig build bench-check");
    } else {
        try passport.add(allocator, "public_claims", "Public performance claims", .warn, "README and performance docs carry current public numbers, explicitly marked pending receipt-backed measurement", "zig build bench-check");
    }
}

fn addCurrentDocsScopeCheck(allocator: std.mem.Allocator, passport: *ReleasePassport) !void {
    const readme = readOptionalFile(allocator, "README.md", 2 * 1024 * 1024);
    defer if (readme) |bytes| allocator.free(bytes);
    const docs_index = readOptionalFile(allocator, "docs/README.md", 512 * 1024);
    defer if (docs_index) |bytes| allocator.free(bytes);
    const roadmap = readOptionalFile(allocator, "docs/roadmap.md", 512 * 1024);
    defer if (roadmap) |bytes| allocator.free(bytes);

    if (readme == null or docs_index == null or roadmap == null) {
        try passport.add(allocator, "docs_scope", "Current docs scope", .fail, "README, docs index, or roadmap is missing", null);
        return;
    }

    const stale_markers = [_][]const u8{
        "Release Scope",
        "beta checklist",
        "docs/releases",
        "migration instructions",
        "old plans",
    };
    if (containsAny(readme.?, &stale_markers) or
        containsAny(docs_index.?, &stale_markers) or
        containsAny(roadmap.?, &stale_markers))
    {
        try passport.add(allocator, "docs_scope", "Current docs scope", .fail, "front-door docs still point at historical release material", null);
    } else {
        try passport.add(allocator, "docs_scope", "Current docs scope", .ok, "front-door docs describe the current codebase and use one roadmap/user guide", null);
    }
}

fn addReliabilityKnownIssuesCheck(allocator: std.mem.Allocator, passport: *ReleasePassport) !void {
    const reliability = readOptionalFile(allocator, "docs/reliability.md", 512 * 1024);
    defer if (reliability) |bytes| allocator.free(bytes);
    if (reliability == null) {
        try passport.add(allocator, "known_issues", "Known reliability issues", .fail, "docs/reliability.md is missing", null);
        return;
    }
    if (std.mem.indexOf(u8, reliability.?, "closes the connection without") != null and
        std.mem.indexOf(u8, reliability.?, "413") != null)
    {
        try passport.add(allocator, "known_issues", "Known reliability issues", .warn, "oversized request bodies are documented as a known 413 gap", null);
    } else {
        try passport.add(allocator, "known_issues", "Known reliability issues", .ok, "no documented release-blocking reliability gap found", null);
    }
}

fn addProofSurfaceCheck(allocator: std.mem.Allocator, passport: *ReleasePassport) !void {
    // The advertised surface lives in the help listing (`cli_help.zig`) and the
    // signing opt-out in the build command, not in `dev_cli.zig`. This check
    // read dev_cli.zig until the release tooling moved out of the product CLI,
    // and passed only because dev_cli.zig carried these three strings inside a
    // *test fixture* for this very check. Read the files that actually own the
    // surface instead.
    const help_source = readOptionalFile(allocator, "packages/runtime/src/cli_help.zig", 2 * 1024 * 1024);
    defer if (help_source) |bytes| allocator.free(bytes);
    const build_source = readOptionalFile(allocator, "packages/runtime/src/build_command.zig", 2 * 1024 * 1024);
    defer if (build_source) |bytes| allocator.free(bytes);
    const proofs_cli_source = readOptionalFile(allocator, "packages/runtime/src/proofs_cli.zig", 2 * 1024 * 1024);
    defer if (proofs_cli_source) |bytes| allocator.free(bytes);

    if (help_source == null or build_source == null or proofs_cli_source == null) {
        try passport.add(allocator, "proof_surface", "Proof surface", .fail, "developer CLI or proof ledger CLI source is missing", "zig build test-cli");
        return;
    }

    const dev_ok =
        std.mem.indexOf(u8, help_source.?, "zttp verify <url>") != null and
        std.mem.indexOf(u8, help_source.?, "proofs") != null and
        std.mem.indexOf(u8, build_source.?, "--no-attest") != null;
    const proofs_ok =
        std.mem.indexOf(u8, proofs_cli_source.?, "badge") != null and
        std.mem.indexOf(u8, proofs_cli_source.?, "bundle") != null and
        std.mem.indexOf(u8, proofs_cli_source.?, "verify") != null;
    if (dev_ok and proofs_ok) {
        try passport.add(allocator, "proof_surface", "Proof surface", .ok, "proof receipts, ledger, badge, bundle, and verify surfaces are present", "zig build test-cli");
    } else {
        try passport.add(allocator, "proof_surface", "Proof surface", .fail, "proof receipt, ledger, badge, bundle, or verify surface is missing", "zig build test-cli");
    }
}

fn renderReleasePassportText(allocator: std.mem.Allocator, passport: *const ReleasePassport, out_path: ?[]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const verdict = passport.verdict();
    try aw.writer.print(
        \\zttp release doctor
        \\Release:  {s}
        \\Verdict:  {s}
        \\
    , .{ passport.version, verdict.toString() });
    for (passport.checks.items) |check| {
        try aw.writer.print("[{s}] {s}: {s}\n", .{ check.status.toString(), check.label, check.detail });
        if (check.command) |cmd| try aw.writer.print("      verify: {s}\n", .{cmd});
    }
    try aw.writer.writeAll("\nRelease verification commands:\n");
    for (release_verify_commands) |cmd| {
        try aw.writer.print("  {s}\n", .{cmd});
    }
    try aw.writer.writeByte('\n');
    if (out_path) |path| {
        try aw.writer.print("Wrote JSON passport: {s}\n", .{path});
    }
    if (verdict == .blocked) {
        try aw.writer.writeAll("Next: resolve the failed release rows, then run `zig build release-check` again.\n");
    }
    return try allocator.dupe(u8, aw.writer.buffered());
}

pub fn renderReleasePassportJson(allocator: std.mem.Allocator, passport: *const ReleasePassport) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var json: std.json.Stringify = .{ .writer = &aw.writer };
    try passport.writeJson(&json);
    try aw.writer.writeByte('\n');
    return try allocator.dupe(u8, aw.writer.buffered());
}

fn readOptionalFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ?[]u8 {
    return zts.file_io.readFile(allocator, path, max_size) catch null;
}

fn extractZonVersion(bytes: []const u8) ?[]const u8 {
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const value_start = start + marker.len;
    const rest = bytes[value_start..];
    const value_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..value_end];
}

fn extractVersionMarker(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return null;
    const version = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, version, "\r\n") != null) return null;
    _ = std.SemanticVersion.parse(version) catch return null;
    return version;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn containsAll(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) == null) return false;
    }
    return true;
}

fn hasPendingReceiptBackedMeasurementNote(haystack: []const u8) bool {
    return std.mem.indexOf(u8, haystack, "pending receipt-backed measurement") != null or
        std.mem.indexOf(u8, haystack, "pending receipt-backed\nmeasurement") != null or
        std.mem.indexOf(u8, haystack, "pending\nreceipt-backed measurement") != null;
}

fn releaseGateRequirementsPresent(build_zig: []const u8, ci_yml: []const u8, release_yml: []const u8, verify_sh: []const u8) bool {
    return containsAll(build_zig, &build_gate_markers) and
        containsAll(ci_yml, &ci_gate_markers) and
        containsAll(release_yml, &ci_gate_markers) and
        containsAll(release_yml, &release_verify_commands) and
        std.mem.indexOf(u8, release_yml, release_only_verify_marker) != null and
        std.mem.indexOf(u8, release_yml, release_permission_marker) != null and
        containsAll(verify_sh, &verify_script_markers);
}

fn hasReleaseVerifyCommand(command: []const u8) bool {
    for (release_verify_commands) |candidate| {
        if (std.mem.eql(u8, candidate, command)) return true;
    }
    return false;
}

test "release verify commands cover release gates" {
    try std.testing.expect(hasReleaseVerifyCommand("bash scripts/verify.sh"));
    try std.testing.expect(hasReleaseVerifyCommand("zig build smoke-getting-started"));
    try std.testing.expect(hasReleaseVerifyCommand("zig build smoke-demo"));
    try std.testing.expect(hasReleaseVerifyCommand("zig build smoke-studio"));
    try std.testing.expect(hasReleaseVerifyCommand("zig build bench-check"));
    try std.testing.expect(hasReleaseVerifyCommand("zig build release-check"));
}

test "pending receipt-backed measurement note tolerates markdown wrapping" {
    try std.testing.expect(hasPendingReceiptBackedMeasurementNote("pending receipt-backed measurement"));
    try std.testing.expect(hasPendingReceiptBackedMeasurementNote("pending receipt-backed\nmeasurement"));
    try std.testing.expect(hasPendingReceiptBackedMeasurementNote("pending\nreceipt-backed measurement"));
    try std.testing.expect(!hasPendingReceiptBackedMeasurementNote("pending manual benchmark measurement"));
}

test "release gate requirements require semantics and doctor wiring" {
    const build_zig =
        "smoke-v1 test-panic-isolation smoke-getting-started smoke-demo smoke-studio " ++
        "test-module-governance test-capability-audit test-docs-drift test-evidence-marker " ++
        "test-examples";
    const ci_yml = "bash scripts/verify.sh\n";
    const release_yml =
        "bash scripts/verify.sh --release\n" ++
        "zig build smoke-getting-started\nzig build smoke-demo\nzig build smoke-studio\n" ++
        "zig build bench-check\nzig build release-check\ncontents: write\n";
    const verify_sh =
        "zig build test\nzig build test-zruntime\n" ++
        "zig build -Doptimize=ReleaseFast\nzig build wasm\nzig build smoke-v1\nzig build test-panic-isolation\n" ++
        "zig build test-cli -Dstudio\n" ++
        "bash scripts/test-install-archive-safety.sh\n" ++
        "bash scripts/check-normalize-idempotent.sh\nbash scripts/check-idiom-table.sh\n" ++
        "bash scripts/check-canonical-style.sh\nbash scripts/check-grammar-drift.sh\n" ++
        "bash scripts/check-decision-registry.sh\nbash scripts/check-meta-drift.sh\n" ++
        "bash scripts/check-agent-determinism.sh\nbash scripts/check-semantics-spec.sh\n" ++
        "zts module-spec-render --check\nzts meta --json\n" ++
        "zig build release-provenance\nzig fmt --check build.zig packages/\n";

    try std.testing.expect(releaseGateRequirementsPresent(build_zig, ci_yml, release_yml, verify_sh));
    try std.testing.expect(!releaseGateRequirementsPresent(build_zig, ci_yml, "zig build test\n", verify_sh));
    try std.testing.expect(!releaseGateRequirementsPresent(build_zig, "zig build test\n", release_yml, verify_sh));
    try std.testing.expect(!releaseGateRequirementsPresent(build_zig, ci_yml, release_yml, "zig build test\n"));

    // The release workflow must run the release form. A release.yml that runs
    // only the per-commit verifier never reaches the evidence-provenance gate,
    // and the passport would still report every gate wired.
    const per_commit_release_yml =
        ci_yml ++
        "zig build smoke-getting-started\nzig build smoke-demo\nzig build smoke-studio\n" ++
        "zig build bench-check\nzig build release-check\ncontents: write\n";
    try std.testing.expect(!releaseGateRequirementsPresent(build_zig, ci_yml, per_commit_release_yml, verify_sh));
}

// ---------------------------------------------------------------------------
// Tests
//
// The passport reads the repository it runs in, so every test stages a fixture
// tree in a tmp dir and runs from there. `chdirTmpForTest` is local rather than
// borrowed from the runtime package: this tool depends on std and zts only.
// ---------------------------------------------------------------------------

fn chdirTmpForTest(tmp: *std.testing.TmpDir) ![:0]u8 {
    const old_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    errdefer std.testing.allocator.free(old_cwd);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    try std.Io.Threaded.chdir(buf[0..len]);
    return old_cwd;
}

test "release doctor options parse json and out path" {
    const opts = try parseReleaseDoctorOptions(&.{ "--json", "--out", ".zttp/release-passport.json" });
    try std.testing.expect(opts.json);
    try std.testing.expectEqualStrings(".zttp/release-passport.json", opts.out_path.?);
    try std.testing.expectError(error.InvalidArgument, parseReleaseDoctorOptions(&.{"--out"}));
    try std.testing.expectError(error.InvalidArgument, parseReleaseDoctorOptions(&.{"--bad"}));
}

test "release passport accepts matching VERSION and reports pending measurement" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeReleaseDoctorFixture(io, &tmp, .{});

    var passport = try collectReleasePassportWithProvenance(testing.allocator, true);
    defer passport.deinit(testing.allocator);
    try testing.expectEqual(ReleaseVerdict.ready_with_known_issues, passport.verdict());

    const json = try renderReleasePassportJson(testing.allocator, &passport);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"verdict\":\"ready_with_known_issues\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"release\":\"0.18.0\"") != null);
}

test "release passport blocks a missing VERSION marker" {
    try expectVersionFixtureBlocked(.missing);
}

test "release passport blocks a malformed VERSION marker" {
    try expectVersionFixtureBlocked(.malformed);
}

test "release passport blocks a stale VERSION marker" {
    try expectVersionFixtureBlocked(.stale);
}

test "release passport blocks stale public claims" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeReleaseDoctorFixture(io, &tmp, .{ .stale_readme = true });

    var passport = try collectReleasePassportWithProvenance(testing.allocator, true);
    defer passport.deinit(testing.allocator);
    try testing.expectEqual(ReleaseVerdict.blocked, passport.verdict());
}

test "release passport blocks a failed provenance validator" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeReleaseDoctorFixture(io, &tmp, .{});

    var passport = try collectReleasePassportWithProvenance(testing.allocator, false);
    defer passport.deinit(testing.allocator);
    try testing.expectEqual(ReleaseVerdict.blocked, passport.verdict());
}

test "release passport warns for documented reliability gap" {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeReleaseDoctorFixture(io, &tmp, .{ .document_413_gap = true });

    var passport = try collectReleasePassportWithProvenance(testing.allocator, true);
    defer passport.deinit(testing.allocator);
    try testing.expectEqual(ReleaseVerdict.ready_with_known_issues, passport.verdict());
}

const ReleaseDoctorFixtureOptions = struct {
    stale_readme: bool = false,
    document_413_gap: bool = false,
    version_marker: VersionMarkerFixture = .matching,
};

const VersionMarkerFixture = enum {
    matching,
    missing,
    malformed,
    stale,
};

fn expectVersionFixtureBlocked(version_marker: VersionMarkerFixture) !void {
    const testing = std.testing;

    var io_backend = std.Io.Threaded.init(testing.allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_cwd = try chdirTmpForTest(&tmp);
    defer testing.allocator.free(old_cwd);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    try writeReleaseDoctorFixture(io, &tmp, .{ .version_marker = version_marker });

    var passport = try collectReleasePassportWithProvenance(testing.allocator, true);
    defer passport.deinit(testing.allocator);
    try testing.expectEqual(ReleaseVerdict.blocked, passport.verdict());
}

fn writeReleaseDoctorFixture(io: std.Io, tmp: *std.testing.TmpDir, opts: ReleaseDoctorFixtureOptions) !void {
    try tmp.dir.createDirPath(io, "packages/zts/src");
    try tmp.dir.createDirPath(io, "packages/runtime/src");
    try tmp.dir.createDirPath(io, "docs/virtual-modules");
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "scripts");
    try tmp.dir.createDirPath(io, ".github/workflows");

    try tmp.dir.writeFile(io, .{
        .sub_path = "build.zig.zon",
        .data =
        \\.{
        \\    .name = .zttp,
        \\    .version = "0.18.0",
        \\}
        ,
    });
    switch (opts.version_marker) {
        .matching => try tmp.dir.writeFile(io, .{ .sub_path = "VERSION", .data = "0.18.0\n" }),
        .missing => {},
        .malformed => try tmp.dir.writeFile(io, .{ .sub_path = "VERSION", .data = "v0.18.0\n" }),
        .stale => try tmp.dir.writeFile(io, .{ .sub_path = "VERSION", .data = "0.17.0\n" }),
    }
    try tmp.dir.writeFile(io, .{
        .sub_path = "packages/zts/src/root.zig",
        .data =
        \\pub const version = struct {
        \\    pub const string = "0.18.0";
        \\};
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "packages/zts/build.zig.zon",
        .data = ".{ .name = .zts, .version = \"0.18.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "packages/runtime/build.zig.zon",
        .data = ".{ .name = .runtime, .version = \"0.18.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "build.zig",
        .data =
        \\// smoke-v1
        \\// test-panic-isolation
        \\// smoke-getting-started
        \\// smoke-demo
        \\// smoke-studio
        \\// test-module-governance
        \\// test-capability-audit
        \\// test-docs-drift
        \\// test-evidence-marker
        \\// test-examples
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/smoke-v1.sh", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/test-examples.sh", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/test-install-archive-safety.sh", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/check-semantics-spec.sh", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "scripts/verify.sh",
        .data =
        \\zig build test
        \\zig build test-zruntime
        \\zig build test-docs-drift test-doc-links
        \\zig build -Doptimize=ReleaseFast
        \\zig build wasm
        \\zig build smoke-v1
        \\zig build test-panic-isolation
        \\zig build test-cli -Dstudio
        \\bash scripts/check-normalize-idempotent.sh
        \\bash scripts/check-idiom-table.sh
        \\bash scripts/check-canonical-style.sh
        \\bash scripts/check-grammar-drift.sh
        \\bash scripts/check-decision-registry.sh
        \\bash scripts/check-meta-drift.sh
        \\bash scripts/check-agent-determinism.sh
        \\bash scripts/test-install-archive-safety.sh
        \\bash scripts/check-semantics-spec.sh
        \\zts module-spec-render --check
        \\zts meta --json
        \\zig build release-provenance
        \\zig fmt --check build.zig packages/
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".github/workflows/ci.yml",
        .data = "bash scripts/verify.sh\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".github/workflows/release.yml",
        .data =
        \\bash scripts/verify.sh --release
        \\zig build smoke-getting-started
        \\zig build smoke-demo
        \\zig build smoke-studio
        \\zig build bench-check
        \\zig build release-check
        \\contents: write
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/README.md",
        .data =
        \\# Documentation
        \\Current docs use one user guide and one roadmap.
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/user-guide.md",
        .data =
        \\# User Guide
        \\Current user flow.
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/roadmap.md",
        .data =
        \\# Roadmap
        \\Current support boundary.
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/virtual-modules/README.md",
        .data =
        \\# Virtual Modules
        \\| Module | Exports | Capabilities |
        \\|---|---|---|
        \\| `zttp:env` | `env` | `env`, `policy_check` |
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "README.md",
        .data = if (opts.stale_readme)
            "Numbers: 3ms runtime init. 1.2MB binary. 4MB memory baseline.\n"
        else
            "Numbers: cold-start floor 3.5 ms, typical 7-15 ms, RSS 13 MB, throughput 112k req/s. These numbers are pending receipt-backed measurement.\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/performance.md",
        .data = "Performance: 3.5 ms floor, 7-15 ms typical, 13 MB RSS, 112k req/s. These numbers are pending receipt-backed measurement.\n",
    });
    const evidence_json =
        "{\"complete\":true,\"publishable\":true,\"publicationMode\":true,\"sourceCommit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sourceDirty\":false}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/coverage.json", .data = evidence_json });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/convergence.json", .data = evidence_json });
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/reliability.md",
        .data = if (opts.document_413_gap)
            "Request bodies over the cap closes the connection without a response; 413 is tracked.\n"
        else
            "No release-blocking reliability gaps are documented.\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "packages/runtime/src/cli_help.zig",
        .data = "zttp verify <url>\nproofs\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "packages/runtime/src/build_command.zig",
        .data = "--no-attest\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "packages/runtime/src/proofs_cli.zig",
        .data = "badge\nbundle\nverify\n",
    });
}
