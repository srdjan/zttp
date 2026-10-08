//! The probe census of the flow checker (plan F0, constraint K1).
//!
//! This file generates the probes and carries the explicit table of expected
//! verdicts. `flow_census_gate.zig` writes the probes to a scratch directory,
//! runs the default check over them, and compares each observed verdict with
//! the expectation here.
//!
//! A probe puts one labelled value on a path to one sink, through one kind of
//! callee. The axes are:
//!   * four label families: secret, credential, user_input, clean;
//!   * seven sinks: log, egress_url, egress_body, egress_headers,
//!     egress_opaque, response, response_html;
//!   * the callee kinds in `specs`: the 18 kinds of the 2026-10-08 research
//!     (group `matrix`), the kinds that plan F0 adds (group `extended`), and
//!     the hand-written probes in `hand_written` (group `hand`).
//! Each label family claims exactly one property, the one its probe states in
//! `Proof<T, | "...">`, and the gate reads that property only.
//!
//! THE EXPECTATION IS NOT DERIVED FROM THE IMPLEMENTATION. The research
//! classifier took each cell's expectation from the handler-body row, so a
//! fail-open in the handler body made a whole column read as held: a
//! credential in an egress body was "held" in all 18 rows. `cellFor` is an
//! explicit (label, sink) table instead, derived from the documented promise
//! (docs/proofs-and-receipts.md:73-76) and from the owner decisions in
//! docs/plans/2026-10-08-flow-checker-sinks-in-callees.md. Every `hold` cell
//! carries the reason it holds. The callee-kind exceptions are named in
//! `expectationFor`. A later unit that changes a verdict edits this file in
//! the same commit as the checker.

const std = @import("std");

pub const Label = enum { secret, credential, user_input, clean };
pub const Sink = enum { log, egress_url, egress_body, egress_headers, egress_opaque, response, response_html };

/// The property a probe claims, and the only one the gate reads for it.
pub const Property = enum {
    no_secret_leakage,
    no_credential_leakage,
    injection_safe,

    pub fn claim(self: Property) []const u8 {
        return switch (self) {
            .no_secret_leakage => "\"no_secret_leakage\"",
            .no_credential_leakage => "\"no_credential_leakage\"",
            .injection_safe => "\"injection_safe\"",
        };
    }
};

/// What the documented promise says the checker must do with a probe.
pub const Expect = enum {
    /// The claimed property is false and a flow sink diagnostic says why.
    refuse,
    /// An unresolved call can only fail closed: either a refusal or an
    /// unproven property is correct, and a held property is a fail-open.
    refuse_or_unprove,
    /// The labelled value never reaches a sink, or the sink is not one by
    /// policy. The claimed property holds.
    hold,
};

/// Which part of the census a probe belongs to. The counts are per group.
pub const Group = enum {
    /// The 18 callee kinds of the research, 504 probes.
    matrix,
    /// The callee kinds that plan F0 adds to the matrix.
    extended,
    /// The hand-written probes.
    hand,
};

pub fn labelProperty(label: Label) Property {
    return switch (label) {
        .secret, .clean => .no_secret_leakage,
        .credential => .no_credential_leakage,
        .user_input => .injection_safe,
    };
}

pub const SourceFile = struct {
    /// A path relative to the scratch directory.
    name: []const u8,
    text: []const u8,
};

pub const Probe = struct {
    /// Unique. The main source is `name ++ ".ts"`.
    name: []const u8,
    group: Group,
    /// Null for a hand-written probe.
    label: ?Label,
    sink: ?Sink,
    /// The callee kind, or the hand-written probe's short name.
    kind: []const u8,
    property: Property,
    expect: Expect,
    /// Why the cell holds, or the promise a refusal rests on. Never empty.
    reason: []const u8,
    /// `files[0]` is the handler. Later files are libraries it imports.
    files: []const SourceFile,
};

/// The number of columns: one per (label, sink) pair, and one for the hand-
/// written probes.
pub const label_count = std.meta.fields(Label).len;
pub const sink_count = std.meta.fields(Sink).len;
pub const column_count = label_count * sink_count + 1;
pub const hand_column = column_count - 1;

pub fn columnOf(probe: Probe) usize {
    const label = probe.label orelse return hand_column;
    const sink = probe.sink orelse return hand_column;
    return @as(usize, @intFromEnum(label)) * sink_count + @intFromEnum(sink);
}

pub fn columnName(buf: []u8, column: usize) []const u8 {
    if (column == hand_column) return "hand_written";
    const label: Label = @enumFromInt(column / sink_count);
    const sink: Sink = @enumFromInt(column % sink_count);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ @tagName(label), @tagName(sink) }) catch "?";
}

// ---------------------------------------------------------------------------
// The expected-verdict table.
// ---------------------------------------------------------------------------

pub const Cell = struct { expect: Expect, reason: []const u8 };

const reason_not_injection_sink =
    "user input in a log or a JSON response is not an injection sink by policy: injection_safe covers SQL, HTML and egress (docs/proofs-and-receipts.md:73)";
const reason_clean = "the value comes from env(\"REGION\"), which carries no label, so no property is at risk";

/// Per (label, sink): what a probe must do when the labelled value really
/// reaches the sink. Every label family has all seven sinks written out.
pub fn cellFor(label: Label, sink: Sink) Cell {
    return switch (label) {
        // docs/proofs-and-receipts.md:75: no secret-labelled value reaches a
        // response, header, or egress call. A log is refused by ZTS402.
        .secret => .{ .expect = .refuse, .reason = switch (sink) {
            .log => "a secret in a log is refused by ZTS402",
            .egress_url => "a secret in an egress URL is refused by ZTS404",
            .egress_body => "a secret in an egress body is refused by ZTS406",
            .egress_headers => "a secret in an egress header leaves the machine (docs/proofs-and-receipts.md:75)",
            .egress_opaque => "a secret in an opaque fetch init leaves the machine (docs/proofs-and-receipts.md:75)",
            .response => "a secret in a response body is refused by ZTS400",
            .response_html => "a secret in an HTML response is refused by ZTS400",
        } },
        // Owner decision Q6 (a): the credential promise covers every egress
        // form. The checker does not refuse a body or an opaque init yet.
        .credential => .{ .expect = .refuse, .reason = switch (sink) {
            .log => "a credential in a log is refused (docs/proofs-and-receipts.md:76)",
            .egress_url => "a credential in an egress URL is refused by ZTS405",
            .egress_body => "owner decision Q6 (a): a credential in an egress body is a leak, plan unit F10",
            .egress_headers => "a credential in an egress header is refused",
            .egress_opaque => "owner decision Q6 (a): a credential in an opaque fetch init is a leak, plan unit F10",
            .response => "a credential in a response body is refused (docs/proofs-and-receipts.md:76)",
            .response_html => "a credential in an HTML response is refused (docs/proofs-and-receipts.md:76)",
        } },
        .user_input => switch (sink) {
            .log, .response => .{ .expect = .hold, .reason = reason_not_injection_sink },
            .egress_url, .egress_body, .egress_headers, .egress_opaque => .{
                .expect = .refuse,
                .reason = "unvalidated user input in an egress call is refused by ZTS407",
            },
            .response_html => .{ .expect = .refuse, .reason = "unvalidated user input in HTML is an XSS sink (docs/proofs-and-receipts.md:73)" },
        },
        .clean => .{ .expect = .hold, .reason = reason_clean },
    };
}

/// The expectation for one (label, sink, callee kind). The exceptions are the
/// kinds in which the labelled value does not reach the sink.
fn expectationFor(label: Label, sink: Sink, spec: Spec) Cell {
    const base = cellFor(label, sink);
    if (spec.never_reaches) {
        return .{ .expect = .hold, .reason = "the helper receives a string literal, so the labelled value never reaches the sink" };
    }
    const is_response_sink = sink == .response or sink == .response_html;
    if (spec.discards_result and is_response_sink) {
        return .{ .expect = .hold, .reason = "the helper's response is built from the labelled value and then discarded, so it never reaches the caller's response" };
    }
    if (spec.unresolved and base.expect == .refuse) {
        return .{ .expect = .refuse_or_unprove, .reason = "the call cannot be resolved by the summary, so it can only fail closed: refuse or leave the property unproven" };
    }
    return base;
}

// ---------------------------------------------------------------------------
// Templates. A placeholder is `@NAME@`; `@USE{expr}USE@` is the use of a call.
// ---------------------------------------------------------------------------

const header =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\import { fetch } from "zttp:fetch";
    \\import { routerMatch } from "zttp:router";
;

const Vars = struct {
    src: []const u8,
    claim: []const u8,
    stmt: []const u8,
    ret: []const u8,
    rt: []const u8,
    is_response: bool,
    liba: []const u8,
    libb: []const u8,
    cexpr: []const u8,
    crt: []const u8,
    effects: []const u8,
};

fn srcOf(label: Label) []const u8 {
    return switch (label) {
        .secret => "env(\"API_TOKEN\") ?? \"\"",
        .credential => "req.headers[\"authorization\"] ?? \"\"",
        .user_input => "req.url",
        .clean => "env(\"REGION\") ?? \"\"",
    };
}

/// The `Effects<...>` ceiling an exported helper must declare (ZTS610) and may
/// not exceed (ZTS505 warns on a capability it never reaches). The check
/// names the capabilities of the source, the sink, and the policy check, so
/// this is the exact list for each (label, sink).
fn effectsOf(label: Label, sink: Sink) []const u8 {
    const env_label = label == .secret or label == .clean;
    return switch (sink) {
        .log => if (env_label) "\"env\" | \"clock\" | \"stderr\" | \"policy_check\"" else "\"clock\" | \"stderr\"",
        .egress_url, .egress_body, .egress_headers, .egress_opaque => if (env_label)
            "\"env\" | \"runtime_callback\" | \"network\" | \"policy_check\""
        else
            "\"runtime_callback\" | \"network\"",
        .response, .response_html => if (env_label) "\"env\" | \"policy_check\"" else "",
    };
}

fn stmtOf(sink: Sink) []const u8 {
    return switch (sink) {
        .log => "logInfo(x, { n: 1 });",
        .egress_url => "const r = fetch(\"https://api.example.com/x\", { query: { k: x } });",
        .egress_body => "const r = fetch(\"https://api.example.com/x\", { method: \"POST\", body: x });",
        .egress_headers => "const r = fetch(\"https://api.example.com/x\", { headers: { \"x-k\": x } });",
        .egress_opaque => "const o = { method: \"POST\", body: x }; const r = fetch(\"https://api.example.com/x\", o);",
        .response, .response_html => "",
    };
}

fn retOf(sink: Sink) []const u8 {
    return switch (sink) {
        .response => "Response.json({ k: x })",
        .response_html => "Response.html(x)",
        else => "1",
    };
}

fn isResponse(sink: Sink) bool {
    return sink == .response or sink == .response_html;
}

/// The expression of a concise arrow body that is a sink. Null when the sink
/// has no one-expression form.
fn conciseExprOf(sink: Sink) ?[]const u8 {
    return switch (sink) {
        .log => "logInfo(x, { n: 1 })",
        .egress_url => "fetch(\"https://api.example.com/x\", { query: { k: x } })",
        .egress_body => "fetch(\"https://api.example.com/x\", { method: \"POST\", body: x })",
        .egress_headers => "fetch(\"https://api.example.com/x\", { headers: { \"x-k\": x } })",
        .egress_opaque => null,
        .response => "Response.json({ k: x })",
        .response_html => "Response.html(x)",
    };
}

fn isNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn lookup(vars: Vars, name: []const u8, a: std.mem.Allocator) !?[]const u8 {
    if (std.mem.eql(u8, name, "PRE")) {
        return try std.fmt.allocPrint(a, "{s}\nstructural Claim<T> = Proof<T, | {s}>;", .{ header, vars.claim });
    }
    if (std.mem.eql(u8, name, "SRC")) return vars.src;
    if (std.mem.eql(u8, name, "STMT")) return vars.stmt;
    if (std.mem.eql(u8, name, "RT")) return vars.rt;
    if (std.mem.eql(u8, name, "BODY")) return try std.fmt.allocPrint(a, "{s} return {s};", .{ vars.stmt, vars.ret });
    if (std.mem.eql(u8, name, "TAIL")) {
        return if (vars.is_response)
            try std.fmt.allocPrint(a, "return {s};", .{vars.ret})
        else
            "return Response.json({ ok: 1 });";
    }
    if (std.mem.eql(u8, name, "EFFECTS")) return vars.effects;
    if (std.mem.eql(u8, name, "LIBA")) return vars.liba;
    if (std.mem.eql(u8, name, "LIBB")) return vars.libb;
    if (std.mem.eql(u8, name, "CEXPR")) return vars.cexpr;
    if (std.mem.eql(u8, name, "CRT")) return vars.crt;
    return null;
}

/// Replace every `@NAME@` and every `@USE{expr}USE@` in `template`. An unknown
/// name is an error, so a typo in a template cannot reach a probe silently.
fn render(a: std.mem.Allocator, template: []const u8, vars: Vars) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c != '@') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, template[i..], "@USE{")) {
            const body_start = i + "@USE{".len;
            const end = std.mem.find(u8, template[body_start..], "}USE@") orelse return error.UnterminatedUse;
            const expr = try render(a, template[body_start .. body_start + end], vars);
            if (vars.is_response) {
                try out.appendSlice(a, "return ");
                try out.appendSlice(a, expr);
                try out.append(a, ';');
            } else {
                try out.appendSlice(a, "const n = ");
                try out.appendSlice(a, expr);
                try out.appendSlice(a, "; return Response.json({ ok: 1 });");
            }
            i = body_start + end + "}USE@".len;
            continue;
        }
        var j = i + 1;
        while (j < template.len and isNameChar(template[j])) j += 1;
        if (j > i + 1 and j < template.len and template[j] == '@') {
            const name = template[i + 1 .. j];
            const value = try lookup(vars, name, a) orelse return error.UnknownPlaceholder;
            try out.appendSlice(a, value);
            i = j + 1;
            continue;
        }
        try out.append(a, '@');
        i += 1;
    }
    return out.toOwnedSlice(a);
}

// The 18 callee kinds of the research. The text follows gen.sh in the
// 2026-10-08 scratchpad, except `export_fn` (see below).
const t_handler =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  const x = @SRC@;
    \\  @STMT@
    \\  @TAIL@
    \\}
;
const t_top_fn =
    \\@PRE@
    \\function helper(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{helper(s)}USE@
    \\}
;
const t_top_fn_self =
    \\@PRE@
    \\function helper(req: Request): @RT@ {
    \\  const x = @SRC@;
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  @USE{helper(req)}USE@
    \\}
;
const t_top_arrow =
    \\@PRE@
    \\const helper = (x: string): @RT@ => {
    \\  @BODY@
    \\};
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{helper(s)}USE@
    \\}
;
const t_nested_fn_param =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  function inner(x: string): @RT@ {
    \\    @BODY@
    \\  }
    \\  const s = @SRC@;
    \\  @USE{inner(s)}USE@
    \\}
;
const t_nested_arrow_param =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  const inner = (x: string): @RT@ => {
    \\    @BODY@
    \\  };
    \\  const s = @SRC@;
    \\  @USE{inner(s)}USE@
    \\}
;
const t_nested_fn_capture =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  const x = @SRC@;
    \\  function inner(): @RT@ {
    \\    @BODY@
    \\  }
    \\  @USE{inner()}USE@
    \\}
;
const t_nested_arrow_capture =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  const x = @SRC@;
    \\  const inner = (): @RT@ => {
    \\    @BODY@
    \\  };
    \\  @USE{inner()}USE@
    \\}
;
const t_hof_callback =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  const ns = [s].map((x: string): @RT@ => {
    \\    @BODY@
    \\  });
    \\  return Response.json({ ok: 1 });
    \\}
;
const t_route_direct =
    \\@PRE@
    \\function leak(req: Request): Response {
    \\  const x = @SRC@;
    \\  @STMT@
    \\  @TAIL@
    \\}
    \\const routes = { "GET /leak": leak };
    \\function handler(req: Request): Claim<Response> {
    \\  const found = routerMatch(routes, req);
    \\  if (found === undefined) return Response.json({ error: "nf" }, { status: 404 });
    \\  return found.handler(req);
    \\}
;
const t_route_helper =
    \\@PRE@
    \\function helper(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function leak(req: Request): Response {
    \\  const s = @SRC@;
    \\  @USE{helper(s)}USE@
    \\}
    \\const routes = { "GET /leak": leak };
    \\function handler(req: Request): Claim<Response> {
    \\  const found = routerMatch(routes, req);
    \\  if (found === undefined) return Response.json({ error: "nf" }, { status: 404 });
    \\  return found.handler(req);
    \\}
;
// The research used one `export_fn` text for every cell. An exported helper
// that reaches a capability must declare `Effects<...>` (ZTS610), and an
// `Effects` value is not a `Response` (ZTS204), so that text reached no flow
// verdict in 24 cells. These three texts avoid both. A response sink fed from
// env passes the value in, inside a record, because the export would otherwise
// reach `env`, and an exported parameter of a raw built-in type is ZTS061.
const t_export_fn =
    \\@PRE@
    \\export function helper(req: Request): Effects<number, @EFFECTS@> {
    \\  const x = @SRC@;
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Effects<Response, @EFFECTS@>> {
    \\  const n = helper(req);
    \\  return Response.json({ ok: 1 });
    \\}
;
const t_export_fn_response_env =
    \\@PRE@
    \\export structural Token = { value: string };
    \\export function helper(t: Token): Response {
    \\  const x = t.value;
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  return helper({ value: s });
    \\}
;
const t_export_fn_response_req =
    \\@PRE@
    \\export function helper(req: Request): Response {
    \\  const x = @SRC@;
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  return helper(req);
    \\}
;
const t_import_fn_lib =
    \\@HEADER@
    \\export function helper(x: string): @RT@ {
    \\  @BODY@
    \\}
;
const t_import_fn =
    \\@PRE@
    \\import { helper } from "./@LIBA@";
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{helper(s)}USE@
    \\}
;
const t_chain2 =
    \\@PRE@
    \\function b(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function a(x: string): @RT@ {
    \\  return b(x);
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{a(s)}USE@
    \\}
;
const t_recursion =
    \\@PRE@
    \\function rec(x: string, k: number): @RT@ {
    \\  if (k <= 0) {
    \\    @BODY@
    \\  }
    \\  return rec(x, k - 1);
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{rec(s, 2)}USE@
    \\}
;
const t_twice_clean_first =
    \\@PRE@
    \\function helper(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  const first = helper("hello");
    \\  @USE{helper(s)}USE@
    \\}
;
const t_twice_secret_first =
    \\@PRE@
    \\function helper(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  const first = helper(s);
    \\  @USE{helper("hello")}USE@
    \\}
;
const t_clean_arg =
    \\@PRE@
    \\function helper(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{helper("hello")}USE@
    \\}
;

// The kinds that plan F0 adds. A module-level constant needs a source that
// does not read `req`, so those three kinds take the secret and clean labels.
const t_module_const_handler =
    \\@PRE@
    \\const token = @SRC@;
    \\function handler(req: Request): Claim<Response> {
    \\  const x = token;
    \\  @STMT@
    \\  @TAIL@
    \\}
;
const t_module_const_helper =
    \\@PRE@
    \\const token = @SRC@;
    \\function helper(): @RT@ {
    \\  const x = token;
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  @USE{helper()}USE@
    \\}
;
const t_module_const_closure =
    \\@PRE@
    \\const token = @SRC@;
    \\function handler(req: Request): Claim<Response> {
    \\  const inner = (): @RT@ => {
    \\    const x = token;
    \\    @BODY@
    \\  };
    \\  @USE{inner()}USE@
    \\}
;
// Nine helpers: the ninth holds the sink, one past the summary depth cap of 8.
const t_chain9 =
    \\@PRE@
    \\function h9(x: string): @RT@ {
    \\  @BODY@
    \\}
    \\function h8(x: string): @RT@ { return h9(x); }
    \\function h7(x: string): @RT@ { return h8(x); }
    \\function h6(x: string): @RT@ { return h7(x); }
    \\function h5(x: string): @RT@ { return h6(x); }
    \\function h4(x: string): @RT@ { return h5(x); }
    \\function h3(x: string): @RT@ { return h4(x); }
    \\function h2(x: string): @RT@ { return h3(x); }
    \\function h1(x: string): @RT@ { return h2(x); }
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{h1(s)}USE@
    \\}
;
// Nine parameters: one past the parameter cap of 8.
const t_param9 =
    \\@PRE@
    \\function helper(x: string, p2: number, p3: number, p4: number, p5: number, p6: number, p7: number, p8: number, p9: number): @RT@ {
    \\  @BODY@
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{helper(s, 2, 3, 4, 5, 6, 7, 8, 9)}USE@
    \\}
;
// The callee produces the labelled value and hands it to the callback.
const t_apply_cb =
    \\@PRE@
    \\function apply(req: Request, f: (v: string) => @RT@): @RT@ {
    \\  const t = @SRC@;
    \\  return f(t);
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  @USE{apply(req, (x: string): @RT@ => { @BODY@ })}USE@
    \\}
;
const t_apply_record =
    \\@PRE@
    \\function via(req: Request, o: { go: (v: string) => @RT@ }): @RT@ {
    \\  const t = @SRC@;
    \\  return o.go(t);
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  @USE{via(req, { go: (x: string): @RT@ => { @BODY@ } })}USE@
    \\}
;
// The outer call passes a clean string. The recursive call passes the labelled
// value, and the base case reaches the sink with it.
const t_recursion_taint =
    \\@PRE@
    \\function rec(req: Request, x: string, k: number): @RT@ {
    \\  if (k <= 0) {
    \\    @BODY@
    \\  }
    \\  const t = @SRC@;
    \\  return rec(req, t, k - 1);
    \\}
    \\function handler(req: Request): Claim<Response> {
    \\  @USE{rec(req, "hello", 1)}USE@
    \\}
;
const t_concise_arrow =
    \\@PRE@
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  const inner = (x: string): @CRT@ => @CEXPR@;
    \\  @USE{inner(s)}USE@
    \\}
;
const t_import2_lib_b =
    \\@HEADER@
    \\export function inner(x: string): @RT@ {
    \\  @BODY@
    \\}
;
const t_import2_lib_a =
    \\@HEADER@
    \\import { inner } from "./@LIBB@";
    \\export function helper(x: string): @RT@ {
    \\  return inner(x);
    \\}
;
const t_import2 =
    \\@PRE@
    \\import { helper } from "./@LIBA@";
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  @USE{helper(s)}USE@
    \\}
;
const t_parallel_cb =
    \\@PRE@
    \\import { parallel } from "zttp:io";
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  const results = parallel([(): @RT@ => { const x = s; @BODY@ }]);
    \\  return Response.json({ ok: 1 });
    \\}
;
const t_durable_run_cb =
    \\@PRE@
    \\import { run } from "zttp:durable";
    \\function handler(req: Request): Claim<Response> {
    \\  const s = @SRC@;
    \\  const out = run("job:1", (): @RT@ => { const x = s; @BODY@ });
    \\  return Response.json({ ok: 1 });
    \\}
;

const all_labels = [_]Label{ .secret, .credential, .user_input, .clean };
const env_labels = [_]Label{ .secret, .clean };
/// The kinds whose unresolved call can only fail closed take no clean label:
/// the fail-closed answer for a clean value would be an over-refusal that the
/// unit F1b chooses on purpose.
const leaking_labels = [_]Label{ .secret, .credential, .user_input };
const all_sinks = [_]Sink{ .log, .egress_url, .egress_body, .egress_headers, .egress_opaque, .response, .response_html };
const effect_sinks = [_]Sink{ .log, .egress_url, .egress_body, .egress_headers, .egress_opaque };
const concise_sinks = [_]Sink{ .log, .egress_url, .egress_body, .egress_headers, .response, .response_html };

const Lib = struct { suffix: []const u8, template: []const u8 };

const Spec = struct {
    name: []const u8,
    group: Group,
    labels: []const Label = &all_labels,
    sinks: []const Sink = &all_sinks,
    template: []const u8,
    /// The text for the cells in which the sink is a response.
    response_template: ?[]const u8 = null,
    libs: []const Lib = &.{},
    /// The labelled value is never passed to the sink (the helper gets a literal).
    never_reaches: bool = false,
    /// The helper's result is dropped, so a response sink never reaches the caller.
    discards_result: bool = false,
    /// The call cannot be resolved by the summary.
    unresolved: bool = false,
};

const specs = [_]Spec{
    .{ .name = "handler", .group = .matrix, .template = t_handler },
    .{ .name = "top_fn", .group = .matrix, .template = t_top_fn },
    .{ .name = "top_fn_self", .group = .matrix, .template = t_top_fn_self },
    .{ .name = "top_arrow", .group = .matrix, .template = t_top_arrow },
    .{ .name = "nested_fn_param", .group = .matrix, .template = t_nested_fn_param },
    .{ .name = "nested_arrow_param", .group = .matrix, .template = t_nested_arrow_param },
    .{ .name = "nested_fn_capture", .group = .matrix, .template = t_nested_fn_capture },
    .{ .name = "nested_arrow_capture", .group = .matrix, .template = t_nested_arrow_capture },
    .{ .name = "hof_callback", .group = .matrix, .template = t_hof_callback, .discards_result = true },
    .{ .name = "route_direct", .group = .matrix, .template = t_route_direct },
    .{ .name = "route_helper", .group = .matrix, .template = t_route_helper },
    .{ .name = "export_fn", .group = .matrix, .template = t_export_fn, .response_template = t_export_fn_response_env },
    .{ .name = "import_fn", .group = .matrix, .template = t_import_fn, .libs = &.{.{ .suffix = "a", .template = t_import_fn_lib }} },
    .{ .name = "chain2", .group = .matrix, .template = t_chain2 },
    .{ .name = "recursion", .group = .matrix, .template = t_recursion },
    .{ .name = "twice_clean_first", .group = .matrix, .template = t_twice_clean_first },
    .{ .name = "twice_secret_first", .group = .matrix, .template = t_twice_secret_first, .discards_result = true },
    .{ .name = "clean_arg", .group = .matrix, .template = t_clean_arg, .never_reaches = true },

    .{ .name = "module_const_handler", .group = .extended, .labels = &env_labels, .template = t_module_const_handler },
    .{ .name = "module_const_helper", .group = .extended, .labels = &env_labels, .template = t_module_const_helper },
    .{ .name = "module_const_closure", .group = .extended, .labels = &env_labels, .template = t_module_const_closure },
    .{ .name = "chain9", .group = .extended, .labels = &leaking_labels, .template = t_chain9, .unresolved = true },
    .{ .name = "param9", .group = .extended, .labels = &leaking_labels, .template = t_param9, .unresolved = true },
    .{ .name = "apply_cb", .group = .extended, .labels = &leaking_labels, .template = t_apply_cb, .unresolved = true },
    .{ .name = "apply_record", .group = .extended, .labels = &leaking_labels, .template = t_apply_record, .unresolved = true },
    .{ .name = "recursion_taint", .group = .extended, .template = t_recursion_taint },
    .{ .name = "concise_arrow", .group = .extended, .sinks = &concise_sinks, .template = t_concise_arrow },
    .{
        .name = "import2",
        .group = .extended,
        .template = t_import2,
        .libs = &.{ .{ .suffix = "a", .template = t_import2_lib_a }, .{ .suffix = "b", .template = t_import2_lib_b } },
    },
    .{ .name = "parallel_cb", .group = .extended, .sinks = &effect_sinks, .template = t_parallel_cb },
    .{ .name = "durable_run_cb", .group = .extended, .sinks = &effect_sinks, .template = t_durable_run_cb },
};

fn contains(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |item| if (item == needle) return true;
    return false;
}

fn buildMatrixProbe(a: std.mem.Allocator, spec: Spec, label: Label, sink: Sink) !Probe {
    const stem = try std.fmt.allocPrint(a, "{s}__{s}__{s}", .{ @tagName(label), @tagName(sink), spec.name });
    const liba = try std.fmt.allocPrint(a, "lib__{s}__{s}__{s}__a.ts", .{ @tagName(label), @tagName(sink), spec.name });
    const libb = try std.fmt.allocPrint(a, "lib__{s}__{s}__{s}__b.ts", .{ @tagName(label), @tagName(sink), spec.name });
    const concise = conciseExprOf(sink);
    const vars: Vars = .{
        .src = srcOf(label),
        .claim = labelProperty(label).claim(),
        .stmt = stmtOf(sink),
        .ret = retOf(sink),
        .rt = if (isResponse(sink)) "Response" else "number",
        .is_response = isResponse(sink),
        .liba = liba,
        .libb = libb,
        .cexpr = concise orelse "",
        .crt = if (isResponse(sink)) "Response" else "unknown",
        .effects = effectsOf(label, sink),
    };
    // An exported helper that reads the request needs no `env` for the
    // credential and user_input labels, so a response sink can stay as it was.
    var template = spec.template;
    if (spec.response_template) |response_template| {
        if (isResponse(sink)) {
            template = if (label == .secret or label == .clean) response_template else t_export_fn_response_req;
        }
    }
    var files: std.ArrayList(SourceFile) = .empty;
    try files.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.ts", .{stem}), .text = try renderWithHeader(a, template, vars) });
    for (spec.libs) |lib| {
        const lib_name = if (std.mem.eql(u8, lib.suffix, "a")) liba else libb;
        try files.append(a, .{ .name = lib_name, .text = try renderWithHeader(a, lib.template, vars) });
    }
    const cell = expectationFor(label, sink, spec);
    return .{
        .name = stem,
        .group = spec.group,
        .label = label,
        .sink = sink,
        .kind = spec.name,
        .property = labelProperty(label),
        .expect = cell.expect,
        .reason = cell.reason,
        .files = try files.toOwnedSlice(a),
    };
}

fn renderWithHeader(a: std.mem.Allocator, template: []const u8, vars: Vars) ![]u8 {
    // `@HEADER@` is the import block alone, for the library files.
    const expanded = try std.mem.replaceOwned(u8, a, template, "@HEADER@", header);
    return render(a, expanded, vars);
}

// ---------------------------------------------------------------------------
// Hand-written probes.
// ---------------------------------------------------------------------------

const hand_header =
    \\import { env } from "zttp:env";
    \\import { logInfo } from "zttp:log";
    \\import { fetch } from "zttp:fetch";
    \\import { mask, escapeHtml } from "zttp:text";
    \\import { schemaCompile, validateJson } from "zttp:validate";
    \\import { parallel } from "zttp:io";
;

const Hand = struct {
    name: []const u8,
    property: Property,
    expect: Expect,
    reason: []const u8,
    body: []const u8,
};

const hand_written = [_]Hand{
    .{
        .name = "x01_mask_in_handler_log",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "mask with a literal bound declassifies the secret, so the log receives no secret",
        .body =
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  logInfo(mask(t, 4), { n: 1 });
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x02_mask_in_helper_log",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "mask with a literal bound declassifies the secret inside the helper, so the log receives no secret",
        .body =
        \\function report(x: string): number {
        \\  logInfo(mask(x, 4), { n: 1 });
        \\  return 1;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const n = report(t);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x03_escape_in_helper_html",
        .property = .injection_safe,
        .expect = .hold,
        .reason = "escapeHtml discharges user_input, so the HTML response receives no unvalidated input",
        .body =
        \\function page(x: string): Response {
        \\  return Response.html(escapeHtml(x));
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  return page(req.url);
        \\}
        ,
    },
    .{
        .name = "x04_validate_in_helper_egress",
        .property = .injection_safe,
        .expect = .hold,
        .reason = "validateJson discharges user_input, so the egress body receives only validated input",
        .body =
        \\schemaCompile("todo", "{\"type\":\"object\"}");
        \\function forward(body: string): number {
        \\  const parsed = validateJson("todo", body);
        \\  if (!parsed.ok) return 0;
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: JSON.stringify(parsed.value) });
        \\  return 1;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const n = forward(req.body ?? "");
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x05_validate_in_handler_egress",
        .property = .injection_safe,
        .expect = .hold,
        .reason = "validateJson discharges user_input, so the egress body receives only validated input",
        .body =
        \\schemaCompile("todo", "{\"type\":\"object\"}");
        \\function handler(req: Request): Claim<Response> {
        \\  const parsed = validateJson("todo", req.body ?? "");
        \\  if (!parsed.ok) return Response.json({ ok: 0 });
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: JSON.stringify(parsed.value) });
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x06_upvalue_name_collision",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "the helper logs its own clean x; the handler's secret x is only measured, never logged",
        .body =
        \\function helperA(): number {
        \\  const x = "clean";
        \\  const inner = (): number => {
        \\    logInfo(x, { n: 1 });
        \\    return 1;
        \\  };
        \\  return inner();
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const x = env("API_TOKEN") ?? "";
        \\  const n = helperA();
        \\  const m = x.length;
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x07_helper_logs_req_url",
        .property = .injection_safe,
        .expect = .hold,
        .reason = reason_not_injection_sink,
        .body =
        \\function audit(req: Request): number {
        \\  logInfo(req.url, { n: 1 });
        \\  return 1;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const n = audit(req);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x08_secret_to_helper_no_sink",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "the helper measures the secret and returns a number; no sink receives it",
        .body =
        \\function size(x: string): number {
        \\  return x.length;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const n = size(t);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x09_nested_decl_returns_secret_len",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "the nested function returns the length of the secret to a variable that no sink receives",
        .body =
        \\function handler(req: Request): Claim<Response> {
        \\  const x = env("API_TOKEN") ?? "";
        \\  function inner(): number {
        \\    return x.length;
        \\  }
        \\  const n = inner();
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x10_helper_return_fetch_body",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "the helper sends the secret in an egress body through its return statement (ZTS406)",
        .body =
        \\function send(x: string): unknown {
        \\  return fetch("https://api.example.com/x", { method: "POST", body: x });
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const r = send(t);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x11_sink_nested_in_expression",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "the secret goes in an egress body inside an array literal in the handler body (ZTS406)",
        .body =
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const rs = [fetch("https://api.example.com/x", { method: "POST", body: t })];
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x12_parallel_callback_logs_secret",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "the parallel callback logs a secret it reads itself (ZTS402)",
        .body =
        \\function work(): unknown {
        \\  const t = env("API_TOKEN") ?? "";
        \\  logInfo(t, { n: 1 });
        \\  return fetch("https://api.example.com/x", {});
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const results = parallel([work]);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x13_helper_clean_then_secret_return_only",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "the secret goes through id() and is not sunk; shout() receives only the clean value",
        .body =
        \\function id(x: string): string {
        \\  const y = x;
        \\  return y;
        \\}
        \\function shout(x: string): number {
        \\  logInfo(x, { n: 1 });
        \\  return 1;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const a = id(t);
        \\  const b = id("hello");
        \\  const n = shout(b);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x14_dead_helper_logs_secret",
        .property = .no_secret_leakage,
        .expect = .hold,
        .reason = "the helper is never called, so it never runs; plan unit F1 decides whether never-called functions are walked",
        .body =
        \\function unused(): number {
        \\  const t = env("API_TOKEN") ?? "";
        \\  logInfo(t, { n: 1 });
        \\  return 1;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    // The sanitizer counter-controls: each sanitizer discharges one label and
    // keeps the others, so a different label through it still leaks.
    .{
        .name = "x15_secret_through_escape_html_response",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "escapeHtml discharges user_input only, so a secret through it still reaches the HTML response (ZTS400)",
        .body =
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  return Response.html(escapeHtml(t));
        \\}
        ,
    },
    .{
        .name = "x16_secret_through_escape_html_helper",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "escapeHtml discharges user_input only, so a secret through it in a helper still reaches the HTML response (ZTS400)",
        .body =
        \\function page(x: string): Response {
        \\  return Response.html(escapeHtml(x));
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  return page(t);
        \\}
        ,
    },
    .{
        .name = "x17_secret_through_validate_json_egress",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "validateJson discharges user_input only, so a secret through it still reaches the egress body (ZTS406)",
        .body =
        \\schemaCompile("todo", "{\"type\":\"object\"}");
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const parsed = validateJson("todo", t);
        \\  if (!parsed.ok) return Response.json({ ok: 0 });
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: JSON.stringify(parsed.value) });
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x18_secret_through_validate_json_helper",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "validateJson discharges user_input only, so a secret through it in a helper still reaches the egress body (ZTS406)",
        .body =
        \\schemaCompile("todo", "{\"type\":\"object\"}");
        \\function forward(body: string): number {
        \\  const parsed = validateJson("todo", body);
        \\  if (!parsed.ok) return 0;
        \\  const r = fetch("https://api.example.com/x", { method: "POST", body: JSON.stringify(parsed.value) });
        \\  return 1;
        \\}
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  const n = forward(t);
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x19_mask_runtime_bound_log",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "mask declassifies only while its bound is a literal; a runtime bound leaves the secret in the log (ZTS402)",
        .body =
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  logInfo(mask(t, t.length), { n: 1 });
        \\  return Response.json({ ok: 1 });
        \\}
        ,
    },
    .{
        .name = "x20_return_path_sink_in_handler_expression",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "the secret goes in an egress body inside the expression of the handler's return statement (ZTS406)",
        .body =
        \\function handler(req: Request): Claim<Response> {
        \\  const t = env("API_TOKEN") ?? "";
        \\  return Response.json({ status: fetch("https://api.example.com/x", { method: "POST", body: t }).status });
        \\}
        ,
    },
    .{
        .name = "x21_module_const_returned_by_handler",
        .property = .no_secret_leakage,
        .expect = .refuse,
        .reason = "the module-level constant holds a secret and the handler returns it in a response (ZTS400)",
        .body =
        \\const token = env("API_TOKEN") ?? "";
        \\function handler(req: Request): Claim<Response> {
        \\  return Response.json({ k: token });
        \\}
        ,
    },
};

/// Every probe of the census, in a fixed order. All memory comes from `a`.
pub fn generate(a: std.mem.Allocator) ![]Probe {
    var probes: std.ArrayList(Probe) = .empty;
    for (specs) |spec| {
        for (all_labels) |label| {
            if (!contains(Label, spec.labels, label)) continue;
            for (all_sinks) |sink| {
                if (!contains(Sink, spec.sinks, sink)) continue;
                try probes.append(a, try buildMatrixProbe(a, spec, label, sink));
            }
        }
    }
    for (hand_written) |hand| {
        const vars: Vars = .{
            .src = "",
            .claim = hand.property.claim(),
            .stmt = "",
            .ret = "",
            .rt = "",
            .is_response = false,
            .liba = "",
            .libb = "",
            .cexpr = "",
            .crt = "",
            .effects = "",
        };
        const claim_line = try std.fmt.allocPrint(a, "structural Claim<T> = Proof<T, | {s}>;", .{vars.claim});
        const text = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ hand_header, claim_line, hand.body });
        const files = try a.alloc(SourceFile, 1);
        files[0] = .{ .name = try std.fmt.allocPrint(a, "{s}.ts", .{hand.name}), .text = text };
        try probes.append(a, .{
            .name = hand.name,
            .group = .hand,
            .label = null,
            .sink = null,
            .kind = "hand_written",
            .property = hand.property,
            .expect = hand.expect,
            .reason = hand.reason,
            .files = files,
        });
    }
    return probes.toOwnedSlice(a);
}

/// The committed floors on the census itself. A generator that yields fewer
/// probes than these has lost an axis, and every count below it means less.
/// Raise a floor in the commit that adds probes, to the count the gate prints.
/// Never lower one to make a deletion pass.
pub const minimum_matrix: usize = 504;
pub const minimum_extended: usize = 246;
pub const minimum_hand: usize = 21;
/// The fewest probes a (label, sink) column holds: the 18 research kinds.
pub const minimum_per_column: usize = 18;

const testing = std.testing;

test "the generator yields unique names and renders every placeholder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const probes = try generate(arena.allocator());
    for (probes, 0..) |probe, i| {
        for (probes[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier.name, probe.name));
        try testing.expect(probe.reason.len != 0);
        for (probe.files) |file| {
            try testing.expect(std.mem.find(u8, file.text, "@") == null);
        }
    }
}
