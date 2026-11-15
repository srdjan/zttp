//! Probe inputs for the restriction gate (`zig build test-ts-restrictions`).
//!
//! This table holds inputs only. A key is the exact text of a form cell in
//! `docs/ts-restrictions.md`, with `\|` written as `|`. The expected codes come
//! from that file, never from this one: the gate reads the code cell of the
//! row that the key names.
//!
//! A refusal row needs one `Refusal` for each backticked span of its form cell
//! (a row with no span needs one with an empty span) and one clean source for
//! its "Write instead" form. A span can have more than one probe, so that the
//! probes together reach each code of the row. A gap row needs at least one
//! source.

pub const File = struct { name: []const u8, text: []const u8 };

pub const Source = struct {
    text: []const u8,
    /// The path that the check sees. The extension decides ZTS052.
    path: []const u8 = "probe.ts",
    /// Files that a relative import reads, by file name.
    files: []const File = &.{},
};

pub const Refusal = struct {
    /// The backticked span of the form cell that this probe refuses, or "".
    span: []const u8 = "",
    source: Source,
};

pub const RefusalRow = struct {
    key: []const u8,
    refused: []const Refusal,
    clean: Source,
};

pub const GapRow = struct {
    key: []const u8,
    sources: []const Source,
};

// ---------------------------------------------------------------------------
// Source builders
// ---------------------------------------------------------------------------

const head = "export function handler(req: Request): Proof<Response, \"no_secret_leakage\"> {\n";
const tail = head ++ "  return Response.text(\"ok\");\n}\n";

/// Top-level declarations, then a valid handler.
fn top(comptime s: []const u8) []const u8 {
    return s ++ "\n" ++ tail;
}

/// Statements inside a valid handler.
fn body(comptime s: []const u8) []const u8 {
    return head ++ s ++ "\n  return Response.text(\"ok\");\n}\n";
}

fn r(comptime span: []const u8, comptime text: []const u8) Refusal {
    return .{ .span = span, .source = .{ .text = text } };
}

fn rp(comptime span: []const u8, comptime path: []const u8, comptime text: []const u8) Refusal {
    return .{ .span = span, .source = .{ .text = text, .path = path } };
}

fn rf(comptime span: []const u8, comptime text: []const u8, comptime files: []const File) Refusal {
    return .{ .span = span, .source = .{ .text = text, .files = files } };
}

fn c(comptime text: []const u8) Source {
    return .{ .text = text };
}

fn cf(comptime text: []const u8, comptime files: []const File) Source {
    return .{ .text = text, .files = files };
}

const mod_file: []const File = &.{.{ .name = "mod.ts", .text = "export function x(): number {\n  return 1;\n}\n" }};

const g_fn = "function g(): number {\n  return 1;\n}\n";

/// A function whose one parameter has the type text `t`.
fn param(comptime t: []const u8) Source {
    return c(top("function g(a: " ++ t ++ "): number {\n  return 1;\n}"));
}

/// A function that returns the array expression `e` over a `number[]` named `xs`.
fn arr_call(comptime e: []const u8) Source {
    return c(top("function g(xs: number[]): unknown {\n  return " ++ e ++ ";\n}"));
}

const boundary_proof = "structural Boundary<T> = Proof<T, \"deterministic\" | \"read_only\">;\n";

const dict_round_trip = "import { dictEmpty, dictSet, dictEntries, dictFromEntries } from \"zttp:collections\";\nfunction g(): boolean {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const pairs = dictEntries(d).map((p) => [p[0], p[1] * 2]);\n  const rebuilt = dictFromEntries(pairs);\n  return rebuilt.ok;\n}\n" ++ tail;

const dict_reduce = "import { dictEmpty, dictSet, dictEntries } from \"zttp:collections\";\nfunction g(): number {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  return dictEntries(d).reduce((acc, p) => acc + p[1], 0);\n}\n" ++ tail;

const dict_bulk = "import { dictEmpty, dictSet, dictMapValues, dictFilter, dictFold } from \"zttp:collections\";\nfunction g(): number {\n  const d = dictSet(dictEmpty(), \"a\", 1);\n  const m = dictMapValues(d, (v, k) => v * 2);\n  const f = dictFilter(m, (v, k) => v > 0);\n  return dictFold(f, (acc, v, k) => acc + v, 0);\n}\n" ++ tail;

const command_type = "structural Cmd = { kind: \"a\", text: string } | { kind: \"b\", text: string };\n";

// ---------------------------------------------------------------------------
// Refusal rows
// ---------------------------------------------------------------------------

pub const refusal_rows = [_]RefusalRow{
    // ----- Source Files And Modules -----
    .{
        .key = "A `.js`, `.jsx`, `.tsx`, or unknown file extension",
        .refused = &.{
            rp(".js", "probe.js", tail),
            rp(".jsx", "probe.jsx", tail),
            rp(".tsx", "probe.tsx", tail),
            rp(".js", "probe.foo", tail),
        },
        .clean = c(tail),
    },
    .{
        .key = "`import X from \"mod\"` (default import)",
        .refused = &.{rf("import X from \"mod\"", top("import X from \"./mod.ts\";"), mod_file)},
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst y: number = x();"), mod_file),
    },
    .{
        .key = "`import * as X from \"mod\"` (namespace import)",
        .refused = &.{rf("import * as X from \"mod\"", top("import * as X from \"./mod.ts\";"), mod_file)},
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst y: number = x();"), mod_file),
    },
    .{
        .key = "`import \"mod\"` (side-effect import)",
        .refused = &.{rf("import \"mod\"", top("import \"./mod.ts\";"), mod_file)},
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst y: number = x();"), mod_file),
    },
    .{
        .key = "`import(\"mod\")` (dynamic import)",
        .refused = &.{rf("import(\"mod\")", body("  const m = import(\"./mod.ts\");"), mod_file)},
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst y: number = x();"), mod_file),
    },
    .{
        .key = "`export { x } from \"mod\"` and `export { x }` of an imported name",
        .refused = &.{
            rf("export { x } from \"mod\"", top("export { x } from \"./mod.ts\";"), mod_file),
            rf("export { x }", top("import { x } from \"./mod.ts\";\nexport { x };"), mod_file),
        },
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst n: number = x();"), mod_file),
    },
    .{
        .key = "`export * from \"mod\"`",
        .refused = &.{rf("export * from \"mod\"", top("export * from \"./mod.ts\";"), mod_file)},
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst y: number = x();"), mod_file),
    },
    .{
        .key = "`export default ...`",
        .refused = &.{r("export default ...", "export default function handler(req: Request): Response {\n  return Response.text(\"ok\");\n}\n")},
        .clean = c(tail),
    },
    .{
        .key = "`export let x = ...` (mutable top-level export)",
        .refused = &.{r("export let x = ...", top("export let x = 1;"))},
        .clean = c(top("export const x = 1;")),
    },
    .{
        .key = "A top-level `let` that is never reassigned",
        .refused = &.{r("let", top("let x = 1;"))},
        .clean = c(top("const x = 1;")),
    },
    .{
        .key = "A handler that writes to a module-scope variable",
        .refused = &.{r("", "let counter = 0;\n" ++ head ++ "  counter = counter + 1;\n  return Response.text(\"ok\");\n}\n")},
        .clean = c(body("  let counter = 0;\n  counter = counter + 1;")),
    },
    .{
        .key = "An unknown `zttp:` module, or a name that the module does not export",
        .refused = &.{
            r("zttp:", top("import { x } from \"zttp:nope\";")),
            r("zttp:", top("import { nope } from \"zttp:collections\";")),
        },
        .clean = c(top("import { dictEmpty } from \"zttp:collections\";\nconst d: Dict<string, number> = dictEmpty();")),
    },
    .{
        .key = "`namespace` and `module` declarations",
        .refused = &.{
            r("namespace", top("namespace N {\n  export const a = 1;\n}")),
            r("module", top("module M {\n  export const a = 1;\n}")),
        },
        .clean = cf(top("import { x } from \"./mod.ts\";\nconst y: number = x();"), mod_file),
    },

    // ----- Lexical Rules -----
    .{
        .key = "An escape outside the closed set, such as `\"a\\qb\"`",
        .refused = &.{r("\"a\\qb\"", body("  const s = \"a\\qb\";"))},
        .clean = c(body("  const s = \"a\\nb\";")),
    },
    .{
        .key = "A backslash before a real newline",
        .refused = &.{r("", body("  const s = \"a\\\nb\";"))},
        .clean = c(body("  const s = \"ab\";")),
    },
    .{
        .key = "A string literal that reaches the end of its line",
        .refused = &.{r("", body("  const s = \"abc\n;"))},
        .clean = c(body("  const s = \"abc\";")),
    },
    .{
        .key = "`0x`, `0b`, or `0o` with no digits, and `1e` with no exponent digits",
        .refused = &.{
            r("0x", body("  const n = 0x;")),
            r("0b", body("  const n = 0b;")),
            r("0o", body("  const n = 0o;")),
            r("1e", body("  const n = 1e;")),
        },
        .clean = c(body("  const n = 0x1f;")),
    },
    .{
        .key = "A legacy octal literal such as `0755`",
        .refused = &.{r("0755", body("  const n = 0755;"))},
        .clean = c(body("  const n = 0o755;")),
    },
    .{
        .key = "A numeric separator such as `1_000`",
        .refused = &.{r("1_000", body("  const n = 1_000;"))},
        .clean = c(body("  const n = 1000;")),
    },
    .{
        .key = "A character above ASCII in an identifier",
        .refused = &.{r("", body("  const caf\u{e9} = 1;"))},
        .clean = c(body("  const cafe = 1;")),
    },
    .{
        .key = "A statement with no `;`",
        .refused = &.{r(";", body("  const x = 1"))},
        .clean = c(body("  const x = 1;")),
    },

    // ----- Declarations And Bindings -----
    .{
        .key = "`var`",
        .refused = &.{r("var", body("  var x = 1;"))},
        .clean = c(body("  const x = 1;")),
    },
    .{
        .key = "A `let` that is never reassigned",
        .refused = &.{r("let", body("  let x = 1;"))},
        .clean = c(body("  const x = 1;")),
    },
    .{
        .key = "Object or array declaration destructuring, and destructuring renames",
        .refused = &.{
            r("", body("  const o = { a: 1 };\n  const { a } = o;")),
            r("", body("  const xs = [1, 2];\n  const [a, b] = xs;")),
            r("", body("  const o = { a: 1 };\n  const { a: b } = o;")),
        },
        .clean = c(body("  const o = { a: 1 };\n  const a = o.a;")),
    },
    .{
        .key = "`class` declarations and `class` expressions",
        .refused = &.{
            r("class", top("class A {\n}")),
            r("class", body("  const A = class {\n  };")),
        },
        .clean = c(top("structural A = { a: number };")),
    },
    .{
        .key = "`enum` and `const enum`",
        .refused = &.{
            r("enum", top("enum E {\n  A,\n}")),
            r("const enum", top("const enum E {\n  A,\n}")),
        },
        .clean = c(top("structural E = \"a\" | \"b\";")),
    },
    .{
        .key = "Decorators (`@decorator`)",
        .refused = &.{r("@decorator", top("@decorator\nfunction f(): number {\n  return 1;\n}"))},
        .clean = c(top("function f(): number {\n  return 1;\n}")),
    },
    .{
        .key = "`implements` and access modifiers (`public`, `private`, `protected`)",
        .refused = &.{
            r("implements", top("class A implements B {\n}")),
            r("public", top("class A {\n  public a: number;\n}")),
            r("private", top("class A {\n  private a: number;\n}")),
            r("protected", top("class A {\n  protected a: number;\n}")),
        },
        .clean = c(top("structural A = { a: number };")),
    },
    .{
        .key = "`interface X { ... }`",
        .refused = &.{r("interface X { ... }", top("interface X {\n  a: number;\n}"))},
        .clean = c(top("structural X = { a: number };")),
    },
    .{
        .key = "`type X = ...;`",
        .refused = &.{r("type X = ...;", top("type X = string;"))},
        .clean = c(top("structural X = string;")),
    },
    .{
        .key = "`distinct type X = string;`",
        .refused = &.{r("distinct type X = string;", top("distinct type X = string;"))},
        .clean = c(top("nominal X = string;")),
    },
    .{
        .key = "A `nominal` type over a record, tuple, union, or function",
        .refused = &.{
            r("nominal", top("nominal X = { a: number };")),
            r("nominal", top("nominal X = [number, number];")),
            r("nominal", top("nominal X = string | number;")),
            r("nominal", top("nominal X = (a: number) => number;")),
        },
        .clean = c(top("nominal X = string;")),
    },
    .{
        .key = "A reused arrow helper, such as `const double = (x) => x * 2;`",
        .refused = &.{r("const double = (x) => x * 2;", top("const double = (x: number): number => x * 2;\nfunction use(): number {\n  return double(1) + double(2);\n}"))},
        .clean = c(top("function double(x: number): number {\n  return x * 2;\n}\nfunction use(): number {\n  return double(1) + double(2);\n}")),
    },
    .{
        .key = "An exported function-valued `const`",
        .refused = &.{r("const", top("export const f = (x: number): number => x;"))},
        .clean = c(top("nominal N = number;\n" ++ boundary_proof ++ "export function f(x: N): Boundary<N> {\n  return x;\n}")),
    },
    .{
        .key = "A nominal type called as a function, such as `Id(\"a\")`",
        .refused = &.{r("Id(\"a\")", top("nominal Id = string;\nfunction g(): string {\n  const x = Id(\"a\");\n  return x;\n}"))},
        .clean = c(top("nominal Id = string;\nfunction g(): string {\n  const x: Id = \"a\";\n  return x;\n}")),
    },

    // ----- Functions And Parameters -----
    .{
        .key = "Function expressions, named or anonymous",
        .refused = &.{
            r("", body("  const f = function (x: number): number {\n    return x;\n  };")),
            r("", body("  const f = function g(x: number): number {\n    return x;\n  };")),
        },
        .clean = c(top("function f(x: number): number {\n  return x;\n}")),
    },
    .{
        .key = "Generators (`function*`) and `yield`",
        .refused = &.{
            r("function*", top("function* g() {\n  yield 1;\n}")),
            r("yield", top("function* g() {\n  yield 1;\n}")),
        },
        .clean = c(top("function g(): number[] {\n  return [1];\n}")),
    },
    .{
        .key = "`async` functions, `await`, and `Promise`",
        .refused = &.{
            r("async", top("async function f(): Promise<number> {\n  return 1;\n}")),
            r("await", top("async function f(): Promise<number> {\n  return await 1;\n}")),
            r("Promise", body("  const p = Promise.resolve(1);")),
        },
        .clean = c(top("function f(): number {\n  return 1;\n}")),
    },
    .{
        .key = "A default parameter, such as `limit = 50`",
        .refused = &.{r("limit = 50", top("function f(limit: number = 50): number {\n  return limit;\n}"))},
        .clean = c(top("function f(limit: number | undefined): number {\n  const resolved = limit ?? 50;\n  return resolved;\n}")),
    },
    .{
        .key = "Optional parameter shorthand `name?: T`",
        .refused = &.{r("name?: T", top("function f(name?: string): string {\n  return \"a\";\n}"))},
        .clean = c(top("function f(name: string | undefined): string {\n  return name ?? \"a\";\n}")),
    },
    .{
        .key = "Rest parameters `...args`",
        .refused = &.{r("...args", top("function f(...args: number[]): number {\n  return 1;\n}"))},
        .clean = c(top("function f(args: number[]): number {\n  return 1;\n}")),
    },
    .{
        .key = "Call-site spread `f(...args)`",
        .refused = &.{r("f(...args)", top("function f(a: number): number {\n  return a;\n}\nfunction g(args: number[]): number {\n  return f(...args);\n}"))},
        .clean = c(top("function f(a: number): number {\n  return a;\n}\nfunction g(args: number[]): number {\n  return f(1);\n}")),
    },
    .{
        .key = "A named function without parameter or return annotations",
        .refused = &.{r("", top("function f(x) {\n  return x;\n}"))},
        .clean = c(top("function f(x: number): number {\n  return x;\n}")),
    },
    .{
        .key = "A call with too few or too many arguments",
        .refused = &.{
            r("", top("function f(a: number, b: number): number {\n  return a;\n}\nfunction g(): number {\n  return f(1);\n}")),
            r("", top("function f(a: number): number {\n  return a;\n}\nfunction g(): number {\n  return f(1, 2);\n}")),
        },
        .clean = c(top("function f(a: number): number {\n  return a;\n}\nfunction g(): number {\n  return f(1);\n}")),
    },
    .{
        .key = "`this` and `super`",
        .refused = &.{
            r("this", top("function f(): number {\n  return this;\n}")),
            r("super", top("function f(): number {\n  return super.a;\n}")),
        },
        .clean = c(top("function f(ctx: number): number {\n  return ctx;\n}")),
    },
    .{
        .key = "An exported function that reaches a capability with no `Effects<...>` return ceiling",
        .refused = &.{r("Effects<...>", top("import { env } from \"zttp:env\";\nstructural B<T> = Proof<T, \"read_only\">;\nexport function f(): B<string> {\n  return env(\"A\") ?? \"\";\n}"))},
        .clean = c(top("import { env } from \"zttp:env\";\nstructural B<T> = Proof<T, \"read_only\">;\nexport function f(): B<Effects<string, \"env\" | \"policy_check\">> {\n  return env(\"A\") ?? \"\";\n}")),
    },
    .{
        .key = "A module-internal function that declares an `Effects<...>` ceiling",
        .refused = &.{r("Effects<...>", top("function f(): Effects<string, \"env\"> {\n  return \"a\";\n}"))},
        .clean = c(top("function f(): string {\n  return \"a\";\n}")),
    },
    .{
        .key = "An `await` outside an async function",
        .refused = &.{r("await", body("  const a = await 1;"))},
        .clean = c(top("function g(): number {\n  return 1;\n}")),
    },
    .{
        .key = "A generic call in which no argument fixes a type parameter",
        .refused = &.{r("", top("function f<T>(): number {\n  return 1;\n}\nfunction g(): number {\n  return f();\n}"))},
        .clean = c(top("function f<T>(): number {\n  return 1;\n}\nfunction g(): number {\n  return f<number>();\n}")),
    },
    .{
        .key = "An exported helper with no `Proof<...>` capsule, when the handler declares a proof spec",
        .refused = &.{r("Proof<...>", "nominal Id = string;\nexport function helper(a: Id): Id {\n  return a;\n}\nexport function handler(req: Request): Proof<Response, \"deterministic\"> {\n  return Response.text(\"ok\");\n}\n")},
        .clean = c("nominal Id = string;\nexport function helper(a: Id): Proof<Id, \"deterministic\"> {\n  return a;\n}\nexport function handler(req: Request): Proof<Response, \"deterministic\"> {\n  return Response.text(\"ok\");\n}\n"),
    },

    // ----- Statements And Control Flow -----
    .{
        .key = "`switch` / `case`",
        .refused = &.{
            r("switch", body("  const n = 1;\n  switch (n) {\n    default:\n  }")),
            r("case", body("  const n = 1;\n  switch (n) {\n    case 1:\n  }")),
        },
        .clean = c(top("function f(n: number): number {\n  return match (n) {\n    when 1: 1\n    default: 0\n  };\n}")),
    },
    .{
        .key = "`while` and `do...while`",
        .refused = &.{
            r("while", body("  while (false) {\n  }")),
            r("do...while", body("  do {\n  } while (false);")),
        },
        .clean = c(body("  for (const i of range(3)) {\n  }")),
    },
    .{
        .key = "`for...in`",
        .refused = &.{r("for...in", body("  const o = { a: 1 };\n  for (const k in o) {\n  }"))},
        .clean = c(body("  const o = { a: 1 };\n  for (const k of Object.keys(o)) {\n  }")),
    },
    .{
        .key = "`throw`, `try`, `catch`, and `finally`",
        .refused = &.{
            r("throw", body("  throw 1;")),
            r("try", body("  try {\n  } finally {\n  }")),
            r("catch", body("  try {\n  } catch (e) {\n  }")),
            r("finally", body("  try {\n  } finally {\n  }")),
        },
        .clean = c(body("  return Response.text(\"no\", { status: 400 });")),
    },
    .{
        .key = "`debugger;`",
        .refused = &.{r("debugger;", body("  debugger;"))},
        .clean = c(body("  const x = 1;")),
    },
    .{
        .key = "An empty statement `;`",
        .refused = &.{r(";", body("  ;"))},
        .clean = c(body("  const x = 1;")),
    },
    .{
        .key = "A fallback `assert` form",
        .refused = &.{r("assert", body("  assert 1 === 1, Response.text(\"no\");"))},
        .clean = c(body("  if (1 !== 1) {\n    return Response.text(\"no\");\n  }")),
    },
    .{
        .key = "A `for...of` body that mutates the collection that it iterates",
        .refused = &.{r("for...of", body("  const xs = [1, 2];\n  for (const x of xs) {\n    xs.push(x);\n  }"))},
        .clean = c(body("  const xs = [1, 2];\n  const ys = [1, 2];\n  for (const x of xs) {\n    ys.push(x);\n  }")),
    },
    .{
        .key = "`range(n).map(f)` and other array members on `range(n)`",
        .refused = &.{
            r("range(n).map(f)", body("  const ys = range(3).map((i: number): number => i);")),
            r("range(n)", body("  const ys = range(3).filter((i: number): boolean => i > 0);")),
        },
        .clean = c(body("  for (const i of range(3)) {\n  }")),
    },

    // ----- Operators And Expressions -----
    .{
        .key = "`==` and `!=`",
        .refused = &.{
            r("==", body("  const a: boolean = 1 == 1;")),
            r("!=", body("  const a: boolean = 1 != 1;")),
        },
        .clean = c(body("  const a: boolean = 1 === 1;\n  const b: boolean = 1 !== 1;")),
    },
    .{
        .key = "`++` and `--`, prefix and postfix",
        .refused = &.{
            r("++", body("  let i = 0;\n  i++;")),
            r("++", body("  let i = 0;\n  ++i;")),
            r("--", body("  let i = 0;\n  i--;")),
            r("--", body("  let i = 0;\n  --i;")),
        },
        .clean = c(body("  let i = 0;\n  i = i + 1;")),
    },
    .{
        .key = "Compound assignment: `+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`",
        .refused = &.{
            r("+=", body("  let x = 1;\n  x += 1;")),
            r("-=", body("  let x = 1;\n  x -= 1;")),
            r("*=", body("  let x = 1;\n  x *= 1;")),
            r("/=", body("  let x = 1;\n  x /= 1;")),
            r("%=", body("  let x = 1;\n  x %= 1;")),
            r("**=", body("  let x = 1;\n  x **= 1;")),
            r("&=", body("  let x = 1;\n  x &= 1;")),
            r("|=", body("  let x = 1;\n  x |= 1;")),
            r("^=", body("  let x = 1;\n  x ^= 1;")),
            r("<<=", body("  let x = 1;\n  x <<= 1;")),
            r(">>=", body("  let x = 1;\n  x >>= 1;")),
            r(">>>=", body("  let x = 1;\n  x >>>= 1;")),
        },
        .clean = c(body("  let x = 1;\n  x = x + 1;")),
    },
    .{
        .key = "Logical assignment: `&&=`, `||=`, `??=`",
        .refused = &.{
            r("&&=", body("  let x = true;\n  x &&= false;")),
            r("||=", body("  let x = true;\n  x ||= false;")),
            r("??=", body("  let x: number | undefined = undefined;\n  x ??= 1;")),
        },
        .clean = c(body("  let x = true;\n  x = x && false;")),
    },
    .{
        .key = "`instanceof`",
        .refused = &.{r("instanceof", body("  const a = req instanceof Request;"))},
        .clean = c(top(command_type ++ "function f(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\", text }: text\n    when { kind: \"b\", text }: text\n  };\n}")),
    },
    .{
        .key = "The `in` operator",
        .refused = &.{r("in", body("  const o = { a: 1 };\n  const a = \"a\" in o;"))},
        .clean = c(top("import { dictHas, dictEmpty } from \"zttp:collections\";\nfunction f(): boolean {\n  const d: Dict<string, number> = dictEmpty();\n  return dictHas(d, \"a\");\n}")),
    },
    .{
        .key = "Unary `+`",
        .refused = &.{r("+", body("  const s = \"1\";\n  const n = +s;"))},
        .clean = c(body("  const n = parseInt(\"1\");")),
    },
    .{
        .key = "Unary `void`",
        .refused = &.{r("void", body("  const u = void 0;"))},
        .clean = c(body("  const u = undefined;")),
    },
    .{
        .key = "`delete`",
        .refused = &.{r("delete", body("  const o = { a: 1, b: 2 };\n  delete o.a;"))},
        .clean = c(body("  const o = { b: 2 };")),
    },
    .{
        .key = "`new`",
        .refused = &.{r("new", body("  const d = new Date();"))},
        .clean = c(body("  const d = Date.now();")),
    },
    .{
        .key = "Regex literals and the `RegExp` global",
        .refused = &.{
            r("RegExp", body("  const re = /a/;")),
            r("RegExp", body("  const re = RegExp(\"a\");")),
        },
        .clean = c(body("  const s = \"abc\";\n  const b = s.includes(\"a\");")),
    },
    .{
        .key = "Comma and sequence expressions",
        .refused = &.{r("", body("  const a = (1, 2);"))},
        .clean = c(body("  const a = 2;")),
    },
    .{
        .key = "Template interpolation `` `n=${n}` ``",
        .refused = &.{r("`n=${n}`", body("  const n = 1;\n  const s = `n=${n}`;"))},
        .clean = c(body("  const n = 1;\n  const s = [\"n=\", String(n)].join(\"\");\n  const t = `plain`;")),
    },
    .{
        .key = "`+` with a string operand",
        .refused = &.{r("+", body("  const s = \"a\";\n  const t = s + \"b\";"))},
        .clean = c(body("  const s = \"a\";\n  const t = [s, \"b\"].join(\"\");")),
    },
    .{
        .key = "`+` with a boolean, optional, or untyped operand",
        .refused = &.{
            r("+", body("  const b = true;\n  const n = b + 1;")),
            r("+", body("  const o: number | undefined = undefined;\n  const n = o + 1;")),
        },
        .clean = c(body("  const o: number | undefined = undefined;\n  const n = (o ?? 0) + 1;")),
    },
    .{
        .key = "`-`, `*`, `/`, `%`, `**`, or unary `-` on a non-number",
        .refused = &.{
            r("-", body("  const a = \"a\" - 1;")),
            r("*", body("  const a = \"a\" * 1;")),
            r("/", body("  const a = \"a\" / 1;")),
            r("%", body("  const a = \"a\" % 1;")),
            r("**", body("  const a = \"a\" ** 1;")),
            r("-", body("  const a = -\"a\";")),
        },
        .clean = c(body("  const a = 2 * 3 - 1;")),
    },
    .{
        .key = "A non-boolean condition in `if`, `assert`, or `?:`",
        .refused = &.{
            r("if", body("  const n = 1;\n  if (n) {\n  }")),
            r("assert", body("  const n = 1;\n  assert n;")),
            r("?:", body("  const n = 1;\n  const a = n ? 1 : 2;")),
        },
        .clean = c(body("  const n = 1;\n  if (n > 0) {\n  }")),
    },
    .{
        .key = "A non-boolean operand of `&&`, `||`, or `!`",
        .refused = &.{
            r("&&", body("  const n = 1;\n  const a = n && true;")),
            r("||", body("  const n = 1;\n  const a = n || true;")),
            r("!", body("  const n = 1;\n  const a = !n;")),
        },
        .clean = c(body("  const n = 1;\n  const a = n > 0 && true;")),
    },
    .{
        .key = "`|>`",
        .refused = &.{r("|>", body("  const a = 1 |> String;"))},
        .clean = c(body("  const a = String(1);")),
    },
    .{
        .key = "Optional call `f?.()`",
        .refused = &.{r("f?.()", top("function g(f: (() => number) | undefined): number {\n  return f?.();\n}"))},
        .clean = c(top("function g(f: () => number): number {\n  return f();\n}")),
    },
    .{
        .key = "Optional computed access `xs?.[i]`",
        .refused = &.{r("xs?.[i]", top("function g(xs: number[] | undefined): number | undefined {\n  return xs?.[0];\n}"))},
        .clean = c(top("function g(xs: number[] | undefined): number | undefined {\n  if (xs === undefined) {\n    return undefined;\n  }\n  return xs[0];\n}")),
    },
    .{
        .key = "An effectful arm in `a ? b : c`",
        .refused = &.{r("a ? b : c", top("import { env } from \"zttp:env\";\nfunction g(a: boolean): string | undefined {\n  return a ? env(\"A\") : \"b\";\n}"))},
        .clean = c(top("import { env } from \"zttp:env\";\nfunction g(a: boolean): string | undefined {\n  const e = env(\"A\");\n  return a ? e : \"b\";\n}")),
    },
    .{
        .key = "A conditional expression as an arm of another conditional",
        .refused = &.{r("", top("function g(a: boolean, b: boolean): number {\n  return a ? 1 : b ? 2 : 3;\n}"))},
        .clean = c(top("function g(a: boolean, b: boolean): number {\n  if (a) {\n    return 1;\n  }\n  return b ? 2 : 3;\n}")),
    },
    .{
        .key = "A boolean compared to a boolean literal, such as `x === true`",
        .refused = &.{r("x === true", top("function g(x: boolean): boolean {\n  return x === true;\n}"))},
        .clean = c(top("function g(x: boolean): boolean {\n  return x;\n}")),
    },

    // ----- Records, Arrays, And Strings -----
    .{
        .key = "Object literal shorthand `{ value }`",
        .refused = &.{r("{ value }", body("  const value = 1;\n  const o = { value };"))},
        .clean = c(body("  const value = 1;\n  const o = { value: value };")),
    },
    .{
        .key = "Object methods, getters, and setters",
        .refused = &.{
            r("", body("  const o = {\n    m() {\n      return 1;\n    },\n  };")),
            r("", body("  const o = {\n    get a() {\n      return 1;\n    },\n  };")),
            r("", body("  const o = {\n    set a(v: number) {\n    },\n  };")),
        },
        .clean = c(top("function m(): number {\n  return 1;\n}")),
    },
    .{
        .key = "A computed record key `{ [k]: v }`",
        .refused = &.{r("{ [k]: v }", body("  const k = \"a\";\n  const o = { [k]: 1 };"))},
        .clean = c(body("  const o = { a: 1 };")),
    },
    .{
        .key = "A numeric record key `{ 1: \"a\" }`",
        .refused = &.{r("{ 1: \"a\" }", body("  const o = { 1: \"a\" };"))},
        .clean = c(body("  const o = { one: \"a\" };")),
    },
    .{
        .key = "An object spread after an explicit key, or a second spread",
        .refused = &.{
            r("", body("  const base = { a: 1 };\n  const o = { x: 1, ...base };")),
            r("", body("  const base = { a: 1 };\n  const o = { ...base, ...base };")),
        },
        .clean = c(body("  const base = { a: 1 };\n  const o = { ...base, x: 1 };")),
    },
    .{
        .key = "Dynamic property access `obj[key]`",
        .refused = &.{r("obj[key]", top("function g(obj: { a: number }, key: string): number {\n  return obj[key];\n}"))},
        .clean = c(top("function g(obj: { a: number }): number {\n  return obj.a;\n}")),
    },
    .{
        .key = "`Object.assign`, `Object.freeze`, and `Object.isFrozen`",
        .refused = &.{
            r("Object.assign", body("  const o = Object.assign({ a: 1 }, { b: 2 });")),
            r("Object.freeze", body("  const o = Object.freeze({ a: 1 });")),
            r("Object.isFrozen", body("  const o = Object.isFrozen({ a: 1 });")),
        },
        .clean = c(body("  const base = { a: 1 };\n  const o = { ...base, b: 2 };")),
    },
    .{
        .key = "A member that the runtime does not hold, such as `n.toFixed(2)` or `n.toString()`",
        .refused = &.{
            r("n.toFixed(2)", body("  const n = 1;\n  const s = n.toFixed(2);")),
            r("n.toString()", body("  const n = 1;\n  const s = n.toString();")),
        },
        .clean = c(body("  const n = 1;\n  const s = String(n);")),
    },
    .{
        .key = "A numeric index read on a string, such as `s[0]`",
        .refused = &.{r("s[0]", body("  const s = \"abc\";\n  const c = s[0];"))},
        .clean = c(body("  const s = \"abc\";\n  const c = s.charAt(0);")),
    },
    .{
        .key = "A member call on `unknown` or on a value with no known type",
        .refused = &.{r("unknown", top("function g(v: unknown): string {\n  return v.toUpperCase();\n}"))},
        .clean = c(top("function g(v: unknown): string {\n  if (typeof v === \"string\") {\n    return v.toUpperCase();\n  }\n  return \"\";\n}")),
    },
    .{
        .key = "A container write whose value does not fit the slot type",
        .refused = &.{r("", body("  const xs: number[] = [1];\n  xs[0] = \"a\";"))},
        .clean = c(body("  const xs: number[] = [1];\n  xs.push(2);")),
    },
    .{
        .key = "`push`, `pop`, `shift`, `unshift`, `splice`, or a `length` write on a tuple",
        .refused = &.{
            r("push", body("  const t: [number, number] = [1, 2];\n  t.push(3);")),
            r("pop", body("  const t: [number, number] = [1, 2];\n  t.pop();")),
            r("shift", body("  const t: [number, number] = [1, 2];\n  t.shift();")),
            r("unshift", body("  const t: [number, number] = [1, 2];\n  t.unshift(3);")),
            r("splice", body("  const t: [number, number] = [1, 2];\n  t.splice(0, 1);")),
            r("length", body("  const t: [number, number] = [1, 2];\n  t.length = 1;")),
        },
        .clean = c(body("  const t: number[] = [1, 2];\n  t.push(3);")),
    },
    .{
        .key = "A mutating method on a `readonly` array",
        .refused = &.{r("readonly", top("function g(xs: readonly number[]): number {\n  xs.push(1);\n  return 1;\n}"))},
        .clean = c(top("function g(xs: readonly number[]): number[] {\n  const ys: number[] = xs.slice(0, 1);\n  ys.push(1);\n  return ys;\n}")),
    },
    .{
        .key = "A `dictEntries` round trip through `dictFromEntries` that changes only values or drops entries",
        .refused = &.{
            r("dictEntries", dict_round_trip),
            r("dictFromEntries", dict_round_trip),
        },
        .clean = c(dict_bulk),
    },
    .{
        .key = "A `reduce` over `dictEntries(d)`",
        .refused = &.{
            r("reduce", dict_reduce),
            r("dictEntries(d)", dict_reduce),
        },
        .clean = c(dict_bulk),
    },

    // ----- Null, Undefined, And Absence -----
    .{
        .key = "`null` where the type does not name `null`",
        .refused = &.{
            r("null", body("  const a: string = null;")),
            r("null", top("function g(a: string): string {\n  return a;\n}\nfunction h(): string {\n  return g(null);\n}")),
        },
        .clean = c(body("  const a: string | null = null;")),
    },
    .{
        .key = "`??` or `?.` on an operand whose type admits `null`, a generic parameter, or `unknown`",
        .refused = &.{
            r("??", body("  const name: string | null = req.url;\n  const shown = name ?? \"anonymous\";")),
            r("null", body("  const name: string | null = req.url;\n  const shown = name ?? \"anonymous\";")),
            r("?.", body("  const row: { name: string } | null = null;\n  const shown = row?.name;")),
            r("unknown", body("  const raw: unknown = req.url;\n  const shown = raw ?? \"anonymous\";")),
        },
        .clean = c(body("  const name: string | undefined = req.url;\n  const shown = name ?? \"anonymous\";")),
    },
    .{
        .key = "A read of a possibly absent value without a check",
        .refused = &.{
            r("", "import { env } from \"zttp:env\";\n" ++ head ++ "  const e = env(\"A\");\n  const n = String(e);\n  return Response.text(\"ok\");\n}\n"),
            r("", top("function g(a: string | undefined): string {\n  return a.toUpperCase();\n}")),
        },
        .clean = c("import { env } from \"zttp:env\";\n" ++ head ++ "  const e = env(\"A\");\n  if (e !== undefined) {\n    const n = e.length;\n  }\n  return Response.text(\"ok\");\n}\n"),
    },
    .{
        .key = "A call result with an implicit `unknown` type",
        .refused = &.{r("unknown", top("function g(cb: unknown): number {\n  const v = cb(1);\n  return 1;\n}"))},
        .clean = c(top("function g(cb: (n: number) => number): number {\n  const v = cb(1);\n  return v;\n}")),
    },

    // ----- Match -----
    .{
        .key = "A `default` arm before a `when` arm, or a second `default` arm",
        .refused = &.{
            r("default", top("function g(n: number): number {\n  return match (n) {\n    default: 0\n    when 1: 1\n  };\n}")),
            r("when", top("function g(n: number): number {\n  return match (n) {\n    default: 0\n    when 1: 1\n  };\n}")),
            r("default", top("function g(n: number): number {\n  return match (n) {\n    when 1: 1\n    default: 0\n    default: 2\n  };\n}")),
        },
        .clean = c(top("function g(n: number): number {\n  return match (n) {\n    when 1: 1\n    default: 0\n  };\n}")),
    },
    .{
        .key = "A type-test name below the top level of a pattern, such as `when { v: string }`",
        .refused = &.{r("when { v: string }", top("structural R = { v: string | number };\nfunction g(r: R): number {\n  return match (r) {\n    when { v: string }: 1\n    default: 0\n  };\n}"))},
        .clean = c(top("structural R = { v: string | number };\nfunction g(r: R): number {\n  const v = r.v;\n  return match (v) {\n    when string: 1\n    default: 0\n  };\n}")),
    },
    .{
        .key = "`when _:`",
        .refused = &.{r("when _:", top("function g(n: number): number {\n  return match (n) {\n    when _: 0\n  };\n}"))},
        .clean = c(top("function g(n: number): number {\n  return match (n) {\n    default: 0\n  };\n}")),
    },
    .{
        .key = "A rename to the same name, such as `{ text: text }` in a pattern",
        .refused = &.{r("{ text: text }", top(command_type ++ "function g(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\", text: text }: text\n    when { kind: \"b\", text }: text\n  };\n}"))},
        .clean = c(top(command_type ++ "function g(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\", text }: text\n    when { kind: \"b\", text }: text\n  };\n}")),
    },
    .{
        .key = "An arm that reads a field off the scrutinee",
        .refused = &.{r("", top(command_type ++ "function g(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\" }: c.text\n    when { kind: \"b\", text }: text\n  };\n}"))},
        .clean = c(top(command_type ++ "function g(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\", text }: text\n    when { kind: \"b\", text }: text\n  };\n}")),
    },

    // ----- Types -----
    .{
        .key = "`any` in any position",
        .refused = &.{r("any", top("function g(a: any): number {\n  return 1;\n}"))},
        .clean = c(top("function g(a: unknown): number {\n  return 1;\n}")),
    },
    .{
        .key = "`x as T`",
        .refused = &.{r("x as T", body("  const v: unknown = 1;\n  const n = v as number;"))},
        .clean = c(body("  const v: unknown = 1;\n  if (typeof v === \"number\") {\n    const n: number = v;\n  }")),
    },
    .{
        .key = "`x satisfies T`",
        .refused = &.{r("x satisfies T", body("  const n = 1 satisfies number;"))},
        .clean = c(body("  const n: number = 1;")),
    },
    .{
        .key = "`Array<T>`",
        .refused = &.{r("Array<T>", body("  const xs: Array<number> = [1];"))},
        .clean = c(body("  const xs: number[] = [1];")),
    },
    .{
        .key = "`ReadonlyArray<T>`",
        .refused = &.{r("ReadonlyArray<T>", body("  const xs: ReadonlyArray<number> = [1];"))},
        .clean = c(body("  const xs: readonly number[] = [1];")),
    },
    .{
        .key = "The `void` type",
        .refused = &.{r("void", top("function g(): void {\n}"))},
        .clean = c(top("function g(): undefined {\n  return undefined;\n}")),
    },
    .{
        .key = "A raw built-in open type in an exported parameter or return",
        .refused = &.{r("", top("export function g(a: string): string {\n  return a;\n}"))},
        .clean = c(top("nominal Id = string;\nstructural B<T> = Proof<T, \"deterministic\">;\nexport function g(a: Id): B<Id> {\n  return a;\n}")),
    },
    .{
        .key = "A recursive alias with a cycle that does not pass through a record, tuple, array, or `Dict`",
        .refused = &.{r("Dict", top("structural A = A | number;\nconst value: A = 1;"))},
        .clean = c(top("structural A = { next: A | undefined };\nconst value: A = { next: undefined };")),
    },
    .{
        .key = "A type predicate whose body does not prove the predicate",
        .refused = &.{r("", top("function isStr(x: unknown): x is string {\n  return true;\n}"))},
        .clean = c(top("function isStr(x: unknown): x is string {\n  return typeof x === \"string\";\n}")),
    },
    .{
        .key = "A wrong number of explicit type arguments, or a violated constraint",
        .refused = &.{
            r("", top("function f<T>(a: T): T {\n  return a;\n}\nconst r1 = f<string, number>(\"a\");")),
            r("", top("function f<T extends string>(a: T): T {\n  return a;\n}\nconst r1 = f<number>(1);")),
        },
        .clean = c(top("function f<T>(a: T): T {\n  return a;\n}\nconst r1 = f<string>(\"a\");")),
    },

    // ----- Ambient Names And Effects -----
    .{
        .key = "A value name outside the ambient namespace, such as `console`, `process`, `globalThis`, or `Symbol`",
        .refused = &.{
            r("console", body("  console.log(\"x\");")),
            r("process", body("  const p = process;")),
            r("globalThis", body("  const g = globalThis;")),
            r("Symbol", body("  const s = Symbol;")),
        },
        .clean = c(top("import { env } from \"zttp:env\";\nfunction g(): string | undefined {\n  return env(\"A\");\n}")),
    },
    .{
        .key = "`eval`, `Proxy`, and `Reflect`",
        .refused = &.{
            r("eval", body("  const a = eval(\"1\");")),
            r("Proxy", body("  const a = Proxy;")),
            r("Reflect", body("  const a = Reflect;")),
        },
        .clean = c(top("function f(x: number): number {\n  return x;\n}")),
    },
    .{
        .key = "A capability call with a dynamic argument, such as a computed env key",
        .refused = &.{r("", top("import { env } from \"zttp:env\";\nfunction g(k: string): string | undefined {\n  return env(k);\n}"))},
        .clean = c(top("import { env } from \"zttp:env\";\nfunction g(): string | undefined {\n  return env(\"A\");\n}")),
    },

    // ----- Request, Response, And JSON -----
    .{
        .key = "A Response init member other than `status`, such as `headers`",
        .refused = &.{
            r("headers", body("  const a = Response.text(\"x\", { headers: { a: \"b\" } });")),
            r("status", body("  const a = Response.text(\"x\", { status: 200, headers: { a: \"b\" } });")),
        },
        .clean = c(body("  const a = Response.text(\"x\", { status: 201 });")),
    },
    .{
        .key = "A Response init that is not a record, or a `status` that is not a number",
        .refused = &.{
            r("status", body("  const a = Response.text(\"x\", 404);")),
            r("status", body("  const a = Response.text(\"x\", { status: \"404\" });")),
        },
        .clean = c(body("  const a = Response.text(\"x\", { status: 404 });")),
    },
    .{
        .key = "`Response.redirect(url, { status: 301 })`",
        .refused = &.{r("Response.redirect(url, { status: 301 })", body("  const a = Response.redirect(\"/x\", { status: 301 });"))},
        .clean = c(body("  const a = Response.redirect(\"/x\", 301);")),
    },
    .{
        .key = "A `Response.json` payload that JSON cannot carry, such as `Dict<number, string>`",
        .refused = &.{
            r("Response.json", top("import { dictEmpty } from \"zttp:collections\";\nfunction g(): Response {\n  const d: Dict<number, string> = dictEmpty();\n  return Response.json(d);\n}")),
            r("Dict<number, string>", top("import { dictEmpty } from \"zttp:collections\";\nfunction g(): Response {\n  const d: Dict<number, string> = dictEmpty();\n  return Response.json(d);\n}")),
        },
        .clean = c(top("import { dictEmpty } from \"zttp:collections\";\nfunction g(): Response {\n  const d: Dict<string, string> = dictEmpty();\n  return Response.json(d);\n}")),
    },
    .{
        .key = "A member or index read on the `.value` of `requestJson(req)`",
        .refused = &.{
            r(".value", body("  const j = requestJson(req);\n  if (j.ok) {\n    const n = j.value.name;\n  }")),
            r("requestJson(req)", body("  const j = requestJson(req);\n  if (j.ok) {\n    const n = j.value[0];\n  }")),
        },
        .clean = c(top("import { dictGet } from \"zttp:collections\";\nfunction g(req: Request): unknown {\n  const j = requestJson(req);\n  if (j.ok) {\n    const v: unknown = j.value;\n    if (isDict(v)) {\n      return dictGet(v, \"name\");\n    }\n  }\n  return undefined;\n}")),
    },
};

// ---------------------------------------------------------------------------
// Gap rows
// ---------------------------------------------------------------------------

pub const gap_rows = [_]GapRow{
    .{
        .key = "Assignment in expression position, such as `const m = (n = 2);`",
        .sources = &.{c(body("  let n = 1;\n  const m = (n = 2);"))},
    },
    .{
        .key = "Generic defaults, such as `function f<T = string>(a: T): T`",
        .sources = &.{c(top("function f<T = string>(a: T): T {\n  return a;\n}"))},
    },
    .{
        .key = "Index signatures, such as `{ [k: string]: number }`",
        .sources = &.{
            c(top("structural M = { [k: string]: number };")),
            c(top("structural M = { [k: string]: number };\nfunction g(m: M): number {\n  return 1;\n}")),
        },
    },
    .{
        .key = "`JSON.parse` and `JSON.stringify`",
        .sources = &.{
            c(body("  const a = JSON.parse(\"1\");")),
            c(body("  const a = JSON.stringify(1);")),
        },
    },
    .{
        .key = "`match` on a call, such as `match (g()) { ... }`",
        .sources = &.{c(top("function g(): number {\n  return 1;\n}\nfunction h(): number {\n  return match (g()) {\n    when 1: 1\n    default: 0\n  };\n}"))},
    },
    .{
        .key = "`for...of` over a fixed record",
        .sources = &.{c(body("  const o = { a: 1 };\n  for (const v of o) {\n  }"))},
    },
    .{
        .key = "`keyof`, mapped types, conditional types, and type-position `typeof`, when unused",
        .sources = &.{
            c(top("structural K = keyof { a: number };")),
            c(top("structural M = { [K in \"a\"]: number };")),
            c(top("structural C = string extends string ? number : string;")),
            c(top("const v = 1;\nstructural T = typeof v;")),
        },
    },
    .{
        .key = "`keyof`, mapped types, conditional types, and type-position `typeof`, when used in a signature",
        .sources = &.{
            c(top("function h(x: string): number {\n  return 1;\n}\nfunction g(a: keyof { a: number }): number {\n  return h(a);\n}")),
            c(top("function g(a: { [K in \"a\"]: number }): number {\n  return a.a;\n}")),
            c(top("function g(a: string extends string ? number : string): number {\n  return a;\n}")),
            c(top("const v = 1;\nfunction g(a: typeof v): string {\n  return a;\n}")),
        },
    },
    .{
        .key = "`declare`, `abstract class`, and the non-null assertion `x!`",
        .sources = &.{
            c(top("declare const a: number;")),
            c(top("abstract class A {\n}")),
            c(body("  const a: number | undefined = 1;\n  const b = a!;")),
        },
    },
    .{
        .key = "Overload declarations and comma expressions",
        .sources = &.{
            c(top("function f(a: number): number;\nfunction f(a: string): string;\nfunction f(a: unknown): unknown {\n  return a;\n}")),
            c(body("  const a = (1, 2);")),
        },
    },
    .{
        .key = "Tagged templates",
        .sources = &.{c(body("  const a = String`x`;"))},
    },
    .{
        .key = "The angle-bracket assertion `<number>x`",
        .sources = &.{c(body("  const v: unknown = 1;\n  const n = <number>v;"))},
    },
    .{
        .key = "A generic declaration with nine type parameters",
        .sources = &.{c(top("function g<A, B, C, D, E, F, G, H, I>(a: A, b: B, c: C, d: D, e: E, f: F, g2: G, h: H, i: I): A {\n  return a;\n}\nconst r1 = g(1, 2, 3, 4, 5, 6, 7, 8, 9);"))},
    },
    .{
        .key = "Array members `forEach`, `pop`, `shift`, `unshift`, `splice`",
        .sources = &.{
            c(body("  const xs: number[] = [1, 2];\n  xs.forEach((x: number): undefined => undefined);")),
            c(body("  const xs: number[] = [1, 2];\n  const a = xs.pop();")),
            c(body("  const xs: number[] = [1, 2];\n  const a = xs.shift();")),
            c(body("  const xs: number[] = [1, 2];\n  const a = xs.unshift(0);")),
            c(body("  const xs: number[] = [1, 2];\n  const a = xs.splice(0, 1);")),
        },
    },
    .{
        .key = "`import { ... } from \"zttp:types\"`",
        .sources = &.{
            c(top("import { Proof } from \"zttp:types\";")),
            c(top("import type { Proof } from \"zttp:types\";")),
        },
    },
    .{
        .key = "C-style `for (;;)`",
        .sources = &.{
            c(body("  for (;;) {\n  }")),
        },
    },
    .{
        .key = "Labeled `break` and `continue`",
        .sources = &.{
            c(body("  outer: for (const i of range(3)) {\n    break outer;\n  }")),
            c(body("  outer: for (const i of range(3)) {\n    continue outer;\n  }")),
        },
    },
    .{
        .key = "`break` or `continue` outside a loop",
        .sources = &.{
            c(body("  break;")),
            c(body("  continue;")),
            c(body("  if (true) {\n    break;\n  }")),
        },
    },
    .{
        .key = "`pipe()` and `guard()`",
        .sources = &.{
            c(body("  const a = pipe(1, String);")),
            c(body("  const a = guard(1);")),
        },
    },
    .{
        .key = "A write to a `readonly` field",
        .sources = &.{c(top("structural R = { readonly a: number };\nfunction g(r: R): number {\n  r.a = 2;\n  return r.a;\n}"))},
    },
    .{
        .key = "A `match` that does not cover every case, in a statement or a `const`",
        .sources = &.{
            c(top(command_type ++ "function g(c: Cmd): string {\n  const v = match (c) {\n    when { kind: \"a\", text }: text\n  };\n  return \"x\";\n}")),
            c(top("function g(n: number): string {\n  const v = match (n) {\n    when 1: \"a\"\n  };\n  return \"x\";\n}")),
        },
    },
    .{
        .key = "A `match` that does not cover every case, as the return value",
        .sources = &.{c(top(command_type ++ "function g(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\", text }: text\n  };\n}"))},
    },
    // ----- U1b rows, in the order of the row assignment of the plan -----
    .{
        .key = "`let` with no initializer, such as `let a: number;`",
        .sources = &.{c(top("function g(): number {\n  let a: number;\n  a = 1;\n  return a;\n}"))},
    },
    .{
        .key = "A body that is not a block, such as `if (c) g();`, `else g();`, and `for (const k of xs) g();`",
        .sources = &.{
            c(top(g_fn ++ "function h(c: boolean): number {\n  if (c) g();\n  return 2;\n}")),
            c(top(g_fn ++ "function h(c: boolean): number {\n  if (c) {\n    return 1;\n  } else g();\n  return 2;\n}")),
            c(top(g_fn ++ "function h(xs: number[]): number {\n  for (const k of xs) g();\n  return 2;\n}")),
        },
    },
    .{
        .key = "An `import` after a declaration",
        .sources = &.{c(top("const a = 1;\nimport { dictEmpty } from \"zttp:collections\";\nfunction g(): Dict<string, number> {\n  return dictEmpty();\n}"))},
    },
    .{
        .key = "An `import` or `export` inside a function body",
        .sources = &.{
            c(top("function f(): Dict<string, number> {\n  import { dictEmpty } from \"zttp:collections\";\n  return dictEmpty();\n}")),
            c(top("function f(): number {\n  export const q = 1;\n  return q;\n}")),
        },
    },
    .{
        .key = "`import type X from \"./x.ts\";`",
        .sources = &.{c(top("import type X from \"./x.ts\";"))},
    },
    .{
        .key = "One `const` that binds two names, such as `const a = 1, b = 2;`",
        .sources = &.{c(body("  const a = 1, b = 2;"))},
    },
    .{
        .key = "Destructuring in a `for...of` head",
        .sources = &.{
            c(top("function g(xs: number[][]): number {\n  for (const [a, b] of xs) {\n  }\n  return 1;\n}")),
            c(top("function g(xs: { a: number }[]): number {\n  for (const { a } of xs) {\n  }\n  return 1;\n}")),
        },
    },
    .{
        .key = "An assignment target that is not a name, a member path, or an index, such as `(n) = 2;` and `o.a?.a = 1;`",
        .sources = &.{
            c(top("function g(): number {\n  let n = 1;\n  (n) = 2;\n  return n;\n}")),
            c(top("function g(): number {\n  const o = { a: { a: 1 } };\n  o.a?.a = 1;\n  return 1;\n}")),
        },
    },
    .{
        .key = "A bigint literal, such as `10n`",
        .sources = &.{c(body("  const a = 10n;"))},
    },
    .{
        .key = "A module specifier that is not a string literal, such as `import { ok } from m;`",
        .sources = &.{c(top("import { ok } from m;"))},
    },
    .{
        .key = "A `structural` or `nominal` declaration inside a function",
        .sources = &.{
            c(top("function g(): number {\n  structural L = number;\n  return 1;\n}")),
            c(top("function g(): number {\n  nominal L = number;\n  return 1;\n}")),
        },
    },
    .{
        .key = "Type parameters on an arrow, such as `<T>(x: T) => x`",
        .sources = &.{c(top("function g(): number[] {\n  return [1].map(<T>(x: T) => x);\n}"))},
    },
    .{
        .key = "A type-parameter modifier (`in`, `const`) and an `asserts` return type",
        .sources = &.{
            c(top("function f<in T>(a: T): T {\n  return a;\n}")),
            c(top("function f<const T>(a: T): T {\n  return a;\n}")),
            c(top("function f(x: unknown): asserts x is string {\n}")),
        },
    },
    .{
        .key = "A quoted key in a record type, such as `{ \"a\": number }`, when unused",
        .sources = &.{c(top("structural R = { \"a\": number };"))},
    },
    .{
        .key = "A quoted key in a record type, such as `{ \"a\": number }`, when read",
        .sources = &.{c(top("structural R = { \"a\": number };\nfunction g(r: R): number {\n  return r.a;\n}"))},
    },
    .{
        .key = "A type name outside the admitted types, such as `Record<K, V>`, `Map`, `Set`, `bigint`, `symbol`, `Function`, `Exclude`, `NonNullable`, `Date`, `RegExp`, `Error`",
        .sources = &.{
            param("Record<string, number>"),
            param("Map<string, number>"),
            param("Set<number>"),
            param("bigint"),
            param("symbol"),
            param("Function"),
            param("{}"),
            param("Exclude<string, number>"),
            param("NonNullable<string>"),
            param("Date"),
            param("RegExp"),
            param("Error"),
        },
    },
    .{
        .key = "A type form outside the admitted grammar, such as `new () => T`, `unique symbol`, `[string?]`, `[a: string]`, `[...string[]]`, `readonly { a: number }`, a rest parameter in a function type, a method signature, a call signature, and a record type with comma separators",
        .sources = &.{
            param("new () => string"),
            param("unique symbol"),
            param("[string?]"),
            param("[a: string]"),
            param("[...string[]]"),
            param("readonly { a: number }"),
            param("(...a: string[]) => number"),
            param("{ m(): number }"),
            param("{ (): number }"),
            param("{ a: number, b: string }"),
        },
    },
    .{
        .key = "A `Dict` key type other than `string` or `number`, such as `Dict<boolean, string>`",
        .sources = &.{
            param("Dict<boolean, string>"),
            param("Dict<{ a: number }, string>"),
        },
    },
    .{
        .key = "`toReversed`, `Array.from`, `Array.of`, and a write to `xs.length`",
        .sources = &.{
            c(top("function g(xs: number[]): number[] {\n  return xs.toReversed();\n}")),
            c(top("function g(xs: number[]): number[] {\n  return Array.from(xs);\n}")),
            c(top("function g(): number[] {\n  return Array.of(1);\n}")),
            c(top("function g(xs: number[]): number {\n  xs.length = 0;\n  return 1;\n}")),
        },
    },
    .{
        .key = "An array member call with an argument list that spec 6.5 does not give, such as `xs.slice(1)`, `xs.slice()`, `xs.toSorted()`, `xs.join()`, `xs.reduce(f)`, `xs.indexOf(v, i)`, and a three-parameter `map` callback",
        .sources = &.{
            arr_call("xs.slice(1)"),
            arr_call("xs.slice()"),
            arr_call("xs.toSorted()"),
            arr_call("xs.indexOf(1, 0)"),
            arr_call("xs.includes(1, 0)"),
            arr_call("xs.reduce((a: number, b: number): number => a)"),
            arr_call("xs.map((x: number, i: number, all: number[]): number => x)"),
            c(top("function g(xs: string[]): string {\n  return xs.join();\n}")),
        },
    },
    .{
        .key = "`join` on an array of non-strings, such as `[1, 2].join(\"\")`",
        .sources = &.{c(top("function g(): string {\n  return [1, 2].join(\"\");\n}"))},
    },
    .{
        .key = "An index read or a `length` read on `Bytes`",
        .sources = &.{
            c(top("function g(b: Bytes): number {\n  return b[0];\n}")),
            c(top("function g(b: Bytes): number {\n  return b.length;\n}")),
        },
    },
    .{
        .key = "`Object` members other than `keys`, `values`, and `entries`, such as `Object.create`, `Object.defineProperty`, and `Object.fromEntries`",
        .sources = &.{
            c(top("function g(): unknown {\n  return Object.create(null);\n}")),
            c(top("function g(): unknown {\n  const o = { a: 1 };\n  Object.defineProperty(o, \"a\", 1);\n  return o;\n}")),
            c(top("function g(): unknown {\n  return Object.fromEntries([[\"a\", 1]]);\n}")),
        },
    },
    .{
        .key = "A write to a field that the record type does not declare, such as `o.z = 1`",
        .sources = &.{c(top("function g(): number {\n  const o = { a: 1 };\n  o.z = 1;\n  return o.a;\n}"))},
    },
    .{
        .key = "A second `const` of the same name in one scope",
        .sources = &.{c(top("function g(): number {\n  const a = 1;\n  const a = 2;\n  return a;\n}"))},
    },
    .{
        .key = "A duplicate parameter name, such as `function f(a: number, a: number)`",
        .sources = &.{c(top("function f(a: number, a: number): number {\n  return a;\n}"))},
    },
    .{
        .key = "A duplicate type parameter, such as `function f<T, T>(a: T): T`",
        .sources = &.{c(top("function f<T, T>(a: T): T {\n  return a;\n}\nfunction g(): string {\n  return String(f(1));\n}"))},
    },
    .{
        .key = "An assignment to a `const`, such as `const n: number = 1; n = 2;`",
        .sources = &.{c(top("function g(): number {\n  const n: number = 1;\n  n = 2;\n  return n;\n}"))},
    },
    .{
        .key = "A quoted key in a record literal, such as `{ \"a\": 1 }`",
        .sources = &.{c(top("function g(): number {\n  const o = { \"a\": 1 };\n  return o.a;\n}"))},
    },
    .{
        .key = "A spread with no explicit field after it, such as `{ ...o }`",
        .sources = &.{c(top("function g(): number {\n  const o = { a: 1 };\n  const p = { ...o };\n  return p.a;\n}"))},
    },
    .{
        .key = "A string-literal read of an identifier key, such as `r[\"a\"]`",
        .sources = &.{c(top("function g(): number {\n  const r = { a: 1 };\n  return r[\"a\"];\n}"))},
    },
    .{
        .key = "A call in an assignment target, such as `mk().n = 2`",
        .sources = &.{c(top("function mk(): { n: number } {\n  return { n: 1 };\n}\nfunction g(): number {\n  mk().n = 2;\n  return 1;\n}"))},
    },
    .{
        .key = "A higher-order callback that calls `push`, or that assigns a captured binding",
        .sources = &.{
            c(top("function g(xs: number[]): number[] {\n  const out: number[] = [];\n  const ys = xs.map((x: number): number => out.push(x));\n  return out;\n}")),
            c(top("function g(xs: number[]): number {\n  let t = 0;\n  const ys = xs.map((x: number): number => {\n    t = x;\n    return x;\n  });\n  return t;\n}")),
        },
    },
    .{
        .key = "A top-level statement other than a registration call, such as `f();` and `if (c) { }`",
        .sources = &.{
            c(top("function f(): number {\n  return 1;\n}\nf();")),
            c(top("if (true) {\n}")),
        },
    },
    .{
        .key = "An arrow outside a callback argument: a `const`-bound arrow, a returned arrow, an arrow in a record field, an immediately called arrow, and an arrow as a `?:` arm",
        .sources = &.{
            c(top("function g(): number {\n  const f = (x: number): number => x;\n  return f(1);\n}")),
            c(top("function g(): (x: number) => number {\n  return (x: number): number => x;\n}")),
            c(top("function g(): number {\n  const o = { f: (x: number): number => x };\n  return o.f(1);\n}")),
            c(top("function g(): number {\n  return ((x: number): number => x)(1);\n}")),
            c(top("function g(c: boolean): number {\n  const f = c ? (x: number): number => x : (x: number): number => x + 1;\n  return f(1);\n}")),
        },
    },
    .{
        .key = "A top-level initializer with an effect, such as `const t: number = Date.now();`",
        .sources = &.{c(top("const t: number = Date.now();"))},
    },
    .{
        .key = "`for...of` over a number, such as `for (const k of 5)`",
        .sources = &.{c(top("function g(): number {\n  for (const k of 5) {\n  }\n  return 1;\n}"))},
    },
    .{
        .key = "`stringifyJson` of a value that JSON cannot carry, such as a function or a `Dict<number, string>`",
        .sources = &.{
            c(top("import { stringifyJson } from \"zttp:json\";\nimport { dictEmpty } from \"zttp:collections\";\nfunction g(): boolean {\n  const d: Dict<number, string> = dictEmpty();\n  const s = stringifyJson(d);\n  return s.ok;\n}")),
            c(top("import { stringifyJson } from \"zttp:json\";\nfunction f(x: number): number {\n  return x;\n}\nfunction g(): boolean {\n  const s = stringifyJson(f);\n  return s.ok;\n}")),
        },
    },
    .{
        .key = "A `default` arm on a closed union that is already covered, or a duplicate `when` arm",
        .sources = &.{
            c(top(command_type ++ "function g(c: Cmd): string {\n  return match (c) {\n    when { kind: \"a\", text }: text\n    when { kind: \"b\", text }: text\n    default: \"\"\n  };\n}")),
            c(top("function g(n: number): number {\n  return match (n) {\n    when 1: 1\n    when 1: 2\n    default: 0\n  };\n}")),
        },
    },
};
