//! The trusted-boundary ratchet.
//!
//! A certificate's grade is only meaningful next to a statement of what the
//! consumer actually re-derived. That statement lives in
//! `proof_system.Property.consumerChecked`, and this file is what stops it from
//! drifting: it compiles real handlers, builds real certificates, runs the real
//! kernel over them, and asserts the exact edge each property was answered with.
//!
//! Every assertion here is a number somebody has to change on purpose. A
//! promotion - moving a property from disclosed to consumer-checked - moves
//! them, and that is the point: the ratchet is a floor you can raise and cannot
//! lower by accident.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const pcc = @import("zttp_proof_checker");

const artifact_graph = @import("artifact_graph.zig");
const precompile = zts_cli.precompile;
const proof_certificate = @import("proof_certificate.zig");
const self_extract = @import("self_extract.zig");

const cert = pcc.certificate;
const ps = pcc.proof_system;

/// The proof capsule every corpus handler declares, so the compiler discharges
/// the same property set for each and the ratchet compares like with like.
const capsule =
    "Proof<Response, \"deterministic\" | \"read_only\" | \"state_isolated\" | " ++
    "\"no_secret_leakage\" | \"result_safe\">";

/// Handlers that must certify. Each one exercises a different control-flow
/// family, because the totality fold is what the consumer re-derives and a
/// corpus of one shape would prove the fold works on one shape.
const corpus = [_]struct { name: []const u8, source: []const u8 }{
    .{
        .name = "straight-line return",
        .source = "export function handler(req: Request): " ++ capsule ++ " {\n" ++
            "  return Response.text(\"ok\");\n" ++
            "}\n",
    },
    .{
        .name = "both branch arms return",
        .source = "export function handler(req: Request): " ++ capsule ++ " {\n" ++
            "  if (req.method === \"GET\") {\n" ++
            "    return Response.text(\"get\");\n" ++
            "  } else {\n" ++
            "    return Response.text(\"other\");\n" ++
            "  }\n" ++
            "}\n",
    },
    .{
        .name = "nested branches return on every path",
        .source = "export function handler(req: Request): " ++ capsule ++ " {\n" ++
            "  if (req.method === \"GET\") {\n" ++
            "    if (req.url === \"/a\") {\n" ++
            "      return Response.text(\"a\");\n" ++
            "    } else {\n" ++
            "      return Response.text(\"b\");\n" ++
            "    }\n" ++
            "  } else {\n" ++
            "    return Response.text(\"other\");\n" ++
            "  }\n" ++
            "}\n",
    },
};

/// The floor. A corpus smaller than this is a corpus that stopped covering the
/// families it claims to, and a gate over it would report a pass while checking
/// one shape.
const min_corpus: usize = 3;

const Certified = struct {
    allocator: std.mem.Allocator,
    compiled: precompile.CompiledHandler,
    built: proof_certificate.Built,
    members: []artifact_graph.Member,
    scratch: []u8,

    fn deinit(self: *Certified) void {
        self.allocator.free(self.scratch);
        self.allocator.free(self.members);
        self.built.deinit();
        self.compiled.deinit(self.allocator);
    }

    fn assess(self: *Certified, policy: pcc.Policy) pcc.Assessment {
        return pcc.check(.{
            .certificate = self.built.bytes,
            .observed_graph = self.members,
            .scratch = self.scratch,
        }, policy);
    }
};

fn certify(allocator: std.mem.Allocator, source: []const u8) !Certified {
    return certifyAt(allocator, source, "handler.ts");
}

fn certifyAt(allocator: std.mem.Allocator, source: []const u8, filename: []const u8) !Certified {
    var compiled = try precompile.compileHandler(allocator, source, filename, .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    errdefer compiled.deinit(allocator);

    const evidence = compiled.proof_evidence orelse return error.NoProofEvidence;
    const contract = compiled.contract orelse return error.NoContract;

    const contract_json = try contractJson(allocator, &contract);
    defer allocator.free(contract_json);
    // The ratchet corpus is literal-only, so there is no dynamic category for a
    // configured policy to supply entries to.
    const policy = zts.handler_policy.contractToRuntimePolicy(&contract, null);
    const policy_section = try self_extract.serializePolicy(allocator, &policy);
    defer allocator.free(policy_section);

    const sections = artifact_graph.ArtifactInputs{
        .bytecode = compiled.bytecode,
        .dep_bytecodes = compiled.dep_bytecodes orelse &.{},
        .contract_section = contract_json,
        .policy_section_digest = artifact_graph.digestOf(policy_section),
        .identity = artifact_graph.identityFromContract(&contract),
    };

    var built = try proof_certificate.build(allocator, .{
        .evidence = &evidence,
        .properties = .{
            .results_checked = contract.properties.?.result_safe,
            .no_secret_leakage = contract.properties.?.no_secret_leakage,
            .state_isolated = contract.properties.?.state_isolated,
            .deterministic = contract.properties.?.deterministic,
            .read_only = contract.properties.?.read_only,
            .retry_safe = contract.properties.?.retry_safe,
            .capability_bounded = contract.capability_budget.len > 0,
        },
        .artifact = sections,
        .contract_digest = artifact_graph.digestOf(contract_json),
    });
    errdefer built.deinit();

    // The consumer's own inventory, derived from the same sections.
    const scratch_members = try allocator.alloc(artifact_graph.Member, artifact_graph.max_members);
    defer allocator.free(scratch_members);
    var observed_sections = sections;
    observed_sections.proof_ir_digest = built.ir_root;
    observed_sections.proof_certificate_digest = built.certificate_digest;
    const observed = try artifact_graph.build(
        allocator,
        artifact_graph.fromArtifact(observed_sections),
        scratch_members,
    );
    const members = try allocator.alloc(artifact_graph.Member, observed.len);
    errdefer allocator.free(members);
    @memcpy(members, observed);

    const scratch = try allocator.alloc(u8, pcc.checker.scratchBytes(.{}));
    errdefer allocator.free(scratch);

    return .{
        .allocator = allocator,
        .compiled = compiled,
        .built = built,
        .members = members,
        .scratch = scratch,
    };
}

fn contractJson(allocator: std.mem.Allocator, contract: *const zts.HandlerContract) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try zts.handler_contract.writeContractJson(contract, &aw.writer);
    return allocator.dupe(u8, aw.writer.buffered());
}

/// The edge each property was answered with, in property order.
fn edgeProfile(built: *const proof_certificate.Built) ![@typeInfo(ps.Property).@"enum".field_names.len]?cert.EdgeKind {
    var profile = @as([(@typeInfo(ps.Property).@"enum".field_names.len)]?cert.EdgeKind, @splat(null));
    var budget = pcc.limits.Budget.init(.{});
    const decoded = try cert.decode(built.bytes, .{}, &budget);

    var index: u32 = 0;
    while (index < decoded.evidence.len()) : (index += 1) {
        const entry = try decoded.evidence.get(index);
        const obligation = try decoded.obligations.get(entry.obligation_index);
        const slot = @backingInt(obligation.property) - 1;
        // Keep the weakest answer seen: that is what the grade is folded from.
        if (profile[slot]) |existing| {
            const existing_grade = existing.grade() orelse continue;
            const grade = entry.edge.grade() orelse {
                profile[slot] = entry.edge;
                continue;
            };
            if (@backingInt(grade) > @backingInt(existing_grade)) profile[slot] = entry.edge;
        } else {
            profile[slot] = entry.edge;
        }
    }
    return profile;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the ratchet corpus is not empty" {
    // The floor before any count below means anything. A corpus that lost its
    // entries would otherwise make every assertion here vacuously true.
    try testing.expect(corpus.len >= min_corpus);
}

test "every corpus handler certifies and reaches production acceptance" {
    const allocator = testing.allocator;
    var accepted: usize = 0;
    for (corpus) |case| {
        var certified = certify(allocator, case.source) catch |err| {
            std.debug.print("ratchet: '{s}' did not certify: {s}\n", .{ case.name, @errorName(err) });
            return err;
        };
        defer certified.deinit();

        const result = certified.assess(pcc.policy.production);
        if (result.rejection()) |rejection| {
            std.debug.print(
                "ratchet: '{s}' rejected at {s} ({s})\n",
                .{ case.name, rejection.stage.name(), rejection.code.text() },
            );
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(pcc.SemanticState.policy_accepted, result.semantic());
        accepted += 1;
    }
    try testing.expectEqual(corpus.len, accepted);
}

test "the disclosed boundary is exactly what the kernel does not re-derive" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, corpus[1].source);
    defer certified.deinit();

    const profile = try edgeProfile(&certified.built);

    // Totality is re-derived by the consumer: its answer is a rule the kernel
    // ran, capped by the translation edge it also ran.
    const totality = profile[@backingInt(ps.Property.response_total) - 1].?;
    try testing.expect(totality == .proved or totality == .translation_validated);

    // Everything else is a disclosure or an explicit refusal. Neither is a
    // consumer-checked edge, and the ratchet is the statement that this is
    // still true.
    inline for (@typeInfo(ps.Property).@"enum".field_names) |field| {
        const property: ps.Property = @fromBackingInt(@intCast(@backingInt(@field(ps.Property, field))));
        if (comptime !property.consumerChecked()) {
            const edge = profile[@backingInt(@field(ps.Property, field)) - 1] orelse return error.TestUnexpectedResult;
            testing.expect(edge == .tested or edge == .not_established) catch |err| {
                std.debug.print(
                    "ratchet: '{s}' was answered with a consumer-checked edge but is published as disclosed\n",
                    .{property.name()},
                );
                return err;
            };
        }
    }

    // And the count is the floor the gate publishes.
    try testing.expectEqual(@as(usize, 2), ps.Property.consumerCheckedCount());
}

test "a certificate that only discloses totality is refused by the production floor" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, corpus[0].source);
    defer certified.deinit();

    // The deliberate invalidation. A policy that demands totality be re-derived
    // must refuse a certificate that only declares it, or the grade ladder is
    // decoration.
    var demanding = pcc.policy.production;
    const requirements = [_]pcc.policy.Requirement{
        .{ .property = .response_total, .min_grade = .proved },
        .{ .property = .results_checked, .min_grade = .proved },
    };
    demanding.required = &requirements;

    const result = certified.assess(demanding);
    try testing.expect(!result.accepted());
    try testing.expectEqual(pcc.verdict.Stage.policy, result.rejection().?.stage);
    try testing.expectEqual(
        pcc.ReasonCode.grade_below_floor,
        result.rejection().?.code,
    );
    try testing.expectEqual(
        @as(u64, pcc.AssuranceGrade.proved.toWire()),
        result.rejection().?.expected.?.scalar,
    );
}

test "each corpus family exercises a different totality rule" {
    const allocator = testing.allocator;
    var seen_rules = std.EnumSet(ps.Rule).empty;

    for (corpus) |case| {
        var certified = try certify(allocator, case.source);
        defer certified.deinit();

        var budget = pcc.limits.Budget.init(.{});
        const decoded = try cert.decode(certified.built.bytes, .{}, &budget);
        var index: u32 = 0;
        while (index < decoded.evidence.len()) : (index += 1) {
            const entry = try decoded.evidence.get(index);
            if (entry.rule) |rule| seen_rules.insert(rule);
        }
    }

    // A corpus that only ever trips one rule would report the same coverage as
    // one that tripped all of them.
    try testing.expect(seen_rules.contains(.sequence_member_total));
    try testing.expect(seen_rules.contains(.emission_contiguous));
    try testing.expect(seen_rules.count() >= 2);
}

/// The edge a certificate answers `capability_bounded` with.
fn capabilityBoundedEdge(certified: *Certified) !cert.EdgeKind {
    const profile = try edgeProfile(&certified.built);
    return profile[@backingInt(ps.Property.capability_bounded) - 1] orelse error.TestUnexpectedResult;
}

test "a handler with no Effects ceiling does not claim capability_bounded and is still accepted" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, corpus[0].source);
    defer certified.deinit();

    try testing.expectEqual(cert.EdgeKind.not_established, try capabilityBoundedEdge(&certified));

    const result = certified.assess(pcc.policy.production);
    try testing.expect(result.rejection() == null);
    try testing.expectEqual(pcc.SemanticState.policy_accepted, result.semantic());
}

test "a handler under a declared Effects ceiling holds capability_bounded at tested" {
    const allocator = testing.allocator;
    const source =
        "import { sha256 } from \"zttp:crypto\";\n" ++
        "export function handler(req: Request): Proof<Effects<Response, \"crypto\">, " ++
        "\"deterministic\" | \"read_only\" | \"state_isolated\" | \"no_secret_leakage\" | \"result_safe\"> {\n" ++
        "  return Response.text(sha256(\"zttp\"));\n" ++
        "}\n";
    var certified = try certify(allocator, source);
    defer certified.deinit();

    try testing.expectEqual(cert.EdgeKind.tested, try capabilityBoundedEdge(&certified));

    const result = certified.assess(pcc.policy.production);
    try testing.expect(result.rejection() == null);
    try testing.expectEqual(pcc.SemanticState.policy_accepted, result.semantic());
}

// ---------------------------------------------------------------------------
// Result events
// ---------------------------------------------------------------------------

const result_capsule = "Proof<Response, \"deterministic\" | \"read_only\" | \"result_safe\">";

const validate_prelude =
    "import { schemaCompile, validateJson } from \"zttp:validate\";\n" ++
    "schemaCompile(\"todo\", \"{\\\"type\\\":\\\"object\\\",\\\"required\\\":[\\\"title\\\"]}\");\n";

/// The edge a certificate answers `results_checked` with.
fn resultsEdge(certified: *Certified) !cert.EdgeKind {
    const profile = try edgeProfile(&certified.built);
    return profile[@backingInt(ps.Property.results_checked) - 1] orelse error.TestUnexpectedResult;
}

fn irTagCount(certified: *Certified, tag: ps.NodeTag) !u32 {
    var budget = pcc.limits.Budget.init(.{});
    const decoded = try cert.decode(certified.built.bytes, .{}, &budget);
    var count: u32 = 0;
    var index: u32 = 0;
    while (index < decoded.ir.len()) : (index += 1) {
        if ((try decoded.ir.get(index)).tag == tag) count += 1;
    }
    return count;
}

fn expectAcceptedAtTrusted(certified: *Certified) !void {
    const result = certified.assess(pcc.policy.production);
    if (result.rejection()) |rejection| {
        std.debug.print("rejected at {s} ({s})\n", .{ rejection.stage.name(), rejection.code.text() });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(pcc.SemanticState.policy_accepted, result.semantic());
    try testing.expectEqual(
        @as(?pcc.AssuranceGrade, .trusted),
        result.properties.gradeFor(.results_checked),
    );
}

test "a handler that returns early on a failed Result proves its reads" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, validate_prelude ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  const r = validateJson(\"todo\", \"{}\");\n" ++
        "  if (!r.ok) {\n" ++
        "    return Response.json({ error: r.errors }, { status: 400 });\n" ++
        "  }\n" ++
        "  return Response.json({ title: r.value }, { status: 200 });\n" ++
        "}\n");
    defer certified.deinit();

    try testing.expectEqual(cert.EdgeKind.proved, try resultsEdge(&certified));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_def));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_guard_err));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_read_ok));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_read_err));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_escape));
    try expectAcceptedAtTrusted(&certified);
}

test "a read inside an ok guard with no else is proved" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, validate_prelude ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  const r = validateJson(\"todo\", \"{}\");\n" ++
        "  if (r.ok) {\n" ++
        "    return Response.json({ title: r.value }, { status: 200 });\n" ++
        "  }\n" ++
        "  return Response.json({ n: 0 }, { status: 400 });\n" ++
        "}\n");
    defer certified.deinit();

    try testing.expectEqual(cert.EdgeKind.proved, try resultsEdge(&certified));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_guard_ok));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_read_ok));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_escape));
    try expectAcceptedAtTrusted(&certified);
}

test "an error read inside the err arm is proved" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, validate_prelude ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  const r = validateJson(\"todo\", \"{}\");\n" ++
        "  if (!r.ok) {\n" ++
        "    return Response.json({ error: r.errors }, { status: 400 });\n" ++
        "  } else {\n" ++
        "    return Response.json({ n: 1 }, { status: 200 });\n" ++
        "  }\n" ++
        "}\n");
    defer certified.deinit();

    try testing.expectEqual(cert.EdgeKind.proved, try resultsEdge(&certified));
    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_read_err));
    try expectAcceptedAtTrusted(&certified);
}

test "an error read with a nullish fallback emits no event" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, "import { parseJson } from \"zttp:json\";\n" ++
        "const describe = (text: string): string => {\n" ++
        "  const r = parseJson(text);\n" ++
        "  const reason = r.error ?? \"none\";\n" ++
        "  return reason;\n" ++
        "};\n" ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  return Response.json({ out: describe(\"1\") });\n" ++
        "}\n");
    defer certified.deinit();

    try testing.expectEqual(@as(u32, 1), try irTagCount(&certified, .result_def));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_read_err));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_escape));
    try testing.expectEqual(cert.EdgeKind.proved, try resultsEdge(&certified));
    try expectAcceptedAtTrusted(&certified);
}

/// One program the producer must refuse.
const FalseProof = struct {
    name: []const u8,
    body: []const u8,
    /// Functions declared before the handler. Each probe carries only its
    /// own, so that no other probe's unchecked read causes the refusal.
    helpers: []const u8 = "",
};

const false_proofs = [_]FalseProof{
    .{
        .name = "p_alias",
        .body = "  const late = validateJson(\"todo\", \"{}\");\n" ++
            "  const alias = late;\n" ++
            "  const v = alias.value;\n" ++
            "  return Response.json({ n: 1 }, { status: 200 });\n",
    },
    .{
        .name = "p_obj",
        .body = "  const late = validateJson(\"todo\", \"{}\");\n" ++
            "  const box = { r: late };\n" ++
            "  const v = box.r.value;\n" ++
            "  return Response.json({ n: 1 }, { status: 200 });\n",
    },
    .{
        .name = "p_chain",
        .body = "  const v = validateJson(\"todo\", \"{}\").value;\n" ++
            "  return Response.json({ n: 1 }, { status: 200 });\n",
    },
    .{
        .name = "p_sibling",
        .body = "  const n = inner();\n" ++
            "  return Response.json({ n: n }, { status: 200 });\n",
        .helpers = "function inner(): number {\n" ++
            "  const local = validateJson(\"todo\", \"{}\");\n" ++
            "  const v = local.value;\n" ++
            "  return 1;\n" ++
            "}\n",
    },
    .{
        .name = "p_eqvar",
        .body = "  const late = validateJson(\"todo\", \"{}\");\n" ++
            "  const flag = req.method === \"GET\";\n" ++
            "  if (late.ok === flag) {\n" ++
            "    const v = late.value;\n" ++
            "  }\n" ++
            "  return Response.json({ n: 1 }, { status: 200 });\n",
    },
    .{
        .name = "p_helper",
        .body = "  const late = validateJson(\"todo\", \"{}\");\n" ++
            "  const n = reader(late);\n" ++
            "  return Response.json({ n: n }, { status: 200 });\n",
        .helpers = "function reader(r: unknown): number {\n" ++
            "  const v = r.value;\n" ++
            "  return 1;\n" ++
            "}\n",
    },
    .{
        .name = "p_err",
        .body = "  const late = validateJson(\"todo\", \"{}\");\n" ++
            "  const v = late.error;\n" ++
            "  return Response.json({ n: 1 }, { status: 200 });\n",
    },
    .{
        .name = "p_errors",
        .body = "  const late = validateJson(\"todo\", \"{}\");\n" ++
            "  return Response.json({ e: late.errors }, { status: 200 });\n",
    },
    .{
        .name = "p_spread",
        .body = "  const r = validateJson(\"todo\", \"{}\");\n" ++
            "  const box = { ...r };\n" ++
            "  return Response.json({ v: box.value });\n",
    },
    .{
        .name = "p_computed",
        .body = "  const r = validateJson(\"todo\", \"{}\");\n" ++
            "  const k = \"value\";\n" ++
            "  const v = r[k];\n" ++
            "  return Response.json({ v: v });\n",
    },
    .{
        .name = "p_closure_dup2",
        .body = "  if (req.method === \"GET\") {\n" ++
            "    const r = validateJson(\"todo\", \"{}\");\n" ++
            "    if (!r.ok) {\n" ++
            "      return Response.json({ bad: true }, { status: 400 });\n" ++
            "    }\n" ++
            "    return Response.json({ v: r.value });\n" ++
            "  }\n" ++
            "  const r = validateJson(\"todo\", \"{}\");\n" ++
            "  const read = (): unknown => {\n" ++
            "    return r.value;\n" ++
            "  };\n" ++
            "  return Response.json({ v: read() });\n",
    },
};

/// Whether the producer refuses `source`: the verifier reports an error, so no
/// certificate exists to carry a `results_checked` claim.
fn producerRefuses(allocator: std.mem.Allocator, source: []const u8) !bool {
    var compiled = try precompile.compileHandler(allocator, source, "handler.ts", .{
        .emit_verify = true,
        .emit_contract = true,
        .emit_proof_evidence = true,
    });
    defer compiled.deinit(allocator);
    return compiled.verify_failed and compiled.proof_evidence == null;
}

test "the producer accepts the probe prelude when the handler checks its Result" {
    const allocator = testing.allocator;
    try testing.expect(!(try producerRefuses(allocator, validate_prelude ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  const late = validateJson(\"todo\", \"{}\");\n" ++
        "  if (!late.ok) { return Response.json({ e: late.errors }, { status: 400 }); }\n" ++
        "  return Response.json({ v: late.value }, { status: 200 });\n" ++
        "}\n")));
}

test "the producer refuses every false-proof probe, so no certificate carries the claim" {
    const allocator = testing.allocator;
    inline for (false_proofs) |probe| {
        const source = comptime validate_prelude ++ probe.helpers ++
            "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++ probe.body ++ "}\n";
        testing.expect(try producerRefuses(allocator, source)) catch |err| {
            std.debug.print("probe '{s}' was not refused by the producer\n", .{probe.name});
            return err;
        };
    }
}

test "a handler with no Result binding lowers without Result events" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, corpus[1].source);
    defer certified.deinit();

    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_def));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_guard_ok));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_guard_err));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_read_ok));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_read_err));
    try testing.expectEqual(@as(u32, 0), try irTagCount(&certified, .result_escape));
    try testing.expectEqual(cert.EdgeKind.tested, try resultsEdge(&certified));
}

test "an unchecked requestJson read is refused beside a checked Result" {
    const allocator = testing.allocator;
    try testing.expect(try producerRefuses(allocator, validate_prelude ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  const r = validateJson(\"todo\", \"{}\");\n" ++
        "  if (!r.ok) { return Response.json({ e: r.errors }, { status: 400 }); }\n" ++
        "  const body = requestJson(req);\n" ++
        "  const v = body.value;\n" ++
        "  return Response.json({ t: r.value, v: v }, { status: 200 });\n" ++
        "}\n"));
}

test "a guarded requestText read is proved" {
    const allocator = testing.allocator;
    var certified = try certify(allocator, validate_prelude ++
        "export function handler(req: Request): " ++ result_capsule ++ " {\n" ++
        "  const r = validateJson(\"todo\", \"{}\");\n" ++
        "  if (!r.ok) { return Response.json({ e: r.errors }, { status: 400 }); }\n" ++
        "  const t = requestText(req);\n" ++
        "  if (!t.ok) { return Response.json({ n: 0 }, { status: 400 }); }\n" ++
        "  return Response.json({ t: r.value, v: t.value }, { status: 200 });\n" ++
        "}\n");
    defer certified.deinit();

    try testing.expectEqual(cert.EdgeKind.proved, try resultsEdge(&certified));
    try testing.expectEqual(@as(u32, 2), try irTagCount(&certified, .result_def));
    try expectAcceptedAtTrusted(&certified);
}

// ---------------------------------------------------------------------------
// Parity census over the tracked handler corpus
// ---------------------------------------------------------------------------

/// Roots the census walks for `.ts` handlers.
const census_roots = [_][]const u8{
    "examples",
    "tests",
    "packages/tools/tests/fixtures",
    "packages/pi/src/simulator/testdata",
};

/// Directories of deliberately malformed sources, not handlers.
const census_skipped = [_][]const u8{
    "tests/corpus/check/bad",
    "tests/corpus/parse/bad",
};

/// The floors. A census that compiled fewer certificates, or met fewer Result
/// events, than this stopped covering the shapes the table below explains.
const census_min_certified: usize = 93;
const census_min_with_result_events: usize = 19;

/// One file where the verifier says `result_safe` and the kernel did not
/// re-derive `results_checked`, with the named cause. A file that stops being
/// a difference fails as a stale row; a new difference fails as unexplained.
const ParityDifference = struct { path: []const u8, cause: []const u8 };

const known_differences = [_]ParityDifference{};

fn hasResultEvent(built: *const proof_certificate.Built) !bool {
    var budget = pcc.limits.Budget.init(.{});
    const decoded = try cert.decode(built.bytes, .{}, &budget);
    var index: u32 = 0;
    while (index < decoded.ir.len()) : (index += 1) {
        switch ((try decoded.ir.get(index)).tag) {
            .result_def,
            .result_guard_ok,
            .result_guard_err,
            .result_read_ok,
            .result_read_err,
            .result_escape,
            => return true,
            .function, .sequence, .branch, .loop_node, .return_node, .plain, .capability_call => {},
        }
    }
    return false;
}

/// Production with only `results_checked` required. The census reads a
/// certificate under it when production refuses the handler for another
/// property, because the marker is set whenever the kernel accepts.
const census_results_requirements = [_]pcc.policy.Requirement{
    .{ .property = .results_checked, .min_grade = .trusted },
};
const census_results_only = pcc.Policy{
    .proof_systems = pcc.policy.production.proof_systems,
    .semantics_epochs = pcc.policy.production.semantics_epochs,
    .required = &census_results_requirements,
};

fn censusRejected(path: []const u8, rejection: pcc.verdict.Rejection) error{TestUnexpectedResult} {
    std.debug.print(
        "census: '{s}' rejected at {s} ({s})\n",
        .{ path, rejection.stage.name(), rejection.code.text() },
    );
    return error.TestUnexpectedResult;
}

fn isCensusSkipped(path: []const u8) bool {
    for (census_skipped) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

test "the kernel re-derives results_checked wherever the verifier says result_safe, except the named differences" {
    const allocator = testing.allocator;
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();

    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |path| allocator.free(path);
        found.deinit(allocator);
    }
    var differences: std.ArrayList([]u8) = .empty;
    defer {
        for (differences.items) |path| allocator.free(path);
        differences.deinit(allocator);
    }

    for (census_roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
            std.debug.print("census: cannot open root '{s}': {s}\n", .{ root, @errorName(err) });
            return err;
        };
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ts")) continue;
            const path = try std.fs.path.join(allocator, &.{ root, entry.path });
            errdefer allocator.free(path);
            if (isCensusSkipped(path)) {
                allocator.free(path);
                continue;
            }
            try found.append(allocator, path);
        }
    }
    std.mem.sort([]u8, found.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var certified_count: usize = 0;
    var skipped_count: usize = 0;
    var relaxed_count: usize = 0;
    var with_events: usize = 0;
    var rederived_count: usize = 0;
    for (found.items) |path| {
        const source = try zts.file_io.readFile(allocator, path, 4 * 1024 * 1024);
        defer allocator.free(source);
        var certified = certifyAt(allocator, source, path) catch {
            skipped_count += 1;
            continue;
        };
        defer certified.deinit();
        certified_count += 1;

        // Production first. A policy-stage refusal means the handler does not
        // hold a property production requires (totality, say), so the same
        // certificate is read again under a policy that asks only for
        // `results_checked`. A refusal at any earlier stage means the kernel
        // disagreed with the producer about the certificate itself.
        var assessed = certified.assess(pcc.policy.production);
        if (assessed.rejection()) |rejection| {
            if (rejection.stage != .policy) return censusRejected(path, rejection);
            relaxed_count += 1;
            assessed = certified.assess(census_results_only);
            if (assessed.rejection()) |again| {
                if (again.stage != .policy) return censusRejected(path, again);
            }
        }

        const rederived = assessed.properties.consumerChecked(.results_checked);
        if (rederived) rederived_count += 1;
        if (!try hasResultEvent(&certified.built)) continue;
        with_events += 1;
        const verifier_safe = certified.compiled.contract.?.properties.?.result_safe;
        if (verifier_safe and !rederived) try differences.append(allocator, try allocator.dupe(u8, path));
    }
    std.debug.print(
        "census: {d} files, {d} certified, {d} skipped, {d} read under the results-only policy, {d} with Result events, {d} re-derived, {d} differences\n",
        .{ found.items.len, certified_count, skipped_count, relaxed_count, with_events, rederived_count, differences.items.len },
    );

    try testing.expect(certified_count >= census_min_certified);
    try testing.expect(with_events >= census_min_with_result_events);

    var failed = false;
    for (differences.items) |path| {
        var named = false;
        for (known_differences) |row| {
            if (std.mem.eql(u8, row.path, path)) named = true;
        }
        if (!named) {
            std.debug.print("census: unexplained difference: {s}\n", .{path});
            failed = true;
        }
    }
    for (known_differences) |row| {
        try testing.expect(row.cause.len > 0);
        var still = false;
        for (differences.items) |path| {
            if (std.mem.eql(u8, row.path, path)) still = true;
        }
        if (!still) {
            std.debug.print("census: stale row (no longer a difference): {s}\n", .{row.path});
            failed = true;
        }
    }
    try testing.expect(!failed);
}
