//! One canonical minimal example per admitted surface form.
//!
//! Spec 4.8 requires `meta.payload.examples` to publish these so an agent can
//! learn the ZTS-specific spellings - `match`, `distinct type`, `assert`,
//! `comptime()`, the pipe - from the protocol rather than from hidden
//! instructions.
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const limit: number = 10;
        \\  return Response.json({ limit });
        \\}
        \\
        ,
    },
    .{
        .feature = "let",
        .evidence = .{ .var_kind = .let },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  let total: number = 0;
        \\  for (const n of [1, 2, 3]) {
        \\    total = total + n;
        \\  }
        \\  return Response.json({ total });
        \\}
        \\
        ,
    },
    .{
        .feature = "function",
        .evidence = .{ .node = .function_decl },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\function double(n: number): number {
        \\  return n * 2;
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  return Response.json({ four: double(2) });
        \\}
        \\
        ,
    },
    .{
        .feature = "arrow functions",
        .evidence = .{ .node = .arrow_function },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const doubled: number[] = [1, 2, 3].map((n: number): number => n * 2);
        \\  return Response.json({ doubled });
        \\}
        \\
        ,
    },
    .{
        .feature = "destructuring",
        .evidence = .{ .node = .object_pattern },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Point = { x: number, y: number };
        \\
        \\function origin(): Point {
        \\  return { x: 1, y: 2 };
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const { x, y } = origin();
        \\  return Response.json({ sum: x + y });
        \\}
        \\
        ,
    },
    .{
        .feature = "spread/rest",
        .evidence = .{ .node = .object_spread },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Config = { host: string, port: number };
        \\
        \\function defaults(): Config {
        \\  return { host: "localhost", port: 80 };
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const config: Config = { ...defaults(), port: 8080 };
        \\  return Response.json(config);
        \\}
        \\
        ,
    },
    .{
        .feature = "template literals",
        .evidence = .{ .node = .template_literal },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const name: string = "world";
        \\  return Response.text(`hello, ${name}`);
        \\}
        \\
        ,
    },
    .{
        .feature = "if/else",
        .evidence = .{ .node = .if_stmt },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  let total: number = 0;
        \\  for (const n of [1, 2, 3]) {
        \\    total = total + n;
        \\  }
        \\  return Response.json({ total });
        \\}
        \\
        ,
    },
    .{
        .feature = "ternary",
        .evidence = .{ .node = .ternary },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Profile = { name: string, city?: string };
        \\
        \\function profile(): Profile {
        \\  return { name: "ada" };
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const p: Profile = profile();
        \\  const city = p?.city;
        \\  return Response.json({ city });
        \\}
        \\
        ,
    },
    .{
        .feature = "nullish coalescing",
        .evidence = .{ .binary_operator = .nullish },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Profile = { name: string, city?: string };
        \\
        \\function profile(): Profile {
        \\  return { name: "ada" };
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Command = { kind: "echo", text: string } | { kind: "ping" };
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const items: number[] = [1, 2, 3];
        \\  assert items.length > 0;
        \\  return Response.json({ first: items[0] });
        \\}
        \\
        ,
    },
    .{
        .feature = "pipe operator",
        .evidence = .{ .source_text = .{
            .needle = "|>",
            .reason = "the parser folds `a |> f` into the call `f(a)`, so the tree carries a `call` node indistinguishable from one written that way",
        } },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\function double(n: number): number {
        \\  return n * 2;
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const score: number = 21;
        \\  const doubled: number = score |> double;
        \\  return Response.json({ doubled });
        \\}
        \\
        ,
    },
    .{
        .feature = "import/export",
        .evidence = .{ .node = .import_decl },
        .source =
        \\import { ok } from "zttp:result";
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\function area(width: number, height: number): number {
        \\  return width * height;
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  return Response.json({ area: area(3, 4) });
        \\}
        \\
        ,
    },
    .{
        .feature = "distinct type",
        .evidence = .{ .type_annotation = .distinct_type },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\distinct type UserId = string;
        \\
        \\function label(id: UserId): string {
        \\  return id;
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const id: UserId = UserId("u-1");
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Config = { readonly port: number, host: string };
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\function isString(value: string | number): value is string {
        \\  return typeof value === "string";
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Route = `/api/${string}`;
        \\
        \\function path(route: Route): string {
        \\  return route;
        \\}
        \\
        \\export function handler(req: Request): Response & Guard {
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
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\export function handler(req: Request): Response & Guard {
        \\  const seconds: number = comptime(60 * 60 * 24);
        \\  return Response.json({ seconds });
        \\}
        \\
        ,
    },
    .{
        .feature = "null",
        .evidence = .{ .node = .lit_null },
        .source =
        \\import type { Spec } from "zttp:types";
        \\
        \\type Guard = Spec<"state_isolated">;
        \\
        \\type Row = { id: number, note: string | null };
        \\
        \\export function handler(req: Request): Response & Guard {
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
