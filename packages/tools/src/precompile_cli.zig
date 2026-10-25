//! The `-Dhandler` code generation CLI: argument handling and the generated Zig file writers.

const std = @import("std");
const builtin = @import("builtin");
const zts = @import("zts");
const handler_contract = zts.handler_contract;
const writeContractJson = zts.writeContractJson;
const HandlerContract = zts.HandlerContract;
const handler_policy = zts.handler_policy;
const HandlerPolicy = zts.HandlerPolicy;
const util = @import("precompile_util.zig");
const retired_authority = @import("project_config").retired_authority;
const args_mod = @import("precompile_args.zig");
const parsePrecompileArgSlice = args_mod.parsePrecompileArgSlice;
const collectModuleManifestPaths = args_mod.collectModuleManifestPaths;
const buildManifestRegistryFromPaths = args_mod.buildManifestRegistryFromPaths;
const collectArgs = args_mod.collectArgs;
const readFilePosix = zts.file_io.readFile;
/// Write a file synchronously using posix operations
const writeFilePosix = util.writeFilePosix;
/// Derive contract.json path from the output .zig path.
const deriveSiblingPath = util.deriveSiblingPath;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;
const readFailureReason = stderr_mod.readFailureReason;
const pc = @import("precompile.zig");
const compileHandler = pc.compileHandler;
const reports_mod = @import("precompile_reports.zig");
const printSandboxReport = reports_mod.printSandboxReport;
const printPropertiesReport = reports_mod.printPropertiesReport;
const CompiledHandler = pc.CompiledHandler;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: if (builtin.mode == .debug) std.heap.SafeAllocator else void =
        if (builtin.mode == .debug) .init(std.heap.page_allocator, .{}) else {};
    defer if (builtin.mode == .debug) {
        _ = debug_alloc.deinit();
    };
    const allocator = if (builtin.mode == .debug) debug_alloc.allocator() else std.heap.smp_allocator;

    const argv = try collectArgs(allocator, init.args);
    defer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    try runCompileWithArgs(allocator, argv[1..]);
}

pub fn runCompileWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const opts = parsePrecompileArgSlice(argv) catch |err| {
        if (err == error.MissingArgument) return;
        return err;
    };

    // Partner virtual-module manifests (--module-manifest <path>, repeatable).
    // Read, parse, validate, and register before compilation. Failures here
    // fail loud: a malformed manifest must not silently compile to nothing.
    const manifest_paths = collectModuleManifestPaths(allocator, argv) catch |err| {
        if (err == error.MissingArgument) return;
        return err;
    };
    defer allocator.free(manifest_paths);

    var manifest_registry = if (manifest_paths.len > 0)
        try buildManifestRegistryFromPaths(allocator, manifest_paths)
    else
        zts.ManifestRegistry.init(allocator);
    defer manifest_registry.deinit();

    const registry_ptr: ?*const zts.ManifestRegistry =
        if (manifest_paths.len > 0) &manifest_registry else null;

    const handler_path_final = opts.handler_path;
    const output_path_final = opts.output_path;
    const emit_verify = opts.emit_verify;
    const emit_contract = opts.emit_contract;
    const sql_schema_path = opts.sql_schema_path;
    const policy_path = opts.policy_path;

    // Read the handler source file (using posix for synchronous I/O)
    // Each read failure is printed here. A distinct error lets the CLI exit 1
    // without a stack trace, as `zttp build` does with `HandlerReadFailed`.
    const source = readFilePosix(allocator, handler_path_final, 10 * 1024 * 1024) catch |err| {
        debugPrint("Error reading handler file '{s}': {s}\n", .{ handler_path_final, readFailureReason(err) });
        return error.HandlerReadFailed;
    };
    defer allocator.free(source);

    var policy: ?HandlerPolicy = null;
    defer if (policy) |*p| p.deinit(allocator);
    if (policy_path) |path| {
        const policy_source = readFilePosix(allocator, path, 1024 * 1024) catch |err| {
            debugPrint("Error reading policy file '{s}': {s}\n", .{ path, readFailureReason(err) });
            return error.PolicyReadFailed;
        };
        defer allocator.free(policy_source);

        policy = handler_policy.parsePolicyJson(allocator, policy_source) catch |err| {
            debugPrint("Error parsing policy file '{s}': {}\n", .{ path, err });
            const help = handler_policy.policyErrorHelp(err);
            if (help.len > 0) debugPrint("{s}\n", .{help});
            return err;
        };
    }

    debugPrint("Compiling handler: {s} ({d} bytes)\n", .{ handler_path_final, source.len });

    // Compile the handler to bytecode (+ optional verification + optional contract)
    var compiled = compileHandler(allocator, source, handler_path_final, .{
        .emit_verify = emit_verify,
        .emit_contract = emit_contract,
        .policy = policy,
        .sql_schema_path = sql_schema_path,
        .manifest_registry = registry_ptr,
    }) catch |err| {
        debugPrint("Compilation failed: {}\n", .{err});
        return err;
    };
    defer compiled.deinit(allocator);

    var retired_facts: retired_authority.Facts = .{};
    if (compiled.contract) |*contract| retired_facts = retired_authority.contractFacts(contract);
    if (retired_authority.first(retired_facts)) |feature| {
        debugPrint("Precompile refused retired runtime authority: {s}\n", .{feature.sentence()});
        return error.UnsupportedRuntimeAuthority;
    }

    // Deferred verification failure: violations enriched with counterexamples, return error now.
    if (compiled.verify_failed) {
        if (compiled.violations_jsonl) |viol_jsonl| {
            const viol_path = deriveSiblingPath(allocator, output_path_final, "handler.violations.jsonl") catch |err| {
                debugPrint("Error deriving violations output path: {}\n", .{err});
                return error.VerificationFailed;
            };
            defer allocator.free(viol_path);
            var violations_written = true;
            writeFilePosix(viol_path, viol_jsonl, allocator) catch |err| {
                debugPrint("Error writing violations file '{s}': {}\n", .{ viol_path, err });
                violations_written = false;
            };
            if (compiled.violations_summary) |summary| debugPrint("{s}", .{summary});
            if (violations_written) {
                debugPrint("  Counterexample tests written to: {s}\n", .{viol_path});
                debugPrint("  Run: zig build run -- {s} --test {s}\n", .{ output_path_final, viol_path });
            }
        } else if (compiled.violations_summary) |summary| {
            debugPrint("{s}", .{summary});
        }
        return error.VerificationFailed;
    }

    debugPrint("Generated bytecode: {d} bytes\n", .{compiled.bytecode.len});

    // Write the output Zig file
    writeZigFile(output_path_final, compiled, policy, allocator) catch |err| {
        debugPrint("Error writing output file '{s}': {}\n", .{ output_path_final, err });
        return err;
    };

    debugPrint("Wrote embedded handler to: {s}\n", .{output_path_final});

    // Print sandbox report when auto-deriving from contract (no explicit policy)
    if (policy == null) {
        if (compiled.contract) |*contract| {
            printSandboxReport(contract);
        }
    }

    // Print handler effect properties
    if (compiled.contract) |*contract| {
        printPropertiesReport(contract);
    }

    if (compiled.contract) |*contract| {
        // Stamp the compiled-artifact hash so the runtime can verify the
        // embedded bytecode at boot against the contract it shipped with.
        std.crypto.hash.sha2.Sha256.hash(compiled.bytecode, &contract.artifact_sha256, .{});

        // Write contract.json alongside the output if requested
        if (emit_contract) {
            const contract_path = deriveSiblingPath(allocator, output_path_final, "contract.json") catch |err| {
                debugPrint("Error deriving contract path: {}\n", .{err});
                return err;
            };
            defer allocator.free(contract_path);

            var json_output: std.ArrayList(u8) = .empty;
            defer json_output.deinit(allocator);
            var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &json_output);

            writeContractJson(contract, &aw.writer) catch |err| {
                debugPrint("Error serializing contract: {}\n", .{err});
                return err;
            };
            json_output = aw.toArrayList();

            writeFilePosix(contract_path, json_output.items, allocator) catch |err| {
                debugPrint("Error writing contract file '{s}': {}\n", .{ contract_path, err });
                return err;
            };

            debugPrint("Wrote contract manifest to: {s}\n", .{contract_path});
        }

        // Write the generated tests. A contract build always generates them
        // to populate the behavioral paths.
        if (compiled.generated_tests) |tests_jsonl| {
            const tests_path = deriveSiblingPath(allocator, output_path_final, "handler.auto-tests.jsonl") catch |err| {
                debugPrint("Error deriving test output path: {}\n", .{err});
                return err;
            };
            defer allocator.free(tests_path);

            writeFilePosix(tests_path, tests_jsonl, allocator) catch |err| {
                debugPrint("Error writing generated tests '{s}': {}\n", .{ tests_path, err });
                return err;
            };

            debugPrint("Wrote generated tests to: {s}\n", .{tests_path});
        }

        // Write property violation counterexample tests and print unified summary.
        // violations_summary covers all analyzers (flow, verifier, fault coverage).
        // violations_jsonl is only present when fault-coverage counterexamples exist.
        if (compiled.violations_jsonl) |viol_jsonl| {
            const viol_path = deriveSiblingPath(allocator, output_path_final, "handler.violations.jsonl") catch |err| {
                debugPrint("Error deriving violations output path: {}\n", .{err});
                return err;
            };
            defer allocator.free(viol_path);

            writeFilePosix(viol_path, viol_jsonl, allocator) catch |err| {
                debugPrint("Error writing violations file '{s}': {}\n", .{ viol_path, err });
                return err;
            };

            if (compiled.violations_summary) |summary| {
                debugPrint("{s}", .{summary});
            }
            debugPrint("  Counterexample tests written to: {s}\n", .{viol_path});
            debugPrint("  Run: zig build run -- {s} --test {s}\n", .{ output_path_final, viol_path });
        } else if (compiled.violations_summary) |summary| {
            // Violations from flow or verifier analysis (no counterexample JSONL).
            debugPrint("{s}", .{summary});
        }
    }
}

fn writeZigFile(
    path: []const u8,
    compiled: CompiledHandler,
    policy: ?HandlerPolicy,
    allocator: std.mem.Allocator,
) !void {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);
    const writer = &aw.writer;

    try writer.writeAll("//! Auto-generated embedded handler bytecode\n");
    try writer.writeAll("//! Do not edit - regenerate with: zig build -Dhandler=<path>\n");
    try writer.writeAll("\n");

    try writer.writeAll("const std = @import(\"std\");\n");
    try writer.writeAll("const zq = @import(\"zts\");\n\n");

    try writer.writeAll("pub const bytecode = [_]u8{\n");
    try writeBytecodeArray(writer, compiled.bytecode);
    try writer.writeAll("};\n");

    // Write dependency module bytecodes if present
    if (compiled.dep_bytecodes) |deps| {
        try writer.print("\npub const dep_count: u16 = {d};\n\n", .{deps.len});
        for (deps, 0..) |dep, i| {
            try writer.print("const dep_{d} = [_]u8{{\n", .{i});
            try writeBytecodeArray(writer, dep);
            try writer.writeAll("};\n\n");
        }
        try writer.print("pub const dep_bytecodes = [_][]const u8{{\n", .{});
        for (0..deps.len) |i| {
            try writer.print("    &dep_{d},\n", .{i});
        }
        try writer.writeAll("};\n");
    } else {
        try writer.writeAll("\npub const dep_count: u16 = 0;\n");
        try writer.writeAll("pub const dep_bytecodes = [_][]const u8{};\n");
    }

    const contract_ptr = if (compiled.contract) |*c| c else null;
    try writeCapabilityPolicy(writer, policy, contract_ptr);

    output = aw.toArrayList();
    try writeFilePosix(path, output.items, allocator);
}

fn writeCapabilityPolicy(writer: anytype, policy: ?HandlerPolicy, contract: ?*const HandlerContract) !void {
    try writer.writeAll("\npub const capability_policy = @import(\"zts\").handler_policy.RuntimePolicy{\n");
    if (policy) |p| {
        // Explicit policy takes precedence
        try writePolicySectionFromAllowList(writer, "env", p.env);
        try writePolicySectionFromAllowList(writer, "egress", p.egress);
        try writePolicySectionFromAllowList(writer, "cache", p.cache);
        try writePolicySectionFromAllowList(writer, "sql", p.sql);
    } else if (contract) |c| {
        // Auto-derive from contract proven facts
        try writeContractDerivedSection(writer, "env", c.env.literal.items, c.env.dynamic);
        try writeContractDerivedSection(writer, "egress", c.egress.endpoints.items, c.egress.dynamic);
        try writeContractDerivedSection(writer, "cache", c.cache.namespaces.items, c.cache.dynamic);
        try writeSqlContractDerivedSection(writer, c);
    } else {
        // No policy, no contract: permissive
        try writePolicySectionFromAllowList(writer, "env", null);
        try writePolicySectionFromAllowList(writer, "egress", null);
        try writePolicySectionFromAllowList(writer, "cache", null);
        try writePolicySectionFromAllowList(writer, "sql", null);
    }
    try writer.print("    .egress_scopes = .{{ .bits = {d} }},\n", .{
        if (policy) |p| p.egress_scopes.bits else 0,
    });
    try writer.writeAll("};\n");
    try writer.writeAll("pub const runtime_policy_index_required = ");
    try writer.writeAll(if (contract) |c|
        if (handler_policy.contractRequiresRuntimePolicyIndex(c)) "true;\n" else "false;\n"
    else
        "false;\n");
}

fn writePolicySectionFromAllowList(writer: anytype, field_name: []const u8, section: ?handler_policy.AllowList) !void {
    try writer.print("    .{s} = ", .{field_name});
    if (section) |allow| {
        try writer.writeAll(".{\n");
        try writer.writeAll("        .enabled = true,\n");
        if (allow.values.items.len == 0) {
            try writer.writeAll("        .values = &[_][]const u8{},\n");
        } else {
            try writer.writeAll("        .values = &[_][]const u8{\n");
            for (allow.values.items) |item| {
                try writer.writeAll("            ");
                try writeZigStringLiteral(writer, item);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
        return;
    }
    try writer.writeAll(".{},\n");
}

/// Write a policy section derived from contract proven facts.
/// When dynamic is false, restrict to exactly the proven literals.
/// When dynamic is true, leave permissive.
fn writeContractDerivedSection(writer: anytype, field_name: []const u8, literals: []const []const u8, dynamic: bool) !void {
    try writer.print("    .{s} = ", .{field_name});
    if (!dynamic) {
        // Static: restrict to proven literals
        try writer.writeAll(".{\n");
        try writer.writeAll("        .enabled = true,\n");
        if (literals.len == 0) {
            try writer.writeAll("        .values = &[_][]const u8{},\n");
        } else {
            try writer.writeAll("        .values = &[_][]const u8{\n");
            for (literals) |item| {
                try writer.writeAll("            ");
                try writeZigStringLiteral(writer, item);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    } else {
        // Dynamic: can't restrict
        try writer.writeAll(".{},\n");
    }
}

fn writeSqlContractDerivedSection(writer: anytype, contract: *const HandlerContract) !void {
    // Emit the per-query allowlist with each query's operation so the
    // precompiled binary enforces the db.read/db.write split (not a flat,
    // operation-agnostic name list).
    try writer.writeAll("    .sql = ");
    if (!contract.sql.dynamic) {
        try writer.writeAll(".{\n");
        try writer.writeAll("        .enabled = true,\n");
        if (contract.sql.queries.items.len == 0) {
            try writer.writeAll("        .queries = &[_]@import(\"zts\").handler_policy.SqlQueryInfo{},\n");
        } else {
            try writer.writeAll("        .queries = &[_]@import(\"zts\").handler_policy.SqlQueryInfo{\n");
            for (contract.sql.queries.items) |query| {
                const op = if (handler_policy.sqlQueryIsReadOnly(query)) "select" else "write";
                try writer.writeAll("            .{ .name = ");
                try writeZigStringLiteral(writer, query.name);
                try writer.print(", .operation = \"{s}\", .statement = \"\" }},\n", .{op});
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    } else {
        try writer.writeAll(".{},\n");
    }
}

fn writeBytecodeArray(writer: anytype, bytecode_data: []const u8) !void {
    var i: usize = 0;
    while (i < bytecode_data.len) {
        try writer.writeAll("    ");
        const row_end = @min(i + 16, bytecode_data.len);
        while (i < row_end) {
            const byte = bytecode_data[i];
            var buf: [5]u8 = undefined;
            buf[0] = '0';
            buf[1] = 'x';
            buf[2] = hexChar(@truncate(byte >> 4));
            buf[3] = hexChar(@truncate(byte & 0x0f));
            buf[4] = ',';
            try writer.writeAll(buf[0..]);
            i += 1;
            if (i < row_end) try writer.writeAll(" ");
        }
        try writer.writeAll("\n");
    }
}

fn writeZigStringLiteral(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                var buf: [4]u8 = undefined;
                buf[0] = '\\';
                buf[1] = 'x';
                buf[2] = hexChar(@truncate(c >> 4));
                buf[3] = hexChar(@truncate(c & 0x0f));
                try writer.writeAll(&buf);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"");
}

fn hexChar(n: u4) u8 {
    const hex_chars = "0123456789abcdef";
    return hex_chars[n];
}

test "writeBytecodeArray emits zig-fmt stable rows" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);

    const bytes = [_]u8{ 0x01, 0xab, 0xff };
    try writeBytecodeArray(&aw.writer, &bytes);
    output = aw.toArrayList();

    try std.testing.expectEqualStrings(
        "    0x01, 0xab, 0xff,\n",
        output.items,
    );
}

test "writeCapabilityPolicy emits zig-fmt stable empty allowlists" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &output);

    const policy = HandlerPolicy{
        .env = .{},
        .egress = .{},
        .egress_scopes = .{ .bits = 5 },
        .cache = .{},
        .sql = .{},
    };
    try writeCapabilityPolicy(&aw.writer, policy, null);
    output = aw.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, output.items, ".values = &[_][]const u8{},") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".values = &[_][]const u8{\n        },") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".egress_scopes = .{ .bits = 5 },") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "runtime_policy_index_required = false;") != null);

    output.clearRetainingCapacity();
    aw = .fromArrayList(allocator, &output);
    var guarded = handler_contract.emptyContract("borrowed-test-path.ts");
    guarded.env.dynamic = true;
    try writeCapabilityPolicy(&aw.writer, null, &guarded);
    output = aw.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, output.items, "runtime_policy_index_required = true;") != null);
}

test "precompile refuses every retired module before replacing generated output" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { specifier: []const u8, symbol: []const u8 }{
        .{ .specifier = "zttp:durable", .symbol = "run" },
        .{ .specifier = "zttp:workflow", .symbol = "call" },
        .{ .specifier = "zttp:queue", .symbol = "send" },
        .{ .specifier = "zttp:scope", .symbol = "scope" },
        .{ .specifier = "zttp:io", .symbol = "parallel" },
        .{ .specifier = "zttp:service", .symbol = "serviceCall" },
        .{ .specifier = "zttp:ledger", .symbol = "balance" },
        .{ .specifier = "zttp:tool", .symbol = "toolInput" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try allocator.print("import {{ {s} }} from \"{s}\";\n" ++
            "function handler(req: Request): Response {{ return Response.text(\"ok\"); }}\n", .{ case.symbol, case.specifier });
        defer allocator.free(source);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "handler.ts", .data = source });
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "embedded_handler.zig",
            .data = "sentinel",
        });
        const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "handler.ts", allocator);
        defer allocator.free(handler_path);
        const output_path = try tmp.dir.realPathFileAlloc(
            std.testing.io,
            "embedded_handler.zig",
            allocator,
        );
        defer allocator.free(output_path);

        try std.testing.expectError(
            error.UnknownVirtualModule,
            runCompileWithArgs(allocator, &.{ "--contract", handler_path, output_path }),
        );
        const output = try zts.file_io.readFile(allocator, output_path, 64);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("sentinel", output);
    }
}
