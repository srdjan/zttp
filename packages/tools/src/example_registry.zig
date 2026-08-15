//! One canonical minimal example per admitted surface form.
//!
//! Spec 4.8 requires `meta.payload.examples` to publish these so an agent can
//! learn the ZTS-specific spellings - `match`, `distinct type`, `assert`,
//! `comptime()` - from the protocol rather than from hidden instructions.
//!
//! Two gates, both in `agent_protocol.zig` where the feature table and the
//! checker both live. Completeness: the example set and
//! `json_diagnostics.allowed_feature_names` are compared both ways, so an
//! admitted form with no example fails and an example naming no admitted form
//! fails. Legality: every example is run through the same check `zts check`
//! runs and must report no diagnostic at any severity - an example that stops
//! being legal fails the build instead of teaching a form the compiler refuses.
//!
//! Each example is a complete handler rather than a snippet. That is what the
//! checker takes, and it means an agent can copy one and have it check clean
//! rather than assemble the surrounding shape from memory.
//!
//! The third thing a row carries is evidence that the example exercises the
//! form it names, so an edit that quietly drops the construct fails rather than
//! leaving a published example that teaches nothing. Where the parse tree
//! records the form, the evidence is a node tag and the gate walks the tree.
//! Where the form is type-level, it is a type-map kind and the gate walks the
//! stripper's map. Three forms leave neither trace and say so on the row.

const std = @import("std");

const zts = @import("zts");

pub const NodeTag = zts.parser.NodeTag;
pub const BinaryOp = zts.parser.BinaryOp;
pub const VarKind = zts.parser.Node.VarDecl.VarKind;
pub const TypeMapKind = zts.TypeMapKind;

/// What proves the example exercises the form its row names.
pub const Evidence = union(enum) {
    /// The parse tree contains this node tag.
    node: NodeTag,
    /// The parse tree contains a `var_decl` of this kind. `const` and `let`
    /// share one tag, and which keyword was written is the whole difference
    /// between the two rows.
    var_kind: VarKind,
    /// The parse tree contains a binary operation with this operator. `??` is a
    /// binary op like `+`, so the tag alone would not separate them.
    binary_operator: BinaryOp,
    /// The stripper's type map contains an annotation of this kind. The form is
    /// type-level, so it is gone before the parser runs.
    type_annotation: TypeMapKind,
    /// Neither trace exists. `needle` must appear in the source, and `reason`
    /// says why nothing stronger is available - a text match is the weakest
    /// evidence here and is used only where the alternative is none.
    source_text: struct { needle: []const u8, reason: []const u8 },
};

pub const Example = struct {
    /// The admitted form this example teaches. Matches a member of
    /// `json_diagnostics.allowed_feature_names` exactly; the gate compares the
    /// two sets in both directions.
    feature: []const u8,
    source: []const u8,
    evidence: Evidence,
};

pub const examples = [_]Example{
    .{
        .feature = "const",
        .evidence = .{ .var_kind = .@"const" },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const limit: number = 10;
        \\  return Response.json({ limit: limit });
        \\}
        \\
        ,
    },
    .{
        .feature = "let",
        .evidence = .{ .var_kind = .let },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  let total: number = 0;
        \\  for (const n of [1, 2, 3]) {
        \\    total = total + n;
        \\  }
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
    },
    .{
        .feature = "function",
        .evidence = .{ .node = .function_decl },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\function double(n: number): number {
        \\  return n * 2;
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  return Response.json({ four: double(2) });
        \\}
        \\
        ,
    },
    .{
        .feature = "arrow functions",
        .evidence = .{ .node = .arrow_function },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const doubled: number[] = [1, 2, 3].map((n: number): number => n * 2);
        \\  return Response.json({ doubled: doubled });
        \\}
        \\
        ,
    },
    .{
        .feature = "spread/rest",
        .evidence = .{ .node = .object_spread },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Config = { host: string, port: number };
        \\
        \\function defaults(): Config {
        \\  return { host: "localhost", port: 80 };
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const config: Config = { ...defaults(), port: 8080 };
        \\  return Response.json(config);
        \\}
        \\
        ,
    },
    .{
        .feature = "if/else",
        .evidence = .{ .node = .if_stmt },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const n: number = 3;
        \\  if (n > 2) {
        \\    return Response.text("big");
        \\  } else {
        \\    return Response.text("small");
        \\  }
        \\}
        \\
        ,
    },
    .{
        .feature = "for...of",
        .evidence = .{ .node = .for_of_stmt },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  let total: number = 0;
        \\  for (const n of [1, 2, 3]) {
        \\    total = total + n;
        \\  }
        \\  return Response.json({ total: total });
        \\}
        \\
        ,
    },
    .{
        .feature = "ternary",
        .evidence = .{ .node = .ternary },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const n: number = 3;
        \\  const label: string = n > 2 ? "big" : "small";
        \\  return Response.text(label);
        \\}
        \\
        ,
    },
    .{
        .feature = "optional chaining",
        .evidence = .{ .node = .optional_chain },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Profile = { name: string, city?: string };
        \\
        \\function profile(): Profile {
        \\  return { name: "ada" };
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const p: Profile = profile();
        \\  const city = p?.city;
        \\  return Response.json({ city: city });
        \\}
        \\
        ,
    },
    .{
        .feature = "nullish coalescing",
        .evidence = .{ .binary_operator = .nullish },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Profile = { name: string, city?: string };
        \\
        \\function profile(): Profile {
        \\  return { name: "ada" };
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const p: Profile = profile();
        \\  const city: string = p.city ?? "unknown";
        \\  return Response.text(city);
        \\}
        \\
        ,
    },
    .{
        .feature = "match expression",
        .evidence = .{ .node = .match_expr },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Command = { kind: "echo", text: string } | { kind: "ping" };
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const command: Command = { kind: "ping" };
        \\  const reply: string = match (command) {
        \\    when { kind: "echo", text }: text,
        \\    when { kind: "ping" }: "pong",
        \\  };
        \\  return Response.text(reply);
        \\}
        \\
        ,
    },
    .{
        .feature = "assert statement",
        .evidence = .{ .node = .assert_stmt },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const items: number[] = [1, 2, 3];
        \\  assert items.length > 0;
        \\  return Response.json({ first: items[0] });
        \\}
        \\
        ,
    },
    .{
        .feature = "import/export",
        .evidence = .{ .node = .import_decl },
        .source =
        \\import { ok } from "zttp:result";
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const parsed = ok(42);
        \\  if (!parsed.ok) {
        \\    return Response.text("unreachable");
        \\  }
        \\  return Response.json({ value: parsed.value });
        \\}
        \\
        ,
    },
    .{
        .feature = "type annotations",
        .evidence = .{ .type_annotation = .param_annotation },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\function area(width: number, height: number): number {
        \\  return width * height;
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  return Response.json({ area: area(3, 4) });
        \\}
        \\
        ,
    },
    .{
        .feature = "structural",
        .evidence = .{ .source_text = .{
            .needle = "structural Point",
            .reason = "`structural` and `type` share the `type_alias` map kind by construction - the keyword is the whole difference and the map records neither, so a kind-based row here would be satisfied by an example that writes `type` throughout and teaches nothing",
        } },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Point = { x: number; y: number };
        \\
        \\function sum(point: Point): number {
        \\  return point.x + point.y;
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const origin: Point = { x: 1, y: 2 };
        \\  return Response.json({ total: sum(origin) });
        \\}
        \\
        ,
    },
    .{
        .feature = "nominal",
        .evidence = .{ .source_text = .{
            .needle = "nominal OrderId",
            .reason = "the same reason the `structural` row gives: the map kind is `distinct_type` whatever the source spelled, so a kind-based row would be satisfied by an example that never wrote the keyword",
        } },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\nominal OrderId = string;
        \\
        \\function label(id: OrderId): string {
        \\  return id;
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const id: OrderId = OrderId("o-1");
        \\  return Response.text(label(id));
        \\}
        \\
        ,
    },
    .{
        .feature = "readonly fields",
        .evidence = .{ .source_text = .{
            .needle = "readonly port",
            .reason = "`readonly` is a modifier inside a type alias, and the type map records the alias as one annotation without a kind of its own for the modifier",
        } },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Config = { readonly port: number, host: string };
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const config: Config = { port: 3000, host: "localhost" };
        \\  return Response.json({ port: config.port, host: config.host });
        \\}
        \\
        ,
    },
    .{
        .feature = "type guards (x is T)",
        .evidence = .{ .type_annotation = .type_guard_annotation },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\function isString(value: string | number): value is string {
        \\  return typeof value === "string";
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const value: string | number = "ada";
        \\  if (isString(value)) {
        \\    return Response.text(value);
        \\  }
        \\  return Response.text("number");
        \\}
        \\
        ,
    },
    .{
        .feature = "template literal types",
        .evidence = .{ .source_text = .{
            .needle = "`/api/${string}`",
            .reason = "the pattern is the body of a type alias, and the type map records the alias without distinguishing a pattern body from any other",
        } },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Route = `/api/${string}`;
        \\
        \\function path(route: Route): string {
        \\  return route;
        \\}
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const route: Route = "/api/orders";
        \\  return Response.text(path(route));
        \\}
        \\
        ,
    },
    .{
        .feature = "comptime()",
        .evidence = .{ .source_text = .{
            .needle = "comptime(",
            .reason = "the stripper folds the call to its value before the parser runs, so the tree holds the literal and no trace of the call",
        } },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const seconds: number = comptime(60 * 60 * 24);
        \\  return Response.json({ seconds: seconds });
        \\}
        \\
        ,
    },
    .{
        .feature = "null",
        .evidence = .{ .node = .lit_null },
        .source =
        \\
        \\structural Guard<T> = Proof<T, "state_isolated">;
        \\
        \\structural Row = { id: number, note: string | null };
        \\
        \\export function handler(req: Request): Guard<Response> {
        \\  const row: Row = { id: 1, note: null };
        \\  return Response.json(row);
        \\}
        \\
        ,
    },
};

pub fn findByFeature(feature: []const u8) ?*const Example {
    for (&examples) |*entry| {
        if (std.mem.eql(u8, entry.feature, feature)) return entry;
    }
    return null;
}

const testing = std.testing;

test "no form is published twice, and every example is a whole handler" {
    for (&examples, 0..) |entry, i| {
        for (examples[i + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.feature, other.feature)) {
                std.debug.print("duplicate example feature: {s}\n", .{entry.feature});
                return error.DuplicateExample;
            }
        }
        // A snippet would not check, and the legality gate would then be
        // measuring the snippet's incompleteness rather than the form.
        try testing.expect(std.mem.indexOf(u8, entry.source, "export function handler(") != null);
    }
    try testing.expect(findByFeature("match expression") != null);
    try testing.expect(findByFeature("classes") == null);
}
