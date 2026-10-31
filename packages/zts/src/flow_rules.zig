//! The rule tables of the flow evaluator: result types, the node tag census,
//! builtin operation rows, defense sources, and sink requirements.
//! `flow_interp.zig` holds the evaluator that reads these tables.

const std = @import("std");
const engine = @import("zts-engine");
const ir = engine.parser.ir;
const report_types = @import("flow_report.zig");
const flow_value = @import("flow_value.zig");

const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const null_node = ir.null_node;

const ModuleId = flow_value.ModuleId;
const ModuleExport = flow_value.ModuleExport;
const Defense = flow_value.Defense;
const Defenses = flow_value.Defenses;
const Flow = flow_value.Flow;
const DefenseEdge = flow_value.DefenseEdge;
const Value = flow_value.Value;
const State = flow_value.State;
const PathEvidence = flow_value.PathEvidence;

// ---------------------------------------------------------------------------
// Results and the tag census
// ---------------------------------------------------------------------------

/// How the evaluators treat one `NodeTag`.
pub const TagPlan = union(enum) {
    /// A rule exists and resolves the tag in every context the census uses.
    handled,
    /// The parser accepts the construct and the strict checker refuses it, so
    /// no checked module holds it. The runtime does not evaluate it as the
    /// source reads, so the evaluator does not follow it either.
    refused_by_strict,
    /// The parser produces no such node, or produces it only where a parent
    /// rule reads it through an accessor, so it is never an evaluation target.
    not_produced,
};

/// Why a construct is unresolved: the mechanism the evaluator does not model.
///
/// - `prototype_method_unmodeled`: a method of a request, headers, or response
///   site that the runtime prototype table has no row for.
/// - `module_graph_gap`: the module graph is absent, incomplete, or inconsistent,
///   or an import or re-export has no resolvable source.
/// - `module_state_unmodeled`: module-level state the evaluator does not place:
///   a global read or write with no persistent cell, an upvalue store, or a
///   write into a runtime object that every request shares.
/// - `fixpoint_limit`: a loop reached `max_loop_passes`, or a recursive
///   function reached `max_recursion_passes`, before its summary stopped
///   changing.
/// - `read_before_declaration`: a local read ran before its declaration, so
///   the slot holds something this evaluator never saw.
/// - `unknown_callee`: a call whose callee may be a function this analysis
///   cannot name (a value read from a property, or a join with `top`).
/// - `capture_unplaced`: a closure read a captured binding and no capture
///   table was given, so the binding's cell is unknown.
/// - `capture_unseeded`: the analyzed function itself captures bindings that
///   no activation in this analysis created.
/// - `budget_limit`: the root analysis reached `max_steps`, the activation
///   depth limit, or the native depth limit.
/// - `refused_by_strict`: the strict checker refuses the construct (call-site
///   spread, ZTS616, or a global the strict checker does not know).
/// - `no_operation_rule`: an operation that has no transfer rule: a method of
///   a native Result, a callback argument that holds no function, a call that
///   the runtime fails with `NotCallable`, or a native method of an object the
///   analysis does not model (R3).
pub const Owner = enum {
    prototype_method_unmodeled,
    module_graph_gap,
    module_state_unmodeled,
    fixpoint_limit,
    read_before_declaration,
    unknown_callee,
    capture_unplaced,
    capture_unseeded,
    budget_limit,
    refused_by_strict,
    no_operation_rule,
    refused_by_parser,
    not_produced,
};

pub const Unresolved = struct {
    node: NodeIndex,
    tag: NodeTag,
    owner: Owner,
    module: ModuleId = 0,
};

pub const CompletionKind = enum {
    returned,
    /// A failed `assert cond, message;`: the message becomes the response.
    assert_message,
    /// A failed `assert cond;`: the runtime halts and answers with `undefined`
    /// (the prerequisite code generation fix).
    halt,
};

pub const Completion = struct {
    kind: CompletionKind,
    node: NodeIndex = null_node,
    value: ?Value,
    state: State,
};

pub const FunctionResult = struct {
    /// Join of every returned value, every assert message, every halt value,
    /// and `clean` when the end of the body is reachable (an implicit
    /// `return undefined`).
    returned: ?Value,
    /// Join of the states of every completion and of the fallthrough.
    exit: State,
    completions: []const Completion,
    /// True when any construct was unresolved: every flow property is then
    /// cleared, and `returned` and `exit` carry no guarantee.
    cleared: bool,
    unresolved: []const Unresolved,
};

pub const SinkEvent = struct {
    node: NodeIndex,
    source_node: NodeIndex = null_node,
    module: ModuleId = 0,
    callsite: ?NodeIndex = null,
    sink: InputSink,
    reached: Flow,
    path: PathEvidence = .{},
};

/// Unsupported constructs clear every property. Sink
/// diagnostics have no witness until an executable path can be established.
pub const HandlerReport = struct {
    evaluation: FunctionResult,
    properties: report_types.FlowProperties,
    diagnostics: []const report_types.Diagnostic,
    events: []const SinkEvent,
    defended_paths: []const report_types.DefendedPath = &.{},
};

/// A handled tag that reaches an evaluator in a position its parent rule does
/// not read (an `object_property` evaluated as an expression) is the parser
/// putting a tag where it never does, so it reports `not_produced`.
pub fn ownerOf(tag: NodeTag) Owner {
    return switch (tagPlan(tag)) {
        .refused_by_strict => .refused_by_strict,
        .handled, .not_produced => .not_produced,
    };
}

/// The disposition of every node tag. The switch has no `else` arm, so a new
/// tag fails to compile until it has a row here and in `eval` and `exec`.
pub fn tagPlan(tag: NodeTag) TagPlan {
    return switch (tag) {
        .lit_int,
        .lit_float,
        .lit_string,
        .lit_bool,
        .lit_null,
        .lit_undefined,
        .identifier,
        .binary_op,
        .unary_op,
        .ternary,
        .member_access,
        .computed_access,
        .optional_chain,
        .assignment,
        .array_literal,
        .object_literal,
        .object_property,
        .object_spread,
        .function_expr,
        .arrow_function,
        .match_expr,
        .match_arm,
        .match_pattern,
        .array_pattern,
        .match_type_test,
        .expr_stmt,
        .var_decl,
        .if_stmt,
        .return_stmt,
        .assert_stmt,
        .block,
        .function_decl,
        .pattern_element,
        .for_of_stmt,
        .break_stmt,
        .continue_stmt,
        .call,
        => .handled,

        // A spread inside an array or object literal is read by the literal's
        // rule. A call-site spread is the case this plan names.
        .spread => .refused_by_strict,

        .import_decl,
        .import_specifier,
        .export_decl,
        .program,
        => .not_produced,
    };
}

// ---------------------------------------------------------------------------
// Builtin operations (P5a)
// ---------------------------------------------------------------------------

/// How the evaluator transfers labels, origins, and writes through one builtin
/// operation. The names state what the operation does to the heap and to its
/// result; `applyRule` holds the transfer for each.
const Rule = enum {
    /// A string method that returns a primitive.
    string_scalar,
    /// `split`: a fresh array of pieces.
    string_split,
    /// `push` and `unshift`: write each argument into the receiver.
    array_push,
    /// `pop` and `shift`: an element of the receiver.
    array_pop,
    array_splice,
    /// `indexOf`, `includes`, and `join`: a primitive that reads the elements.
    array_scalar,
    /// `slice` and `toReversed`: a fresh array of the elements.
    array_copy,
    /// `toSorted`: a copy, and a comparator is a callback.
    array_to_sorted,
    /// `map`: a fresh array of the callback results.
    array_map,
    /// `filter`: a fresh array of the elements, labelled by the predicate.
    array_filter,
    /// `find`: an element, labelled by the predicate.
    array_find,
    /// `forEach`: the callback runs for its writes.
    array_for_each,
    /// `every`, `some`, and `findIndex`: a primitive that the predicate decides.
    array_test,
    /// `reduce`: the accumulator.
    array_reduce,
    /// `Array.from`: a fresh array of the elements, or of the mapped elements.
    array_from,
    /// `h`: a vnode that holds what it was given, components included.
    vnode,
    /// `renderToString`: runs no component, so it has a rule only for a vnode
    /// that holds none.
    render,
    array_concat,
    /// A primitive computed from the arguments alone.
    deep_scalar,
    /// A primitive that differs between runs (a clock or random read).
    nondeterministic,
    /// `JSON.parse` and the request readers: a container built from the
    /// arguments.
    parsed,
    object_keys,
    object_values,
    object_entries,
    array_of,
    /// A `Response` static: a container that holds native methods.
    response_static,
    fetch_sync,
    log,
    range,
    /// `hole()`: the call never returns.
    hole,
    /// Runtime-installed request and headers prototype methods (P7b).
    request_text,
    request_json,
    header_get,
    header_has,
    header_write,
    header_delete,
    /// The operation has no rule, and the row says why.
    no_rule,
};

/// One builtin operation. `scope` is `global` for a global function, the
/// namespace name for a namespace member, and `String.prototype`,
/// `Array.prototype`, or `Result.prototype` for a method of a prototype.
pub const OperationRow = struct {
    scope: []const u8,
    name: []const u8,
    rule: Rule,
    /// What the operation does to the defenses of the flow that its rule
    /// builds the result from. There is no default: every row states it.
    defense: DefenseEdge,
    /// Why the operation has no rule. Set for `no_rule` rows only.
    reason: []const u8 = "",
};

pub const callback_reason = "takes a callback, and a Result method is not modeled";
const result_reason = "a Result method is not modeled";

fn rowsOf(
    comptime scope: []const u8,
    comptime rule: Rule,
    comptime defense: DefenseEdge,
    comptime reason: []const u8,
    comptime names: []const []const u8,
) [names.len]OperationRow {
    var rows: [names.len]OperationRow = undefined;
    for (names, 0..) |name, i| {
        rows[i] = .{ .scope = scope, .name = name, .rule = rule, .defense = defense, .reason = reason };
    }
    return rows;
}

/// The operation table. The census (C1) checks it against the registered
/// builtins in both directions, and checks that exactly twelve rows have an
/// edge other than `keep`. The edges that remove a defense, and why:
///
/// - `replace` and `replaceAll` can bring back markup or decode escaped text,
///   so they remove both defenses.
/// - `String.fromCharCode` makes a character from a number, so it removes
///   both.
/// - `JSON.stringify` adds a `"` next to the text, so it removes
///   `html_escaped`.
/// - `JSON.parse` and `JSON.tryParse` turn the text `\u003c` into `<` and
///   build a structure that no schema checked, so they remove both.
/// - `Object.keys` and `Object.entries` return property names, and no export
///   escapes one, so they remove `html_escaped`.
/// - `renderToString` writes tag names, attribute names, and the children of
///   `script` unescaped, so it removes `html_escaped`.
/// - The request readers return fresh request data, so they remove both.
pub const operation_rows =
    rowsOf("String.prototype", .string_scalar, .keep, "", &.{
        "charAt",      "charCodeAt", "indexOf",   "lastIndexOf", "startsWith",
        "endsWith",    "includes",   "slice",     "substring",   "toLowerCase",
        "toUpperCase", "trim",       "trimStart", "trimEnd",     "repeat",
        "padStart",    "padEnd",     "concat",
    }) ++
    rowsOf("String.prototype", .string_scalar, .drop_all, "", &.{ "replace", "replaceAll" }) ++
    rowsOf("String.prototype", .string_split, .keep, "", &.{"split"}) ++
    rowsOf("Array.prototype", .array_push, .keep, "", &.{ "push", "unshift" }) ++
    rowsOf("Array.prototype", .array_pop, .keep, "", &.{ "pop", "shift" }) ++
    rowsOf("Array.prototype", .array_splice, .keep, "", &.{"splice"}) ++
    rowsOf("Array.prototype", .array_scalar, .keep, "", &.{ "indexOf", "includes", "join" }) ++
    rowsOf("Array.prototype", .array_copy, .keep, "", &.{ "slice", "toReversed" }) ++
    rowsOf("Array.prototype", .array_to_sorted, .keep, "", &.{"toSorted"}) ++
    rowsOf("Array.prototype", .array_concat, .keep, "", &.{"concat"}) ++
    rowsOf("Array.prototype", .array_map, .keep, "", &.{"map"}) ++
    rowsOf("Array.prototype", .array_filter, .keep, "", &.{"filter"}) ++
    rowsOf("Array.prototype", .array_find, .keep, "", &.{"find"}) ++
    rowsOf("Array.prototype", .array_for_each, .keep, "", &.{"forEach"}) ++
    rowsOf("Array.prototype", .array_test, .keep, "", &.{ "every", "some", "findIndex" }) ++
    rowsOf("Array.prototype", .array_reduce, .keep, "", &.{"reduce"}) ++
    rowsOf("Result.prototype", .no_rule, .keep, result_reason, &.{
        "isOk", "isErr", "unwrap", "unwrapOr", "unwrapErr",
    }) ++
    rowsOf("Result.prototype", .no_rule, .keep, callback_reason, &.{ "map", "mapErr", "andThen", "match" }) ++
    rowsOf("Math", .deep_scalar, .keep, "", &.{
        "abs", "floor", "ceil", "round", "min", "max", "pow", "trunc", "sqrt", "sin", "cos", "tan", "log", "exp",
    }) ++
    rowsOf("Math", .nondeterministic, .keep, "", &.{"random"}) ++
    rowsOf("JSON", .parsed, .drop_all, "", &.{ "parse", "tryParse" }) ++
    rowsOf("JSON", .deep_scalar, .drop_html, "", &.{"stringify"}) ++
    rowsOf("Object", .object_keys, .drop_html, "", &.{"keys"}) ++
    rowsOf("Object", .object_values, .keep, "", &.{"values"}) ++
    rowsOf("Object", .object_entries, .drop_html, "", &.{"entries"}) ++
    rowsOf("Object", .deep_scalar, .keep, "", &.{"hasOwn"}) ++
    rowsOf("Number", .deep_scalar, .keep, "", &.{ "isInteger", "isNaN", "isFinite", "parseFloat", "parseInt" }) ++
    rowsOf("Response", .response_static, .keep, "", &.{ "json", "text", "html", "redirect", "rawJson" }) ++
    rowsOf("console", .log, .keep, "", &.{"log"}) ++
    rowsOf("Date", .nondeterministic, .keep, "", &.{"now"}) ++
    rowsOf("Array", .deep_scalar, .keep, "", &.{"isArray"}) ++
    rowsOf("Array", .array_of, .keep, "", &.{"of"}) ++
    rowsOf("Array", .array_from, .keep, "", &.{"from"}) ++
    rowsOf("String", .deep_scalar, .drop_all, "", &.{"fromCharCode"}) ++
    rowsOf("global", .deep_scalar, .keep, "", &.{ "String", "Number", "parseFloat", "parseInt", "isDict", "isBytes" }) ++
    rowsOf("global", .range, .keep, "", &.{"range"}) ++
    rowsOf("global", .request_json, .drop_all, "", &.{ "requestBody", "requestText", "requestJson" }) ++
    rowsOf("global", .hole, .keep, "", &.{"hole"}) ++
    rowsOf("global", .vnode, .keep, "", &.{"h"}) ++
    rowsOf("global", .render, .drop_html, "", &.{"renderToString"});

/// These methods are installed by HandlerInstance, outside the engine builtin
/// registry. Keep their read/write edges explicit and census their registration
/// roster separately from the engine operations.
pub const runtime_prototype_rows =
    rowsOf("Request.prototype", .request_text, .drop_all, "", &.{"text"}) ++
    rowsOf("Request.prototype", .request_json, .drop_all, "", &.{"json"}) ++
    rowsOf("Headers.prototype", .header_get, .keep, "", &.{"get"}) ++
    rowsOf("Headers.prototype", .header_has, .keep, "", &.{"has"}) ++
    rowsOf("Headers.prototype", .header_write, .keep, "", &.{ "set", "append" }) ++
    rowsOf("Headers.prototype", .header_delete, .keep, "", &.{"delete"});

// HandlerInstance installs this global separately from engine builtins.
pub const runtime_global_rows = rowsOf("global", .fetch_sync, .keep, "", &.{"fetchSync"});

/// The builtin objects whose members are the `Math`-style namespace rows.
pub const namespace_names = [_][]const u8{ "Array", "Date", "JSON", "Math", "Number", "Object", "Response", "String", "console" };

/// The namespaces that are also functions, so a read of the name may be called.
pub const callable_namespaces = [_][]const u8{ "Number", "Response", "String" };

pub fn nameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub fn findRow(rows: []const OperationRow, scope: []const u8, name: []const u8) ?OperationRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.scope, scope) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// What a virtual-module export that calls a function passes to it. The
/// callback is argument 1 of every one of them.
pub const CallbackShape = enum {
    /// `(value, key)` for each entry of the dictionary in argument 0.
    dict_entries,
    /// `(acc, value, key)`, with the initial value in argument 2.
    dict_fold,
    /// The payload of the Result in argument 0.
    payload,
};

pub const CallbackExport = struct {
    specifier: []const u8,
    name: []const u8,
    shape: CallbackShape,
};

/// The exports with a precise callback rule. The binding cannot say that a
/// parameter is a callback, so any other export keeps the presumed call.
/// Census C2 checks each row against `findExport` and against a test.
pub const callback_exports = [_]CallbackExport{
    .{ .specifier = "zttp:collections", .name = "dictMapValues", .shape = .dict_entries },
    .{ .specifier = "zttp:collections", .name = "dictFilter", .shape = .dict_entries },
    .{ .specifier = "zttp:collections", .name = "dictFold", .shape = .dict_fold },
    .{ .specifier = "zttp:result", .name = "mapResult", .shape = .payload },
    .{ .specifier = "zttp:result", .name = "mapError", .shape = .payload },
    .{ .specifier = "zttp:result", .name = "andThen", .shape = .payload },
    .{ .specifier = "zttp:result", .name = "orElse", .shape = .payload },
};

pub fn findCallbackExport(rows: []const CallbackExport, specifier: []const u8, name: []const u8) ?CallbackExport {
    for (rows) |row| {
        if (std.mem.eql(u8, row.specifier, specifier) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Defense sources and sink requirements (P6b)
// ---------------------------------------------------------------------------

/// What an export that declares `validated` does to the defenses of its
/// result. The result of every other export has none, because the binding
/// cannot say that an export leaves the characters of its input alone.
///
/// The result has the defenses of everything the call reads, minus `removes`,
/// plus `establishes`. `keeps` states what the row passes through from its
/// input, and the census checks that it never overlaps `removes`. No source
/// removes a label: a validated request value keeps `user_input` (D23).
pub const DefenseSource = struct {
    specifier: []const u8,
    name: []const u8,
    establishes: Defenses = .{},
    keeps: Defenses = .{},
    removes: Defenses = .{},
    /// Why the row establishes nothing. Set for such rows only.
    reason: []const u8 = "",

    pub fn outcome(self: DefenseSource, input: Defenses) Defenses {
        return input.without(self.removes).unite(self.establishes);
    }
};

pub const html_only: Defenses = .{ .html_escaped = true };
pub const schema_only: Defenses = .{ .schema_checked = true };

/// One row for each export whose binding declares `validated`. A row that
/// establishes a defense needs a binding that declares only string
/// parameters: each of these exports answers an `err` Result or `undefined`
/// when an argument is not a string, so the origins of what the call reads
/// need no check. Census C3 checks the table against the bindings and against
/// an expected mapping.
pub const defense_sources = [_]DefenseSource{
    .{ .specifier = "zttp:text", .name = "escapeHtml", .establishes = html_only, .keeps = schema_only },
    .{ .specifier = "zttp:validate", .name = "validateJson", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:validate", .name = "coerceJson", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeJson", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeForm", .establishes = schema_only, .removes = html_only },
    .{ .specifier = "zttp:decode", .name = "decodeFormMultipart", .establishes = schema_only, .removes = html_only },
    .{
        .specifier = "zttp:validate",
        .name = "validateObject",
        .reason = "returns an alias; schema evidence is attached by the generation-bound checked-view transfer, not this unconditional table",
    },
    .{
        .specifier = "zttp:decode",
        .name = "decodeQuery",
        .reason = "takes an object, and defense evidence for an object is deferred (R13)",
    },
    .{
        .specifier = "zttp:auth",
        .name = "jwtVerify",
        .reason = "authenticates the token and validates no claim",
    },
};

comptime {
    for (defense_sources) |row| {
        if (!row.keeps.intersect(row.removes).isEmpty()) {
            @compileError(row.name ++ " keeps and removes the same defense");
        }
    }
}

pub fn findDefenseSource(rows: []const DefenseSource, specifier: []const u8, name: []const u8) ?DefenseSource {
    for (rows) |row| {
        if (std.mem.eql(u8, row.specifier, specifier) and std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// A place where request data can arrive in a response, a log, or a call to
/// the network. P7 maps each call it finds to one of these.
pub const InputSink = enum {
    /// The body of `Response.html`.
    response_html,
    /// The body of another `Response` helper.
    response_other,
    /// The second argument of a helper (the status and headers).
    response_init,
    log,
    egress_url,
    egress_body,
    egress_headers,
    /// The options object that a call passes by name. It takes the strictest
    /// row of the three egress fields.
    egress_opaque,
};

/// A property that request data decides.
pub const InputProperty = enum { input_validated, injection_safe, pii_contained };

/// What a sink accepts for a property of request data (R12, D24).
pub const Requirement = union(enum) {
    /// The sink does not govern the property, so request data may arrive.
    not_governed,
    /// The sink accepts request data that holds this defense.
    defense: Defense,
    /// No defense is enough, so request data may not arrive.
    no_defense,
};

/// The requirement of each sink and property. The switch has no `else` arm, so
/// a new sink or property fails to compile until it has a row.
///
/// Two limits hold for every row. `html_escaped` covers HTML text and quoted
/// attribute values: a URL attribute such as `href="javascript:..."` and a
/// script context are outside it (D24). And it covers request characters, not
/// the author characters that request data selects through a slice bound, an
/// order, or a count (D25).
pub fn requirement(sink: InputSink, property: InputProperty) Requirement {
    return switch (sink) {
        .response_html => switch (property) {
            .input_validated => .not_governed,
            .injection_safe => .{ .defense = .html_escaped },
            .pii_contained => .not_governed,
        },
        .response_other, .response_init, .log => switch (property) {
            .input_validated => .not_governed,
            .injection_safe => .not_governed,
            .pii_contained => .not_governed,
        },
        .egress_url, .egress_headers, .egress_opaque => switch (property) {
            .input_validated => .{ .defense = .schema_checked },
            .injection_safe => .no_defense,
            .pii_contained => .no_defense,
        },
        .egress_body => switch (property) {
            .input_validated => .{ .defense = .schema_checked },
            .injection_safe => .{ .defense = .schema_checked },
            .pii_contained => .no_defense,
        },
    };
}

/// Whether request data that reaches `sink` is acceptable for `property`.
///
/// `reached` must be the `deepFlow` of the value that reaches the sink, in
/// the state at the sink. The value alone is not enough: a container with
/// clean surface labels can hold request data in its cells, and a validated
/// value keeps its own defense after an alias writes raw data into a cell.
///
/// A flow that is not exposed is always accepted. Request data is accepted
/// where the sink does not govern the property, or where the flow holds the
/// defense that the sink requires. It is never accepted where no defense is
/// enough.
///
/// The limits of `requirement` apply: HTML context (D24) and request
/// characters only (D25).
pub fn inputAccepted(reached: Flow, sink: InputSink, property: InputProperty) bool {
    if (!reached.exposed()) return true;
    return switch (requirement(sink, property)) {
        .not_governed => true,
        .defense => |defense| reached.defenses.has(defense),
        .no_defense => false,
    };
}

/// The part of `yieldsSource` that depends on the export alone. Public for the
/// census over the builtin registry.
pub fn exportYieldsSource(resolved: ModuleExport) bool {
    const func = resolved.func;
    if (func.derives_from_args or func.declassify_bound_arg != null) return false;
    if (findCallbackExport(&callback_exports, resolved.binding.specifier, func.name) != null) return false;
    return switch (func.returns) {
        .boolean, .number, .string, .optional_string, .optional_number => true,
        .undefined, .object, .unknown, .optional_object, .result, .result_list, .result_fn, .dict, .bytes => false,
    };
}
