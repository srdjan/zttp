//! Deterministic security cohort for expert qualification.
//!
//! These are compiler probes, not model-authoring prompts. Every adversarial
//! row names the exact diagnostic it must trigger. Every positive row names an
//! exact proven property or capability budget. The suite derives its family
//! floor from the compiler-owned diagnostic taxonomy.

const std = @import("std");
const zts = @import("zts");
const zts_cli = @import("zts_cli");
const evidence_identity = @import("expert_evidence_identity.zig");

pub const Probe = evidence_identity.SecurityProbe;
pub const Claim = evidence_identity.SecurityProbeClaim;
const ExpectedDiagnostic = evidence_identity.SecurityProbeExpectedDiagnostic;

const crypto_budget = [_][]const u8{"crypto"};
const secret_diagnostics = [_]ExpectedDiagnostic{
    .{ .code = "ZTS400", .severity = .err },
    .{ .code = "ZTS500", .severity = .err },
};
const credential_diagnostics = [_]ExpectedDiagnostic{
    .{ .code = "ZTS401", .severity = .warning },
    .{ .code = "ZTS500", .severity = .err },
};
const injection_diagnostics = [_]ExpectedDiagnostic{
    .{ .code = "ZTS407", .severity = .warning },
    .{ .code = "ZTS500", .severity = .err },
};
const state_diagnostics = [_]ExpectedDiagnostic{
    .{ .code = "ZTS310", .severity = .err },
};
const capability_diagnostics = [_]ExpectedDiagnostic{
    .{ .code = "ZTS506", .severity = .err },
};

pub const corpus = [_]Probe{
    .{
        .scenario = "secret-use-with-public-response",
        .family = "sensitive_data_flow",
        .source =
        \\import { env } from "zttp:env";
        \\structural Guard<T> = Proof<T, "no_secret_leakage">;
        \\function handler(req: Request): Guard<Response> {
        \\  const secret = env("JWT_SECRET");
        \\  if (secret === undefined) {
        \\    return Response.json({ configured: false });
        \\  }
        \\  return Response.json({ configured: true });
        \\}
        ,
        .claim = .{ .positive = .{ .property = .{
            .name = "no_secret_leakage",
            .value = true,
        } } },
    },
    .{
        .scenario = "secret-direct-return-refused",
        .family = "sensitive_data_flow",
        .source =
        \\import { env } from "zttp:env";
        \\structural Guard<T> = Proof<T, "no_secret_leakage">;
        \\function handler(req: Request): Guard<Response> {
        \\  const secret = env("JWT_SECRET");
        \\  if (secret === undefined) {
        \\    return Response.json({ error: "unconfigured" }, { status: 503 });
        \\  }
        \\  return Response.json({ value: secret });
        \\}
        ,
        .claim = .{ .adversarial = .{
            .primary = "ZTS400",
            .exact_diagnostics = &secret_diagnostics,
        } },
    },
    .{
        .scenario = "secret-validate-transform-refused",
        .family = "sensitive_data_flow",
        .source =
        \\import { env } from "zttp:env";
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\structural Guard<T> = Proof<T, "no_secret_leakage">;
        \\function handler(req: Request): Guard<Response> {
        \\  schemaCompile("payload", "{}");
        \\  const secret = env("JWT_SECRET");
        \\  if (secret === undefined) {
        \\    return Response.json({ error: "unconfigured" }, { status: 503 });
        \\  }
        \\  const checked = validateJson("payload", secret);
        \\  if (!checked.ok) {
        \\    return Response.json({ error: "invalid" }, { status: 400 });
        \\  }
        \\  return Response.json({ value: checked.value });
        \\}
        ,
        .claim = .{ .adversarial = .{
            .primary = "ZTS400",
            .exact_diagnostics = &secret_diagnostics,
        } },
    },
    .{
        .scenario = "credential-validate-transform-refused",
        .family = "sensitive_data_flow",
        .source =
        \\import { parseBearer, jwtVerify } from "zttp:auth";
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\structural Guard<T> = Proof<T, "no_credential_leakage">;
        \\function handler(req: Request): Guard<Response> {
        \\  const token = parseBearer(req.headers["authorization"] ?? "");
        \\  if (token === undefined) {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  const verified = jwtVerify(token, "test-key");
        \\  if (!verified.ok) {
        \\    return Response.json({ error: "unauthorized" }, { status: 401 });
        \\  }
        \\  schemaCompile("claims", "{}");
        \\  const checked = validateJson("claims", JSON.stringify(verified.value));
        \\  if (!checked.ok) {
        \\    return Response.json({ error: "invalid" }, { status: 400 });
        \\  }
        \\  return Response.json({ claims: checked.value });
        \\}
        ,
        .claim = .{ .adversarial = .{
            .primary = "ZTS401",
            .exact_diagnostics = &credential_diagnostics,
        } },
    },
    .{
        .scenario = "escaped-input-is-safe",
        .family = "untrusted_input_flow",
        .source =
        \\import { escapeHtml } from "zttp:text";
        \\structural Guard<T> = Proof<T, "injection_safe">;
        \\function handler(req: Request): Guard<Response> {
        \\  return Response.html(escapeHtml(req.path));
        \\}
        ,
        .claim = .{ .positive = .{ .property = .{
            .name = "injection_safe",
            .value = true,
        } } },
    },
    .{
        .scenario = "raw-input-html-refused",
        .family = "untrusted_input_flow",
        .source =
        \\structural Guard<T> = Proof<T, "injection_safe">;
        \\function handler(req: Request): Guard<Response> {
        \\  return Response.html(req.path);
        \\}
        ,
        .claim = .{ .adversarial = .{
            .primary = "ZTS407",
            .exact_diagnostics = &injection_diagnostics,
        } },
    },
    .{
        .scenario = "request-local-mutation-is-isolated",
        .family = "state_isolation",
        .source =
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\function handler(req: Request): Guard<Response> {
        \\  let count = 0;
        \\  count = count + 1;
        \\  return Response.json({ count: count });
        \\}
        ,
        .claim = .{ .positive = .{ .property = .{
            .name = "state_isolated",
            .value = true,
        } } },
    },
    .{
        .scenario = "module-mutation-refused",
        .family = "state_isolation",
        .source =
        \\let count = 0;
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\function handler(req: Request): Guard<Response> {
        \\  count = count + 1;
        \\  return Response.json({ count: count });
        \\}
        ,
        .claim = .{ .adversarial = .{
            .primary = "ZTS310",
            .exact_diagnostics = &state_diagnostics,
        } },
    },
    .{
        .scenario = "declared-crypto-budget-is-exact",
        .family = "capability_control",
        .source =
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req: Request): Proof<Effects<Response, "crypto">, "deterministic"> {
        \\  return Response.text(sha256("x"));
        \\}
        ,
        .claim = .{ .positive = .{ .capability_budget = &crypto_budget } },
    },
    .{
        .scenario = "undeclared-crypto-capability-refused",
        .family = "capability_control",
        .source =
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req: Request): Proof<Effects<Response, "env">, "deterministic"> {
        \\  return Response.text(sha256("x"));
        \\}
        ,
        .claim = .{ .adversarial = .{
            .primary = "ZTS506",
            .exact_diagnostics = &capability_diagnostics,
        } },
    },
};

fn familyFromName(name: []const u8) ?zts.DiagnosticCatalog.Family {
    for (std.enums.values(zts.DiagnosticCatalog.Family)) |family| {
        if (std.mem.eql(u8, name, @tagName(family))) return family;
    }
    return null;
}

fn propertyValue(properties: zts.HandlerProperties, name: []const u8) ?bool {
    if (std.mem.eql(u8, name, "no_secret_leakage")) return properties.no_secret_leakage;
    if (std.mem.eql(u8, name, "no_credential_leakage")) return properties.no_credential_leakage;
    if (std.mem.eql(u8, name, "input_validated")) return properties.input_validated;
    if (std.mem.eql(u8, name, "injection_safe")) return properties.injection_safe;
    if (std.mem.eql(u8, name, "state_isolated")) return properties.state_isolated;
    return null;
}

fn diagnosticCount(
    diagnostics: []const zts_cli.precompile.json_diag.JsonDiagnostic,
    expected: ExpectedDiagnostic,
) usize {
    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, expected.code) and
            std.mem.eql(u8, diagnostic.severity, switch (expected.severity) {
                .err => "error",
                .warning => "warning",
                .advisory => "advisory",
            })) count += 1;
    }
    return count;
}

fn containsDiagnostic(
    expected_diagnostics: []const ExpectedDiagnostic,
    diagnostic: zts_cli.precompile.json_diag.JsonDiagnostic,
) bool {
    for (expected_diagnostics) |expected| {
        if (diagnosticCount(&.{diagnostic}, expected) == 1) return true;
    }
    return false;
}

fn containsCode(expected_diagnostics: []const ExpectedDiagnostic, code: []const u8) bool {
    for (expected_diagnostics) |expected| {
        if (std.mem.eql(u8, expected.code, code)) return true;
    }
    return false;
}

fn expectCapabilityBudget(
    contract: *const zts.HandlerContract,
    expected: []const []const u8,
) !void {
    const actual = contract.capability_budget.slice();
    if (actual.len != expected.len) return error.SecurityProbeCapabilityBudgetMismatch;
    for (actual, expected) |capability, name| {
        if (!std.mem.eql(u8, @tagName(capability), name)) {
            return error.SecurityProbeCapabilityBudgetMismatch;
        }
    }
}

fn runProbe(allocator: std.mem.Allocator, probe: Probe) !void {
    var result = try zts_cli.precompile.runCheckOnlyFromSource(
        allocator,
        probe.source,
        "security-probe.ts",
        null,
        true,
        null,
        false,
    );
    defer result.deinit(allocator);

    const Report = struct {
        fn diagnostics(name: []const u8, check: *const zts_cli.precompile.CheckResult) void {
            std.debug.print(
                "[security-probe] {s}: unexpected compiler diagnostics " ++
                    "total={d} parse={d} bool={d} type={d} strict={d} verify={d} flow={d} canonical={d}\n",
                .{
                    name,
                    check.totalErrors(),
                    check.parse_errors,
                    check.bool_errors,
                    check.type_errors,
                    check.strict_errors,
                    check.verify_errors,
                    check.flow_errors,
                    check.canonical_errors,
                },
            );
            for (check.json_diagnostics.items) |diagnostic| {
                std.debug.print(
                    "[security-probe] {s}: {s} ({s}) {s}\n",
                    .{ name, diagnostic.code, diagnostic.severity, diagnostic.message },
                );
            }
        }
    };

    switch (probe.claim) {
        .adversarial => |expected| {
            var exact = result.json_diagnostics.items.len == expected.exact_diagnostics.len;
            var primary_count: usize = 0;
            for (result.json_diagnostics.items) |diagnostic| {
                if (std.mem.eql(u8, diagnostic.code, expected.primary)) primary_count += 1;
                if (!containsDiagnostic(expected.exact_diagnostics, diagnostic)) exact = false;
            }
            for (expected.exact_diagnostics) |diagnostic| {
                if (diagnosticCount(result.json_diagnostics.items, diagnostic) != 1) exact = false;
            }
            if (primary_count != 1) exact = false;
            if (!exact) {
                std.debug.print(
                    "[security-probe] {s}: expected primary {s} and {d} exact diagnostics\n",
                    .{ probe.scenario, expected.primary, expected.exact_diagnostics.len },
                );
                Report.diagnostics(probe.scenario, &result);
                return error.SecurityProbeDiagnosticMismatch;
            }
        },
        .positive => |positive| {
            if (result.totalErrors() != 0) {
                Report.diagnostics(probe.scenario, &result);
                return error.PositiveSecurityProbeDidNotCompile;
            }
            const contract = result.contract orelse return error.SecurityProbeContractMissing;
            switch (positive) {
                .property => |expected| {
                    const actual = propertyValue(
                        contract.properties orelse return error.SecurityProbePropertiesMissing,
                        expected.name,
                    ) orelse return error.UnknownSecurityProbeProperty;
                    if (actual != expected.value) return error.SecurityProbePropertyMismatch;
                },
                .capability_budget => |expected| try expectCapabilityBudget(&contract, expected),
            }
        },
    }
}

fn validateCorpus(probes: []const Probe) !void {
    if (probes.len == 0) return error.EmptySecurityProbeCorpus;

    for (probes, 0..) |probe, index| {
        if (probe.scenario.len == 0 or probe.family.len == 0 or probe.source.len == 0) {
            return error.EmptySecurityProbeField;
        }
        const family = familyFromName(probe.family) orelse return error.UnknownSecurityProbeFamily;
        for (probes[index + 1 ..]) |other| {
            if (std.mem.eql(u8, probe.scenario, other.scenario)) return error.DuplicateSecurityProbe;
        }
        switch (probe.claim) {
            .positive => {},
            .adversarial => |expected| {
                if (expected.primary.len == 0 or expected.exact_diagnostics.len == 0 or
                    !containsCode(expected.exact_diagnostics, expected.primary))
                {
                    return error.InvalidSecurityProbeDiagnosticExpectation;
                }
                for (expected.exact_diagnostics, 0..) |diagnostic, diagnostic_index| {
                    if (zts.DiagnosticCatalog.findByCode(diagnostic.code) == null) {
                        return error.UncatalogedSecurityProbeDiagnostic;
                    }
                    for (expected.exact_diagnostics[diagnostic_index + 1 ..]) |other| {
                        if (std.mem.eql(u8, diagnostic.code, other.code)) {
                            return error.DuplicateSecurityProbeExpectedDiagnostic;
                        }
                    }
                }
                const diagnostic = zts.DiagnosticCatalog.findByCode(expected.primary) orelse
                    return error.UncatalogedSecurityProbeDiagnostic;
                if (diagnostic.family != family or diagnostic.risk != .security_critical) {
                    return error.SecurityProbeTaxonomyMismatch;
                }
            },
        }
    }

    for (std.enums.values(zts.DiagnosticCatalog.Family)) |family| {
        var critical = false;
        for (zts.DiagnosticCatalog.entries()) |entry| {
            if (entry.family == family and entry.risk == .security_critical) critical = true;
        }
        if (!critical) continue;

        var positive: usize = 0;
        var adversarial: usize = 0;
        for (probes) |probe| {
            if (!std.mem.eql(u8, probe.family, @tagName(family))) continue;
            switch (probe.claim) {
                .positive => positive += 1,
                .adversarial => adversarial += 1,
            }
        }
        if (positive == 0 or adversarial == 0) return error.UnpairedCriticalDiagnosticFamily;
    }
}

pub fn identity() evidence_identity.SecurityProbeCorpusIdentity {
    return evidence_identity.securityProbeCorpus(&corpus);
}

test "security probe corpus is nonempty unique and pairs every critical family" {
    try validateCorpus(&corpus);
    try std.testing.expectError(error.EmptySecurityProbeCorpus, validateCorpus(&.{}));
    try std.testing.expectError(
        error.UnpairedCriticalDiagnosticFamily,
        validateCorpus(corpus[1..]),
    );
    try std.testing.expectError(
        error.UnpairedCriticalDiagnosticFamily,
        validateCorpus(corpus[0 .. corpus.len - 1]),
    );
}

test "security probes resolve exactly once and assert their named claim" {
    try validateCorpus(&corpus);
    var resolved: usize = 0;
    for (corpus) |probe| {
        try runProbe(std.testing.allocator, probe);
        resolved += 1;
    }
    try std.testing.expect(corpus.len > 0);
    try std.testing.expectEqual(corpus.len, resolved);
}

test "label propagation regression has direct and transformed adversarial probes" {
    var direct_secret = false;
    var transformed_secret = false;
    var transformed_credential = false;
    for (corpus) |probe| {
        const code = switch (probe.claim) {
            .adversarial => |value| value.primary,
            .positive => continue,
        };
        if (std.mem.eql(u8, probe.scenario, "secret-direct-return-refused") and
            std.mem.eql(u8, code, "ZTS400")) direct_secret = true;
        if (std.mem.eql(u8, probe.scenario, "secret-validate-transform-refused") and
            std.mem.eql(u8, code, "ZTS400")) transformed_secret = true;
        if (std.mem.eql(u8, probe.scenario, "credential-validate-transform-refused") and
            std.mem.eql(u8, code, "ZTS401")) transformed_credential = true;
    }
    try std.testing.expect(direct_secret);
    try std.testing.expect(transformed_secret);
    try std.testing.expect(transformed_credential);
}
