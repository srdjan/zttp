//! Type Checker: validates types across the IR tree.
//!
//! Walks the IR tree produced by the parser, consulting the TypeEnv populated
//! from parser-owned type syntax to check:
//! - Variable declarations match their type annotations
//! - Function call arguments match parameter types
//! - Property access on known record types
//! - Return values match declared return types
//! - Union types require narrowing before type-specific operations
//!
//! Architecture follows bool_checker.zig: a struct with walkStmt/walkExpr/inferType
//! methods that produces diagnostics.
//!
//! When a type cannot be determined statically, null_type_idx is returned (escape hatch).
//! Only annotated values are checked - unannotated code passes through unchecked.

const std = @import("std");
const SourceView = @import("zts-base").source_diagnostics.SourceView;
const handler_verifier = @import("handler_verifier.zig");
const diagnostic_catalog = @import("diagnostic_catalog.zig");
const diagnostic_projection = @import("diagnostic_projection.zig");
const ir = @import("zts-engine").parser.ir;
const ScopeAnalyzer = @import("zts-engine").parser.ScopeAnalyzer;
const json_utils = @import("zts-base").json_utils;
const isMutatingArrayMethod = @import("mutating_methods.zig").isMutatingArrayMethod;

/// Help for a ZTS200 or ZTS203 whose source type has an absent case (A3, Decision 40).
const undefined_source_help_text = "the value may be undefined: check it first, or use `?? fallback`";
const mismatch_help_text = "Change the value or the declared type so that the two types match.";
const arg_type_help_text = "Pass a value of the parameter type, or change the parameter type.";
/// Help for a ZTS203 on a member of a `Response` helper init.
const response_init_help_text = "A Response init supports only `status`. Response headers are not supported. Remove this member.";
/// The one member that a `Response` helper reads from its init.
const response_init_status = "status";
const result_shape_fallback = "a Result argument has the wrong type";
const object = @import("zts-engine").object;
const context = @import("zts-engine").context;
const type_pool_mod = @import("type_pool.zig");
const strict_checker_mod = @import("strict_checker.zig");
const type_key = @import("type_key.zig");
const type_env_mod = @import("type_env.zig");
const abi_types = @import("abi_types.zig");
const builtin_results = @import("builtin_results.zig");
const module_result_errors = @import("module_result_errors.zig");
const match_analysis_mod = @import("match_analysis.zig");
const ir_json_literal = @import("ir_json_literal.zig");
const module_facts_mod = @import("module_facts.zig");
const import_signatures_mod = @import("import_signatures.zig");

const Node = ir.Node;
const NodeIndex = ir.NodeIndex;
const NodeTag = ir.NodeTag;
const IrView = ir.IrView;
const null_node = ir.null_node;
const TypePool = type_pool_mod.TypePool;
const TypeIndex = type_pool_mod.TypeIndex;
const null_type_idx = type_pool_mod.null_type_idx;
const TypeEnv = type_env_mod.TypeEnv;

/// Max union members tracked during type inference (member access, return types, etc.).
/// The width of this file's stack scratch buffers when collecting branch types
/// before a join. It is not a limit on how wide a union may be: `addUnion`
/// normalizes on the heap and a schema enum is routinely wider than this.
const MAX_UNION_MEMBERS = 16;
const max_function_stack = 64;

pub const TypeCheckerError = type_pool_mod.TypePoolError || error{UnresolvedTypeBinding};

// ---------------------------------------------------------------------------
// Diagnostic types
// ---------------------------------------------------------------------------

pub const Severity = enum {
    err,
    warning,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

pub const DiagnosticKind = enum {
    type_mismatch, // declared type != inferred type
    missing_field, // property access on record missing field
    arg_count_mismatch, // wrong number of arguments
    arg_type_mismatch, // argument type doesn't match parameter
    return_type_mismatch, // return value doesn't match declared return type
    non_exhaustive_match, // match is not provably exhaustive
    redundant_match_arm, // a match arm that no value can reach
    invalid_type_predicate, // `v is T` whose body does not verify the claim
    ambiguous_type_argument, // a type parameter no argument position determines
    type_constraint_violation, // a type argument outside its `extends` bound
    type_argument_count_mismatch, // explicit type arguments, wrong count
    non_contractive_alias, // a recursive alias whose cycle no data constructor guards
    unencodable_json_payload, // a `Response.json` payload whose type cannot be JSON
    string_add, // string-valued use of + instead of explicit join
    nominal_constructor_call, // a nominal type name used in call position
    readonly_mutation, // a mutating array method called on a readonly receiver
};

pub const Diagnostic = struct {
    severity: Severity,
    kind: DiagnosticKind,
    node: NodeIndex,
    message: []const u8,
    help: ?[]const u8,
    /// Whether the message was dynamically allocated.
    allocated: bool = false,
    /// Whether `help` was dynamically allocated. Only a witness-bearing help
    /// (the first missing `match` case) is built at diagnosis time.
    help_owned: bool = false,
    /// Result shape and borrowed subject name, set when the subject is a Result.
    result_shape: ?handler_verifier.ResultShape = null,
    result_subject: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Type Checker
// ---------------------------------------------------------------------------

pub const TypeChecker = struct {
    const CallableMetadata = union(enum) {
        unavailable,
        signature: type_env_mod.FunctionSig,
        /// A source function with no annotation at all: nothing is known of its
        /// types, but its parameter list says how many arguments a call may supply.
        arity: u8,
    };

    const CompiledSchemaType = struct {
        name: []const u8,
        type_idx: TypeIndex,
    };

    const NarrowJournalEntry = struct {
        key: u64,
        /// What the key held before the change, or null when it held nothing.
        prev: ?TypeIndex,
        /// True when the change dropped the narrowing, false when it installed
        /// one. A scope's kills are applied again where its branch joins.
        killed: bool,
    };

    /// The keys a scope killed, collected without an allocation. More keys than
    /// the buffer holds set `overflow`, which stands for every key: the join
    /// then drops every narrowing, and a kill is never lost.
    const KillSet = struct {
        const capacity = 32;
        keys: [capacity]u64 = undefined,
        len: usize = 0,
        overflow: bool = false,

        fn add(self: *KillSet, key: u64) void {
            if (self.overflow or self.contains(key)) return;
            if (self.len == capacity) {
                self.overflow = true;
                return;
            }
            self.keys[self.len] = key;
            self.len += 1;
        }

        fn contains(self: *const KillSet, key: u64) bool {
            if (self.overflow) return true;
            for (self.keys[0..self.len]) |k| {
                if (k == key) return true;
            }
            return false;
        }

        fn merge(self: *KillSet, other: KillSet) void {
            if (other.overflow) {
                self.overflow = true;
                return;
            }
            for (other.keys[0..other.len]) |k| self.add(k);
        }
    };

    allocator: std.mem.Allocator,
    ir_view: IrView,
    atoms: ?*context.AtomTable,
    env: *TypeEnv,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    compiled_schemas: std.ArrayListUnmanaged(CompiledSchemaType),
    /// Canonical import facts borrowed from a stable analysis owner. Contract
    /// extraction's optional partial facts are a different authority.
    import_facts: ?*const module_facts_mod.ModuleFacts = null,
    /// Direct checker users own one fallback index. Never retain a pointer
    /// into this field: the checker can move by value after checking.
    owned_import_facts: ?module_facts_mod.ModuleFacts = null,
    /// Signatures of the file imports of this module. Null on every path but
    /// the compile path of a multi-module build, where it is off by default.
    /// With it set, a file import is typed from the signature of its export.
    file_imports: ?*const import_signatures_mod.FileImportSignatures = null,
    /// The callable behind each file import, keyed by slot and binding kind.
    /// Filled once at the start of `check`.
    file_import_callables: std.AutoHashMapUnmanaged(u32, CallableMetadata) = .empty,
    /// The local name atom of each file import that has no type, in import order.
    file_import_untyped: std.ArrayListUnmanaged(u16) = .empty,

    /// Inferred types for const/let bindings: packed(scope_id, slot) -> TypeIndex
    binding_types: std.AutoHashMapUnmanaged(u64, TypeIndex),
    /// The `const` and `let` declarations with no type annotation whose
    /// initializer holds literal types (`initializerHoldsLiteralTypes`), keyed
    /// like `binding_types`.
    /// A write into such a binding widens the literal types of the slot.
    unannotated_decls: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Callable metadata for declarations keyed by packed(scope_id, slot).
    /// An explicit `unavailable` entry is significant: it prevents a local
    /// binding from inheriting an unrelated module signature by bare name.
    binding_callables: std.AutoHashMapUnmanaged(u64, CallableMetadata),
    /// Declared parameter types keyed by (scope_id, slot). Kept SEPARATE from
    /// `binding_types` deliberately: feeding parameter types into general
    /// identifier inference would subject every `req: Request` argument to
    /// module-signature assignability checks the pool cannot discharge yet.
    /// Consulted only where a declared parameter type is load-bearing:
    /// match-discriminant exhaustiveness.
    param_types: std.AutoHashMapUnmanaged(u64, TypeIndex),
    /// The parser's scope analysis, which records for each closure the exact
    /// binding that each of its upvalues names. Set by the caller that owns the
    /// parser, as the flow checker's `scopes` is. A reference of kind `upvalue`
    /// resolves to its declaring binding through this record and never by
    /// name, because a name finds an unrelated outer binding when the
    /// captured one is a `for...of` or `match` binding. Without the record an
    /// upvalue has no type and no callable signature: unknown, which skips a
    /// check and grants nothing.
    scopes: ?*const ScopeAnalyzer = null,
    bound_var_annotations: usize = 0,
    binding_resolution_failed: bool = false,
    /// Flow-sensitive narrowing: binding key -> narrowed TypeIndex
    narrowed: std.AutoHashMapUnmanaged(u64, TypeIndex),
    /// Type predicates whose bodies were read and found to prove what they
    /// claim, by function name. A declared predicate that is not in here
    /// installs no narrowing anywhere.
    admitted_predicates: std.StringHashMapUnmanaged(void),
    /// Undo log for `narrowed`, so a branch can restore every key it touched
    /// and not only the one its own guard installed.
    narrow_journal: std.ArrayListUnmanaged(NarrowJournalEntry),
    /// How many branch scopes are open. Nothing is journalled at zero.
    narrow_scopes: u32 = 0,
    /// The type of each boolean-context operand (an `if`, `assert` or ternary
    /// condition, an operand of `!`, `&&` or `||`), read while the walk's
    /// narrowing overlay was live. The overlay is closed by the time another
    /// checker asks, so a later `inferType` of the same node would forget the
    /// guards that held where the operand was written. Keyed by node: each
    /// node is walked once.
    context_types: std.AutoHashMapUnmanaged(NodeIndex, TypeIndex) = .empty,
    /// Member, computed, for-of, or spread operand nodes whose receiver type
    /// admits undefined at the walk point. Keyed by the read node. The
    /// verifier turns each entry into one ZTS309.
    absent_receivers: std.AutoHashMapUnmanaged(NodeIndex, TypeIndex) = .empty,
    /// Pattern bindings typed `unknown` because their arm has no record type.
    /// A read of one is still recorded: the fallback stays fail-closed.
    opaque_pattern_bindings: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Track current function's declared return type for return statement checking
    current_return_type: TypeIndex = null_type_idx,
    /// Sticky failure for proof-relevant type, narrowing, schema, parameter,
    /// and diagnostic state. Message-only formatting may retain a static
    /// fallback because the core diagnostic is still stored.
    allocation_failed: bool = false,
    /// One canonical `unknown[]` for unresolved array elements. Deep repeated
    /// inference must not consume one pool node for the same type each time.
    unknown_array_type: TypeIndex = null_type_idx,
    /// Cached types retain absence diagnostics for unknown values and bound
    /// repeated inference for arrays and index reads.
    nullable_unknown_type: TypeIndex = null_type_idx,
    nullable_unknown_array_type: TypeIndex = null_type_idx,
    /// Secondary analyzers may ask for a type outside the statement walk's
    /// live narrowing context. Those queries must not create compiler
    /// diagnostics, although allocation failures remain sticky.
    report_inference_diagnostics: bool = true,
    /// Set by the pipeline before `check` when the strict checker runs after
    /// this one. The strict checker reports a match that is not exhaustive as
    /// ZTS603, so `check` removes ZTS205 when it found no type error: one
    /// mistake, one diagnostic.
    strict_checker_follows: bool = false,
    /// Set by `scanClosureWrites` before the walk when a function body at any
    /// depth assigns a captured or module-level binding. A call may then run
    /// that closure, so each call kills every narrowing.
    closure_writes_outer: bool = false,
    /// The function nodes that enclose the node under the walk, innermost last,
    /// and the number of enclosing functions. The skip for a parameter of a
    /// function that ZTS601 refuses reads the stack. A function nested deeper
    /// than the stack is not recorded, so a parameter of it is not skipped and
    /// its member call is refused: the overflow only adds a refusal.
    function_stack: [max_function_stack]NodeIndex = undefined,
    function_depth: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        ir_view: IrView,
        atoms: ?*context.AtomTable,
        env: *TypeEnv,
    ) TypeChecker {
        return .{
            .allocator = allocator,
            .ir_view = ir_view,
            .atoms = atoms,
            .env = env,
            .diagnostics = .empty,
            .compiled_schemas = .empty,
            .binding_types = .empty,
            .binding_callables = .empty,
            .param_types = .empty,
            .narrowed = .empty,
            .narrow_journal = .empty,
            .admitted_predicates = .empty,
            .allocation_failed = false,
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        if (self.owned_import_facts) |*facts| facts.deinit();
        for (self.diagnostics.items) |diag| {
            if (diag.allocated) {
                self.allocator.free(diag.message);
            }
            if (diag.help_owned) {
                if (diag.help) |help| self.allocator.free(help);
            }
        }
        self.diagnostics.deinit(self.allocator);
        for (self.compiled_schemas.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.compiled_schemas.deinit(self.allocator);
        self.binding_types.deinit(self.allocator);
        self.unannotated_decls.deinit(self.allocator);
        self.binding_callables.deinit(self.allocator);
        self.file_import_callables.deinit(self.allocator);
        self.file_import_untyped.deinit(self.allocator);
        self.param_types.deinit(self.allocator);
        self.narrowed.deinit(self.allocator);
        self.context_types.deinit(self.allocator);
        self.absent_receivers.deinit(self.allocator);
        self.opaque_pattern_bindings.deinit(self.allocator);
        self.narrow_journal.deinit(self.allocator);
        self.admitted_predicates.deinit(self.allocator);
    }

    /// Run the checker on the given root node. Returns the number of errors.
    pub fn check(self: *TypeChecker, root: NodeIndex) !u32 {
        try self.ensureHealthy();
        if (self.import_facts == null and self.owned_import_facts == null) {
            errdefer self.markAllocationFailure();
            self.owned_import_facts = try module_facts_mod.ModuleFacts.build(
                self.allocator,
                self.ir_view,
                self.atoms,
                null,
            );
        }
        self.materializeFileImports();
        // Before the main walk, so a call to a predicate declared later in the
        // file still narrows. A predicate whose body is not an admitted test is
        // rejected here and installs nothing anywhere.
        self.admitTypePredicates(root, 0, true);
        self.scanClosureWrites(root, 0, false);
        self.walkStmt(root);
        if (self.bound_var_annotations != self.env.varAnnotationCount()) {
            self.binding_resolution_failed = true;
        }
        try self.ensureHealthy();
        var error_count: u32 = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.severity == .err) error_count += 1;
        }
        // The check pipeline stops at the type stage when it found an error
        // (`precompile.runCheckOnlyFromSourceWithOptions`), so the strict
        // checker reports a match that is not exhaustive only when this
        // checker found none. Then ZTS603 answers for it and ZTS205 would be a
        // second diagnostic for the same mistake. With a type error present,
        // strict never reports, and ZTS205 stays: it would otherwise sit
        // behind the type error its `| undefined` result type caused.
        if (self.strict_checker_follows and error_count == 0) self.dropDiagnosticsOfKind(.non_exhaustive_match);
        return error_count;
    }

    fn dropDiagnosticsOfKind(self: *TypeChecker, kind: DiagnosticKind) void {
        var kept: usize = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.kind != kind) {
                self.diagnostics.items[kept] = diag;
                kept += 1;
                continue;
            }
            if (diag.allocated) self.allocator.free(diag.message);
            if (diag.help_owned) {
                if (diag.help) |help| self.allocator.free(help);
            }
        }
        self.diagnostics.items.len = kept;
    }

    /// Record the type of a boolean-context operand while the walk's narrowing
    /// overlay describes the path that reaches it.
    fn recordContextType(self: *TypeChecker, node: NodeIndex) void {
        if (node == null_node) return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        self.context_types.put(self.allocator, node, self.inferType(node)) catch self.markAllocationFailure();
    }

    fn admitsUndefined(self: *const TypeChecker, raw: TypeIndex) bool {
        return self.admitsUndefinedAt(raw, 0);
    }

    /// Fail closed: a type that may hold `undefined`, or that the checker
    /// cannot bound, admits it. `null_type_idx` (no type at all) answers
    /// false: that is the disclosed class of reads this rule cannot see.
    /// The switch names every type tag, so a new tag is a compile error here.
    fn admitsUndefinedAt(self: *const TypeChecker, raw: TypeIndex, depth: u8) bool {
        if (raw == null_type_idx) return false;
        if (depth > 8) return true;
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(t) orelse return true;
        return switch (tag) {
            .t_nullable, .t_undefined, .t_void, .t_unknown_type, .t_generic_param => true,
            .t_union => blk: {
                for (pool.getUnionMembers(t)) |m| {
                    if (self.admitsUndefinedAt(m, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .t_intersection => blk: {
                for (pool.getIntersectionMembers(t)) |m| {
                    if (!self.admitsUndefinedAt(m, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            .t_generic_app => blk: {
                const inst = self.env.finishParsedTypeRoot(t);
                if (inst == t or inst == null_type_idx) break :blk true;
                break :blk self.admitsUndefinedAt(inst, depth + 1);
            },
            .t_ref => !std.mem.eql(u8, pool.getRefName(t), "object"),
            .t_boolean,
            .t_number,
            .t_string,
            .t_null,
            .t_dict,
            .t_bytes,
            .t_never,
            .t_error,
            .t_record,
            .t_array,
            .t_tuple,
            .t_function,
            .t_literal_string,
            .t_literal_number,
            .t_literal_bool,
            .t_template_literal,
            => false,
        };
    }

    /// Whether `raw` is the JSON value type, or a nullable, union, or
    /// intersection that has it as a member, the way `isDictOperandType`
    /// treats a Dict member.
    fn isJsonValueOperandType(self: *const TypeChecker, raw: TypeIndex, depth: u8) bool {
        if (raw == null_type_idx or depth > 8) return false;
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        if (t == pool.idx_json_value) return true;
        const tag = pool.getTag(t) orelse return false;
        switch (tag) {
            .t_nullable => return self.isJsonValueOperandType(pool.getNullableInner(t), depth + 1),
            .t_union => {
                for (pool.getUnionMembers(t)) |m| {
                    if (self.isJsonValueOperandType(m, depth + 1)) return true;
                }
                return false;
            },
            .t_intersection => {
                for (pool.getIntersectionMembers(t)) |m| {
                    if (self.isJsonValueOperandType(m, depth + 1)) return true;
                }
                return false;
            },
            // exhaustive: any other type is not the JSON value type and holds no member of it.
            else => return false,
        }
    }

    /// Whether a read on a value of this type reads a Dict entry. A union, a
    /// nullable, or an intersection with any Dict member counts: a Dict
    /// member or index read yields `undefined` at run time on every Dict
    /// that the runtime builds, so the read is refused, not typed.
    fn isDictOperandType(self: *const TypeChecker, raw: TypeIndex, depth: u8) bool {
        if (raw == null_type_idx) return false;
        if (depth > 8) return false;
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(t) orelse return false;
        return switch (tag) {
            .t_dict => true,
            .t_nullable => self.isDictOperandType(pool.getNullableInner(t), depth + 1),
            .t_union => blk: {
                for (pool.getUnionMembers(t)) |m| {
                    if (self.isDictOperandType(m, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .t_intersection => blk: {
                for (pool.getIntersectionMembers(t)) |m| {
                    if (self.isDictOperandType(m, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .t_undefined,
            .t_void,
            .t_unknown_type,
            .t_generic_param,
            .t_generic_app,
            .t_ref,
            .t_boolean,
            .t_number,
            .t_string,
            .t_null,
            .t_bytes,
            .t_never,
            .t_error,
            .t_record,
            .t_array,
            .t_tuple,
            .t_function,
            .t_literal_string,
            .t_literal_number,
            .t_literal_bool,
            .t_template_literal,
            => false,
        };
    }

    fn isOpaquePatternBinding(self: *const TypeChecker, operand: NodeIndex) bool {
        if (self.ir_view.getTag(operand) != .identifier) return false;
        const binding = self.ir_view.getBinding(operand) orelse return false;
        return self.opaque_pattern_bindings.contains(bindingKey(binding));
    }

    /// The type a read of `field` yields: an optional field may be absent.
    fn fieldReadType(self: *const TypeChecker, field: type_pool_mod.RecordField) TypeIndex {
        if (!field.optional or field.type_idx == null_type_idx) return field.type_idx;
        if (self.admitsUndefined(field.type_idx)) return field.type_idx;
        return self.env.pool.addNullable(self.allocator, field.type_idx);
    }

    /// The type a read of `field` of `record` yields. A field of a Result
    /// record that the checker built for a fallible export keeps its declared
    /// type: the Result check (ZTS303) owns that read. The test is the type's
    /// identity in the pool (`TypePool.isResultRecord`), never its shape, so a
    /// record a handler declares itself widens like any other optional field.
    fn recordFieldReadType(self: *const TypeChecker, record: TypeIndex, field: type_pool_mod.RecordField) TypeIndex {
        if (self.env.pool.isResultRecord(record)) return field.type_idx;
        return self.fieldReadType(field);
    }

    /// Record `read` when `operand` may be undefined under the live narrowing.
    fn recordAbsentReceiver(self: *TypeChecker, read: NodeIndex, operand: NodeIndex) void {
        if (read == null_node or operand == null_node) return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const t = self.inferType(operand);
        if (!self.admitsUndefined(t)) return;
        // A read on `unknown` is not recorded (a Result `.value`, a request
        // body, a fetch `.json()`): disclosed in the property text. A
        // pattern binding that only has the type `unknown` because its arm
        // has no record type is still recorded, so that fallback fails closed.
        const resolved = self.env.pool.unwrapNominal(self.env.resolveRef(t));
        if (self.env.pool.getTag(resolved) == .t_unknown_type and !self.isOpaquePatternBinding(operand)) return;
        self.absent_receivers.put(self.allocator, read, t) catch self.markAllocationFailure();
    }

    /// Whether the type of `node` is a Result whose `errors` field is not
    /// `never`. Such a Result ends a failure with `errors` filled and `error`
    /// absent, so a read of its `error` may see `undefined`.
    pub fn resultMayFillErrors(self: *TypeChecker, node: NodeIndex) bool {
        if (node == null_node) return false;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const errors_type = self.resultFieldType(self.inferType(node), "errors", 0);
        return errors_type != null_type_idx and errors_type != self.env.pool.idx_never;
    }

    /// Whether the type of `node` is a Result whose `value` field admits
    /// `undefined`. The Result record stores the value type unchanged, so
    /// such a Result can end `ok` with an absent `value`, and a successful
    /// `ok` check proves nothing about a read of that value.
    pub fn resultValueMayBeAbsent(self: *TypeChecker, node: NodeIndex) bool {
        if (node == null_node) return false;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const value_type = self.resultFieldType(self.inferType(node), "value", 0);
        return value_type != null_type_idx and self.admitsUndefined(value_type);
    }

    /// Whether `read` is a recorded read (a key of `absent_receivers`) that
    /// the handler verifier will report as ZTS309. It applies the rule of
    /// `isTrackedResultFieldRead` in `handler_verifier.zig`, which leaves a
    /// read to the Result check (ZTS303) when its object is a member read
    /// (dotted, or computed with a string literal) of `unwrap` or `errors`;
    /// of `error` on a Result for which `resultMayFillErrors` is false; or of
    /// `value` on a Result for which `resultValueMayBeAbsent` is false.
    ///
    /// This function does not ask whether the receiver is a tracked Result
    /// binding. The verifier reports a read on an untracked Result, so the
    /// skip set here is a subset of what the verifier reports: no read is
    /// skipped without a diagnostic. A read that the verifier gives to
    /// ZTS309 on an untracked Result gets the caller's own diagnostic.
    ///
    /// A strict check that refuses a value with no type calls this to leave
    /// such a read to ZTS309, because the precompile run returns after a
    /// boolean, type, or strict error and before the verifier runs.
    pub fn verifierReportsAbsentRead(self: *TypeChecker, read: NodeIndex) bool {
        if (!self.absent_receivers.contains(read)) return false;
        const read_tag = self.ir_view.getTag(read) orelse return true;
        if (read_tag != .member_access and read_tag != .computed_access) return true;
        const read_member = self.ir_view.getMember(read) orelse return true;
        const object_tag = self.ir_view.getTag(read_member.object) orelse return true;
        if (object_tag != .member_access and object_tag != .computed_access) return true;
        const member = self.ir_view.getMember(read_member.object) orelse return true;
        const FieldName = enum { value, unwrap, @"error", errors, other };
        const field: FieldName = blk: {
            if (member.computed != null_node) {
                if (self.ir_view.getTag(member.computed) != .lit_string) break :blk .other;
                const string_index = self.ir_view.getStringIdx(member.computed) orelse break :blk .other;
                const name = self.ir_view.getString(string_index) orelse break :blk .other;
                if (std.mem.eql(u8, name, "value")) break :blk .value;
                if (std.mem.eql(u8, name, "unwrap")) break :blk .unwrap;
                if (std.mem.eql(u8, name, "error")) break :blk .@"error";
                if (std.mem.eql(u8, name, "errors")) break :blk .errors;
                break :blk .other;
            }
            if (member.property == @backingInt(object.Atom.value)) break :blk .value;
            if (member.property == @backingInt(object.Atom.unwrap)) break :blk .unwrap;
            if (member.property == @backingInt(object.Atom.@"error")) break :blk .@"error";
            if (member.property == @backingInt(object.Atom.errors)) break :blk .errors;
            break :blk .other;
        };
        return switch (field) {
            .other => true,
            .unwrap, .errors => false,
            .@"error" => self.resultMayFillErrors(member.object),
            .value => self.resultValueMayBeAbsent(member.object),
        };
    }

    /// Every recorded read, in ascending node order.
    pub fn absentReceiverReads(self: *const TypeChecker, allocator: std.mem.Allocator) ![]NodeIndex {
        const out = try allocator.alloc(NodeIndex, self.absent_receivers.count());
        errdefer allocator.free(out);
        var it = self.absent_receivers.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        std.mem.sort(NodeIndex, out, {}, std.sort.asc(NodeIndex));
        return out;
    }

    /// Refuse a member or index read whose operand is a Dict, or a union or
    /// nullable with a Dict member. On every Dict the runtime builds, such a
    /// read yields `undefined`, so a guard on the result always takes the
    /// absent branch. The walk visits each node once, so each read reports
    /// once.
    fn reportDictEntryRead(self: *TypeChecker, read: NodeIndex, operand: NodeIndex) void {
        if (read == null_node or operand == null_node) return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const operand_type = self.inferType(operand);
        // The `.value` of `requestJson` and `parseJson` (`TypePool.idx_json_value`)
        // is a Dict at run time. It narrows like `unknown`, so only the read is refused.
        if (self.isJsonValueOperandType(operand_type, 0)) {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .missing_field,
                .node = read,
                .message = "a member or index read on a parsed JSON value yields undefined",
                .help = "decode the value with decodeJson(schema, text), or check isDict(v) and read with dictGet(v, key)",
            });
            return;
        }
        if (!self.isDictOperandType(operand_type, 0)) return;
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .missing_field,
            .node = read,
            .message = "a member or index read on a Dict yields undefined",
            .help = "read a Dict entry with dictGet(d, key)",
        });
    }

    /// Refuse an index read whose operand is a `string`. The interpreter's
    /// `get_elem` yields `undefined` for every string receiver, so a read such
    /// as `s[0]` never gives a character. A union with a string member is not
    /// refused here: `inferIndexReadType` adds `undefined` to its read type.
    fn reportStringIndexRead(self: *TypeChecker, read: NodeIndex, operand: NodeIndex) void {
        if (read == null_node or operand == null_node) return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const operand_type = self.inferType(operand);
        if (operand_type == null_type_idx) return;
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(operand_type));
        const tag = pool.getTag(t) orelse return;
        switch (tag) {
            .t_string, .t_literal_string, .t_template_literal => {},
            // exhaustive: only a string receiver makes every index read
            // `undefined`. A union with a string member gets `undefined` in
            // `inferIndexReadType`, and the other receivers are typed there.
            else => return,
        }
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .missing_field,
            .node = read,
            .message = "an index read on a string yields undefined",
            .help = "use s.charAt(i) or s.slice(i, i + 1)",
        });
    }

    /// What a read of a member finds on a value of one type at run time.
    const MemberPresence = enum {
        /// The runtime installs the member, or the record declares it.
        present,
        /// The read yields `undefined`, and a call raises `NotCallable`.
        absent,
        /// The checker does not model the type's members.
        unmodeled,
    };

    fn presenceOf(installed: bool) MemberPresence {
        return if (installed) .present else .absent;
    }

    /// The members of a `number`, a `boolean`, a `string`, an array, or a
    /// tuple. A `number` and a `boolean` have no prototype. A `string` and an
    /// array have the members that `builtins/root.zig` installs, which
    /// `builtin_results.installsMember` reads from the census-checked tables.
    /// Every other type, a record included, is `unmodeled` here.
    fn primitiveMemberPresence(self: *const TypeChecker, raw: TypeIndex, name: []const u8) MemberPresence {
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(t) orelse return .unmodeled;
        return switch (tag) {
            .t_number, .t_literal_number, .t_boolean, .t_literal_bool => .absent,
            .t_string, .t_literal_string, .t_template_literal => presenceOf(builtin_results.installsMember("String.prototype", name)),
            .t_array, .t_tuple => presenceOf(builtin_results.installsMember("Array.prototype", name)),
            // exhaustive: any other type is not one of the receivers whose
            // runtime members the census-checked tables list.
            else => .unmodeled,
        };
    }

    /// `primitiveMemberPresence`, and a record's declared fields.
    fn memberPresence(self: *const TypeChecker, raw: TypeIndex, name: []const u8) MemberPresence {
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        if (pool.getTag(t) == .t_record) return presenceOf(pool.lookupRecordField(t, name) != null);
        return self.primitiveMemberPresence(raw, name);
    }

    /// The name of a member read or call that has a name, or null for an
    /// index read or a member with no node of its own.
    fn namedMember(self: *const TypeChecker, node: NodeIndex) ?struct { member: Node.MemberExpr, name: []const u8 } {
        const tag = self.ir_view.getTag(node) orelse return null;
        if (tag != .member_access and tag != .optional_chain) return null;
        const member = self.ir_view.getMember(node) orelse return null;
        if (member.computed != null_node) return null;
        const name = self.resolveAtomName(member.property) orelse return null;
        return .{ .member = member, .name = name };
    }

    /// Refuse a member read or call on a receiver that cannot hold it at run
    /// time: a `number`, a `boolean`, a `string`, an array, a tuple, or a union
    /// of these. Such a read yields `undefined`, and a call raises
    /// `NotCallable`. A record, a Result record, a named builtin type, and a
    /// receiver with no type are not read here, and a union that holds one of
    /// them is read by `reportUnionMemberCall` and by `inferMemberAccessType`.
    fn reportNonRecordMemberRead(self: *TypeChecker, read: NodeIndex) void {
        const named = self.namedMember(read) orelse return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const operand_type = self.inferType(named.member.object);
        if (operand_type == null_type_idx) return;
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(operand_type));
        var absent = false;
        if (pool.getTag(t) == .t_union) {
            for (pool.getUnionMembers(t)) |m| {
                switch (self.primitiveMemberPresence(m, named.name)) {
                    .absent => absent = true,
                    .present => {},
                    .unmodeled => return,
                }
            }
        } else {
            absent = self.primitiveMemberPresence(t, named.name) == .absent;
        }
        if (!absent) return;
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .missing_field,
            .node = read,
            .message = "member does not exist on this type at runtime",
            .help = "number and boolean values have no members; strings and arrays have only the methods that docs/typescript.md lists",
        });
    }

    /// Refuse a call through a member that the receiver may lack. On an
    /// `unknown` receiver, any member call is refused: the read yields
    /// `undefined` and the call raises `NotCallable`. A member read on an
    /// `unknown` value stays accepted. On a union, a call through a member
    /// that some member lacks is refused. A union with a record is the case
    /// here. A union of numbers, booleans, strings, and arrays alone is
    /// reported by `reportNonRecordMemberRead`. A union with a member of
    /// another kind is not modeled.
    ///
    /// On strict paths (`strict_checker_follows`), a call on a receiver with no
    /// type is refused too: the value may lack the member, and the call then
    /// raises `NotCallable`. `refusesUntypedReceiver` names the four receivers
    /// that it leaves alone.
    fn reportUnionMemberCall(self: *TypeChecker, callee: NodeIndex) void {
        const named = self.namedMember(callee) orelse return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const operand_type = self.inferType(named.member.object);
        if (operand_type == null_type_idx) {
            if (self.refusesUntypedReceiver(named.member.object, named.name)) self.addDiagnostic(.{
                .severity = .err,
                .kind = .missing_field,
                .node = callee,
                .message = "a member call on a value with no known type; give it a type or narrow it first",
                .help = "annotate the value or its source, or check it with typeof, isDict, or a match arm first",
            });
            return;
        }
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(operand_type));
        // A read on an `unknown` value yields `undefined` and does not fault,
        // so it stays accepted. A call raises `NotCallable`. The parsed JSON
        // and Dict receivers keep the message of `reportDictEntryRead`.
        if (t == pool.idx_unknown) {
            if (self.isJsonValueOperandType(operand_type, 0) or self.isDictOperandType(operand_type, 0)) return;
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .missing_field,
                .node = callee,
                .message = "a member read on an unknown value; narrow it first",
                .help = "check the value with typeof, isDict, or a match arm before you read a member",
            });
            return;
        }
        if (pool.getTag(t) != .t_union) return;
        var absent = false;
        var has_record = false;
        for (pool.getUnionMembers(t)) |m| {
            if (self.unionMemberIsRecord(m)) has_record = true;
            switch (self.memberPresence(m, named.name)) {
                .absent => absent = true,
                .present => {},
                .unmodeled => return,
            }
        }
        if (!absent or !has_record) return;
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .missing_field,
            .node = callee,
            .message = "a member that some union member does not have is called; narrow the union first",
            .help = "check the discriminant or the type before you call the member",
        });
    }

    /// Whether strict code refuses a member call whose receiver `receiver` has
    /// no type. Such a call raises `NotCallable` when the value lacks the
    /// member. Four skips leave the receiver alone:
    ///   - a builtin namespace such as `Math` or `JSON`, which has no type by
    ///     design;
    ///   - a read that the verifier reports as ZTS309, because a refusal here
    ///     would hide it: the precompile run returns after a type error and
    ///     before the verifier runs;
    ///   - a parameter of a function that ZTS601 refuses;
    ///   - an array literal, when every array has the member.
    fn refusesUntypedReceiver(self: *TypeChecker, receiver: NodeIndex, member_name: []const u8) bool {
        if (!self.strict_checker_follows) return false;
        if (self.builtinGlobalName(receiver) != null) return false;
        if (self.verifierReportsAbsentRead(receiver)) return false;
        if (self.isParameterOfRefusedFunction(receiver)) return false;
        if (self.isArrayLiteralWithMember(receiver, member_name)) return false;
        return true;
    }

    /// Whether `node` is an array literal and every array has the member
    /// `name`. The literal has no type when an element has none, but it is an
    /// array at run time. A member that arrays lack is still refused. The
    /// presence rule is the one that `reportNonRecordMemberRead` applies to an
    /// array type.
    fn isArrayLiteralWithMember(self: *TypeChecker, node: NodeIndex, name: []const u8) bool {
        if (self.ir_view.getTag(node) != .array_literal) return false;
        const pool = self.env.pool;
        const array = pool.addArray(self.allocator, pool.idx_unknown);
        return self.primitiveMemberPresence(array, name) == .present;
    }

    /// Whether `node` is an identifier bound to a parameter of an enclosing
    /// function that ZTS601 refuses. A parameter read in its own function has
    /// kind `argument` and matches the parameter by scope and slot. A read
    /// from a nested function has kind `upvalue` and matches the nearest
    /// enclosing function that declares a parameter of that name. A local of
    /// an intermediate function that shares the name can make this skip a
    /// read it need not skip; ZTS601 refuses the function either way.
    fn isParameterOfRefusedFunction(self: *const TypeChecker, node: NodeIndex) bool {
        if ((self.ir_view.getTag(node) orelse return false) != .identifier) return false;
        const binding = self.ir_view.getBinding(node) orelse return false;
        if (binding.kind != .argument and binding.kind != .upvalue) return false;
        var depth = @min(self.function_depth, max_function_stack);
        while (depth > 0) {
            depth -= 1;
            const fn_node = self.function_stack[depth];
            const func = self.ir_view.getFunction(fn_node) orelse continue;
            var i: usize = 0;
            while (i < func.params_count) : (i += 1) {
                const param = self.ir_view.getListIndex(func.params_start, @intCast(i));
                const param_binding = self.ir_view.paramBinding(param) orelse continue;
                const same = switch (binding.kind) {
                    .argument => param_binding.scope_id == binding.scope_id and param_binding.slot == binding.slot,
                    .upvalue => param_binding.name_atom == binding.name_atom,
                    // exhaustive: the guard above admits only argument and upvalue bindings.
                    else => false,
                };
                if (!same) continue;
                return strict_checker_mod.functionRefusedForAnnotation(self.env, self.ir_view, fn_node, func);
            }
        }
        return false;
    }

    /// The type a function parameter was declared with, or `null_type_idx` for
    /// a binding that is not a parameter or whose parameter carries no
    /// annotation. Read after the walk: the table is filled as each function is
    /// entered and never narrowed, so this is the declared type, not the type
    /// a guard has since established.
    pub fn declaredParameterType(self: *const TypeChecker, binding: ir.BindingRef) TypeIndex {
        return self.param_types.get(bindingKey(binding)) orelse null_type_idx;
    }

    /// The type `recordContextType` saw for `node`, or null when the walk did
    /// not record one. The error type is hidden as in `inferTypeWithoutDiagnostics`.
    pub fn contextTypeOf(self: *TypeChecker, node: NodeIndex) ?TypeIndex {
        const recorded = self.context_types.get(node) orelse return null;
        return self.hideError(recorded);
    }

    /// Let secondary analyzers query the authoritative type session without
    /// turning a branch-insensitive query into a new compiler verdict. The
    /// statement walk has already checked the expression with its live
    /// narrowing context. Operational failures remain sticky and are checked
    /// by the owning pipeline after the secondary analyzer returns.
    pub fn inferTypeWithoutDiagnostics(self: *TypeChecker, node: NodeIndex) TypeIndex {
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        return self.hideError(self.inferType(node));
    }

    /// The type another checker may see. A refused expression's error type
    /// (`t_error`) is private to this checker: it exists so one mistake gives
    /// one message here, and a consumer that read it would hold a type that
    /// proves nothing. It becomes `null_type_idx`, which every consumer treats
    /// as unknown and refuses to rely on. A type built from it goes the same
    /// way. Every public getter that returns an inferred type routes through
    /// this function.
    fn hideError(self: *const TypeChecker, type_idx: TypeIndex) TypeIndex {
        if (self.refusedExpressionCount() == 0) return type_idx;
        if (self.env.pool.mentionsError(type_idx)) return null_type_idx;
        return type_idx;
    }

    /// Whether the operator at `node` was refused. The answer is read from the
    /// diagnostics the checker recorded, not from a second record, so the
    /// error type exists for exactly the expressions that have a diagnostic:
    /// there is no state to fall out of step and no allocation to fail.
    pub fn isRefused(self: *const TypeChecker, node: NodeIndex) bool {
        for (self.diagnostics.items) |diag| {
            if (diag.kind == .string_add and diag.node == node) return true;
        }
        return false;
    }

    /// Which absent values a type admits. `unknown` and a type parameter admit
    /// neither by name: they are not a union with `null` or `undefined`.
    pub const AbsentValues = struct {
        null_value: bool = false,
        undefined_value: bool = false,
    };

    pub fn absentValuesOf(self: *const TypeChecker, raw: TypeIndex) AbsentValues {
        return self.absentValuesAt(raw, 0);
    }

    fn absentValuesAt(self: *const TypeChecker, raw: TypeIndex, depth: u8) AbsentValues {
        if (raw == null_type_idx or depth > 8) return .{};
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(t) orelse return .{};
        switch (tag) {
            .t_undefined, .t_void => return .{ .undefined_value = true },
            .t_null => return .{ .null_value = true },
            .t_nullable => {
                const inner = self.absentValuesAt(pool.getNullableInner(t), depth + 1);
                return .{ .null_value = inner.null_value, .undefined_value = true };
            },
            .t_union => {
                var found: AbsentValues = .{};
                for (pool.getUnionMembers(t)) |member| {
                    const part = self.absentValuesAt(member, depth + 1);
                    found.null_value = found.null_value or part.null_value;
                    found.undefined_value = found.undefined_value or part.undefined_value;
                }
                return found;
            },
            // exhaustive: every other type names no absent value of its own.
            else => return .{},
        }
    }

    /// How many expressions had an operator refused. A test reads it to check
    /// that the error type exists only where a diagnostic was reported.
    pub fn refusedExpressionCount(self: *const TypeChecker) usize {
        var count: usize = 0;
        for (self.diagnostics.items) |diag| {
            if (diag.kind == .string_add) count += 1;
        }
        return count;
    }

    /// Reject proof/type results after either the checker or its shared pool
    /// encounters an operational allocation or compact-capacity failure.
    pub fn ensureHealthy(self: *const TypeChecker) TypeCheckerError!void {
        try self.env.ensureHealthy();
        try self.env.pool.ensureHealthy();
        if (self.allocation_failed) return error.OutOfMemory;
        if (self.binding_resolution_failed) return error.UnresolvedTypeBinding;
    }

    pub fn getDiagnostics(self: *const TypeChecker) []const Diagnostic {
        return self.diagnostics.items;
    }

    // -------------------------------------------------------------------
    // Diagnostic formatting
    // -------------------------------------------------------------------

    pub fn formatDiagnostics(self: *const TypeChecker, source: SourceView, writer: anytype) !void {
        try diagnostic_projection.writeAll(.type, source, self.diagnostics.items, self.ir_view, writer);
    }

    // -------------------------------------------------------------------
    // Statement walking
    // -------------------------------------------------------------------

    // -------------------------------------------------------------------
    // Flow-sensitive narrowing store (D1 section 5)
    //
    // `binding_types` is the declared or inferred type of a binding.
    // `narrowed` is the flow overlay, and killing a narrowing means dropping
    // the overlay entry rather than losing the declaration.
    // -------------------------------------------------------------------

    /// The type a binding has at this point in the walk: the narrowing if one
    /// is installed, the declared type otherwise.
    ///
    /// The fallback chain is `inferType`'s, and it has to be. A guard extractor
    /// that read only `binding_types` saw `const` and `let` declarations and
    /// nothing else - a function parameter is registered in `param_types` and
    /// in the environment, so no guard over a parameter ever installed. Every
    /// narrowing test in the profile's closed list is written over a parameter
    /// at least as often as over a local.
    fn currentBindingType(self: *const TypeChecker, binding: ir.BindingRef) ?TypeIndex {
        const key = bindingKey(binding);
        if (self.narrowed.get(key)) |t| return t;
        if (self.binding_types.get(key)) |t| return t;
        const declared = self.declaredTypeForBinding(binding);
        return if (declared == null_type_idx) null else declared;
    }

    /// Open a branch scope. Every narrowing written while it is open is undone
    /// by the matching `endNarrowScope`, so a narrowing established inside a
    /// conditional cannot describe the path where that conditional was false.
    ///
    /// Kill rule 5 alone does not cover this: it drops narrowings whose binding
    /// lives in the closing block's scope, and the binding a guard narrows is
    /// usually a parameter of the enclosing function. So a nested early return -
    /// `if (flag) { if (v === undefined) { return "x"; } }` - installed the
    /// forward narrowing `v -> string` and it survived past the outer `if`,
    /// where `v` is still `string | undefined`.
    fn beginNarrowScope(self: *TypeChecker) usize {
        self.narrow_scopes += 1;
        return self.narrow_journal.items.len;
    }

    /// Close a branch scope and undo every change it made. Undoing also undoes
    /// a kill, although the branch really did drop that narrowing. So the
    /// result names the keys the branch killed, and the caller applies them
    /// with `applyKills` where the branch joins the code after it.
    fn endNarrowScope(self: *TypeChecker, mark: usize) KillSet {
        var kills: KillSet = .{};
        var i = self.narrow_journal.items.len;
        while (i > mark) {
            i -= 1;
            const entry = self.narrow_journal.items[i];
            if (entry.killed) kills.add(entry.key);
            if (entry.prev) |prev| {
                self.narrowed.put(self.allocator, entry.key, prev) catch self.markAllocationFailure();
            } else {
                _ = self.narrowed.remove(entry.key);
            }
        }
        self.narrow_journal.items.len = mark;
        if (self.narrow_scopes > 0) self.narrow_scopes -= 1;
        return kills;
    }

    /// Drop the narrowings the closed scope killed, now that its changes are
    /// undone. `killNarrowing` journals each drop in the enclosing scope, so a
    /// kill survives every scope it is nested in.
    fn applyKills(self: *TypeChecker, kills: KillSet) void {
        if (kills.overflow) {
            self.killAllNarrowings();
            return;
        }
        for (kills.keys[0..kills.len]) |key| self.killNarrowing(key);
    }

    /// Start recording the keys killed from here on, without undoing anything.
    /// `endKillWatch` reports them. A watch is not a branch: its changes stay.
    fn beginKillWatch(self: *TypeChecker) usize {
        self.narrow_scopes += 1;
        return self.narrow_journal.items.len;
    }

    /// The entries stay in the journal while an enclosing scope is open, so
    /// that scope still undoes them. With none open nothing reads them.
    fn endKillWatch(self: *TypeChecker, mark: usize) KillSet {
        var kills: KillSet = .{};
        for (self.narrow_journal.items[mark..]) |entry| {
            if (entry.killed) kills.add(entry.key);
        }
        if (self.narrow_scopes > 0) self.narrow_scopes -= 1;
        if (self.narrow_scopes == 0) self.narrow_journal.items.len = mark;
        return kills;
    }

    /// Record what `key` held before it is overwritten or removed, so the
    /// enclosing branch scope can put it back. Outside a branch scope there is
    /// nothing to undo to, and nothing is recorded.
    fn recordNarrowChange(self: *TypeChecker, key: u64, killed: bool) void {
        if (self.narrow_scopes == 0) return;
        self.narrow_journal.append(
            self.allocator,
            .{ .key = key, .prev = self.narrowed.get(key), .killed = killed },
        ) catch self.markAllocationFailure();
    }

    fn putNarrowed(self: *TypeChecker, key: u64, narrowed_type: TypeIndex) void {
        self.recordNarrowChange(key, false);
        self.narrowed.put(self.allocator, key, narrowed_type) catch self.markAllocationFailure();
    }

    /// Kill rule 1. Any assignment to a binding drops its narrowing: the guard
    /// that installed it described the old value. Without this kill, a guard
    /// installed by an early return would survive a later reassignment.
    fn killNarrowing(self: *TypeChecker, key: u64) void {
        self.recordNarrowChange(key, true);
        _ = self.narrowed.remove(key);
    }

    /// Kill rule 5. Drop every narrowing whose binding lives in `scope_id`.
    fn killNarrowingsInScope(self: *TypeChecker, scope_id: ir.ScopeId) void {
        const prefix = @as(u64, scope_id) << 32;
        var it = self.narrowed.iterator();
        var doomed: [32]u64 = undefined;
        var count: usize = 0;
        while (it.next()) |entry| {
            if ((entry.key_ptr.* & 0xFFFFFFFF00000000) != prefix) continue;
            if (count == doomed.len) break;
            doomed[count] = entry.key_ptr.*;
            count += 1;
        }
        for (doomed[0..count]) |key| {
            self.recordNarrowChange(key, true);
            _ = self.narrowed.remove(key);
        }
        // More than the buffer holds is rare and the remainder is dropped on
        // the next pass over the same scope; a leftover entry can only make a
        // later binding read as narrower than it is, so sweep until empty.
        if (count == doomed.len) self.killNarrowingsInScope(scope_id);
    }

    /// Kill rule 4, the entry half. A narrowing established before a loop only
    /// survives the body if the body never assigns the binding, because the
    /// back edge re-enters with whatever the last iteration left.
    ///
    /// The walk descends through `IrView.expressionChildren`, so it reaches an
    /// assignment wherever code can hold one: a declaration initializer, a call
    /// argument, a ternary, a `match` arm, an `assert`, the target of another
    /// assignment, and the body of a nested function. A closure can run during
    /// the loop, so an assignment inside its body kills the narrowing too.
    ///
    /// A captured binding has a different `bindingKey` inside the closure
    /// (kind `upvalue`, the closure's scope and capture slot) than the binding
    /// has where it is declared, so the key cannot name the narrowing to kill.
    /// An assignment to a captured binding inside a nested function therefore
    /// kills every narrowing.
    ///
    /// A shape this walk fails to reach is the unsound direction. The set it
    /// kills only ever grows, and over-killing widens a binding back to its
    /// declared type, which costs precision. A kill that never happens keeps a
    /// narrowing the body has already invalidated, and nothing else catches
    /// it. When the nesting passes `max_kill_depth`, the walk gives up and kills
    /// every narrowing, for the same reason.
    fn killNarrowingsAssignedIn(self: *TypeChecker, node: NodeIndex, depth: u16, in_closure: bool) void {
        if (node == null_node) return;
        if (depth > max_kill_depth) {
            self.killAllNarrowings();
            return;
        }
        const tag = self.ir_view.getTag(node) orelse return;
        if (tag == .assignment) {
            const asgn = self.ir_view.getAssignment(node) orelse return;
            if (self.ir_view.getTag(asgn.target) == .identifier) {
                if (self.ir_view.getBinding(asgn.target)) |binding| {
                    self.killNarrowing(bindingKey(binding));
                    if (in_closure and binding.kind == .upvalue) self.killAllNarrowings();
                }
            }
            // The target can hold an assignment of its own: `a[x = 1] = 2`.
            self.killNarrowingsAssignedIn(asgn.target, depth + 1, in_closure);
            self.killNarrowingsAssignedIn(asgn.value, depth + 1, in_closure);
            return;
        }
        const child_in_closure = in_closure or tag == .function_decl or
            tag == .function_expr or tag == .arrow_function;
        var children = self.ir_view.expressionChildren(node);
        while (children.next()) |child| {
            self.killNarrowingsAssignedIn(child, depth + 1, child_in_closure);
        }
    }

    /// The deepest nesting `killNarrowingsAssignedIn` follows before it kills
    /// every narrowing instead.
    const max_kill_depth: u16 = 256;

    /// Drop every narrowing, journaled so an enclosing branch scope can put
    /// each one back.
    fn killAllNarrowings(self: *TypeChecker) void {
        var keys = self.narrowed.keyIterator();
        while (keys.next()) |key| self.recordNarrowChange(key.*, true);
        self.narrowed.clearRetainingCapacity();
    }

    /// Set `closure_writes_outer` when a function body, at any depth, assigns
    /// an identifier whose binding is a captured one (`upvalue`) or a
    /// module-level one (`global`). Only an assignment to an identifier writes
    /// a binding: the profile refuses compound assignment, so `asgn.op` is
    /// null in an accepted program, and a `for...of` loop declares its own
    /// binding. The rule is program-wide on purpose. A call can run a closure
    /// that the analyzer cannot name: `route_resolution.zig` resolves some
    /// immutable identifiers to their function, but not a function value in
    /// general. A closure that writes an outer binding anywhere therefore
    /// makes every call suspect, and the call arms kill every narrowing.
    ///
    /// The walk descends through `IrView.expressionChildren`, so it reaches
    /// every position that holds code. Past `max_kill_depth` it gives up and
    /// sets the flag, because a write it did not see is the unsound direction.
    fn scanClosureWrites(self: *TypeChecker, node: NodeIndex, depth: u16, in_closure: bool) void {
        if (self.closure_writes_outer or node == null_node) return;
        if (depth > max_kill_depth) {
            self.closure_writes_outer = true;
            return;
        }
        const tag = self.ir_view.getTag(node) orelse return;
        if (in_closure and tag == .assignment) {
            const asgn = self.ir_view.getAssignment(node) orelse return;
            if (self.ir_view.getTag(asgn.target) == .identifier) {
                if (self.ir_view.getBinding(asgn.target)) |binding| {
                    if (binding.kind == .upvalue or binding.kind == .global) {
                        self.closure_writes_outer = true;
                        return;
                    }
                }
            }
        }
        const child_in_closure = in_closure or tag == .function_decl or
            tag == .function_expr or tag == .arrow_function;
        var children = self.ir_view.expressionChildren(node);
        while (children.next()) |child| {
            self.scanClosureWrites(child, depth + 1, child_in_closure);
        }
    }

    /// Compare a value that leaves the enclosing function with its declared
    /// return type. `node` is the statement that returns it: a `return`, or an
    /// `assert` whose error expression a failed condition returns. A function
    /// with no declared return type, and a value whose type is unknown, pass.
    fn checkReturnedValue(self: *TypeChecker, node: NodeIndex, value: NodeIndex) void {
        if (self.current_return_type == null_type_idx) return;
        const inferred = self.inferType(value);
        if (inferred != null_type_idx and !self.env.isAssignableTo(inferred, self.current_return_type)) {
            const result_subject = if (self.env.pool.isResultRecord(self.env.pool.unwrapNominal(self.env.resolveRef(inferred)))) self.identifierName(value) else null;
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .return_type_mismatch,
                .node = node,
                .message = "return type does not match declared return type",
                .help = "the enclosing function's declared return type is what this value must match; " ++
                    "when it comes back from a virtual-module call, wrap it rather than returning it directly",
                .result_shape = if (result_subject != null) .returned else null,
                .result_subject = result_subject,
            });
        }
    }

    /// Record the type of a for-of element variable. An array binds its
    /// element type. A tuple binds the union of its widened element types, so
    /// `[1, 2, 3]` binds `number`. A union whose members are all arrays or
    /// tuples binds the union of each member's element type. Any other
    /// iterable, an empty tuple, and an element with no type leave the
    /// variable untyped, as before.
    fn bindForOfElement(self: *TypeChecker, fi: Node.ForIterStmt) void {
        // `range(...)` returns a lazy iterator of integers (`globalRange`).
        // Only the builtin counts: a parameter named `range` is another binding.
        if (self.isBuiltinRangeCall(fi.iterable)) {
            self.binding_types.put(self.allocator, bindingKey(fi.binding), self.env.pool.idx_number) catch self.markAllocationFailure();
            return;
        }
        const iterable = self.env.resolveRef(self.inferType(fi.iterable));
        if (iterable == null_type_idx) return;
        const element = self.forOfElementType(iterable);
        if (element == null_type_idx) return;
        self.binding_types.put(self.allocator, bindingKey(fi.binding), element) catch self.markAllocationFailure();
    }

    /// The element type that a loop variable takes over `iterable`, or
    /// `null_type_idx` when the iterable is not an array, a tuple, or a union
    /// of those.
    fn forOfElementType(self: *TypeChecker, iterable: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        const shape = pool.unwrapNominal(iterable);
        if (pool.getTag(shape) != .t_union) return self.sequenceElementType(shape);
        var joined: TypeIndex = null_type_idx;
        for (pool.getUnionMembers(shape)) |member| {
            const member_shape = pool.unwrapNominal(self.env.resolveRef(member));
            const element = self.sequenceElementType(member_shape);
            if (element == null_type_idx) return null_type_idx;
            joined = self.joinElementTypes(joined, element);
            if (joined == null_type_idx) return null_type_idx;
        }
        return joined;
    }

    /// The element type of an array, or the union of the widened element
    /// types of a tuple. `null_type_idx` for any other type, for an empty
    /// tuple, and for an element with no type.
    fn sequenceElementType(self: *TypeChecker, shape: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        const tag = pool.getTag(shape) orelse return null_type_idx;
        if (tag == .t_array) return pool.getArrayElement(shape);
        if (tag != .t_tuple) return null_type_idx;
        var joined: TypeIndex = null_type_idx;
        for (pool.getTupleElements(shape)) |member| {
            if (member == null_type_idx) return null_type_idx;
            joined = self.joinElementTypes(joined, pool.widenLiteral(member));
            if (joined == null_type_idx) return null_type_idx;
        }
        return joined;
    }

    /// The union of `joined` and `next`, where `null_type_idx` for `joined`
    /// means that nothing is joined yet. Joining pairwise needs no scratch list.
    fn joinElementTypes(self: *const TypeChecker, joined: TypeIndex, next: TypeIndex) TypeIndex {
        if (joined == null_type_idx) return next;
        return self.env.pool.addUnion(self.allocator, &.{ joined, next });
    }

    fn isBuiltinRangeCall(self: *const TypeChecker, node: NodeIndex) bool {
        if (self.ir_view.getTag(node) != .call) return false;
        const call = self.ir_view.getCall(node) orelse return false;
        const name = self.builtinGlobalName(call.callee) orelse return false;
        return std.mem.eql(u8, name, "range");
    }

    /// Walk a nested function's body in its own narrow scope and discard what
    /// the scope killed. The body has not run where the function is declared,
    /// so its kills do not describe the code after the declaration. The scope
    /// also keeps what the body installs from leaking out. A call that runs the
    /// body is a separate question that this walk does not answer. The function
    /// is on the stack of enclosing functions while its body is walked.
    fn walkFunctionBody(self: *TypeChecker, fn_node: NodeIndex, body: NodeIndex) void {
        if (self.function_depth < max_function_stack) self.function_stack[self.function_depth] = fn_node;
        self.function_depth += 1;
        defer self.function_depth -= 1;
        const mark = self.beginNarrowScope();
        self.walkStmt(body);
        _ = self.endNarrowScope(mark);
    }

    /// The call arms' order when `closure_writes_outer` is set. The arguments
    /// run before the call, so each is walked first and `f(clear(), x)` reads
    /// `x` after the kill that `clear()` made. The argument check follows. The
    /// callee has then run and may have written any outer binding, so every
    /// narrowing dies, journaled for the joins like any other kill.
    fn walkCallArgsThenKill(self: *TypeChecker, node: NodeIndex, call: Node.CallExpr) void {
        for (0..call.args_count) |i| {
            const arg = self.ir_view.getListIndex(call.args_start, @intCast(i));
            self.walkExpr(arg);
        }
        self.checkCallArgs(node, call);
        self.killAllNarrowings();
    }

    fn walkStmt(self: *TypeChecker, node: NodeIndex) void {
        if (self.allocation_failed) return;
        self.env.pool.ensureHealthy() catch return;
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    const stmt_idx = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
                    self.walkStmt(stmt_idx);
                }
                // Kill rule 5. A narrowing of a binding declared in this scope
                // has nothing left to describe once the scope closes, and the
                // key it occupies is (scope, slot) - so leaving it behind would
                // hand it to whatever occupies that slot next.
                self.killNarrowingsInScope(block.scope_id);
            },

            .var_decl => {
                const vd = self.ir_view.getVarDecl(node) orelse return;
                const declared = self.bindVarDeclaration(node, vd.binding);
                if (declared == null_type_idx and self.initializerHoldsLiteralTypes(vd.init)) {
                    self.unannotated_decls.put(self.allocator, bindingKey(vd.binding), {}) catch self.markAllocationFailure();
                }
                self.reportIfNonContractive(declared, node);
                self.bindCallableMetadata(vd.binding, .unavailable);
                if (vd.init != null_node) {
                    self.walkExpr(vd.init);
                    const inferred = self.inferType(vd.init);
                    self.bindCallableMetadata(vd.binding, self.callableMetadataForExpression(vd.init, inferred, vd.kind == .@"const"));

                    // Check: does the initializer type match the declared type?
                    const binding = vd.binding;
                    const key = bindingKey(binding);

                    if (declared != null_type_idx and inferred != null_type_idx) {
                        if (!self.env.isAssignableTo(inferred, declared) and
                            !self.brandsAtDeclaration(declared, inferred))
                        {
                            self.addTypeMismatch(node, declared, inferred);
                        }
                    }

                    // Track inferred type for use in later expressions.
                    // When annotation is a base primitive (number, string, boolean) and
                    // the inferred type is the corresponding literal, keep the narrower
                    // literal. This gives `: Type` satisfies-like semantics for primitives.
                    // For unions and compound annotations, keep the declared type since
                    // the annotation carries semantic intent for exhaustiveness checking.
                    //
                    // Only for `const`. A `let` exists to be reassigned, and
                    // binding it to its initializer's literal type refused every
                    // reassignment as "type '7' is not assignable to type '0'":
                    // the narrower type is sound for a value that cannot change
                    // and is a refusal of the form for one that must.
                    //
                    // For let bindings without explicit type annotations, widen
                    // literal types to their base type so reassignment works.
                    var effective = blk: {
                        if (declared != null_type_idx and inferred != null_type_idx) {
                            if (vd.kind != .@"const") break :blk declared;
                            const dt = self.env.pool.getTag(declared) orelse break :blk declared;
                            const it = self.env.pool.getTag(inferred) orelse break :blk declared;
                            // A nominal declared type is never narrowed to the
                            // initializer's literal. It copies its base node's
                            // tag, so a brand over `string` reads as `.t_string`
                            // here and would be replaced by the literal type -
                            // dropping the brand at the one site that creates
                            // it, which is the opposite of what the annotation
                            // was written to do.
                            if (self.env.pool.isNominal(declared)) break :blk declared;
                            const is_literal_of_base =
                                (dt == .t_number and it == .t_literal_number) or
                                (dt == .t_string and it == .t_literal_string) or
                                (dt == .t_boolean and it == .t_literal_bool);
                            break :blk if (is_literal_of_base) inferred else declared;
                        }
                        break :blk if (declared != null_type_idx) declared else inferred;
                    };
                    if (declared == null_type_idx) {
                        effective = self.arrayLiteralBindingType(vd.init, effective);
                    }
                    if (effective != null_type_idx and declared == null_type_idx and vd.kind == .let) {
                        effective = self.widenEmptyDict(self.env.pool.widenLiteral(effective));
                    }
                    if (effective != null_type_idx) {
                        self.binding_types.put(self.allocator, key, effective) catch self.markAllocationFailure();
                    }
                    // A present initializer narrows a `T | undefined` annotation
                    // (written `T?` or as a union) to `T` for the rest of the scope.
                    if (declared != null_type_idx and inferred != null_type_idx and !self.admitsUndefined(inferred)) {
                        if (self.removeAbsence(declared, .undefined_only)) |inner| {
                            if (self.env.isAssignableTo(inferred, inner)) self.putNarrowed(key, inner);
                        }
                    }
                }
            },

            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return;
                const watch = self.beginKillWatch();
                self.walkExpr(if_s.condition);
                const condition_kills = self.endKillWatch(watch);
                self.recordContextType(if_s.condition);

                // Narrow in both branches when the condition is an admitted
                // guard: if (x), if (!x), if (x !== undefined), a discriminant
                // test. The narrowing lives in the flow overlay, never in
                // `binding_types` - that map is the declared type, and
                // overwriting it is what made a narrowing impossible to kill
                // without losing the declaration.
                var narrow = self.extractNarrowingGuard(if_s.condition);
                // The guard is read from the condition's syntax, after the
                // condition ran. A kill inside the condition describes a later
                // value than the one the test compared, so it voids the guard.
                if (narrow.key) |key| {
                    if (condition_kills.contains(key)) narrow = .{};
                }

                // Each branch runs inside its own narrow scope, so every
                // narrowing written while walking it - the guard's own and any
                // a nested early return installs - is undone on the way out.
                // Restoring only the guard's key let the nested one escape and
                // describe the path where this condition was false. A kill is
                // undone too, so each branch's kills come back at the join: a
                // branch that returns reaches no code after the `if`, and its
                // kills are dropped. The else branch is walked after the then
                // scope is restored, so it does not see the then branch's kills.
                var join: KillSet = .{};
                if (narrow.key != null and narrow.narrowed_type != null_type_idx) {
                    const key = narrow.key.?;

                    const then_mark = self.beginNarrowScope();
                    // A negated guard means the then-branch runs when the test
                    // failed, so the narrowed type belongs to the else branch.
                    if (!narrow.negated) self.putNarrowed(key, narrow.narrowed_type);
                    self.walkStmt(if_s.then_branch);
                    const then_kills = self.endNarrowScope(then_mark);
                    if (!self.branchAlwaysReturns(if_s.then_branch)) join.merge(then_kills);

                    if (if_s.else_branch != null_node) {
                        const else_mark = self.beginNarrowScope();
                        const else_narrowed = if (narrow.negated) narrow.narrowed_type else narrow.else_type;
                        if (else_narrowed != null_type_idx) self.putNarrowed(key, else_narrowed);
                        self.walkStmt(if_s.else_branch);
                        const else_kills = self.endNarrowScope(else_mark);
                        if (!self.branchAlwaysReturns(if_s.else_branch)) join.merge(else_kills);
                    }
                    self.applyKills(join);

                    // Forward narrowing after early return:
                    // if (!x) { return; } narrows x to non-null after the block
                    // if (x.kind === "err") { return; } narrows x to excluded union
                    if (if_s.else_branch == null_node and self.branchAlwaysReturns(if_s.then_branch)) {
                        if (narrow.negated) {
                            self.putNarrowed(key, narrow.narrowed_type);
                        } else if (narrow.else_type != null_type_idx) {
                            self.putNarrowed(key, narrow.else_type);
                        }
                    }
                } else {
                    // A condition that installs no guard still opens a branch:
                    // a narrowing established inside it is no more valid on the
                    // way out than one installed by a guard.
                    const then_mark = self.beginNarrowScope();
                    self.walkStmt(if_s.then_branch);
                    const then_kills = self.endNarrowScope(then_mark);
                    if (!self.branchAlwaysReturns(if_s.then_branch)) join.merge(then_kills);
                    if (if_s.else_branch != null_node) {
                        const else_mark = self.beginNarrowScope();
                        self.walkStmt(if_s.else_branch);
                        const else_kills = self.endNarrowScope(else_mark);
                        if (!self.branchAlwaysReturns(if_s.else_branch)) join.merge(else_kills);
                    }
                    self.applyKills(join);
                }
            },

            .return_stmt => {
                if (self.ir_view.getOptValue(node)) |ret_val| {
                    self.walkExpr(ret_val);
                    self.checkReturnedValue(node, ret_val);
                }
            },

            .assert_stmt => {
                // Extract narrowing guard from the assert condition and install
                // it as permanent forward narrowing (no restore after).
                const assert = self.ir_view.getAssertStmt(node) orelse return;
                self.walkExpr(assert.condition);
                self.recordContextType(assert.condition);
                if (assert.error_expr != null_node) {
                    self.walkExpr(assert.error_expr);
                    // A failed `assert c, e` returns `e` from the enclosing
                    // function, so `e` answers the declared return type the
                    // way a `return e` does.
                    self.checkReturnedValue(node, assert.error_expr);
                }
                const narrow = self.extractNarrowingGuard(assert.condition);
                if (narrow.key) |key| {
                    if (narrow.narrowed_type != null_type_idx and !narrow.negated) {
                        self.putNarrowed(key, narrow.narrowed_type);
                    }
                }
            },

            .expr_stmt => {
                if (self.ir_view.getOptValue(node)) |expr| {
                    self.walkExpr(expr);
                }
            },

            .for_of_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return;
                self.walkExpr(fi.iterable);
                self.recordAbsentReceiver(node, fi.iterable);
                // The element variable of `for (const x of xs)` takes the element
                // type of an array iterable. Without it the variable had no type
                // and a boolean read of it was refused.
                self.bindForOfElement(fi);
                // Kill rule 4. A narrowing established before the loop is only
                // valid inside it if the body never reassigns the binding, and
                // a narrowing established inside the body does not survive the
                // back edge.
                self.killNarrowingsAssignedIn(fi.body, 0, false);
                // The body's scope puts back every narrowing the body changed,
                // which is the state before the body. It also undoes the kills
                // the body made, so they are applied again after the loop.
                const body_mark = self.beginNarrowScope();
                self.walkStmt(fi.body);
                self.applyKills(self.endNarrowScope(body_mark));
            },

            .function_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                const func = self.ir_view.getFunction(decl.init) orelse return;
                // The signature is the one whose parameter list opens where this
                // function's does. A name does not identify it: nested functions
                // repeat names, and the later one would win for both.
                const sig = self.sourceFunctionSignature(decl.init);
                self.bindCallableMetadata(decl.binding, sourceFunctionMetadata(func, sig));
                // Named declarations resolve signatures by binding identity.
                const saved_return = self.current_return_type;
                // A nested function has its own return contract. Leaving the
                // enclosing one in place checked an inner `return` against an
                // outer signature, which the unresolved-name fail-open used to
                // hide by accepting every such comparison.
                self.current_return_type = if (sig) |s|
                    // Proof markers (Spec/Proof/Effects capsules) are
                    // obligations for the verifier, not shapes the returned
                    // value can satisfy; compare returns against the value
                    // type only.
                    self.env.stripProofMarkers(s.return_type)
                else
                    null_type_idx;
                self.registerParamTypes(func, sig orelse .{});
                self.walkFunctionBody(decl.init, func.body);
                self.current_return_type = saved_return;
            },

            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                const sig = self.sourceFunctionSignature(node);
                const saved_return = self.current_return_type;
                // A nested function has its own return contract. Leaving the
                // enclosing one in place checked an inner `return` against an
                // outer signature, which the unresolved-name fail-open used to
                // hide by accepting every such comparison.
                self.current_return_type = if (sig) |s|
                    self.env.stripProofMarkers(s.return_type)
                else
                    null_type_idx;
                self.registerParamTypes(func, sig orelse .{});
                self.walkFunctionBody(node, func.body);
                self.current_return_type = saved_return;
            },

            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.walkStmt(export_decl.declaration);
            },

            .binary_op,
            .unary_op,
            .ternary,
            .call,
            .assignment,
            .match_expr,
            => {
                self.walkExpr(node);
            },

            // Any other tag passes each child it holds back to this walk, so a
            // new node kind is read by default.
            else => {
                var children = self.ir_view.expressionChildren(node);
                while (children.next()) |child| self.walkStmt(child);
            },
        }
    }

    // -------------------------------------------------------------------
    // Expression walking
    // -------------------------------------------------------------------

    fn walkExpr(self: *TypeChecker, node: NodeIndex) void {
        if (self.allocation_failed) return;
        self.env.pool.ensureHealthy() catch return;
        if (node == null_node) return;
        const tag = self.ir_view.getTag(node) orelse return;

        switch (tag) {
            .call => {
                const c = self.ir_view.getCall(node) orelse return;
                self.collectSchemaCompileCall(c) catch self.markAllocationFailure();
                self.reportNominalConstructorCall(node, c);
                self.reportReadonlyMutation(node, c);
                self.reportContainerMutation(node, c);
                self.walkExpr(c.callee);
                self.reportUnionMemberCall(c.callee);
                self.bindCallbackElement(c);
                if (self.closure_writes_outer) {
                    self.walkCallArgsThenKill(node, c);
                    return;
                }
                // Check argument types against function signature
                self.checkCallArgs(node, c);
                for (0..c.args_count) |i| {
                    const arg = self.ir_view.getListIndex(c.args_start, @intCast(i));
                    self.walkExpr(arg);
                }
            },

            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return;
                if (bin.op == .and_op or bin.op == .or_op) {
                    const watch = self.beginKillWatch();
                    self.walkExpr(bin.left);
                    const left_kills = self.endKillWatch(watch);
                    // The right operand runs only when the left one was true
                    // (`&&`) or false (`||`), so it is typed under that guard.
                    self.recordContextType(bin.left);
                    const mark = self.beginNarrowScope();
                    self.installBranchNarrowing(bin.left, bin.op == .and_op, left_kills);
                    self.walkExpr(bin.right);
                    self.recordContextType(bin.right);
                    // The right operand may not run, but when it does its kills
                    // hold for the code after it.
                    self.applyKills(self.endNarrowScope(mark));
                } else {
                    self.walkExpr(bin.left);
                    self.walkExpr(bin.right);
                    // The boolean checker reads an arithmetic operand's type
                    // here, with the narrowing that reaches it still live.
                    switch (bin.op) {
                        .add, .sub, .mul, .div, .mod, .pow => {
                            self.recordContextType(bin.left);
                            self.recordContextType(bin.right);
                        },
                        // exhaustive: only an arithmetic operator puts a numeric obligation on its operands.
                        else => {},
                    }
                }
                if (bin.op == .add and
                    (self.typeMayBeString(self.inferType(bin.left)) or
                        self.typeMayBeString(self.inferType(bin.right))))
                {
                    self.addDiagnostic(.{
                        .severity = .err,
                        .kind = .string_add,
                        .node = node,
                        .message = "string addition is not supported",
                        .help = "build a string array with explicit `String(...)` conversions and call `.join(\"\")`",
                    });
                }
            },

            .unary_op => {
                const un = self.ir_view.getUnary(node) orelse return;
                self.walkExpr(un.operand);
                if (un.op == .not or un.op == .neg) self.recordContextType(un.operand);
            },

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return;
                // Each branch narrows by the condition, as `&&` and `||` do. A
                // guard whose binding the condition reassigns installs nothing.
                const watch = self.beginKillWatch();
                self.walkExpr(t.condition);
                const cond_kills = self.endKillWatch(watch);
                self.recordContextType(t.condition);
                const then_mark = self.beginNarrowScope();
                self.installBranchNarrowing(t.condition, true, cond_kills);
                self.walkExpr(t.then_branch);
                const then_kills = self.endNarrowScope(then_mark);
                const else_mark = self.beginNarrowScope();
                self.installBranchNarrowing(t.condition, false, cond_kills);
                self.walkExpr(t.else_branch);
                const else_kills = self.endNarrowScope(else_mark);
                self.applyKills(then_kills);
                self.applyKills(else_kills);
            },

            .assignment => {
                const asgn = self.ir_view.getAssignment(node) orelse return;
                self.walkExpr(asgn.value);
                // Check assignment type matches target's declared type
                const target_tag = self.ir_view.getTag(asgn.target) orelse return;
                if (asgn.op == null and (target_tag == .member_access or target_tag == .computed_access)) {
                    self.reportContainerWrite(node, asgn);
                }
                if (target_tag == .identifier) {
                    const binding = self.ir_view.getBinding(asgn.target) orelse return;
                    const key = bindingKey(binding);
                    // Kill rule 1: the guard that installed the narrowing
                    // described the value being overwritten.
                    self.killNarrowing(key);
                    if (asgn.op == null) {
                        const declared = self.assignmentTargetType(binding);
                        if (declared != null_type_idx) {
                            const val_type = self.inferType(asgn.value);
                            if (val_type != null_type_idx and !self.env.isAssignableTo(val_type, declared)) {
                                self.addTypeMismatch(node, declared, val_type);
                            }
                        }
                        // A present value narrows a nullable binding to its inner
                        // type. A nullable value leaves the narrowing killed.
                        const assigned = self.inferType(asgn.value);
                        if (assigned != null_type_idx and !self.admitsUndefined(assigned)) {
                            if (self.resolveAbsentBinding(asgn.target, .undefined_only)) |nb| {
                                if (self.env.isAssignableTo(assigned, nb.inner)) self.putNarrowed(nb.key, nb.inner);
                            }
                        }
                    }
                } else if (target_tag == .member_access) {
                    // Check readonly field assignment
                    const member = self.ir_view.getMember(asgn.target) orelse return;
                    self.recordAbsentReceiver(asgn.target, member.object);
                    const obj_tag = self.ir_view.getTag(member.object) orelse return;
                    if (obj_tag == .identifier) {
                        const binding = self.ir_view.getBinding(member.object) orelse return;
                        // Through the narrowing overlay, not `binding_types`:
                        // the readonly record is usually reached by a guard
                        // (`if (v !== undefined) { v.id = "x"; }`), and reading
                        // the declaration finds the nullable node instead. A
                        // non-record tag yields no fields, so the write to a
                        // readonly field passed in silence.
                        if (self.currentBindingType(binding)) |obj_type| {
                            const prop_name = self.resolveAtomName(member.property) orelse return;
                            if (self.env.pool.lookupRecordField(obj_type, prop_name)) |field| {
                                if (field.readonly) {
                                    self.addDiagnostic(.{
                                        .severity = .err,
                                        .kind = .type_mismatch,
                                        .node = node,
                                        .message = "cannot assign to readonly property",
                                        .help = "Assign to a mutable property, or remove the readonly modifier.",
                                    });
                                }
                            }
                        }
                    }
                }
            },

            .array_literal => {
                const arr = self.ir_view.getArray(node) orelse return;
                for (0..arr.elements_count) |i| {
                    const elem = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
                    self.walkExpr(elem);
                }
            },

            .object_literal => {
                const obj = self.ir_view.getObject(node) orelse return;
                for (0..obj.properties_count) |i| {
                    const prop = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
                    // A spread member is not a property: its operand is payload
                    // word `a`, read by `getOptValue`.
                    if (self.ir_view.getTag(prop) == .object_spread) {
                        if (self.ir_view.getOptValue(prop)) |operand| self.walkExpr(operand);
                        continue;
                    }
                    const prop_data = self.ir_view.getProperty(prop) orelse continue;
                    self.walkExpr(prop_data.value);
                }
            },

            // A member read evaluates its base, and a computed read its key too.
            .member_access, .optional_chain, .computed_access => {
                const member = self.ir_view.getMember(node) orelse return;
                self.walkExpr(member.object);
                self.walkExpr(member.computed);
                self.reportDictEntryRead(node, member.object);
                if (tag == .computed_access) self.reportStringIndexRead(node, member.object);
                self.reportNonRecordMemberRead(node);
                if (tag != .optional_chain) self.recordAbsentReceiver(node, member.object);
            },

            // The spread operand is payload word `a`, read by `getOptValue`.
            .spread => {
                if (self.ir_view.getOptValue(node)) |operand| {
                    self.walkExpr(operand);
                    self.recordAbsentReceiver(node, operand);
                }
            },

            .match_expr => {
                const me = self.ir_view.getMatchExpr(node) orelse return;
                self.walkExpr(me.discriminant);
                self.walkMatchWithNarrowing(me);
                self.reportMatchCoverage(node, me);
            },

            .function_expr, .arrow_function => {
                const func = self.ir_view.getFunction(node) orelse return;
                const sig = self.sourceFunctionSignature(node);
                const saved_return = self.current_return_type;
                // A nested function has its own return contract. Leaving the
                // enclosing one in place checked an inner `return` against an
                // outer signature, which the unresolved-name fail-open used to
                // hide by accepting every such comparison.
                self.current_return_type = if (sig) |s|
                    self.env.stripProofMarkers(s.return_type)
                else
                    null_type_idx;
                self.registerParamTypes(func, sig orelse .{});
                self.walkFunctionBody(node, func.body);
                self.current_return_type = saved_return;
            },

            // A tag named above is read by its own arm. Any other tag passes
            // each child it holds back to this walk, so a call under a node
            // this walk does not name is still checked. A leaf has no child.
            else => {
                var children = self.ir_view.expressionChildren(node);
                while (children.next()) |child| self.walkExpr(child);
            },
        }
    }

    fn collectSchemaCompileCall(self: *TypeChecker, call: Node.CallExpr) !void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .identifier or call.args_count < 2) return;

        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const name = self.resolveAtomName(binding.name_atom) orelse return;
        if (!std.mem.eql(u8, name, "schemaCompile")) return;

        const schema_name_node = self.ir_view.getListIndex(call.args_start, 0);
        const schema_name = self.getLiteralString(schema_name_node) orelse return;
        const schema_json_node = self.ir_view.getListIndex(call.args_start, 1);
        const schema_json = (try self.extractSchemaJson(schema_json_node)) orelse return;
        defer self.allocator.free(schema_json);

        const type_idx = try self.schemaJsonToType(schema_json);
        if (type_idx == null_type_idx) return;

        for (self.compiled_schemas.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, schema_name)) continue;
            entry.type_idx = type_idx;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, schema_name);
        errdefer self.allocator.free(owned_name);
        try self.compiled_schemas.append(self.allocator, .{
            .name = owned_name,
            .type_idx = type_idx,
        });
    }

    fn schemaJsonToType(self: *TypeChecker, schema_json: []const u8) !TypeIndex {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => {
                self.markAllocationFailure();
                return error.OutOfMemory;
            },
            // exhaustive: a schema that is not parseable JSON yields no type,
            // which constrains nothing downstream. The one error that must not
            // be treated that way, allocation failure, is marked above.
            else => return null_type_idx,
        };
        defer parsed.deinit();
        return self.schemaValueToType(parsed.value);
    }

    fn schemaValueToType(self: *TypeChecker, value_json: std.json.Value) TypeIndex {
        const pool = self.env.pool;
        const obj = switch (value_json) {
            .object => |o| o,
            // exhaustive: a schema node that is not an object describes no
            // shape, so unknown is the honest answer - the lattice top, which
            // permits nothing to be proved from it.
            else => return pool.idx_unknown,
        };

        if (obj.get("enum")) |enum_val| {
            if (enum_val == .array and enum_val.array.items.len > 0) {
                var members: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer members.deinit(self.allocator);
                for (enum_val.array.items) |item| {
                    const member = switch (item) {
                        .string => |s| pool.addLiteralString(self.allocator, s),
                        .integer => |i| blk: {
                            const lit = std.math.cast(i16, i) orelse break :blk pool.idx_number;
                            break :blk pool.addLiteralNumber(self.allocator, lit);
                        },
                        .float => pool.idx_number,
                        .bool => |b| pool.addLiteralBool(self.allocator, b),
                        // exhaustive: a nonprimitive enum item gives no literal type.
                        else => pool.idx_unknown,
                    };
                    members.append(self.allocator, member) catch {
                        self.markAllocationFailure();
                        return pool.idx_unknown;
                    };
                }
                if (members.items.len > 0) return pool.addUnion(self.allocator, members.items);
            }
        }

        const type_name = if (obj.get("type")) |type_val|
            switch (type_val) {
                .string => |s| s,
                // exhaustive: a non-string type name is not recognized.
                else => "",
            }
        else
            "";

        if (std.mem.eql(u8, type_name, "string")) return pool.idx_string;
        if (std.mem.eql(u8, type_name, "number")) return pool.idx_number;
        if (std.mem.eql(u8, type_name, "integer")) return pool.idx_number;
        if (std.mem.eql(u8, type_name, "boolean")) return pool.idx_boolean;
        if (std.mem.eql(u8, type_name, "array")) {
            if (obj.get("items")) |items| {
                const elem = self.schemaValueToType(items);
                return pool.addArray(self.allocator, if (elem == null_type_idx) pool.idx_unknown else elem);
            }
            return pool.addArray(self.allocator, pool.idx_unknown);
        }

        if (std.mem.eql(u8, type_name, "object") or obj.get("properties") != null) {
            const props = obj.get("properties") orelse return pool.idx_unknown;
            if (props != .object) return pool.idx_unknown;

            var required: std.ArrayList([]const u8) = .empty;
            defer required.deinit(self.allocator);
            if (obj.get("required")) |required_val| {
                if (required_val == .array) {
                    for (required_val.array.items) |item| {
                        if (item != .string) continue;
                        required.append(self.allocator, item.string) catch self.markAllocationFailure();
                    }
                }
            }

            var fields: std.ArrayListUnmanaged(type_pool_mod.RecordField) = .empty;
            defer fields.deinit(self.allocator);
            var it = props.object.iterator();
            while (it.next()) |entry| {
                const prop_type = self.schemaValueToType(entry.value_ptr.*);
                const name = pool.addName(self.allocator, entry.key_ptr.*);
                fields.append(self.allocator, .{
                    .name_start = name.start,
                    .name_len = name.len,
                    .type_idx = if (prop_type == null_type_idx) pool.idx_unknown else prop_type,
                    .optional = !json_utils.containsString(required.items, entry.key_ptr.*),
                }) catch {
                    self.markAllocationFailure();
                    return pool.idx_unknown;
                };
            }
            if (fields.items.len == 0) return pool.idx_unknown;
            return pool.addRecord(self.allocator, fields.items);
        }

        return pool.idx_unknown;
    }

    fn getLiteralString(self: *const TypeChecker, node_idx: NodeIndex) ?[]const u8 {
        const str_idx = self.ir_view.getStringIdx(node_idx) orelse return null;
        return self.ir_view.getString(str_idx);
    }

    fn getJsonStringifyArg(self: *const TypeChecker, node_idx: NodeIndex) ?NodeIndex {
        const call = self.ir_view.getCall(node_idx) orelse return null;
        if (call.args_count != 1) return null;

        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
        if (callee_tag != .member_access) return null;

        const member = self.ir_view.getMember(call.callee) orelse return null;
        if (member.property != @backingInt(object.Atom.stringify)) return null;

        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        if (binding.kind != .global and binding.kind != .undeclared_global) return null;
        if (binding.name_atom != @backingInt(object.Atom.JSON)) return null;

        return self.ir_view.getListIndex(call.args_start, 0);
    }

    fn extractSchemaJson(self: *TypeChecker, node_idx: NodeIndex) !?[]u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        return switch (tag) {
            .lit_string => blk: {
                const raw = self.getLiteralString(node_idx) orelse break :blk null;
                break :blk try self.allocator.dupe(u8, raw);
            },
            .call => blk: {
                const json_arg = self.getJsonStringifyArg(node_idx) orelse break :blk null;
                break :blk try ir_json_literal.serialize(
                    self.allocator,
                    self.ir_view,
                    json_arg,
                    jsonLiteralAtomResolver,
                    self,
                );
            },
            // exhaustive: null means "not a literal the compiler can read", and
            // the caller treats an unreadable schema as dynamic rather than as
            // an absent one.
            else => null,
        };
    }

    fn getObjectPropertyKey(self: *const TypeChecker, node_idx: NodeIndex) ?[]const u8 {
        const tag = self.ir_view.getTag(node_idx) orelse return null;
        return switch (tag) {
            .lit_string => self.getLiteralString(node_idx),
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node_idx) orelse break :blk null;
                break :blk self.resolveAtomName(binding.name_atom);
            },
            // exhaustive: an object key is a string literal or a bare
            // identifier; a computed key is not statically known, and null
            // stops the literal read rather than inventing a name.
            else => null,
        };
    }

    fn schemaTypeByName(self: *const TypeChecker, name: []const u8) ?TypeIndex {
        for (self.compiled_schemas.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.type_idx;
        }
        return null;
    }

    /// The `error` type of the export named `name`, from the table in
    /// `module_result_errors.zig`. A name with no row gets `unknown`.
    fn moduleResultErrorType(self: *const TypeChecker, name: []const u8) TypeIndex {
        const pool = self.env.pool;
        const row = module_result_errors.findByName(name) orelse return pool.idx_unknown;
        return switch (row.error_type) {
            .string => pool.idx_string,
            .unknown => pool.idx_unknown,
        };
    }

    /// The `errors` type of the export named `name`: `unknown` where a runtime
    /// path fills `errors`, `never` where none does. A name with no row gets
    /// `unknown`.
    fn moduleResultErrorsType(self: *const TypeChecker, name: []const u8) TypeIndex {
        const pool = self.env.pool;
        const row = module_result_errors.findByName(name) orelse return pool.idx_unknown;
        return if (row.fills_errors) pool.idx_unknown else pool.idx_never;
    }

    /// A Result whose `value` is `inner`, whose `error` is `error_type`, and
    /// whose `errors` is `errors_type`. When `errors_type` is not `never`, the
    /// failure can sit under `errors` and leave `error` absent, so the pool
    /// adds `undefined` to `error`.
    fn typedResultType(self: *const TypeChecker, inner: TypeIndex, error_type: TypeIndex, errors_type: TypeIndex) TypeIndex {
        return self.env.pool.addTypedResult(self.allocator, inner, error_type, errors_type);
    }

    // -------------------------------------------------------------------
    // Type inference (TypePool-based)
    // -------------------------------------------------------------------

    /// Infer the TypeIndex of an expression. Returns null_type_idx for unknown.
    /// The deterministic join of spec 5.4, steps 1-5. It types `?:`, and
    /// anything else that has to pick one type for two branches.
    ///
    /// Step 2 asks for the canonical type identity from `type_key.zig`, not
    /// index equality: the pool does not intern, so two structurally identical
    /// records hold different indices, and index equality would fall through to
    /// step 3 and produce the right answer only by accident - and the wrong one
    /// as soon as a field is optional on one side.
    fn joinTypes(self: *const TypeChecker, when_true: TypeIndex, when_false: TypeIndex) TypeIndex {
        const pool = self.env.pool;

        // A refused branch makes the join refused: the mistake was reported
        // once, where the branch was refused.
        if (when_true == pool.idx_error or when_false == pool.idx_error) return pool.idx_error;

        // Outside the spec's join, which assumes both branches type: an
        // un-inferred branch contributes nothing, so defer to the other side
        // rather than widening the result to a union with a hole in it.
        if (when_true == null_type_idx) return when_false;
        if (when_false == null_type_idx) return when_true;

        // 1. Remove `never`.
        if (when_true == pool.idx_never) return when_false;
        if (when_false == pool.idx_never) return when_true;

        // 2. Structurally identical.
        if (type_key.structurallyEqual(pool, self.allocator, when_true, when_false)) return when_true;

        // Two Results join to one Result whose value, error, and errors are the joins
        // of the two. A union of records would lose the marking, and with it
        // the Result rules for a field read.
        const true_resolved = self.resolvedType(when_true);
        const false_resolved = self.resolvedType(when_false);
        if (pool.isResultRecord(true_resolved) and pool.isResultRecord(false_resolved)) {
            const true_value = self.resultFieldType(true_resolved, "value", 0);
            const false_value = self.resultFieldType(false_resolved, "value", 0);
            const true_error = self.resultFieldType(true_resolved, "error", 0);
            const false_error = self.resultFieldType(false_resolved, "error", 0);
            const true_errors = self.resultFieldType(true_resolved, "errors", 0);
            const false_errors = self.resultFieldType(false_resolved, "errors", 0);
            if (true_value != null_type_idx and false_value != null_type_idx and
                true_error != null_type_idx and false_error != null_type_idx and
                true_errors != null_type_idx and false_errors != null_type_idx)
            {
                return self.typedResultType(
                    self.joinTypes(true_value, false_value),
                    self.joinTypes(true_error, false_error),
                    self.joinTypes(true_errors, false_errors),
                );
            }
        }

        const true_to_false = pool.isAssignableTo(when_true, when_false);
        const false_to_true = pool.isAssignableTo(when_false, when_true);

        // 3. Mutually assignable: the whenTrue branch wins. A syntactic rule, so
        //    a reader reaches it without a type-identity oracle.
        if (true_to_false and false_to_true) return when_true;

        // 4. Assignable one way only: the receiving type wins.
        if (true_to_false) return when_false;
        if (false_to_true) return when_true;

        // 5. Otherwise the normalized union.
        return pool.addUnion(self.allocator, &.{ when_true, when_false });
    }

    fn inferType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        self.env.pool.ensureHealthy() catch return null_type_idx;
        if (node == null_node) return null_type_idx;
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        const pool = self.env.pool;

        return switch (tag) {
            .lit_bool => blk: {
                const val = self.ir_view.getBoolValue(node) orelse break :blk pool.idx_boolean;
                break :blk pool.addLiteralBool(self.allocator, val);
            },
            .lit_int => blk: {
                const val = self.ir_view.getIntValue(node) orelse break :blk pool.idx_number;
                const int_val = std.math.cast(i16, val) orelse break :blk pool.idx_number;
                break :blk pool.addLiteralNumber(self.allocator, int_val);
            },
            .lit_float => pool.idx_number,
            .lit_string => blk: {
                const str_idx = self.ir_view.getStringIdx(node) orelse break :blk pool.idx_string;
                const str = self.ir_view.getString(str_idx) orelse break :blk pool.idx_string;
                // A value literal too long for the name arena widens to `string`
                // (sound for a value). The pool refuses a longer literal type.
                if (str.len > std.math.maxInt(u8)) break :blk pool.idx_string;
                break :blk pool.addLiteralString(self.allocator, str);
            },
            .lit_null => pool.idx_null,
            .lit_undefined => pool.idx_undefined,
            .object_literal => self.inferObjectLiteralType(node),
            .array_literal => self.inferArrayLiteralType(node),
            // A function value has a function type with one parameter for each
            // parameter node, so a position that admits no function refuses
            // it. See `functionValueType`.
            .function_expr, .arrow_function => self.functionValueType(node),
            .function_decl => null_type_idx,

            .binary_op => self.inferBinaryType(node),
            .unary_op => self.inferUnaryType(node),

            .ternary => {
                const t = self.ir_view.getTernary(node) orelse return null_type_idx;
                return self.joinTypes(
                    self.inferType(t.then_branch),
                    self.inferType(t.else_branch),
                );
            },

            .identifier => {
                const binding = self.ir_view.getBinding(node) orelse return null_type_idx;
                const key = bindingKey(binding);
                // Check narrowing first
                if (self.narrowed.get(key)) |t| return t;
                // Check tracked binding types
                if (self.binding_types.get(key)) |t| return t;
                const declared = self.declaredTypeForBinding(binding);
                if (declared != null_type_idx) return declared;
                return self.functionBindingType(binding);
            },

            .member_access => self.inferMemberAccessType(node),

            .optional_chain => self.inferOptionalChainType(node),

            .computed_access => self.inferIndexReadType(node),

            .call => self.inferCallType(node),

            .match_expr => self.inferMatchType(node),

            // exhaustive: no inferred type. `TypePool.isAssignableTo` treats
            // null_type_idx as "inference produced no result, so skip rather
            // than reject", so an expression that lands here loses a type
            // error and gains nothing.
            else => null_type_idx,
        };
    }

    // -------------------------------------------------------------------
    // If-guard narrowing helpers
    // -------------------------------------------------------------------

    const NarrowingGuard = struct {
        /// Absent means the condition installed no guard. A `0` sentinel would
        /// make the binding at scope 0 slot 0 the one binding in the program
        /// that could never narrow.
        key: ?u64 = null,
        narrowed_type: TypeIndex = null_type_idx,
        negated: bool = false,
        /// For discriminated unions: the type to install after the then-branch
        /// returns (the union with the matched member excluded).
        else_type: TypeIndex = null_type_idx,
    };

    /// Extract a narrowing guard from an if-condition.
    /// Handles: if (x), if (!x), if (x !== undefined), if (x === undefined)
    fn extractNarrowingGuard(self: *const TypeChecker, condition: NodeIndex) NarrowingGuard {
        const tag = self.ir_view.getTag(condition) orelse return .{};

        // if (r.ok) - a bare boolean discriminant read. The `Result` idiom is
        // written this way as often as it is written `r.ok === true`, and only
        // the second form narrowed.
        if (tag == .member_access) {
            // `if (r.ok)` runs its then-branch when the field is true, so the
            // member being selected is the one whose discriminant is `true`.
            // The `!` form is handled by the negation wrapper below, which
            // swaps the two sides rather than asking for a different member.
            if (self.extractBooleanDiscriminantGuard(condition, true)) |guard| return guard;
        }

        // if (Array.isArray(x)), or a call to an admitted type predicate
        if (tag == .call) {
            if (self.extractIsArrayGuard(condition)) |guard| return guard;
            if (self.extractIsDictGuard(condition)) |guard| return guard;
            if (self.extractIsBytesGuard(condition)) |guard| return guard;
            if (self.extractTypePredicateGuard(condition)) |guard| return guard;
        }

        // if (x !== undefined), if (x === undefined), or if (x.prop === "literal")
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(condition) orelse return .{};
            if (bin.op != .strict_neq and bin.op != .strict_eq) return .{};

            const lhs_tag = self.ir_view.getTag(bin.left) orelse return .{};
            const rhs_tag = self.ir_view.getTag(bin.right) orelse return .{};

            // Pattern: x === undefined / x !== undefined, and the same shape
            // over `null`. Spec 5.3 makes the explicit comparison the way a
            // type carrying `null` is taken apart, so each test removes only
            // the value it names.
            const absent_kind: ?AbsentKind = blk: {
                if ((lhs_tag == .identifier and rhs_tag == .lit_undefined) or
                    (rhs_tag == .identifier and lhs_tag == .lit_undefined)) break :blk .undefined_only;
                if ((lhs_tag == .identifier and rhs_tag == .lit_null) or
                    (rhs_tag == .identifier and lhs_tag == .lit_null)) break :blk .null_only;
                break :blk null;
            };
            if (absent_kind) |kind| {
                const ident_node = if (lhs_tag == .identifier) bin.left else bin.right;
                const r = self.resolveAbsentBinding(ident_node, kind) orelse return .{};
                return .{
                    .key = r.key,
                    .narrowed_type = r.inner,
                    .negated = bin.op == .strict_eq, // === undefined is negated (narrows in else)
                };
            }

            // Pattern: typeof x === "string". This test lived only in
            // `bool_checker`'s coarse `ExprType` lattice, so the profile's
            // closed narrowing list had an entry the authoritative system
            // could not answer.
            if (self.extractTypeofGuard(bin)) |guard| return guard;

            // Pattern: x.prop === <literal> (discriminated union narrowing)
            const lhs_is_literal = lhs_tag == .lit_string or lhs_tag == .lit_int or lhs_tag == .lit_bool;
            const rhs_is_literal = rhs_tag == .lit_string or rhs_tag == .lit_int or rhs_tag == .lit_bool;
            if ((lhs_tag == .member_access and rhs_is_literal) or
                (rhs_tag == .member_access and lhs_is_literal))
            {
                const member_node = if (lhs_tag == .member_access) bin.left else bin.right;
                const literal_node = if (lhs_is_literal) bin.left else bin.right;
                if (self.extractDiscriminantGuard(member_node, literal_node, bin.op)) |guard| {
                    return guard;
                }
            }
        }

        // `!` of any admitted test. `if (!r.ok) return;` is the shape the
        // Result idiom depends on, and before this only `!x` on a nullable
        // binding was recognized.
        if (tag == .unary_op) {
            const un = self.ir_view.getUnary(condition) orelse return .{};
            if (un.op != .not) return .{};
            var inner = self.extractNarrowingGuard(un.operand);
            if (inner.key == null) return .{};
            inner.negated = !inner.negated;
            // The two sides swap with the sense of the test, so a discriminant
            // guard keeps describing the branch it actually applies to.
            const then_type = inner.narrowed_type;
            if (inner.else_type != null_type_idx) {
                inner.narrowed_type = inner.else_type;
                inner.else_type = then_type;
                inner.negated = !inner.negated;
            }
            return inner;
        }

        return .{};
    }

    /// Install the narrowing that holds where `condition` evaluated to `sense`.
    /// The caller opens a narrow scope first and closes it after the code the
    /// narrowing covers, so nothing installed here outlives that code.
    ///
    /// A conjunction that is true holds both sides, and a disjunction that is
    /// false fails both sides. A conjunction that is false, or a disjunction
    /// that is true, says only that one side did, so it installs nothing. Any
    /// other condition installs what its guard says for that sense: the
    /// narrowed type when the guard describes the true branch, the else type
    /// when it describes the false branch.
    ///
    /// The guard is read from the syntax of a condition that already ran. A key
    /// in `killed` was killed while it ran, so its guard describes a value the
    /// binding no longer holds, and nothing is installed for it.
    fn installBranchNarrowing(self: *TypeChecker, condition: NodeIndex, sense: bool, killed: KillSet) void {
        const tag = self.ir_view.getTag(condition) orelse return;
        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(condition) orelse return;
            if ((bin.op == .and_op and sense) or (bin.op == .or_op and !sense)) {
                self.installBranchNarrowing(bin.left, sense, killed);
                // The right side is only reached once the left side held.
                self.installBranchNarrowing(bin.right, sense, killed);
                return;
            }
        }
        const guard = self.extractNarrowingGuard(condition);
        const key = guard.key orelse return;
        if (killed.contains(key)) return;
        const narrowed = if (sense)
            (if (guard.negated) null_type_idx else guard.narrowed_type)
        else
            (if (guard.negated) guard.narrowed_type else guard.else_type);
        if (narrowed == null_type_idx) return;
        self.putNarrowed(key, narrowed);
    }

    /// `typeof x === "string"` and its `!==` form, over a binding whose type is
    /// a union. Members matching the named primitive stay in the then branch,
    /// the rest go to the else branch.
    fn extractTypeofGuard(self: *const TypeChecker, bin: anytype) ?NarrowingGuard {
        const lhs_tag = self.ir_view.getTag(bin.left) orelse return null;
        const rhs_tag = self.ir_view.getTag(bin.right) orelse return null;

        const typeof_node, const literal_node = if (lhs_tag == .unary_op and rhs_tag == .lit_string)
            .{ bin.left, bin.right }
        else if (rhs_tag == .unary_op and lhs_tag == .lit_string)
            .{ bin.right, bin.left }
        else
            return null;

        const un = self.ir_view.getUnary(typeof_node) orelse return null;
        if (un.op != .typeof_op) return null;
        if (self.ir_view.getTag(un.operand) != .identifier) return null;

        const binding = self.ir_view.getBinding(un.operand) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const wanted = self.getLiteralString(literal_node) orelse return null;
        const pool = self.env.pool;

        // An unknown value has no members to partition, so the test refines it
        // to the primitive it names in the branch where the test held. The
        // other branch learns nothing: an unknown value that is not a string
        // is still unknown.
        if (pool.getTag(current) == .t_unknown_type) {
            const refined = if (std.mem.eql(u8, wanted, "string"))
                pool.idx_string
            else if (std.mem.eql(u8, wanted, "number"))
                pool.idx_number
            else if (std.mem.eql(u8, wanted, "boolean"))
                pool.idx_boolean
            else if (std.mem.eql(u8, wanted, "undefined"))
                pool.idx_undefined
            else
                return null;
            return .{
                .key = key,
                .narrowed_type = refined,
                .negated = bin.op == .strict_neq,
            };
        }

        // Heap, not a sixteen-slot scratch buffer: a union wider than that is
        // representable and routine, and bailing out left it unnarrowable.
        var matched: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer matched.deinit(self.allocator);
        var rest: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer rest.deinit(self.allocator);

        const members = if (pool.getTag(current) == .t_union)
            pool.getUnionMembers(current)
        else
            &[_]TypeIndex{current};

        for (members) |candidate| {
            const hit = typeofNameOf(pool, candidate);
            const is_match = hit != null and std.mem.eql(u8, hit.?, wanted);
            if (is_match) {
                matched.append(self.allocator, candidate) catch return null;
            } else {
                rest.append(self.allocator, candidate) catch return null;
            }
        }
        if (matched.items.len == 0 or rest.items.len == 0) return null;

        return .{
            .key = key,
            .narrowed_type = pool.addUnion(self.allocator, matched.items),
            .negated = bin.op == .strict_neq,
            .else_type = pool.addUnion(self.allocator, rest.items),
        };
    }

    /// What `typeof` answers for a type, or null when the type has no single
    /// answer. A union member with no answer never matches, which keeps it on
    /// the else side rather than silently joining the narrowed branch.
    fn typeofNameOf(pool: *const TypePool, idx: TypeIndex) ?[]const u8 {
        return switch (pool.getTag(idx) orelse return null) {
            .t_string, .t_literal_string, .t_template_literal => "string",
            .t_number, .t_literal_number => "number",
            .t_boolean, .t_literal_bool => "boolean",
            .t_undefined, .t_void => "undefined",
            .t_function => "function",
            .t_record, .t_array, .t_tuple, .t_null => "object",
            // exhaustive: the remaining tags have no single `typeof` answer - a
            // generic parameter, an unresolved ref, an intersection, and a template
            // literal each stand for more than one runtime shape. Answering null
            // keeps such a member on the else side of the test, which is the
            // direction that cannot claim a narrowing the test did not prove.
            else => null,
        };
    }

    /// `if (r.ok)` over a union discriminated by a boolean field. Reuses the
    /// literal-discriminant machinery with the literal supplied rather than
    /// parsed, since there is no literal node to read.
    fn extractBooleanDiscriminantGuard(
        self: *const TypeChecker,
        member_node: NodeIndex,
        expect: bool,
    ) ?NarrowingGuard {
        const member = self.ir_view.getMember(member_node) orelse return null;
        if (self.ir_view.getTag(member.object) != .identifier) return null;

        const binding = self.ir_view.getBinding(member.object) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;
        if (self.env.pool.getTag(current) != .t_union) return null;

        const prop_name = self.resolveAtomName(member.property) orelse return null;
        const wanted = self.env.pool.addLiteralBool(self.allocator, expect);
        const opposite = self.env.pool.addLiteralBool(self.allocator, !expect);

        // The field has to be an actual discriminant before reading it can
        // select a member: every member must carry it, exactly one must fix it
        // to the value the branch tests for, and every other must fix it to the
        // opposite. Taking the first literal match instead treated any
        // `if (obj.field)` as a discriminant test, so in
        // `{ on: true, a: string } | { on: boolean, b: string }` the guard
        // selected the first member even though the second can also have
        // `on === true`, and `c.b` in the then-branch reported a missing
        // property on a correct program. A plain `boolean` field fixes nothing
        // and now installs no guard at all.
        var selected: TypeIndex = null_type_idx;
        for (self.env.pool.getUnionMembers(current)) |candidate| {
            const field = self.env.pool.lookupRecordField(candidate, prop_name) orelse return null;
            if (self.mutuallyAssignable(field.type_idx, wanted)) {
                if (selected != null_type_idx) return null;
                selected = candidate;
                continue;
            }
            if (!self.mutuallyAssignable(field.type_idx, opposite)) return null;
        }
        if (selected == null_type_idx) return null;

        return .{
            .key = key,
            .narrowed_type = selected,
            .negated = false,
            .else_type = self.env.pool.excludeUnionMember(self.allocator, current, selected),
        };
    }

    fn mutuallyAssignable(self: *const TypeChecker, a: TypeIndex, b: TypeIndex) bool {
        return self.env.isAssignableTo(a, b) and self.env.isAssignableTo(b, a);
    }

    // -------------------------------------------------------------------
    // Type predicates (`function isText(v: unknown): v is string`)
    //
    // The annotation is a claim, not a proof. A predicate installs a narrowing
    // at its call sites only when its body is a single `return` of tests this
    // checker can already verify - the closed narrowing list over the named
    // parameter, combined with `&&`, `||`, and `!`. Any other body keeps the
    // declaration and raises ZTS211, because a guard the compiler cannot check
    // is a narrowing the author asserted and nothing confirmed.
    // -------------------------------------------------------------------

    /// `module_level` stays true only through the program, its blocks, and
    /// export wrappers. Every other node passes false to its children, so a
    /// predicate on a function reached through a function body, an `if`, a
    /// loop, or an expression is refused and not ignored.
    fn admitTypePredicates(self: *TypeChecker, node: NodeIndex, depth: u8, module_level: bool) void {
        if (depth > 200) return;
        const tag = self.ir_view.getTag(node) orelse return;
        switch (tag) {
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return;
                for (0..block.stmts_count) |i| {
                    self.admitTypePredicates(self.ir_view.getListIndex(block.stmts_start, @intCast(i)), depth + 1, module_level);
                }
            },
            .export_decl => {
                const export_decl = self.ir_view.getExportDecl(node) orelse return;
                self.admitTypePredicates(export_decl.declaration, depth + 1, module_level);
            },
            .function_decl, .var_decl => {
                const decl = self.ir_view.getVarDecl(node) orelse return;
                const init_tag = self.ir_view.getTag(decl.init) orelse return;
                const init_is_function = init_tag == .arrow_function or init_tag == .function_expr;
                if (tag == .function_decl and module_level) {
                    self.admitOneTypePredicate(node);
                } else if (init_is_function) {
                    const name = self.resolveAtomName(decl.binding.name_atom) orelse "<anonymous>";
                    self.refuseMisplacedPredicate(node, decl.init, name);
                }
                // The function is read through its own node only when it has
                // no binding to name it, so one predicate is reported once.
                if (init_is_function) {
                    var children = self.ir_view.expressionChildren(decl.init);
                    while (children.next()) |child| self.admitTypePredicates(child, depth + 1, false);
                } else {
                    self.admitTypePredicates(decl.init, depth + 1, false);
                }
            },
            .function_expr, .arrow_function => {
                self.refuseMisplacedPredicate(node, node, "<anonymous>");
                var children = self.ir_view.expressionChildren(node);
                while (children.next()) |child| self.admitTypePredicates(child, depth + 1, false);
            },
            // Any other tag passes each child it holds back to this walk, so a
            // new node kind is read by default.
            else => {
                var children = self.ir_view.expressionChildren(node);
                while (children.next()) |child| self.admitTypePredicates(child, depth + 1, false);
            },
        }
    }

    /// A predicate on a function that is not a named module-level declaration
    /// installs no narrowing. It is refused here, once, and not left silent.
    fn refuseMisplacedPredicate(self: *TypeChecker, report_at: NodeIndex, function_node: NodeIndex, name: []const u8) void {
        const sig = self.sourceFunctionSignature(function_node) orelse return;
        if (sig.type_predicate == null and !sig.type_predicate_unbound) return;
        self.addGenericDiagnostic(
            .invalid_type_predicate,
            report_at,
            "type predicate '{s}' must be a named module-level function declaration",
            .{name},
            "a type predicate is not a named module-level function declaration",
            "Declare the predicate as a function declaration at module level, or return boolean.",
        );
    }

    fn admitOneTypePredicate(self: *TypeChecker, node: NodeIndex) void {
        const decl = self.ir_view.getVarDecl(node) orelse return;
        const func = self.ir_view.getFunction(decl.init) orelse return;
        const fn_name = self.resolveAtomName(decl.binding.name_atom) orelse return;
        if (self.sourceFunctionSignature(decl.init)) |own| {
            if (own.type_predicate_unbound) {
                self.addGenericDiagnostic(
                    .invalid_type_predicate,
                    node,
                    "type predicate on '{s}' does not name an annotated parameter of '{s}'",
                    .{ fn_name, fn_name },
                    "a type predicate does not name an annotated parameter",
                    "Name an annotated parameter of the function before 'is'.",
                );
                return;
            }
        }
        const sig = self.env.getSourceFnSigByName(fn_name) orelse return;
        const predicate = sig.type_predicate orelse return;
        if (predicate.param_index >= func.params_count) return;

        const param_idx = self.ir_view.getListIndex(func.params_start, predicate.param_index);
        const param_binding = self.ir_view.paramBinding(param_idx) orelse return;

        // The guard extractors read the parameter's declared type, so register
        // the parameters for the length of the check and unwind after.
        self.registerParamTypes(func, sig);

        if (self.predicateBodyProves(func.body, param_binding)) {
            // The form is admitted. The claim must also follow from the test:
            // `typeof x === "number"` is a well-formed test that proves
            // `number`, and it must not back `x is string`.
            const proven = self.predicateProvenType(func.body, param_binding);
            if (self.env.isAssignableTo(proven, predicate.narrowed)) {
                self.admitted_predicates.put(self.allocator, fn_name, {}) catch self.markAllocationFailure();
                return;
            }
            var buf: [256]u8 = undefined;
            const claimed_str = self.env.pool.formatType(predicate.narrowed, buf[0..128]);
            const proven_str = self.env.pool.formatType(proven, buf[128..256]);
            self.addGenericDiagnostic(
                .invalid_type_predicate,
                node,
                "type predicate '{s}' claims '{s}', but its test proves '{s}'",
                .{ fn_name, claimed_str, proven_str },
                "a type predicate claims a type its test does not prove",
                "Claim the type the test proves, or change the test to prove the claimed type.",
            );
            return;
        }
        self.addGenericDiagnostic(
            .invalid_type_predicate,
            node,
            "type predicate '{s}' is not verified by its body",
            .{fn_name},
            "a type predicate is not verified by its body",
            "Return one admitted narrowing test over the named parameter, combined with &&, || or !.",
        );
    }

    /// True when the body is exactly `return <admitted test tree>`.
    fn predicateBodyProves(self: *const TypeChecker, body: NodeIndex, param: ir.BindingRef) bool {
        var statement = body;
        if (self.ir_view.getTag(body) == .block) {
            const block = self.ir_view.getBlock(body) orelse return false;
            if (block.stmts_count != 1) return false;
            statement = self.ir_view.getListIndex(block.stmts_start, 0);
        }
        if (self.ir_view.getTag(statement) != .return_stmt) return false;
        const value = self.ir_view.getOptValue(statement) orelse return false;
        return self.predicateTestProves(value, param, 0);
    }

    /// The type the returned test proves for the parameter when it is true.
    /// The body already passed `predicateBodyProves`, so it is one `return`.
    /// Every narrowing written here is undone before this returns.
    fn predicateProvenType(self: *TypeChecker, body: NodeIndex, param: ir.BindingRef) TypeIndex {
        var statement = body;
        if (self.ir_view.getTag(body) == .block) {
            const block = self.ir_view.getBlock(body) orelse return self.env.pool.idx_unknown;
            if (block.stmts_count != 1) return self.env.pool.idx_unknown;
            statement = self.ir_view.getListIndex(block.stmts_start, 0);
        }
        const value = self.ir_view.getOptValue(statement) orelse return self.env.pool.idx_unknown;
        const mark = self.beginNarrowScope();
        const proven = self.provenTypeOfTest(value, true, param, 0);
        _ = self.endNarrowScope(mark);
        return proven;
    }

    /// The type of the parameter where `node` evaluated to `sense`. A side that
    /// the test does not constrain leaves the parameter's current type. Nothing
    /// that cannot be computed is read as proven: it answers `unknown`.
    fn provenTypeOfTest(self: *TypeChecker, node: NodeIndex, sense: bool, param: ir.BindingRef, depth: u8) TypeIndex {
        const pool = self.env.pool;
        if (depth > 16) return pool.idx_unknown;
        const tag = self.ir_view.getTag(node) orelse return pool.idx_unknown;

        if (tag == .unary_op) {
            const un = self.ir_view.getUnary(node) orelse return pool.idx_unknown;
            if (un.op == .not) return self.provenTypeOfTest(un.operand, !sense, param, depth + 1);
        }

        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(node) orelse return pool.idx_unknown;
            if (bin.op == .and_op or bin.op == .or_op) {
                // `&&` that is true and `||` that is false hold both sides, the
                // right one after the left. The other two senses hold one side.
                const both = (bin.op == .and_op) == sense;
                if (both) {
                    self.installBranchNarrowing(bin.left, sense, .{});
                    return self.provenTypeOfTest(bin.right, sense, param, depth + 1);
                }
                const left_mark = self.beginNarrowScope();
                const left = self.provenTypeOfTest(bin.left, sense, param, depth + 1);
                _ = self.endNarrowScope(left_mark);
                const right_mark = self.beginNarrowScope();
                self.installBranchNarrowing(bin.left, !sense, .{});
                const right = self.provenTypeOfTest(bin.right, sense, param, depth + 1);
                _ = self.endNarrowScope(right_mark);
                return pool.addUnion(self.allocator, &.{ left, right });
            }
            // `p === "a"` proves "a" when true, and `p !== "a"` when false.
            const equal = bin.op == .strict_eq;
            if ((bin.op == .strict_eq or bin.op == .strict_neq) and equal == sense) {
                if (self.literalEqualityType(bin, param)) |literal| return literal;
            }
        }

        const mark = self.beginNarrowScope();
        defer _ = self.endNarrowScope(mark);
        self.installBranchNarrowing(node, sense, .{});
        const key = bindingKey(param);
        const result = self.narrowed.get(key) orelse self.currentBindingType(param) orelse pool.idx_unknown;
        return if (result == null_type_idx) pool.idx_unknown else result;
    }

    /// For `p === <literal>` (either order): the type of that literal. Only a bare identifier operand is read here; a property
    /// read off the parameter goes through the guard extractor.
    fn literalEqualityType(self: *TypeChecker, bin: anytype, param: ir.BindingRef) ?TypeIndex {
        const left_tag = self.ir_view.getTag(bin.left) orelse return null;
        const right_tag = self.ir_view.getTag(bin.right) orelse return null;
        const operand, const literal = if (left_tag == .identifier)
            .{ bin.left, bin.right }
        else if (right_tag == .identifier)
            .{ bin.right, bin.left }
        else
            return null;
        const binding = self.ir_view.getBinding(operand) orelse return null;
        if (bindingKey(binding) != bindingKey(param)) return null;
        const literal_tag = self.ir_view.getTag(literal) orelse return null;
        switch (literal_tag) {
            .lit_string, .lit_int, .lit_bool, .lit_undefined, .lit_null => {},
            // exhaustive: only a literal or an absent-value sentinel has a
            // type this equality proves.
            else => return null,
        }
        const literal_type = self.inferType(literal);
        return if (literal_type == null_type_idx) null else literal_type;
    }

    fn predicateTestProves(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef, depth: u8) bool {
        if (depth > 16) return false;
        const tag = self.ir_view.getTag(node) orelse return false;

        if (tag == .binary_op) {
            const bin = self.ir_view.getBinary(node) orelse return false;
            if (bin.op == .and_op or bin.op == .or_op) {
                return self.predicateTestProves(bin.left, param, depth + 1) and
                    self.predicateTestProves(bin.right, param, depth + 1);
            }
        }
        if (tag == .unary_op) {
            const un = self.ir_view.getUnary(node) orelse return false;
            if (un.op == .not) return self.predicateTestProves(un.operand, param, depth + 1);
        }

        // A leaf must be one of the tests in the closed narrowing list, over the
        // parameter the predicate names. The check is on the form of the test,
        // not on whether that test would narrow this particular declared type:
        // `typeof x === "object"` over `x: unknown` narrows nothing today
        // because `unknown` is not a union, and it is still exactly the test the
        // predicate is allowed to be made of. A call to another function, a
        // comparison between two other values, or a bare `true` is not.
        return self.predicateLeafTestsParam(node, param);
    }

    fn predicateLeafTestsParam(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        switch (tag) {
            // A bare boolean discriminant read may prove a predicate. A bare
            // identifier is not a test in the boolean-only profile.
            .member_access => return self.operandNamesParam(node, param),
            // `Array.isArray(x)`
            .call => {
                const call = self.ir_view.getCall(node) orelse return false;
                if (call.args_count != 1) return false;
                if (self.ir_view.getTag(call.callee) != .member_access) return false;
                const callee = self.ir_view.getMember(call.callee) orelse return false;
                if (self.ir_view.getTag(callee.object) != .identifier) return false;
                const object_binding = self.ir_view.getBinding(callee.object) orelse return false;
                const object_name = self.resolveAtomName(object_binding.name_atom) orelse return false;
                if (!std.mem.eql(u8, object_name, "Array")) return false;
                const method = self.resolveAtomName(callee.property) orelse return false;
                if (!std.mem.eql(u8, method, "isArray")) return false;
                const arg = self.ir_view.getListIndex(call.args_start, 0);
                return self.operandNamesParam(arg, param);
            },
            // `typeof x === "..."`, `x === undefined`, `x.kind === "..."`, and
            // the `!==` form of each.
            .binary_op => {
                const bin = self.ir_view.getBinary(node) orelse return false;
                if (bin.op != .strict_eq and bin.op != .strict_neq) return false;
                const left_names = self.operandNamesParam(bin.left, param);
                const right_names = self.operandNamesParam(bin.right, param);
                if (left_names == right_names) return false;
                const other = if (left_names) bin.right else bin.left;
                return self.isComparableLiteral(other);
            },
            // exhaustive: every other expression form is outside the closed
            // narrowing list, so it cannot be part of a verified predicate.
            else => return false,
        }
    }

    /// True when the expression is the named parameter, `typeof` of it, or a
    /// property read off it - the three ways an admitted test mentions its
    /// subject.
    fn operandNamesParam(self: *const TypeChecker, node: NodeIndex, param: ir.BindingRef) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        const target: NodeIndex = switch (tag) {
            .identifier => node,
            .member_access => blk: {
                const member = self.ir_view.getMember(node) orelse return false;
                break :blk member.object;
            },
            .unary_op => blk: {
                const un = self.ir_view.getUnary(node) orelse return false;
                if (un.op != .typeof_op) return false;
                break :blk un.operand;
            },
            // exhaustive: nothing else denotes the parameter directly.
            else => return false,
        };
        if (self.ir_view.getTag(target) != .identifier) return false;
        const binding = self.ir_view.getBinding(target) orelse return false;
        return bindingKey(binding) == bindingKey(param);
    }

    fn isComparableLiteral(self: *const TypeChecker, node: NodeIndex) bool {
        return switch (self.ir_view.getTag(node) orelse return false) {
            .lit_string, .lit_int, .lit_bool, .lit_undefined => true,
            // exhaustive: an admitted test compares against a literal or the
            // absent-value sentinel. Anything else is a value the compiler
            // cannot enumerate, so the comparison proves nothing.
            else => false,
        };
    }

    /// The predicate a call installs, when the callee is an admitted one and
    /// the narrowed argument is a plain identifier.
    fn extractTypePredicateGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (self.ir_view.getTag(call.callee) != .identifier) return null;
        const callee_binding = self.ir_view.getBinding(call.callee) orelse return null;
        const fn_name = self.resolveAtomName(callee_binding.name_atom) orelse return null;
        if (!self.admitted_predicates.contains(fn_name)) return null;

        const sig = self.env.getSourceFnSigByName(fn_name) orelse return null;
        const predicate = sig.type_predicate orelse return null;
        if (predicate.param_index >= call.args_count) return null;

        const arg = self.ir_view.getListIndex(call.args_start, predicate.param_index);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);

        // The else branch keeps whatever the narrowed type does not cover, and
        // only a union says what that is.
        const current = self.currentBindingType(binding) orelse null_type_idx;
        const else_type = if (self.env.pool.getTag(current) == .t_union)
            self.env.pool.excludeUnionMember(self.allocator, current, predicate.narrowed)
        else
            null_type_idx;

        return .{
            .key = key,
            .narrowed_type = predicate.narrowed,
            .negated = false,
            .else_type = else_type,
        };
    }

    /// `if (Array.isArray(x))`. Narrows to the union members that are arrays or
    /// tuples; when no member is, the guard is not installed rather than
    /// narrowing to `never`.
    fn extractIsArrayGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (call.args_count != 1) return null;
        if (self.ir_view.getTag(call.callee) != .member_access) return null;

        const callee = self.ir_view.getMember(call.callee) orelse return null;
        if (self.ir_view.getTag(callee.object) != .identifier) return null;
        const object_binding = self.ir_view.getBinding(callee.object) orelse return null;
        const object_name = self.resolveAtomName(object_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, object_name, "Array")) return null;
        // A shadowed `Array` is a different value. A declared binding has a
        // tracked type; the global does not.
        if (self.binding_types.get(bindingKey(object_binding)) != null) return null;
        const method = self.resolveAtomName(callee.property) orelse return null;
        if (!std.mem.eql(u8, method, "isArray")) return null;

        const arg = self.ir_view.getListIndex(call.args_start, 0);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            .t_array, .t_tuple => return .{ .key = key, .narrowed_type = current, .negated = false },
            .t_union => {
                // Heap, for the same reason as the other two guards.
                var arrays: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer arrays.deinit(self.allocator);
                var others: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer others.deinit(self.allocator);
                for (pool.getUnionMembers(current)) |candidate| {
                    const is_array = switch (pool.getTag(candidate) orelse continue) {
                        .t_array, .t_tuple => true,
                        // exhaustive: keep every other member outside the array branch.
                        else => false,
                    };
                    if (is_array) {
                        arrays.append(self.allocator, candidate) catch return null;
                    } else {
                        others.append(self.allocator, candidate) catch return null;
                    }
                }
                if (arrays.items.len == 0) return null;
                return .{
                    .key = key,
                    .narrowed_type = pool.addUnion(self.allocator, arrays.items),
                    .negated = false,
                    .else_type = if (others.items.len == 0)
                        null_type_idx
                    else
                        pool.addUnion(self.allocator, others.items),
                };
            },
            // exhaustive: `Array.isArray` can only narrow a type that has an array
            // somewhere in it. A record, a primitive, or a function is never an
            // array, so the honest answer is no guard rather than a narrowing to
            // `never` that would make the branch unreachable by construction.
            else => return null,
        }
    }

    /// `isDict(x)` - the intrinsic guard spec 5.7 names, narrowing a union to
    /// its Dict members. It is a global call rather than a method call, which
    /// is the only shape difference from `Array.isArray`; the narrowing it
    /// installs is the same partition.
    fn extractIsDictGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (call.args_count != 1) return null;
        if (self.ir_view.getTag(call.callee) != .identifier) return null;

        const callee_binding = self.ir_view.getBinding(call.callee) orelse return null;
        const callee_name = self.resolveAtomName(callee_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, callee_name, "isDict")) return null;
        // A shadowed `isDict` is a different function, and a declared binding
        // has a tracked type where the intrinsic does not.
        if (self.binding_types.get(bindingKey(callee_binding)) != null) return null;

        const arg = self.ir_view.getListIndex(call.args_start, 0);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            .t_dict => return .{ .key = key, .narrowed_type = current, .negated = false },
            // A guard over `unknown` refines it, which is what an intrinsic
            // type guard is for: after `isDict(x)` is true, `x` is a Dict. The
            // union case below partitions members; there are none here, and
            // answering "no guard" would leave the value unusable at exactly
            // the site the guard was written for - a parsed JSON document.
            .t_unknown_type => return .{
                .key = key,
                .narrowed_type = pool.addDict(self.allocator, pool.idx_unknown, pool.idx_unknown),
                .negated = false,
            },
            .t_union => {
                var dicts: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer dicts.deinit(self.allocator);
                var others: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer others.deinit(self.allocator);
                for (pool.getUnionMembers(current)) |candidate| {
                    if (pool.getTag(candidate) == .t_dict) {
                        dicts.append(self.allocator, candidate) catch return null;
                    } else {
                        others.append(self.allocator, candidate) catch return null;
                    }
                }
                if (dicts.items.len == 0) return null;
                return .{
                    .key = key,
                    .narrowed_type = pool.addUnion(self.allocator, dicts.items),
                    .negated = false,
                    .else_type = if (others.items.len == 0)
                        null_type_idx
                    else
                        pool.addUnion(self.allocator, others.items),
                };
            },
            // exhaustive: same reasoning as the array guard - a type with no
            // Dict in it narrows to nothing, and answering `never` would make
            // the guarded branch unreachable by construction.
            else => return null,
        }
    }

    /// `isBytes(x)` - the intrinsic guard for `Bytes` (spec 6.3). Same shape
    /// as `isDict`: a global call, partitioning a union and refining `unknown`.
    ///
    /// The `unknown` case is not a convenience. A `Result`-returning export
    /// types its payload as `unknown`, so the guard is written at exactly the
    /// site where a member-less union would leave the value unusable - a body
    /// read off a request, or a decoded payload.
    fn extractIsBytesGuard(self: *const TypeChecker, call_node: NodeIndex) ?NarrowingGuard {
        const call = self.ir_view.getCall(call_node) orelse return null;
        if (call.args_count != 1) return null;
        if (self.ir_view.getTag(call.callee) != .identifier) return null;

        const callee_binding = self.ir_view.getBinding(call.callee) orelse return null;
        const callee_name = self.resolveAtomName(callee_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, callee_name, "isBytes")) return null;
        // A shadowed `isBytes` is a different function, and a declared binding
        // has a tracked type where the intrinsic does not.
        if (self.binding_types.get(bindingKey(callee_binding)) != null) return null;

        const arg = self.ir_view.getListIndex(call.args_start, 0);
        if (self.ir_view.getTag(arg) != .identifier) return null;
        const binding = self.ir_view.getBinding(arg) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;

        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            .t_bytes => return .{ .key = key, .narrowed_type = current, .negated = false },
            .t_unknown_type => return .{
                .key = key,
                .narrowed_type = pool.idx_bytes,
                .negated = false,
            },
            .t_union => {
                var matched: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer matched.deinit(self.allocator);
                var others: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer others.deinit(self.allocator);
                for (pool.getUnionMembers(current)) |candidate| {
                    if (pool.getTag(candidate) == .t_bytes) {
                        matched.append(self.allocator, candidate) catch return null;
                    } else {
                        others.append(self.allocator, candidate) catch return null;
                    }
                }
                if (matched.items.len == 0) return null;
                return .{
                    .key = key,
                    .narrowed_type = pool.addUnion(self.allocator, matched.items),
                    .negated = false,
                    .else_type = if (others.items.len == 0)
                        null_type_idx
                    else
                        pool.addUnion(self.allocator, others.items),
                };
            },
            // exhaustive: same reasoning as the array and Dict guards - a type
            // with no Bytes in it narrows to nothing, and answering `never`
            // would make the guarded branch unreachable by construction.
            else => return null,
        }
    }

    const NullableBinding = struct { key: u64, inner: TypeIndex };

    /// Which absent value a guard removes. Spec 5.3 keeps `null` and
    /// `undefined` distinct, so a test against one of them says nothing about
    /// the other: over `string | null | undefined`, `v !== undefined` leaves
    /// `string | null` and not `string`. `.either` is for truthiness, which is
    /// the one test that excludes both.
    const AbsentKind = enum {
        undefined_only,
        null_only,
        either,

        fn removes(self: AbsentKind, tag: type_pool_mod.TypeTag) bool {
            return switch (self) {
                .undefined_only => tag == .t_undefined,
                .null_only => tag == .t_null,
                .either => tag == .t_undefined or tag == .t_null,
            };
        }
    };

    /// If `ident_node` is an identifier bound to a type that may be absent in
    /// the way `kind` names, return its binding key and the type left after
    /// that absence is removed.
    fn resolveAbsentBinding(self: *const TypeChecker, ident_node: NodeIndex, kind: AbsentKind) ?NullableBinding {
        const binding = self.ir_view.getBinding(ident_node) orelse return null;
        const key = bindingKey(binding);
        const current = self.currentBindingType(binding) orelse return null;
        const inner = self.removeAbsence(current, kind) orelse return null;
        return .{ .key = key, .inner = inner };
    }

    /// The type left when the absence that `kind` names is removed from
    /// `current`, or null when `current` is not a type that may be absent in
    /// that way.
    fn removeAbsence(self: *const TypeChecker, current: TypeIndex, kind: AbsentKind) ?TypeIndex {
        const pool = self.env.pool;
        switch (pool.getTag(current) orelse return null) {
            // `t_nullable` is `T | undefined`. It carries no `null`, so a
            // `null` test over it removes nothing and installs no guard.
            .t_nullable => {
                if (kind == .null_only) return null;
                return pool.getNullableInner(current);
            },
            // `string | undefined` written out is the same type as `string?`
            // and narrows the same way. Only the `t_nullable` spelling was
            // recognized, so every author who wrote the union form got no
            // narrowing at all - including from `if (v === undefined) return;`,
            // the most common guard in the corpus.
            .t_union => {
                // On the heap, not a sixteen-slot scratch buffer. `addUnion`
                // dropped its own cap because a schema enum is routinely wider,
                // so bailing out here left exactly those unions unnarrowable:
                // `if (m === undefined) return;` over a seventeen-member enum
                // installed nothing and the value stayed nullable afterwards.
                const members = pool.getUnionMembers(current);
                var kept: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer kept.deinit(self.allocator);
                var saw_absent = false;
                for (members) |member| {
                    const tag = pool.getTag(member) orelse continue;
                    if (kind.removes(tag)) {
                        saw_absent = true;
                        continue;
                    }
                    kept.append(self.allocator, member) catch return null;
                }
                if (!saw_absent or kept.items.len == 0) return null;
                return pool.addUnion(self.allocator, kept.items);
            },
            // exhaustive: only `T?` and a union carrying `undefined` or `null`
            // describe a value that may be absent. Every other tag is a type that
            // is always present, so an absence guard over it narrows nothing and
            // installing one would claim a removal that never happened.
            else => return null,
        }
    }

    /// Extract a discriminated union narrowing guard from x.prop === <literal>.
    ///
    /// Each union member goes to the then-branch, the else-branch, or both:
    /// a member whose field is exactly the literal holds only where the test
    /// is true; a member whose field admits the literal and more, or whose
    /// field is optional, holds on both sides; a member whose field cannot
    /// hold the literal, or that lacks the
    /// field, holds only where the test is false. Taking the first member that
    /// matched narrowed `{ kind: "a", n } | { kind: "a", s }` to the first one,
    /// and a field of `string` was read as no match at all.
    ///
    /// The union and each member are resolved only to read the field. The
    /// narrowed type keeps the member as written, so a named record stays its
    /// alias. The caller handles else-branch narrowing via the negated flag.
    fn extractDiscriminantGuard(
        self: *const TypeChecker,
        member_node: NodeIndex,
        literal_node: NodeIndex,
        op: @import("zts-engine").parser.ir.BinaryOp,
    ) ?NarrowingGuard {
        const member = self.ir_view.getMember(member_node) orelse return null;
        const obj_tag = self.ir_view.getTag(member.object) orelse return null;
        if (obj_tag != .identifier) return null;

        const pool = self.env.pool;
        const binding = self.ir_view.getBinding(member.object) orelse return null;
        const key = bindingKey(binding);
        const declared = self.currentBindingType(binding) orelse return null;
        const current = pool.unwrapNominal(self.env.resolveRef(declared));
        if (pool.getTag(current) != .t_union) return null;

        const prop_name = self.resolveAtomName(member.property) orelse return null;
        const literal_type = self.inferType(literal_node);
        const literal_tag = pool.getTag(literal_type) orelse return null;
        if (literal_tag != .t_literal_string and literal_tag != .t_literal_number and literal_tag != .t_literal_bool) return null;

        // One allocation holds both sides: a member is on one side or both, so
        // each side needs at most one slot for each member.
        const members = pool.getUnionMembers(current);
        const slots = self.allocator.alloc(TypeIndex, members.len * 2) catch return null;
        defer self.allocator.free(slots);
        const then_slots = slots[0..members.len];
        const else_slots = slots[members.len..];
        var then_len: usize = 0;
        var else_len: usize = 0;

        for (members) |candidate| {
            const resolved = pool.unwrapNominal(self.env.resolveRef(candidate));
            // A member without the field, or whose field cannot hold the
            // literal, stays on the else side only.
            var in_then = false;
            var in_else = true;
            if (pool.lookupRecordField(resolved, prop_name)) |field| {
                // An optional field can be absent, so the test can be false for
                // that member even when its declared field is exactly the literal.
                if (!field.optional and self.mutuallyAssignable(field.type_idx, literal_type)) {
                    in_then = true;
                    in_else = false;
                } else if (self.env.isAssignableTo(literal_type, field.type_idx)) {
                    in_then = true;
                }
            }
            if (in_then) {
                then_slots[then_len] = candidate;
                then_len += 1;
            }
            if (in_else) {
                else_slots[else_len] = candidate;
                else_len += 1;
            }
        }
        if (then_len == 0) return null;

        const then_type = pool.addUnion(self.allocator, then_slots[0..then_len]);
        const else_type = if (else_len == 0)
            null_type_idx
        else
            pool.addUnion(self.allocator, else_slots[0..else_len]);

        if (op == .strict_eq) {
            // x.prop === "literal": then-branch narrows to the members that can
            // hold the literal; else_type is what remains after an early return.
            return .{
                .key = key,
                .narrowed_type = then_type,
                .negated = false,
                .else_type = else_type,
            };
        }
        // x.prop !== "literal": narrow to the members that can differ.
        if (else_type == null_type_idx) return null;
        return .{
            .key = key,
            .narrowed_type = else_type,
            .negated = false,
            .else_type = then_type,
        };
    }

    /// Check if a branch unconditionally returns (simple check for early-return pattern).
    fn branchAlwaysReturns(self: *const TypeChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag == .return_stmt) return true;
        if (tag == .block) {
            const block = self.ir_view.getBlock(node) orelse return false;
            if (block.stmts_count == 0) return false;
            // Check the last statement
            const last = self.ir_view.getListIndex(block.stmts_start, @intCast(block.stmts_count - 1));
            return self.branchAlwaysReturns(last);
        }
        return false;
    }

    fn inferBinaryType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const bin = self.ir_view.getBinary(node) orelse return null_type_idx;
        const pool = self.env.pool;

        return switch (bin.op) {
            // Loose equality belongs only to the internal kernel expression profile.
            // Fail closed if such an IR node reaches normal type analysis.
            .loose_eq, .loose_neq => null_type_idx,
            .strict_eq, .strict_neq, .lt, .lte, .gt, .gte => pool.idx_boolean,
            .and_op, .or_op => pool.idx_boolean,
            .sub, .mul, .div, .mod, .pow => pool.idx_number,
            .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => pool.idx_number,
            .add => {
                if (self.isRefused(node)) return pool.idx_error;
                const lt = pool.widenLiteral(self.inferType(bin.left));
                const rt = pool.widenLiteral(self.inferType(bin.right));
                if (lt == pool.idx_string or rt == pool.idx_string) return pool.idx_string;
                if (lt == pool.idx_number and rt == pool.idx_number) return pool.idx_number;
                return null_type_idx;
            },
            .nullish => {
                const lt = self.inferType(bin.left);
                const rt = self.inferType(bin.right);
                const lt_tag = pool.getTag(lt);
                // `T?` and a union written with `undefined` both lose the
                // `undefined` when the left side is not undefined.
                if (self.removeAbsence(lt, .undefined_only)) |inner| {
                    if (rt == null_type_idx) return null_type_idx;
                    return pool.addUnion(self.allocator, &.{ inner, rt });
                }
                if (lt_tag == .t_undefined) return rt;
                if (lt != null_type_idx) return lt; // non-nullable ?? anything -> left
                return null_type_idx;
            },
        };
    }

    fn typeMayBeString(self: *const TypeChecker, idx: TypeIndex) bool {
        if (idx == null_type_idx) return false;
        const pool = self.env.pool;
        return switch (pool.getTag(idx) orelse return false) {
            .t_string, .t_literal_string, .t_template_literal => true,
            .t_union => blk: {
                for (pool.getUnionMembers(idx)) |member| {
                    if (self.typeMayBeString(member)) break :blk true;
                }
                break :blk false;
            },
            // This predicate does not resolve references or nullable wrappers.
            .t_boolean,
            .t_number,
            .t_null,
            .t_dict,
            .t_bytes,
            .t_undefined,
            .t_void,
            .t_never,
            .t_unknown_type,
            .t_error,
            .t_record,
            .t_array,
            .t_tuple,
            .t_function,
            .t_intersection,
            .t_literal_number,
            .t_literal_bool,
            .t_ref,
            .t_generic_param,
            .t_generic_app,
            .t_nullable,
            => false,
        };
    }

    fn inferUnaryType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const un = self.ir_view.getUnary(node) orelse return null_type_idx;
        const pool = self.env.pool;

        return switch (un.op) {
            .not => pool.idx_boolean,
            .neg, .bit_not => pool.idx_number,
            .typeof_op => pool.idx_string,
        };
    }

    fn inferObjectLiteralType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const obj = self.ir_view.getObject(node) orelse return null_type_idx;
        if (obj.properties_count == 0) return null_type_idx;

        var fields_buf: std.ArrayListUnmanaged(type_pool_mod.RecordField) = .empty;
        defer fields_buf.deinit(self.allocator);

        for (0..obj.properties_count) |i| {
            const prop_idx = self.ir_view.getListIndex(obj.properties_start, @intCast(i));
            // A spread element carries its operand where a property carries its
            // key, so reading it as a property named the operand `base` a field
            // and dropped every field `base` actually had. Its fields belong
            // here, in source order: a later key of the same name overrides an
            // earlier one, which is what `addRecord` does with duplicates.
            if (self.ir_view.getTag(prop_idx) == .object_spread) {
                const operand = self.ir_view.getOptValue(prop_idx) orelse continue;
                const spread_type = self.inferType(operand);
                for (self.env.pool.getRecordFields(spread_type)) |field| {
                    fields_buf.append(self.allocator, field) catch {
                        @constCast(self).markAllocationFailure();
                        return null_type_idx;
                    };
                }
                continue;
            }
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            const prop_name_str = self.propertyKeyName(prop.key) orelse continue;
            const val_type = self.inferType(prop.value);
            const n = self.env.pool.addName(self.allocator, prop_name_str);
            fields_buf.append(self.allocator, .{
                .name_start = n.start,
                .name_len = n.len,
                .type_idx = val_type,
                .optional = false,
            }) catch {
                @constCast(self).markAllocationFailure();
                return null_type_idx;
            };
        }

        if (fields_buf.items.len == 0) return null_type_idx;
        return self.env.pool.addRecord(self.allocator, fields_buf.items);
    }

    /// One stable `unknown[]` node for every inference in this checker.
    fn unknownArrayType(self: *const TypeChecker) TypeIndex {
        const mutable = @constCast(self);
        if (mutable.unknown_array_type != null_type_idx) return mutable.unknown_array_type;
        const array_type = self.env.pool.addArray(self.allocator, self.env.pool.idx_unknown);
        if (array_type != null_type_idx) mutable.unknown_array_type = array_type;
        return array_type;
    }

    fn nullableUnknownType(self: *const TypeChecker) TypeIndex {
        const mutable = @constCast(self);
        if (mutable.nullable_unknown_type != null_type_idx) return mutable.nullable_unknown_type;
        const nullable_type = self.env.pool.addNullable(self.allocator, self.env.pool.idx_unknown);
        if (nullable_type != null_type_idx) mutable.nullable_unknown_type = nullable_type;
        return nullable_type;
    }

    fn arrayTypeForElement(self: *const TypeChecker, element: TypeIndex) TypeIndex {
        if (element == self.env.pool.idx_unknown) return self.unknownArrayType();
        const mutable = @constCast(self);
        if (mutable.nullable_unknown_type != null_type_idx and element == mutable.nullable_unknown_type) {
            if (mutable.nullable_unknown_array_type != null_type_idx) return mutable.nullable_unknown_array_type;
            const array_type = self.env.pool.addArray(self.allocator, element);
            if (array_type != null_type_idx) mutable.nullable_unknown_array_type = array_type;
            return array_type;
        }
        return self.env.pool.addArray(self.allocator, element);
    }

    /// The type of one non-spread array element. Empty containers have precise
    /// bottom shapes. Another expression with no inferred type is `unknown`.
    fn inferArrayElementType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const inferred = self.inferType(node);
        if (inferred != null_type_idx) return inferred;
        self.ensureHealthy() catch return null_type_idx;

        const pool = self.env.pool;
        switch (self.ir_view.getTag(node) orelse return pool.idx_unknown) {
            .array_literal => {
                const array = self.ir_view.getArray(node) orelse return pool.idx_unknown;
                if (array.elements_count == 0) return pool.addArray(self.allocator, pool.idx_never);
            },
            .object_literal => {
                const literal_object = self.ir_view.getObject(node) orelse return pool.idx_unknown;
                if (literal_object.properties_count == 0) return pool.addRecord(self.allocator, &.{});
            },
            // exhaustive: another expression with no inferred type contributes unknown below.
            else => {},
        }
        return pool.idx_unknown;
    }

    /// Append stable type indices to scratch storage. Allocation failure is
    /// sticky, so the pipeline refuses before it can use a partial type.
    fn appendArrayInferenceTypes(
        self: *const TypeChecker,
        types: *std.ArrayListUnmanaged(TypeIndex),
        additions: []const TypeIndex,
    ) bool {
        types.appendSlice(self.allocator, additions) catch {
            @constCast(self).markAllocationFailure();
            return false;
        };
        return true;
    }

    const ArrayTupleAlternative = struct { start: usize, len: usize };

    fn appendArrayTupleAlternative(
        self: *const TypeChecker,
        alternatives: *std.ArrayListUnmanaged(ArrayTupleAlternative),
        alternative: ArrayTupleAlternative,
    ) bool {
        alternatives.append(self.allocator, alternative) catch {
            @constCast(self).markAllocationFailure();
            return false;
        };
        return true;
    }

    /// Materialize each `base + common + choice` tuple as the product forms.
    /// Pool capacity therefore bounds the product before scratch can outrun it.
    fn materializeArrayTupleProduct(
        self: *const TypeChecker,
        alternatives: *std.ArrayListUnmanaged(TypeIndex),
        common: *std.ArrayListUnmanaged(TypeIndex),
        choice_types: []const TypeIndex,
        choices: []const ArrayTupleAlternative,
    ) bool {
        var next_alternatives: std.ArrayListUnmanaged(TypeIndex) = .empty;
        var scratch: std.ArrayListUnmanaged(TypeIndex) = .empty;
        var transferred = false;
        defer if (!transferred) {
            next_alternatives.deinit(self.allocator);
            scratch.deinit(self.allocator);
        };

        const base_count: usize = if (alternatives.items.len == 0) 1 else alternatives.items.len;
        for (0..base_count) |base_index| {
            for (choices) |choice| {
                scratch.clearRetainingCapacity();
                if (alternatives.items.len != 0) {
                    const base = alternatives.items[base_index];
                    const base_elements = self.env.pool.getTupleElements(base);
                    if (!self.appendArrayInferenceTypes(&scratch, base_elements)) return false;
                }
                if (!self.appendArrayInferenceTypes(&scratch, common.items)) return false;
                const addition = choice_types[choice.start..][0..choice.len];
                if (!self.appendArrayInferenceTypes(&scratch, addition)) return false;
                const tuple_type = self.env.pool.addTuple(self.allocator, scratch.items);
                if (tuple_type == null_type_idx) return false;
                if (!self.appendArrayInferenceTypes(&next_alternatives, &.{tuple_type})) return false;
            }
        }

        const normalized = self.env.pool.addUnion(self.allocator, next_alternatives.items);
        if (normalized == null_type_idx) return false;
        next_alternatives.clearRetainingCapacity();
        if (self.env.pool.getTag(normalized) == .t_union) {
            const members = self.env.pool.getUnionMembers(normalized);
            if (!self.appendArrayInferenceTypes(&next_alternatives, members)) return false;
        } else if (!self.appendArrayInferenceTypes(&next_alternatives, &.{normalized})) return false;

        alternatives.deinit(self.allocator);
        alternatives.* = next_alternatives;
        common.clearRetainingCapacity();
        scratch.deinit(self.allocator);
        transferred = true;
        return true;
    }

    /// Add every fixed alternative and its shared suffix to variable element
    /// inference. Pool slices are copied before another pool operation occurs.
    fn appendFixedAlternativesAsElements(
        self: *const TypeChecker,
        alternatives: *const std.ArrayListUnmanaged(TypeIndex),
        common: *const std.ArrayListUnmanaged(TypeIndex),
        variable_types: *std.ArrayListUnmanaged(TypeIndex),
    ) bool {
        if (alternatives.items.len == 0) {
            return self.appendArrayInferenceTypes(variable_types, common.items);
        }
        for (alternatives.items) |alternative| {
            const elements = self.env.pool.getTupleElements(alternative);
            if (!self.appendArrayInferenceTypes(variable_types, elements)) return false;
        }
        return self.appendArrayInferenceTypes(variable_types, common.items);
    }

    const SpreadSequenceStatus = enum { known, invalid, failed };
    const FixedSpreadStatus = enum { fixed, variable, invalid, failed };

    /// Collect each correlated tuple alternative of a union. One array member
    /// makes the spread variable-length. The queue preserves union order.
    fn collectFixedSpreadAlternatives(
        self: *const TypeChecker,
        sequence_type: TypeIndex,
        types: *std.ArrayListUnmanaged(TypeIndex),
        alternatives: *std.ArrayListUnmanaged(ArrayTupleAlternative),
    ) FixedSpreadStatus {
        var pending: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer pending.deinit(self.allocator);
        var visited: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer visited.deinit(self.allocator);
        if (!self.appendArrayInferenceTypes(&pending, &.{sequence_type})) return .failed;

        const pool = self.env.pool;
        var next: usize = 0;
        while (next < pending.items.len) : (next += 1) {
            const pending_type = pending.items[next];
            if (std.mem.indexOfScalar(TypeIndex, visited.items, pending_type) != null) continue;
            if (!self.appendArrayInferenceTypes(&visited, &.{pending_type})) return .failed;
            const shape = self.resolvedType(pending_type);
            switch (pool.getTag(shape) orelse return .invalid) {
                .t_tuple => {
                    const elements = pool.getTupleElements(shape);
                    const start = types.items.len;
                    if (!self.appendArrayInferenceTypes(types, elements)) return .failed;
                    if (!self.appendArrayTupleAlternative(alternatives, .{
                        .start = start,
                        .len = elements.len,
                    })) return .failed;
                },
                .t_array => return .variable,
                .t_union => {
                    const members = pool.getUnionMembers(shape);
                    if (!self.appendArrayInferenceTypes(&pending, members)) return .failed;
                },
                // exhaustive: no other type has fixed spread positions.
                else => return .invalid,
            }
        }
        return if (alternatives.items.len == 0) .invalid else .fixed;
    }

    /// Append every possible element type of an array, tuple, or union of
    /// those shapes. The worklist snapshots pool slices before pool growth.
    fn collectSpreadSequenceTypes(
        self: *const TypeChecker,
        sequence_type: TypeIndex,
        types: *std.ArrayListUnmanaged(TypeIndex),
    ) SpreadSequenceStatus {
        var pending: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer pending.deinit(self.allocator);
        var visited: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer visited.deinit(self.allocator);
        if (!self.appendArrayInferenceTypes(&pending, &.{sequence_type})) return .failed;

        const pool = self.env.pool;
        while (pending.pop()) |pending_type| {
            if (std.mem.indexOfScalar(TypeIndex, visited.items, pending_type) != null) continue;
            if (!self.appendArrayInferenceTypes(&visited, &.{pending_type})) return .failed;
            std.debug.assert(visited.items.len <= std.math.maxInt(TypeIndex));
            const shape = self.resolvedType(pending_type);
            switch (pool.getTag(shape) orelse return .invalid) {
                .t_array => {
                    const element = pool.getArrayElement(shape);
                    const stable = if (element == null_type_idx) pool.idx_unknown else element;
                    if (!self.appendArrayInferenceTypes(types, &.{stable})) return .failed;
                },
                .t_tuple => {
                    const elements = pool.getTupleElements(shape);
                    if (!self.appendArrayInferenceTypes(types, elements)) return .failed;
                },
                .t_union => {
                    const members = pool.getUnionMembers(shape);
                    if (!self.appendArrayInferenceTypes(&pending, members)) return .failed;
                },
                // exhaustive: no other type is a sequence that spread can expand.
                else => return .invalid,
            }
        }
        return .known;
    }

    /// Infer a literal that contains a spread. Fixed tuple unions retain each
    /// correlated alternative. Any array member forces an array result.
    fn inferSpreadArrayLiteralType(self: *const TypeChecker, arr: Node.ArrayExpr) TypeIndex {
        var fixed_alternatives: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer fixed_alternatives.deinit(self.allocator);
        var common_fixed_types: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer common_fixed_types.deinit(self.allocator);

        var variable_types: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer variable_types.deinit(self.allocator);
        var variable_length = false;
        const pool = self.env.pool;

        for (0..arr.elements_count) |i| {
            const element_node = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
            if (self.ir_view.getTag(element_node) != .spread) {
                const element_type = self.inferArrayElementType(element_node);
                if (element_type == null_type_idx) return null_type_idx;
                if (variable_length) {
                    if (!self.appendArrayInferenceTypes(&variable_types, &.{element_type})) return null_type_idx;
                } else {
                    if (!self.appendArrayInferenceTypes(&common_fixed_types, &.{element_type})) return null_type_idx;
                }
                continue;
            }

            const operand = self.ir_view.getOptValue(element_node) orelse {
                if (!variable_length) {
                    if (!self.appendFixedAlternativesAsElements(
                        &fixed_alternatives,
                        &common_fixed_types,
                        &variable_types,
                    )) return null_type_idx;
                    variable_length = true;
                }
                if (!self.appendArrayInferenceTypes(&variable_types, &.{pool.idx_unknown})) return null_type_idx;
                continue;
            };
            const operand_type = self.inferType(operand);
            if (operand_type == null_type_idx) {
                self.ensureHealthy() catch return null_type_idx;
                if (self.ir_view.getTag(operand) == .array_literal) {
                    const literal = self.ir_view.getArray(operand) orelse return null_type_idx;
                    if (literal.elements_count == 0) continue;
                }
                if (!variable_length) {
                    if (!self.appendFixedAlternativesAsElements(
                        &fixed_alternatives,
                        &common_fixed_types,
                        &variable_types,
                    )) return null_type_idx;
                    variable_length = true;
                }
                if (!self.appendArrayInferenceTypes(&variable_types, &.{pool.idx_unknown})) return null_type_idx;
                continue;
            }

            const shape = self.resolvedType(operand_type);
            if (variable_length) {
                switch (self.collectSpreadSequenceTypes(shape, &variable_types)) {
                    .known => {},
                    .invalid => if (!self.appendArrayInferenceTypes(&variable_types, &.{pool.idx_unknown})) return null_type_idx,
                    .failed => return null_type_idx,
                }
                continue;
            }

            var choice_types: std.ArrayListUnmanaged(TypeIndex) = .empty;
            defer choice_types.deinit(self.allocator);
            var choices: std.ArrayListUnmanaged(ArrayTupleAlternative) = .empty;
            defer choices.deinit(self.allocator);
            switch (self.collectFixedSpreadAlternatives(shape, &choice_types, &choices)) {
                .fixed => {
                    if (choices.items.len == 1) {
                        const choice = choices.items[0];
                        const additions = choice_types.items[choice.start..][0..choice.len];
                        if (!self.appendArrayInferenceTypes(&common_fixed_types, additions)) return null_type_idx;
                    } else if (!self.materializeArrayTupleProduct(
                        &fixed_alternatives,
                        &common_fixed_types,
                        choice_types.items,
                        choices.items,
                    )) return null_type_idx;
                },
                .variable => {
                    if (!self.appendFixedAlternativesAsElements(
                        &fixed_alternatives,
                        &common_fixed_types,
                        &variable_types,
                    )) return null_type_idx;
                    variable_length = true;
                    switch (self.collectSpreadSequenceTypes(shape, &variable_types)) {
                        .known => {},
                        .invalid => if (!self.appendArrayInferenceTypes(&variable_types, &.{pool.idx_unknown})) return null_type_idx,
                        .failed => return null_type_idx,
                    }
                },
                .invalid => {
                    if (!self.appendFixedAlternativesAsElements(
                        &fixed_alternatives,
                        &common_fixed_types,
                        &variable_types,
                    )) return null_type_idx;
                    if (!self.appendArrayInferenceTypes(&variable_types, &.{pool.idx_unknown})) return null_type_idx;
                    variable_length = true;
                },
                .failed => return null_type_idx,
            }
        }

        if (!variable_length) {
            if (fixed_alternatives.items.len == 0) {
                return pool.addTuple(self.allocator, common_fixed_types.items);
            }
            if (common_fixed_types.items.len == 0) {
                return pool.addUnion(self.allocator, fixed_alternatives.items);
            }
            var tuple_types: std.ArrayListUnmanaged(TypeIndex) = .empty;
            defer tuple_types.deinit(self.allocator);
            for (fixed_alternatives.items) |alternative| {
                var elements: std.ArrayListUnmanaged(TypeIndex) = .empty;
                defer elements.deinit(self.allocator);
                const base_elements = pool.getTupleElements(alternative);
                if (!self.appendArrayInferenceTypes(&elements, base_elements)) return null_type_idx;
                if (!self.appendArrayInferenceTypes(&elements, common_fixed_types.items)) return null_type_idx;
                const tuple_type = pool.addTuple(self.allocator, elements.items);
                if (tuple_type == null_type_idx) return null_type_idx;
                if (!self.appendArrayInferenceTypes(&tuple_types, &.{tuple_type})) return null_type_idx;
            }
            return pool.addUnion(self.allocator, tuple_types.items);
        }
        if (variable_types.items.len == 0) return pool.addArray(self.allocator, pool.idx_never);
        const element_type = pool.addUnion(self.allocator, variable_types.items);
        if (element_type == null_type_idx) return null_type_idx;
        return self.arrayTypeForElement(element_type);
    }

    fn inferArrayLiteralType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const arr = self.ir_view.getArray(node) orelse return null_type_idx;
        if (arr.elements_count == 0) return null_type_idx;
        if (arr.has_spread) return self.inferSpreadArrayLiteralType(arr);

        var element_types: [32]TypeIndex = undefined;
        const element_count: usize = arr.elements_count;
        const count = @min(element_count, element_types.len);
        for (0..count) |i| {
            const elem_idx = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
            const elem_type = self.inferArrayElementType(elem_idx);
            if (elem_type == null_type_idx) return null_type_idx;
            element_types[i] = elem_type;
        }

        const first = element_types[0];
        var homogeneous = true;
        for (element_types[1..count]) |elem_type| {
            if (elem_type != first) {
                homogeneous = false;
                break;
            }
        }

        if (element_count <= element_types.len) {
            if (homogeneous) {
                return self.arrayTypeForElement(first);
            }
            return self.env.pool.addTuple(self.allocator, element_types[0..count]);
        }

        // Keep homogeneous wide literals allocation-free. After the first
        // different type, collect the remaining types and normalize once.
        var wide_types: std.ArrayListUnmanaged(TypeIndex) = .empty;
        defer wide_types.deinit(self.allocator);

        if (!homogeneous) {
            wide_types.ensureTotalCapacity(self.allocator, element_count) catch {
                @constCast(self).markAllocationFailure();
                return null_type_idx;
            };
            wide_types.appendSliceAssumeCapacity(element_types[0..count]);
        }

        for (count..element_count) |i| {
            const elem_idx = self.ir_view.getListIndex(arr.elements_start, @intCast(i));
            const elem_type = self.inferArrayElementType(elem_idx);
            if (elem_type == null_type_idx) return null_type_idx;
            if (wide_types.items.len == 0 and elem_type == first) continue;
            if (wide_types.items.len == 0) {
                wide_types.ensureTotalCapacity(self.allocator, element_count - count + 1) catch {
                    @constCast(self).markAllocationFailure();
                    return null_type_idx;
                };
                wide_types.appendAssumeCapacity(first);
            }
            wide_types.appendAssumeCapacity(elem_type);
        }

        if (wide_types.items.len == 0) {
            return self.arrayTypeForElement(first);
        }
        const element_type = self.env.pool.addUnion(self.allocator, wide_types.items);
        if (element_type == null_type_idx) return null_type_idx;
        return self.arrayTypeForElement(element_type);
    }

    fn unionMemberIsRecord(self: *const TypeChecker, member_type: TypeIndex) bool {
        const resolved = self.env.pool.unwrapNominal(self.env.resolveRef(member_type));
        return self.env.pool.getTag(resolved) == .t_record;
    }

    fn functionsCompatible(self: *const TypeChecker, field_type: TypeIndex, first_info: anytype) bool {
        if (self.env.pool.getTag(field_type) != .t_function) return false;
        const info = self.env.pool.getFunctionInfo(field_type);
        if (info.params.len != first_info.params.len) return false;
        for (info.params, first_info.params) |param, first_param| {
            if (param.type_idx != first_param.type_idx) return false;
        }
        return info.ret == first_info.ret;
    }

    /// An index read of an array or tuple is `T | undefined`, as under
    /// noUncheckedIndexedAccess. A literal key on a record is the field's
    /// type. A union of arrays reads as the union of its elements, plus
    /// `undefined`. A string member of the union contributes `undefined`:
    /// the interpreter yields `undefined` for an index read on a string.
    /// Other receivers stay untyped, as before.
    fn inferIndexReadType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const member = self.ir_view.getMember(node) orelse return null_type_idx;
        const raw = self.inferType(member.object);
        if (raw == null_type_idx) return null_type_idx;
        const pool = self.env.pool;
        var obj = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(obj) orelse return null_type_idx;
        if (tag == .t_record and member.computed != null_node) {
            const key = self.getLiteralString(member.computed) orelse return null_type_idx;
            const field = pool.lookupRecordField(obj, key) orelse return null_type_idx;
            return self.recordFieldReadType(obj, field);
        }
        if (tag == .t_union) {
            var elems: [MAX_UNION_MEMBERS]TypeIndex = undefined;
            var count: usize = 0;
            var has_string_member = false;
            for (pool.getUnionMembers(obj)) |m| {
                var arr = pool.unwrapNominal(self.env.resolveRef(m));
                const mt = pool.getTag(arr) orelse return null_type_idx;
                // The interpreter's `get_elem` yields `undefined` for every
                // string receiver. A string member adds only that `undefined`.
                if (mt == .t_string or mt == .t_literal_string or mt == .t_template_literal) {
                    has_string_member = true;
                    continue;
                }
                if (count >= elems.len) return null_type_idx;
                if (mt == .t_tuple) arr = self.tupleToArrayType(arr) else if (mt != .t_array) return null_type_idx;
                elems[count] = pool.getArrayElement(arr);
                if (elems[count] == null_type_idx) return null_type_idx;
                count += 1;
            }
            if (count == 0) return if (has_string_member) pool.idx_undefined else null_type_idx;
            const joined = pool.addUnion(self.allocator, elems[0..count]);
            if (self.admitsUndefined(joined)) return joined;
            return pool.addNullable(self.allocator, joined);
        }
        if (tag == .t_tuple and member.computed != null_node and self.ir_view.getTag(member.computed) == .lit_int) {
            const at = self.ir_view.getIntValue(member.computed) orelse return null_type_idx;
            const elems = pool.getTupleElements(obj);
            if (at >= 0 and at < elems.len) return elems[@intCast(at)];
        }
        if (tag == .t_tuple) obj = self.tupleToArrayType(obj) else if (tag != .t_array) return null_type_idx;
        const elem = pool.getArrayElement(obj);
        if (elem == null_type_idx) return null_type_idx;
        if (elem == pool.idx_unknown) return self.nullableUnknownType();
        if (pool.getTag(elem) == .t_nullable) return elem;
        return pool.addNullable(self.allocator, elem);
    }

    /// `p?.q` is the field type of `q` plus `undefined` when `p` may be
    /// undefined. A receiver that is not a nullable record stays untyped.
    fn inferOptionalChainType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const member = self.ir_view.getMember(node) orelse return null_type_idx;
        const raw = self.inferType(member.object);
        if (raw == null_type_idx) return null_type_idx;
        if (!self.admitsUndefined(raw)) return self.inferMemberAccessType(node);
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        if (pool.getTag(t) != .t_nullable) return null_type_idx;
        const obj = pool.unwrapNominal(self.env.resolveRef(pool.getNullableInner(t)));
        if (pool.getTag(obj) != .t_record) return null_type_idx;
        const prop_name = self.resolveAtomName(member.property) orelse return null_type_idx;
        const field = pool.lookupRecordField(obj, prop_name) orelse return null_type_idx;
        const ft = self.recordFieldReadType(obj, field);
        if (ft == null_type_idx or self.admitsUndefined(ft)) return ft;
        return pool.addNullable(self.allocator, ft);
    }

    fn inferMemberAccessType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const member = self.ir_view.getMember(node) orelse return null_type_idx;
        const raw_obj_type = self.inferType(member.object);
        if (raw_obj_type == null_type_idx) return self.inferBuiltinConstantType(member);

        // A field of a record type keeps a named type as a reference: the
        // `todo` of `{ todo: Todo }` is a `Todo` ref, not the record it names.
        // Resolve it, or a second member read (`props.todo.done`) finds no
        // type and the read is refused as not boolean.
        // Unwrap nominal types for member access (operations work on the base type)
        const obj_type = self.env.pool.unwrapNominal(self.env.resolveRef(raw_obj_type));

        const prop_name = self.resolveAtomName(member.property) orelse return null_type_idx;

        const tag = self.env.pool.getTag(obj_type) orelse return null_type_idx;
        if (tag == .t_record) {
            if (self.env.pool.lookupRecordField(obj_type, prop_name)) |field| {
                return self.recordFieldReadType(obj_type, field);
            }
            const result_subject = if (self.env.pool.isResultRecord(obj_type)) self.identifierName(member.object) else null;
            self.addInferenceDiagnostic(.{
                .severity = .err,
                .kind = .missing_field,
                .node = node,
                .message = "property does not exist on type",
                .help = "Read a property that the type declares, or add the property to the type.",
                .result_shape = if (result_subject != null) .unknown_member else null,
                .result_subject = result_subject,
            });
            return null_type_idx;
        }

        if (tag == .t_union) {
            // A `length` read on a union of strings, arrays, and tuples.
            if (std.mem.eql(u8, prop_name, "length")) {
                const length = self.inferUnionBuiltinMember(obj_type, prop_name, null);
                if (length != null_type_idx) return length;
            }
            var field_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
            var count: usize = 0;
            var any_field = false;
            for (self.env.pool.getUnionMembers(obj_type)) |member_type| {
                if (count >= field_types.len) return null_type_idx;
                // A member that names a record (`structural P`) is a reference:
                // resolve it, or its fields are not found.
                const resolved_member = self.env.pool.unwrapNominal(self.env.resolveRef(member_type));
                if (self.env.pool.lookupRecordField(resolved_member, prop_name)) |field| {
                    field_types[count] = self.fieldReadType(field);
                    any_field = true;
                } else if (self.unionMemberIsRecord(member_type)) {
                    // A member of the union has no such field: reading it
                    // there yields `undefined`.
                    field_types[count] = self.env.pool.idx_undefined;
                } else if (self.primitiveMemberPresence(member_type, prop_name) == .absent) {
                    // A number, a boolean, a string, an array, or a tuple that
                    // the runtime gives no such member reads `undefined` too.
                    field_types[count] = self.env.pool.idx_undefined;
                } else {
                    return null_type_idx;
                }
                count += 1;
            }
            if (count == 0 or !any_field) return null_type_idx;
            if (count == 1) return field_types[0];

            const first_tag = self.env.pool.getTag(field_types[0]) orelse return null_type_idx;
            if (first_tag == .t_function) {
                const first_info = self.env.pool.getFunctionInfo(field_types[0]);
                for (field_types[1..count]) |field_type| {
                    // A call through a member that some branch lacks stays
                    // untyped, as it was before a missing field read as `undefined`.
                    if (field_type == self.env.pool.idx_undefined) return null_type_idx;
                    if (!self.functionsCompatible(field_type, first_info)) {
                        self.addInferenceDiagnostic(.{
                            .severity = .err,
                            .kind = .type_mismatch,
                            .node = node,
                            .message = "must narrow union before calling this member",
                            .help = "Check which union member the value holds before the call.",
                        });
                        return null_type_idx;
                    }
                }
                return field_types[0];
            }

            return self.env.pool.addUnion(self.allocator, field_types[0..count]);
        }

        if (std.mem.eql(u8, prop_name, "length")) {
            const length = self.inferLengthType(obj_type);
            if (length != null_type_idx) return length;
        }

        // Array (and tuple-typed array literal) receivers. A heterogeneous literal
        // like `[10, 2, 1]` infers as a tuple, so widen it back to a `T[]` result.
        if (tag == .t_array) {
            return self.inferArrayMethodType(obj_type, prop_name);
        }
        if (tag == .t_tuple) {
            return self.inferArrayMethodType(self.tupleToArrayType(obj_type), prop_name);
        }

        return null_type_idx;
    }

    /// Widen a tuple type into a `T[]` whose element is the union of its (widened)
    /// element types. Used so array-method modelling works on array-literal receivers.
    fn tupleToArrayType(self: *const TypeChecker, tuple_type: TypeIndex) TypeIndex {
        const elements = self.env.pool.getTupleElements(tuple_type);
        if (elements.len == 0) return self.env.pool.addArray(self.allocator, self.env.pool.idx_unknown);
        var widened: [32]TypeIndex = undefined;
        var count: usize = 0;
        for (elements) |elem| {
            if (count >= widened.len) break;
            const w = self.env.pool.widenLiteral(elem);
            var seen = false;
            for (widened[0..count]) |existing| {
                if (existing == w) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                widened[count] = w;
                count += 1;
            }
        }
        const element_type = if (count == 1) widened[0] else self.env.pool.addUnion(self.allocator, widened[0..count]);
        return self.env.pool.addArray(self.allocator, element_type);
    }

    /// Model the array methods whose contracts affect static checking. Predicate
    /// callbacks have an explicit boolean return type, matching the runtime
    /// boundary in builtins/array.zig.
    fn inferArrayMethodType(self: *const TypeChecker, array_type: TypeIndex, prop_name: []const u8) TypeIndex {
        const pool = self.env.pool;
        const element_type = pool.getArrayElement(array_type);
        const predicate_type = pool.addFunctionWithReturn(self.allocator, &.{}, pool.idx_boolean);
        const predicate_param = [_]type_pool_mod.FuncParam{.{
            .name_start = 0,
            .name_len = 0,
            .type_idx = predicate_type,
            .optional = false,
        }};
        if (std.mem.eql(u8, prop_name, "filter")) {
            return pool.addFunction(self.allocator, &predicate_param, array_type);
        }
        if (std.mem.eql(u8, prop_name, "every") or std.mem.eql(u8, prop_name, "some")) {
            return pool.addFunction(self.allocator, &predicate_param, pool.idx_boolean);
        }
        if (std.mem.eql(u8, prop_name, "find")) {
            return pool.addFunction(self.allocator, &predicate_param, pool.addNullable(self.allocator, element_type));
        }
        if (std.mem.eql(u8, prop_name, "findIndex")) {
            return pool.addFunction(self.allocator, &predicate_param, pool.idx_number);
        }
        if (std.mem.eql(u8, prop_name, "toSorted")) {
            const params = [_]type_pool_mod.FuncParam{.{
                .name_start = 0,
                .name_len = 0,
                .type_idx = self.env.pool.idx_unknown,
                .optional = true,
            }};
            return self.env.pool.addFunction(self.allocator, &params, array_type);
        }
        if (std.mem.eql(u8, prop_name, "toReversed")) {
            return self.env.pool.addFunction(self.allocator, &.{}, array_type);
        }
        return null_type_idx;
    }

    fn inferFunctionReturnType(self: *const TypeChecker, callee_type: TypeIndex) TypeIndex {
        const tag = self.env.pool.getTag(callee_type) orelse return null_type_idx;
        if (tag == .t_function) {
            return self.env.pool.getFunctionInfo(callee_type).ret;
        }
        if (tag == .t_union) {
            var return_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
            var count: usize = 0;
            for (self.env.pool.getUnionMembers(callee_type)) |member_type| {
                if (self.env.pool.getTag(member_type) != .t_function) return null_type_idx;
                if (count >= return_types.len) return null_type_idx;
                return_types[count] = self.env.pool.getFunctionInfo(member_type).ret;
                count += 1;
            }
            if (count == 0) return null_type_idx;
            if (count == 1) return return_types[0];
            return self.env.pool.addUnion(self.allocator, return_types[0..count]);
        }
        return null_type_idx;
    }

    // -------------------------------------------------------------------
    // Builtin results (`builtin_results.zig`)
    // -------------------------------------------------------------------

    /// The name of the builtin global that `node` reads, or null. The name
    /// qualifies only when no declaration answers for it: the identifier is an
    /// `undeclared_global` and has no type. A parameter, a local, a top-level
    /// declaration, and an import of the same name are other bindings (T3). A
    /// top-level declaration has the kind `global`, which a builtin never has,
    /// so `global` does not qualify.
    fn builtinGlobalName(self: *const TypeChecker, node: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(node) != .identifier) return null;
        const binding = self.ir_view.getBinding(node) orelse return null;
        if (binding.kind != .undeclared_global) return null;
        if (self.inferType(node) != null_type_idx) return null;
        return self.resolveAtomName(binding.name_atom);
    }

    /// The type of a read of an installed builtin constant, such as `Math.PI`.
    fn inferBuiltinConstantType(self: *const TypeChecker, member: Node.MemberExpr) TypeIndex {
        if (member.computed != null_node or member.is_optional) return null_type_idx;
        const namespace = self.builtinGlobalName(member.object) orelse return null_type_idx;
        const name = self.resolveAtomName(member.property) orelse return null_type_idx;
        const row = builtin_results.find(.property, namespace, name) orelse return null_type_idx;
        return self.builtinResultType(row.result);
    }

    fn builtinResultType(self: *const TypeChecker, result: builtin_results.Result) TypeIndex {
        const pool = self.env.pool;
        return switch (result) {
            .number => pool.idx_number,
            .boolean => pool.idx_boolean,
            .string => pool.idx_string,
            .string_array => pool.addArray(self.allocator, pool.idx_string),
            .unknown_array => pool.addArray(self.allocator, pool.idx_unknown),
            .entry_array => pool.addArray(
                self.allocator,
                pool.addTuple(self.allocator, &.{ pool.idx_string, pool.idx_unknown }),
            ),
            .optional_string => pool.addNullable(self.allocator, pool.idx_string),
            .undefined_value => pool.idx_undefined,
            .unknown_value => pool.idx_unknown,
            // `JSON.tryParse` is not a module export and keeps its record.
            .json_result => self.typedResultType(pool.idx_unknown, pool.idx_string, pool.idx_never),
            // These take their type from the receiver or the arguments.
            .receiver_array,
            .receiver_element_or_undefined,
            .concat_array,
            .map_array,
            .reduce_value,
            .json_text,
            .array_of,
            .array_from,
            => null_type_idx,
        };
    }

    /// `type_idx` resolved through a named reference and a nominal wrapper.
    fn resolvedType(self: *const TypeChecker, type_idx: TypeIndex) TypeIndex {
        return self.env.pool.unwrapNominal(self.env.resolveRef(type_idx));
    }

    /// The array type of a receiver: the receiver itself for an array, the
    /// array of the widened union of the elements for a tuple, and null for
    /// every other type, for an empty tuple (whose element type is not known),
    /// and for a receiver with no type. A union receiver is not an array.
    fn arrayReceiverType(self: *const TypeChecker, receiver: TypeIndex) TypeIndex {
        if (receiver == null_type_idx) return null_type_idx;
        const pool = self.env.pool;
        const resolved = self.resolvedType(receiver);
        const tag = pool.getTag(resolved) orelse return null_type_idx;
        switch (tag) {
            .t_array => {
                if (pool.getArrayElement(resolved) == null_type_idx) return null_type_idx;
                return resolved;
            },
            .t_tuple => {
                if (pool.getTupleElements(resolved).len == 0) return null_type_idx;
                return self.tupleToArrayType(resolved);
            },
            // exhaustive: every other receiver type is not an array, so the
            // array rows do not apply and the call stays untyped.
            else => return null_type_idx,
        }
    }

    /// Whether `type_idx` is a type that a result can be built from: it has a
    /// type, and no part of it is `unknown`, `void`, a refused expression, or
    /// an empty tuple. An empty array literal has no element type, so a
    /// result built from it would claim an element that nothing determined.
    fn isDefiniteType(self: *const TypeChecker, type_idx: TypeIndex, depth: u8) bool {
        if (type_idx == null_type_idx or depth >= 8) return false;
        const pool = self.env.pool;
        if (type_idx == pool.idx_unknown or type_idx == pool.idx_json_value) return false;
        if (pool.mentionsError(type_idx)) return false;
        const tag = pool.getTag(type_idx) orelse return false;
        return switch (tag) {
            .t_unknown_type, .t_void, .t_never, .t_generic_param, .t_generic_app, .t_error => false,
            .t_array => self.isDefiniteType(pool.getArrayElement(type_idx), depth + 1),
            .t_nullable => self.isDefiniteType(pool.getNullableInner(type_idx), depth + 1),
            .t_dict => self.isDefiniteType(pool.getDictValue(type_idx), depth + 1),
            .t_tuple => blk: {
                const elements = pool.getTupleElements(type_idx);
                if (elements.len == 0) break :blk false;
                for (elements) |element| {
                    if (!self.isDefiniteType(element, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            .t_union => blk: {
                for (pool.getUnionMembers(type_idx)) |member| {
                    if (!self.isDefiniteType(member, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            .t_boolean,
            .t_number,
            .t_string,
            .t_null,
            .t_bytes,
            .t_undefined,
            .t_record,
            .t_function,
            .t_intersection,
            .t_literal_string,
            .t_literal_number,
            .t_literal_bool,
            .t_ref,
            .t_template_literal,
            => true,
        };
    }

    /// The function type of a callback argument, or null when the argument
    /// is not a function type.
    fn callbackFunctionType(self: *const TypeChecker, callback: NodeIndex) TypeIndex {
        const callback_type = self.resolvedType(self.inferType(callback));
        if (self.env.pool.getTag(callback_type) != .t_function) return null_type_idx;
        return callback_type;
    }

    /// The widened return type of the callback type `callback_type`, or null
    /// when it is not definite.
    fn callbackReturnType(self: *const TypeChecker, callback_type: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        const returned = pool.getFunctionInfo(callback_type).ret;
        if (!self.isDefiniteType(returned, 0)) return null_type_idx;
        return pool.widenLiteral(returned);
    }

    /// Whether each parameter of the callback type `callback_type` accepts the
    /// value that the runtime passes in its position. `passed` lists the types
    /// of those values. The declared return type holds only for those
    /// parameter types: `(n: number) => number` called with a string can
    /// return `n + 1`, a string. A parameter past `passed` gets `undefined`,
    /// and a parameter with no type admits anything, so either one leaves the
    /// result untyped.
    fn callbackAccepts(self: *const TypeChecker, callback_type: TypeIndex, passed: []const TypeIndex) bool {
        const params = self.env.pool.getFunctionInfo(callback_type).params;
        if (params.len > passed.len) return false;
        for (params, passed[0..params.len]) |param, value_type| {
            if (param.type_idx == null_type_idx or value_type == null_type_idx) return false;
            if (!self.env.isAssignableTo(value_type, param.type_idx)) return false;
        }
        return true;
    }

    /// What one `concat` argument of type `arg_type` adds to the result's
    /// element type: the elements of an array or a tuple, which the runtime
    /// flattens one level, and the type itself for a scalar. Any other type
    /// could be an array at runtime, so it adds nothing known (null).
    fn concatContribution(self: *const TypeChecker, arg_type: TypeIndex) TypeIndex {
        if (arg_type == null_type_idx) return null_type_idx;
        const pool = self.env.pool;
        const resolved = pool.widenLiteral(self.resolvedType(arg_type));
        const tag = pool.getTag(resolved) orelse return null_type_idx;
        switch (tag) {
            .t_array => {
                const element = pool.getArrayElement(resolved);
                if (element == null_type_idx) return null_type_idx;
                return pool.widenLiteral(element);
            },
            .t_tuple => {
                // An empty tuple adds no element.
                if (pool.getTupleElements(resolved).len == 0) return pool.idx_never;
                return pool.getArrayElement(self.tupleToArrayType(resolved));
            },
            .t_number, .t_string, .t_boolean => return resolved,
            // exhaustive: a record, a union, `unknown`, and every other type
            // might be an array at runtime, and the runtime would then add its
            // elements and not the value.
            else => return null_type_idx,
        }
    }

    /// How deep the values of a type can nest, for `JSON.stringify`, which
    /// gives up at 512 levels (`JSON_MAX_DEPTH` in http.zig).
    const JsonDepth = enum {
        /// Every value is nested fewer than 512 levels deep.
        bounded,
        /// The type is recursive or deeper than 16 levels, so a value can
        /// nest 512 levels.
        deep,
        /// A part of the type is `unknown` or a type that this walk does not
        /// model, so nothing is known about the depth.
        opaque_part,

        fn join(self: JsonDepth, other: JsonDepth) JsonDepth {
            if (self == .opaque_part or other == .opaque_part) return .opaque_part;
            if (self == .deep or other == .deep) return .deep;
            return .bounded;
        }
    };

    fn jsonDepth(self: *const TypeChecker, type_idx: TypeIndex, depth: u8) JsonDepth {
        if (type_idx == null_type_idx) return .opaque_part;
        if (depth >= 16) return .deep;
        const pool = self.env.pool;
        const resolved = self.resolvedType(type_idx);
        const tag = pool.getTag(resolved) orelse return .opaque_part;
        switch (tag) {
            .t_boolean,
            .t_number,
            .t_string,
            .t_null,
            .t_undefined,
            .t_literal_string,
            .t_literal_number,
            .t_literal_bool,
            => return .bounded,
            .t_array => return self.jsonDepth(pool.getArrayElement(resolved), depth + 1),
            .t_nullable => return self.jsonDepth(pool.getNullableInner(resolved), depth + 1),
            .t_dict => return self.jsonDepth(pool.getDictValue(resolved), depth + 1),
            .t_record => {
                var found: JsonDepth = .bounded;
                for (pool.getRecordFields(resolved)) |field| {
                    found = found.join(self.jsonDepth(field.type_idx, depth + 1));
                }
                return found;
            },
            .t_tuple => {
                var found: JsonDepth = .bounded;
                for (pool.getTupleElements(resolved)) |element| {
                    found = found.join(self.jsonDepth(element, depth + 1));
                }
                return found;
            },
            .t_union => {
                var found: JsonDepth = .bounded;
                for (pool.getUnionMembers(resolved)) |member| {
                    found = found.join(self.jsonDepth(member, depth + 1));
                }
                return found;
            },
            .t_bytes,
            .t_void,
            .t_never,
            .t_unknown_type,
            .t_function,
            .t_intersection,
            .t_ref,
            .t_generic_param,
            .t_generic_app,
            .t_template_literal,
            .t_error,
            => return .opaque_part,
        }
    }

    /// The result of a row whose type depends on the receiver or on the
    /// arguments, or null when a needed type is not known. `receiver_array`
    /// is the array type of the receiver, or null for a row with no
    /// receiver. A result is never built from `unknown[]`.
    fn builtinShapedResult(
        self: *const TypeChecker,
        call: Node.CallExpr,
        result: builtin_results.Result,
        receiver_array: TypeIndex,
    ) TypeIndex {
        const pool = self.env.pool;
        const element = if (receiver_array == null_type_idx)
            null_type_idx
        else
            pool.widenLiteral(pool.getArrayElement(receiver_array));
        switch (result) {
            .receiver_array => {
                if (element == null_type_idx) return null_type_idx;
                return pool.addArray(self.allocator, element);
            },
            .receiver_element_or_undefined => {
                if (!self.isDefiniteType(element, 0)) return null_type_idx;
                if (pool.getTag(element) == .t_nullable) return element;
                return pool.addNullable(self.allocator, element);
            },
            .concat_array => {
                if (element == null_type_idx) return null_type_idx;
                var members: [MAX_UNION_MEMBERS]TypeIndex = undefined;
                if (call.args_count + 1 > members.len) return null_type_idx;
                members[0] = element;
                for (0..call.args_count) |position| {
                    const arg = self.ir_view.getListIndex(call.args_start, @intCast(position));
                    const added = self.concatContribution(self.inferType(arg));
                    if (added == null_type_idx) return null_type_idx;
                    members[position + 1] = added;
                }
                const joined = pool.addUnion(self.allocator, members[0 .. call.args_count + 1]);
                if (joined == null_type_idx) return null_type_idx;
                return pool.addArray(self.allocator, joined);
            },
            .map_array => {
                if (element == null_type_idx) return null_type_idx;
                const callback = self.callbackFunctionType(self.ir_view.getListIndex(call.args_start, 0));
                if (callback == null_type_idx) return null_type_idx;
                const returned = self.callbackReturnType(callback);
                if (returned == null_type_idx) return null_type_idx;
                // `map` passes the element, its index, and the array.
                const passed = [_]TypeIndex{ element, pool.idx_number, receiver_array };
                if (!self.callbackAccepts(callback, &passed)) return null_type_idx;
                return pool.addArray(self.allocator, returned);
            },
            .reduce_value => {
                if (element == null_type_idx) return null_type_idx;
                const callback = self.callbackFunctionType(self.ir_view.getListIndex(call.args_start, 0));
                if (callback == null_type_idx) return null_type_idx;
                const returned = self.callbackReturnType(callback);
                if (returned == null_type_idx) return null_type_idx;
                // With an initial value, an empty array returns it and any
                // other array returns the last callback result. Without one, a
                // one-element array returns its element.
                const seed = if (call.args_count >= 2)
                    pool.widenLiteral(self.inferType(self.ir_view.getListIndex(call.args_start, 1)))
                else
                    element;
                if (!self.isDefiniteType(seed, 0)) return null_type_idx;
                const members = [_]TypeIndex{ seed, returned };
                const joined = pool.addUnion(self.allocator, &members);
                if (joined == null_type_idx) return null_type_idx;
                // `reduce` passes the accumulator (the seed first, then each
                // callback result), the element, its index, and the array.
                const passed = [_]TypeIndex{ joined, element, pool.idx_number, receiver_array };
                if (!self.callbackAccepts(callback, &passed)) return null_type_idx;
                return joined;
            },
            .json_text => {
                const arg = self.ir_view.getListIndex(call.args_start, 0);
                const arg_type = self.inferType(arg);
                if (arg_type == null_type_idx) return null_type_idx;
                // The same payloads that ZTS213 refuses stay untyped.
                if (self.firstUnencodable(arg_type, 0) != null) return null_type_idx;
                return switch (self.jsonDepth(arg_type, 0)) {
                    .bounded => pool.idx_string,
                    .deep => pool.addNullable(self.allocator, pool.idx_string),
                    // Nothing is known about the depth of the value, so the
                    // result stays untyped.
                    .opaque_part => null_type_idx,
                };
            },
            .array_of => {
                var members: [MAX_UNION_MEMBERS]TypeIndex = undefined;
                if (call.args_count > members.len) return null_type_idx;
                for (0..call.args_count) |position| {
                    const arg = self.ir_view.getListIndex(call.args_start, @intCast(position));
                    const arg_type = pool.widenLiteral(self.inferType(arg));
                    if (!self.isDefiniteType(arg_type, 0)) return null_type_idx;
                    members[position] = arg_type;
                }
                const joined = pool.addUnion(self.allocator, members[0..call.args_count]);
                if (joined == null_type_idx) return null_type_idx;
                return pool.addArray(self.allocator, joined);
            },
            .array_from => {
                const arg = self.ir_view.getListIndex(call.args_start, 0);
                const source = pool.widenLiteral(self.resolvedType(self.inferType(arg)));
                const tag = pool.getTag(source) orelse return null_type_idx;
                switch (tag) {
                    .t_string => return pool.addArray(self.allocator, pool.idx_string),
                    .t_array, .t_tuple => {
                        const copied = self.arrayReceiverType(source);
                        if (copied == null_type_idx) return null_type_idx;
                        const copied_element = pool.widenLiteral(pool.getArrayElement(copied));
                        if (copied_element == null_type_idx) return null_type_idx;
                        return pool.addArray(self.allocator, copied_element);
                    },
                    // exhaustive: any other source, such as an object with a
                    // length, gives an array whose elements nothing here
                    // determines.
                    else => return null_type_idx,
                }
            },
            .number,
            .boolean,
            .string,
            .string_array,
            .unknown_array,
            .entry_array,
            .optional_string,
            .undefined_value,
            .unknown_value,
            .json_result,
            => return self.builtinResultType(result),
        }
    }

    /// The type of `.length` on a receiver of type `receiver`: `number` for a
    /// string (a literal receiver widens), an array, and a tuple, and null for
    /// every other receiver.
    fn inferLengthType(self: *const TypeChecker, receiver: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        const tag = pool.getTag(pool.widenLiteral(receiver)) orelse return null_type_idx;
        const scope = switch (tag) {
            .t_string => "String.prototype",
            .t_array, .t_tuple => "Array.prototype",
            // exhaustive: every other receiver type has no `length` row, so the
            // read stays untyped.
            else => return null_type_idx,
        };
        const row = builtin_results.find(.property, scope, "length") orelse return null_type_idx;
        return self.builtinResultType(row.result);
    }

    /// The type of a builtin member on a receiver whose type is the union
    /// `union_type` of strings, arrays, and tuples: a read of `name` when
    /// `call` is null, and the call `call` otherwise. The type is the union of
    /// the result for each member. It is null when a member is another kind of
    /// type, when a member has no row or no result type, and for a method whose
    /// result depends on a callback (`map` and `reduce`), so the result of a
    /// union stays untyped wherever one member's would.
    fn inferUnionBuiltinMember(
        self: *const TypeChecker,
        union_type: TypeIndex,
        name: []const u8,
        call: ?Node.CallExpr,
    ) TypeIndex {
        const pool = self.env.pool;
        var joined: TypeIndex = null_type_idx;
        for (pool.getUnionMembers(union_type)) |raw_member| {
            const member = pool.widenLiteral(self.resolvedType(raw_member));
            const tag = pool.getTag(member) orelse return null_type_idx;
            switch (tag) {
                .t_string, .t_array, .t_tuple => {},
                // exhaustive: a member that is not a string, an array, or a
                // tuple has no row here, so the union result stays untyped.
                else => return null_type_idx,
            }
            var result: TypeIndex = null_type_idx;
            if (call) |member_call| {
                const scope = if (tag == .t_string) "String.prototype" else "Array.prototype";
                const row = builtin_results.find(.call, scope, name) orelse return null_type_idx;
                if (row.result == .map_array or row.result == .reduce_value) return null_type_idx;
                const array = if (tag == .t_string) null_type_idx else self.arrayReceiverType(member);
                if (tag != .t_string and array == null_type_idx) return null_type_idx;
                result = self.builtinCallResult(member_call, row, array);
            } else if (std.mem.eql(u8, name, "length")) {
                result = self.inferLengthType(member);
            }
            if (result == null_type_idx) return null_type_idx;
            joined = self.joinElementTypes(joined, result);
            if (joined == null_type_idx) return null_type_idx;
        }
        return joined;
    }

    /// The result of calling `row` with the arguments of `call`, or null when
    /// the result stays untyped (T1): the count is outside the runtime's range,
    /// an argument is a spread, or an argument that the runtime reads as a
    /// number, a string, a function, or an object has no type or a type that
    /// is not one. `receiver_array` is the array type of the receiver for an
    /// `Array.prototype` row, and null for every other row.
    fn builtinCallResult(
        self: *const TypeChecker,
        call: Node.CallExpr,
        row: builtin_results.Row,
        receiver_array: TypeIndex,
    ) TypeIndex {
        if (!row.acceptsCount(call.args_count)) return null_type_idx;
        const pool = self.env.pool;
        for (0..call.args_count) |position| {
            const arg = self.ir_view.getListIndex(call.args_start, @intCast(position));
            if (self.ir_view.getTag(arg) == .spread) return null_type_idx;
            const param = row.paramAt(position) orelse return null_type_idx;
            if (param == .any) continue;
            const arg_type = self.inferType(arg);
            if (arg_type == null_type_idx or pool.mentionsError(arg_type)) return null_type_idx;
            switch (param) {
                .any => {},
                .number => if (!self.env.isAssignableTo(arg_type, pool.idx_number)) return null_type_idx,
                .string => if (!self.env.isAssignableTo(arg_type, pool.idx_string)) return null_type_idx,
                .function => if (pool.getTag(self.resolvedType(arg_type)) != .t_function) return null_type_idx,
                .object => switch (pool.getTag(self.resolvedType(arg_type)) orelse return null_type_idx) {
                    .t_record, .t_dict, .t_array, .t_tuple => {},
                    // exhaustive: a union, a nullable, a scalar, and every
                    // other type may not be an object at runtime, and
                    // `Object.keys` then returns `undefined`.
                    else => return null_type_idx,
                },
            }
        }
        return switch (row.result) {
            .receiver_array,
            .receiver_element_or_undefined,
            .concat_array,
            .map_array,
            .reduce_value,
            .json_text,
            .array_of,
            .array_from,
            => self.builtinShapedResult(call, row.result, receiver_array),
            .number,
            .boolean,
            .string,
            .string_array,
            .unknown_array,
            .entry_array,
            .optional_string,
            .undefined_value,
            .unknown_value,
            .json_result,
            => self.builtinResultType(row.result),
        };
    }

    /// Whether `node` reads `headers` from a value of the `Request` type. The
    /// type of `req.headers` is the opaque `object`, which a record with its own
    /// `get` also satisfies, so a row applies only to the headers that the
    /// runtime creates for a request, and not to any value typed `object`.
    fn isRequestHeaders(self: *const TypeChecker, node: NodeIndex) bool {
        if (self.ir_view.getTag(node) != .member_access) return false;
        const member = self.ir_view.getMember(node) orelse return false;
        if (member.computed != null_node or member.is_optional) return false;
        const name = self.resolveAtomName(member.property) orelse return false;
        if (!std.mem.eql(u8, name, "headers")) return false;
        const holder = self.inferType(member.object);
        if (holder == null_type_idx) return false;
        const request = abi_types.requestType(self.env);
        if (request == null_type_idx) return false;
        return self.env.resolveRef(holder) == request;
    }

    /// The result of a call of a builtin member: a method of a builtin
    /// namespace, of a string, of an array or a tuple, of a union of these, or
    /// of the headers of a request.
    fn inferBuiltinMemberCall(self: *const TypeChecker, call: Node.CallExpr) TypeIndex {
        const callee = self.ir_view.getMember(call.callee) orelse return null_type_idx;
        if (callee.computed != null_node or callee.is_optional) return null_type_idx;
        const method = self.resolveAtomName(callee.property) orelse return null_type_idx;
        if (self.builtinGlobalName(callee.object)) |namespace| {
            const row = builtin_results.find(.call, namespace, method) orelse return null_type_idx;
            return self.builtinCallResult(call, row, null_type_idx);
        }
        if (self.isRequestHeaders(callee.object)) {
            const row = builtin_results.find(.call, "Headers.prototype", method) orelse return null_type_idx;
            return self.builtinCallResult(call, row, null_type_idx);
        }
        const raw = self.inferType(callee.object);
        if (raw == null_type_idx) return null_type_idx;
        const pool = self.env.pool;
        const receiver = pool.widenLiteral(pool.unwrapNominal(self.env.resolveRef(raw)));
        if (pool.getTag(receiver) == .t_union) return self.inferUnionBuiltinMember(receiver, method, call);
        if (pool.getTag(receiver) == .t_string) {
            const row = builtin_results.find(.call, "String.prototype", method) orelse return null_type_idx;
            return self.builtinCallResult(call, row, null_type_idx);
        }
        const array = self.arrayReceiverType(raw);
        if (array == null_type_idx) return null_type_idx;
        const row = builtin_results.find(.call, "Array.prototype", method) orelse return null_type_idx;
        return self.builtinCallResult(call, row, array);
    }

    /// The result of a call of a builtin global function that no signature or
    /// callable binding answers. A name qualifies only as `builtinGlobalName`
    /// says.
    fn inferBuiltinGlobalCall(self: *const TypeChecker, call: Node.CallExpr) TypeIndex {
        const name = self.builtinGlobalName(call.callee) orelse return null_type_idx;
        const row = builtin_results.find(.call, "global", name) orelse return null_type_idx;
        return self.builtinCallResult(call, row, null_type_idx);
    }

    /// The constructor name when `call` is `Response.<constructor>(...)` on the
    /// `Response` global, otherwise null.
    ///
    /// `Response` is a global with no binding to hang a type on, so the object
    /// side of `Response.json(...)` infers nothing and the member read after it
    /// infers nothing either. Matching the name is how the checker reaches the
    /// only thing that constructs a response. A shadowed `Response` is a
    /// different value and is left alone, the same way `Array.isArray` is.
    ///
    /// `Response.json`, `Response?.json`, and `Response["json"]` name the same
    /// constructor. Strict mode refuses a computed key that is not a literal
    /// (ZTS605), and the parser refuses an optional computed access.
    fn responseConstructorName(self: *const TypeChecker, call: Node.CallExpr) ?[]const u8 {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return null;
        if (callee_tag != .member_access and callee_tag != .optional_chain and callee_tag != .computed_access) return null;
        const callee = self.ir_view.getMember(call.callee) orelse return null;
        if (self.ir_view.getTag(callee.object) != .identifier) return null;
        const object_binding = self.ir_view.getBinding(callee.object) orelse return null;
        const object_name = self.resolveAtomName(object_binding.name_atom) orelse return null;
        if (!std.mem.eql(u8, object_name, abi_types.RESPONSE_TYPE_NAME)) return null;
        if (self.binding_types.get(bindingKey(object_binding)) != null) return null;
        const spelled = if (callee_tag == .computed_access)
            self.literalKeyName(callee.computed)
        else
            self.resolveAtomName(callee.property);
        const method = spelled orelse return null;
        if (!abi_types.isResponseConstructor(method)) return null;
        return method;
    }

    /// The text of the string literal at `key`, or null when `key` is not one.
    fn literalKeyName(self: *const TypeChecker, key: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(key) != .lit_string) return null;
        return self.getLiteralString(key);
    }

    /// The `Response` type when `call` is one of the constructors on the
    /// `Response` global, otherwise `null_type_idx`.
    fn inferResponseConstructorType(self: *const TypeChecker, call: Node.CallExpr) TypeIndex {
        if (self.responseConstructorName(call) == null) return null_type_idx;
        return abi_types.responseType(self.env);
    }

    fn inferCallType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const call = self.ir_view.getCall(node) orelse return null_type_idx;
        const callee_tag = self.ir_view.getTag(call.callee) orelse return null_type_idx;

        if (callee_tag == .member_access) {
            const constructed = self.inferResponseConstructorType(call);
            if (constructed != null_type_idx) return constructed;
            const declared = self.inferFunctionReturnType(self.inferType(call.callee));
            if (declared != null_type_idx) return declared;
            return self.inferBuiltinMemberCall(call);
        }
        if (callee_tag != .identifier) return null_type_idx;

        const binding = self.ir_view.getBinding(call.callee) orelse return null_type_idx;
        if (self.boundCallableMetadata(binding)) |metadata| {
            return switch (metadata) {
                .unavailable, .arity => null_type_idx,
                .signature => |sig| self.instantiatedReturnType(node, sig, call),
            };
        }
        if (self.resultExportCallType(binding, call)) |typed| return typed;
        if (self.collectionsExportCallType(binding, call)) |typed| return typed;
        const name = self.resolveAtomName(binding.name_atom) orelse return null_type_idx;
        // `hole()` types as `never`, the bottom type, so it is assignable to
        // whatever the surrounding context expects and the rest of the program
        // keeps checking. Inferring `unknown` instead would make every hole a
        // second diagnostic on top of the one that says the hole is there.
        if (std.mem.eql(u8, name, "hole")) return self.env.pool.idx_never;
        if (std.mem.eql(u8, name, "validateJson") or
            std.mem.eql(u8, name, "validateObject") or
            std.mem.eql(u8, name, "coerceJson") or
            std.mem.eql(u8, name, "decodeJson") or
            std.mem.eql(u8, name, "decodeForm") or
            std.mem.eql(u8, name, "decodeQuery"))
        {
            if (call.args_count > 0) {
                const schema_node = self.ir_view.getListIndex(call.args_start, 0);
                if (self.getLiteralString(schema_node)) |schema_name| {
                    if (self.schemaTypeByName(schema_name)) |schema_type| {
                        return self.typedResultType(schema_type, self.moduleResultErrorType(name), self.moduleResultErrorsType(name));
                    }
                }
            }
        }
        // A nominal name in call position keeps answering its own type here,
        // which is what stops the declaration it sits in from raising a second,
        // misleading mismatch on the same line. The refusal is reported once by
        // `walkExpr`, which is the mutable pass; inference stays pure.
        if (self.env.getTypeAlias(name)) |alias_type| {
            if (self.env.pool.isNominal(alias_type)) {
                return alias_type;
            }
        }
        const sig = self.env.getFnSigByName(name) orelse return self.inferBuiltinGlobalCall(call);
        return self.instantiatedReturnType(node, sig, call);
    }

    /// The return type of one call to `sig`, with this call's type arguments
    /// substituted. A signature that declares no type parameters, and a call
    /// whose parameters could not all be bound, return the declared type
    /// unchanged - the refusal is reported by `checkCallArgs`, and inferring
    /// `unknown` here would turn one diagnostic into a cascade.
    fn instantiatedReturnType(
        self: *const TypeChecker,
        node: NodeIndex,
        sig: type_env_mod.FunctionSig,
        call: Node.CallExpr,
    ) TypeIndex {
        if (sig.type_param_count == 0) return sig.return_type;
        return self.substitute(self.instantiateSignature(node, sig, call), sig.return_type);
    }

    fn inferMatchType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const me = self.ir_view.getMatchExpr(node) orelse return null_type_idx;
        if (me.arms_count == 0) return null_type_idx;

        var result: TypeIndex = null_type_idx;
        for (0..me.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;
            const arm_type = self.inferType(arm.body);
            if (result == null_type_idx) {
                result = arm_type;
            } else if (arm_type != null_type_idx and arm_type != result) {
                // Different arm types - create union
                result = self.env.pool.addUnion(self.allocator, &.{ result, arm_type });
            }
        }
        if (result == null_type_idx) return result;
        // A match whose arms are not proved to cover every value evaluates to
        // `undefined` when none of them matches (spec 5.5, codegen), so its
        // type admits `undefined`. Without this the paths that run no strict
        // checker would type a partial match as if it were total.
        var coverage = self.matchCoverage(me, false);
        defer coverage.deinit(self.allocator);
        if (!coverage.exhaustive) {
            result = self.env.pool.addUnion(self.allocator, &.{ result, self.env.pool.idx_undefined });
        }
        return result;
    }

    // -------------------------------------------------------------------
    // Match expression narrowing
    // -------------------------------------------------------------------

    fn bindVarDeclaration(
        self: *TypeChecker,
        declaration: NodeIndex,
        binding: ir.BindingRef,
    ) TypeIndex {
        const declared = switch (self.env.sourceTypeMode() orelse .omitted) {
            .direct => self.env.getVarTypeForDeclaration(self.ir_view, declaration) orelse null_type_idx,
            .omitted => null_type_idx,
        };
        if (declared != null_type_idx) {
            self.env.bindVarType(binding.scope_id, binding.name_atom, declared) catch self.markAllocationFailure();
            self.bound_var_annotations += 1;
        }
        return declared;
    }

    fn bindCallableMetadata(self: *TypeChecker, binding: ir.BindingRef, metadata: CallableMetadata) void {
        const key = bindingKey(binding);
        self.binding_callables.put(self.allocator, key, metadata) catch {
            self.markAllocationFailure();
            return;
        };
    }

    /// The declaring binding of an `upvalue` reference, read from the parser's
    /// record of that closure's captures. The upvalue's `scope_id` is the
    /// closure's function scope and its `slot` indexes that scope's upvalue
    /// list, whose entry names the source scope and slot of the declaration
    /// (a transitive capture keeps the original source). The declaration's
    /// kind comes from the source scope's binding at that slot: a parameter is
    /// an `argument` and anything else is a `local`, which is what a direct
    /// read of it carries, so `bindingKey` of the result is the key the
    /// declaration was bound under. A global is never captured: a reference
    /// to one is `global` and shares its declaration's key.
    ///
    /// Null when the record is absent or does not hold the upvalue. The caller
    /// then has no type for it. Searching by name instead would find an
    /// unrelated outer binding whenever the captured one is a `for...of` or
    /// `match` binding.
    fn captureSource(self: *const TypeChecker, upvalue: ir.BindingRef) ?ir.BindingRef {
        if (upvalue.kind != .upvalue) return upvalue;
        const scopes = self.scopes orelse return null;
        if (upvalue.scope_id >= scopes.scopes.items.len) return null;
        const captures = scopes.scopes.items[upvalue.scope_id].upvalues.items;
        if (upvalue.slot >= captures.len) return null;
        const capture = captures[upvalue.slot];
        if (capture.source_scope_id >= scopes.scopes.items.len) return null;
        for (scopes.scopes.items[capture.source_scope_id].bindings.items) |source| {
            if (source.slot != capture.source_slot) continue;
            return .{
                .scope_id = capture.source_scope_id,
                .slot = capture.source_slot,
                .name_atom = source.name_atom,
                .kind = if (source.kind == .parameter) .argument else .local,
            };
        }
        return null;
    }

    /// Whether the declaration that `upvalue` captures is a `const` variable.
    /// A parameter, a function, an import, and a `let` answer false.
    fn captureSourceIsConst(self: *const TypeChecker, upvalue: ir.BindingRef) bool {
        if (upvalue.kind != .upvalue) return false;
        const scopes = self.scopes orelse return false;
        if (upvalue.scope_id >= scopes.scopes.items.len) return false;
        const captures = scopes.scopes.items[upvalue.scope_id].upvalues.items;
        if (upvalue.slot >= captures.len) return false;
        const capture = captures[upvalue.slot];
        if (capture.source_scope_id >= scopes.scopes.items.len) return false;
        for (scopes.scopes.items[capture.source_scope_id].bindings.items) |source| {
            if (source.slot != capture.source_slot) continue;
            return source.is_const and source.kind == .variable;
        }
        return false;
    }

    // -------------------------------------------------------------------
    // File imports (compile path of a multi-module build)
    // -------------------------------------------------------------------

    fn fileImportKey(binding: ir.BindingRef) u32 {
        return (@as(u32, @backingInt(binding.kind)) << 16) | @as(u32, binding.slot);
    }

    /// Give every file import its type in this checker's pool: the callable
    /// metadata of a function export in `file_import_callables`, and the type
    /// of a value export in `binding_types`, under the key of the import's
    /// binding. An import that gets neither is listed in `file_import_untyped`.
    /// The table is null off the compile path, and nothing happens then.
    fn materializeFileImports(self: *TypeChecker) void {
        const rows = self.file_imports orelse return;
        const facts = self.import_facts orelse
            if (self.owned_import_facts) |*owned| owned else {
                self.binding_resolution_failed = true;
                return;
            };
        var copier: import_signatures_mod.Copier = .{
            .allocator = self.allocator,
            .src = rows.source,
            .src_env = null,
            .dst = self.env.pool,
            .dst_env = self.env,
        };
        defer copier.deinit();
        for (0..self.ir_view.nodeCount()) |index| {
            const node: NodeIndex = @intCast(index);
            if (self.ir_view.getTag(node) != .import_decl) continue;
            const decl = self.ir_view.getImportDecl(node) orelse {
                self.binding_resolution_failed = true;
                continue;
            };
            const specifier = self.ir_view.getString(decl.module_idx) orelse {
                self.binding_resolution_failed = true;
                continue;
            };
            if (importsVirtualModule(facts, specifier)) continue;
            for (0..decl.specifiers_count) |position| {
                const spec_index = self.ir_view.getListIndex(decl.specifiers_start, @intCast(position));
                const spec = self.ir_view.getImportSpec(spec_index) orelse {
                    self.binding_resolution_failed = true;
                    continue;
                };
                self.materializeFileImport(&copier, rows, specifier, spec);
            }
        }
    }

    fn importsVirtualModule(facts: *const module_facts_mod.ModuleFacts, specifier: []const u8) bool {
        for (facts.modules.items) |module| {
            if (std.mem.eql(u8, module, specifier)) return true;
        }
        return false;
    }

    fn materializeFileImport(
        self: *TypeChecker,
        copier: *import_signatures_mod.Copier,
        rows: *const import_signatures_mod.FileImportSignatures,
        specifier: []const u8,
        spec: ir.Node.ImportSpec,
    ) void {
        var metadata: CallableMetadata = .unavailable;
        var typed = false;
        switch (spec.kind) {
            .named => if (self.resolveAtomName(spec.imported_atom)) |imported| {
                if (rows.find(specifier, imported)) |row| {
                    if (row.sig) |source_sig| {
                        if (copier.copySignature(source_sig)) |copied| {
                            metadata = .{ .signature = copied };
                            typed = true;
                        }
                    }
                    const value = copier.copy(row.value_type);
                    if (value != null_type_idx) {
                        if (self.env.pool.getTag(value) == .t_function) {
                            // A value of function type is called through its
                            // signature, which a call reads from the metadata.
                            if (!typed) {
                                metadata = self.callableMetadataFromType(value);
                                typed = metadata != .unavailable;
                            }
                        } else {
                            self.binding_types.put(self.allocator, bindingKey(spec.local_binding), value) catch self.markAllocationFailure();
                            typed = true;
                        }
                    }
                }
            },
            // exhaustive: a default or namespace import has no export row, so
            // it has no type that crosses a module.
            .default, .namespace => {},
        }
        const key = fileImportKey(spec.local_binding);
        self.file_import_callables.put(self.allocator, key, metadata) catch self.markAllocationFailure();
        if (!typed) self.file_import_untyped.append(self.allocator, spec.local_binding.name_atom) catch self.markAllocationFailure();
    }

    /// The local name of the first file import that holds neither a signature
    /// nor a value type, or null when every file import is typed. Always null
    /// when no file import table is set. The compile path of a multi-module
    /// build asks it after the check, and refuses the build on a name.
    pub fn firstUntypedFileImport(self: *const TypeChecker) ?[]const u8 {
        if (self.file_import_untyped.items.len == 0) return null;
        return self.resolveAtomName(self.file_import_untyped.items[0]) orelse "<unnamed>";
    }

    /// What a file import holds, or null for a binding that is not one.
    fn fileImportCallable(self: *const TypeChecker, binding: ir.BindingRef) ?CallableMetadata {
        if (self.file_imports == null) return null;
        return self.file_import_callables.get(fileImportKey(binding));
    }

    /// Record the exports of this checked module in `table`, under the module's
    /// index in the graph: the signature of a function, and the declared or
    /// inferred type of a `const` or `let`. An export whose type does not copy
    /// gets a row without it.
    pub fn recordExportedSignatures(
        self: *TypeChecker,
        root: NodeIndex,
        module: u16,
        table: *import_signatures_mod.ExportedSignatures,
    ) !void {
        try self.ensureHealthy();
        const block = self.ir_view.getBlock(root) orelse return;
        var copier = table.copierFrom(self.env.pool, self.env);
        defer copier.deinit();
        for (0..block.stmts_count) |i| {
            const stmt = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
            if (self.ir_view.getTag(stmt) != .export_decl) continue;
            const export_decl = self.ir_view.getExportDecl(stmt) orelse continue;
            if (export_decl.declaration == null_node) continue;
            const declaration_tag = self.ir_view.getTag(export_decl.declaration) orelse continue;
            switch (declaration_tag) {
                .function_decl, .var_decl => {},
                // exhaustive: only a function or a variable declaration exports a
                // value. Any other export form gets no row, and an import of it
                // finds no row, so that import is untyped and the build refuses it.
                else => continue,
            }
            const decl = self.ir_view.getVarDecl(export_decl.declaration) orelse continue;
            const name = self.resolveAtomName(decl.binding.name_atom) orelse continue;
            var sig: ?type_env_mod.FunctionSig = null;
            if (decl.init != null_node) {
                if (self.sourceFunctionSignature(decl.init)) |source_sig| {
                    sig = copier.copySignature(source_sig);
                } else if (self.binding_callables.get(bindingKey(decl.binding))) |bound| {
                    // `export const alias = helper;` keeps the signature of `helper`.
                    switch (bound) {
                        .signature => |bound_sig| sig = copier.copySignature(bound_sig),
                        .arity, .unavailable => {},
                    }
                }
            }
            var value_type: TypeIndex = null_type_idx;
            if (declaration_tag == .var_decl) {
                const declared_type = self.typeOfDeclaration(decl.binding);
                if (declared_type != null_type_idx) value_type = copier.copy(declared_type);
            }
            try table.add(module, name, sig, value_type);
        }
        try table.pool.ensureHealthy();
    }

    fn boundCallableMetadata(self: *const TypeChecker, binding: ir.BindingRef) ?CallableMetadata {
        // A capture the record cannot resolve is unknown. `unavailable` says so
        // and keeps the by-name module signature from answering for it.
        const declaration = self.captureSource(binding) orelse return .unavailable;
        if (self.binding_callables.get(bindingKey(declaration))) |metadata| return metadata;
        return self.fileImportCallable(declaration);
    }

    fn callableSignatureForBinding(self: *const TypeChecker, binding: ir.BindingRef) ?type_env_mod.FunctionSig {
        if (self.boundCallableMetadata(binding)) |metadata| {
            return switch (metadata) {
                .unavailable, .arity => null,
                .signature => |sig| sig,
            };
        }

        const name = self.resolveAtomName(binding.name_atom) orelse return null;
        return self.env.getFnSigByName(name);
    }

    /// How the runtime calls the inline callback of an array method, which
    /// decides the parameters that the checker can type.
    const CallbackShape = enum {
        /// `(element, index, array)`: `map`, `filter`, `find`, `findIndex`,
        /// `forEach`, `some`, and `every`.
        element_index_array,
        /// Only the element is typed. `flatMap` is not installed.
        element_only,
        /// `toSorted` calls its comparator with two elements.
        comparator,
        /// `reduce` calls `(accumulator, element, index, array)`.
        reduce,
    };

    fn callbackShape(name: []const u8) ?CallbackShape {
        const element_index_array = [_][]const u8{ "map", "filter", "find", "findIndex", "forEach", "some", "every" };
        for (element_index_array) |m| {
            if (std.mem.eql(u8, m, name)) return .element_index_array;
        }
        if (std.mem.eql(u8, name, "flatMap")) return .element_only;
        if (std.mem.eql(u8, name, "toSorted")) return .comparator;
        if (std.mem.eql(u8, name, "reduce")) return .reduce;
        return null;
    }

    /// An unannotated parameter of an inline array callback takes the type of
    /// the value that the runtime passes in its position, so a read of it is
    /// checked like any other. The switch below lists the positions.
    ///
    /// Annotations are stored compactly: the signature of a function holds
    /// the annotated parameters only, with no position. A callback with some
    /// but not all parameters annotated therefore binds nothing here, because
    /// an annotation cannot be told from a gap. A callback with every
    /// parameter annotated binds each to its annotation (`bindAnnotatedCallbackParams`).
    /// An annotation wins.
    fn bindCallbackElement(self: *TypeChecker, c: Node.CallExpr) void {
        if (c.args_count == 0) return;
        const callee_tag = self.ir_view.getTag(c.callee) orelse return;
        if (callee_tag == .identifier) {
            self.bindCombinatorCallback(c);
            self.bindDictCallback(c);
            return;
        }
        if (callee_tag != .member_access) return;
        const member = self.ir_view.getMember(c.callee) orelse return;
        const name = self.resolveAtomName(member.property) orelse return;
        const shape = callbackShape(name) orelse return;
        const pool = self.env.pool;
        const arg = self.ir_view.getListIndex(c.args_start, 0);
        const arg_tag = self.ir_view.getTag(arg) orelse return;
        if (arg_tag != .arrow_function and arg_tag != .function_expr) return;
        const func = self.ir_view.getFunction(arg) orelse return;
        if (func.params_count == 0) return;
        if (self.bindAnnotatedCallbackParams(arg, func)) return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const raw = self.inferType(member.object);
        if (raw == null_type_idx) return;
        var arr = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(arr) orelse return;
        if (tag == .t_tuple) arr = self.tupleToArrayType(arr) else if (tag != .t_array) return;
        const elem = pool.getArrayElement(arr);
        if (elem == null_type_idx) return;
        switch (shape) {
            .element_index_array => {
                _ = self.bindCallbackParam(func, 0, elem);
                _ = self.bindCallbackParam(func, 1, pool.idx_number);
                _ = self.bindCallbackParam(func, 2, arr);
            },
            .element_only => _ = self.bindCallbackParam(func, 0, elem),
            .comparator => {
                _ = self.bindCallbackParam(func, 0, elem);
                _ = self.bindCallbackParam(func, 1, elem);
            },
            .reduce => {
                _ = self.bindCallbackParam(func, 1, elem);
                _ = self.bindCallbackParam(func, 2, pool.idx_number);
                _ = self.bindCallbackParam(func, 3, arr);
                self.bindReduceAccumulator(c, arg, func, elem);
            },
        }
    }

    /// Bind each parameter of an inline callback to its annotation when every
    /// parameter is annotated, so the body reads under the types it declares
    /// before the call is checked. A callback that has any annotation is
    /// annotated here and nowhere else: a signature stores annotations without
    /// positions, so a partly annotated callback binds nothing. Returns true
    /// when the callback has an annotation.
    fn bindAnnotatedCallbackParams(self: *TypeChecker, arg: NodeIndex, func: ir.Node.FunctionExpr) bool {
        const sig = self.sourceFunctionSignature(arg) orelse return false;
        if (sig.param_count == 0) return false;
        if (sig.param_count != func.params_count or sig.type_param_count > 0) return true;
        for (0..func.params_count) |i| {
            const declared = sig.param_types[i];
            if (declared == null_type_idx) continue;
            _ = self.bindCallbackParam(func, @intCast(i), declared);
        }
        return true;
    }

    /// The callback of `mapResult`, `mapError`, `andThen`, or `orElse` from
    /// `zttp:result` is called with one value: the payload of the Result. An
    /// unannotated inline callback takes the type of that value (T4). A type
    /// that is not known leaves the parameter untyped.
    fn bindCombinatorCallback(self: *TypeChecker, c: Node.CallExpr) void {
        const name = self.resultExportName(c) orelse return;
        if (!isCallbackCombinator(name) or c.args_count != 2) return;
        const arg = self.ir_view.getListIndex(c.args_start, 1);
        const arg_tag = self.ir_view.getTag(arg) orelse return;
        if (arg_tag != .arrow_function and arg_tag != .function_expr) return;
        const func = self.ir_view.getFunction(arg) orelse return;
        if (func.params_count == 0) return;
        if (self.bindAnnotatedCallbackParams(arg, func)) return;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const passed = self.bindableType(self.combinatorPassedType(name, c));
        if (passed == null_type_idx) return;
        _ = self.bindCallbackParam(func, 0, passed);
    }

    /// The callback of `dictFold`, `dictMapValues`, or `dictFilter` over one
    /// Dict type `Dict<K, V>`. The runtime calls the fold with `(accumulator,
    /// value, key)` and the other two with `(value, key)`. An unannotated
    /// inline callback binds those parameters to `(acc, V, K)` and `(V, K)`,
    /// where `acc` follows the rule of a seeded `reduce`
    /// (`bindSeededAccumulator`) with the third argument as the seed. The
    /// types stand as they are: over a `Dict<unknown, unknown>` the value and
    /// the key are `unknown`, and arithmetic on the value is refused. A Dict
    /// with no key holds no entry, so its callback never runs and binds
    /// nothing. An annotation wins, as for the array methods.
    fn bindDictCallback(self: *TypeChecker, c: Node.CallExpr) void {
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        const info = self.dictCallbackCall(c) orelse return;
        const arg = info.callback;
        const arg_tag = self.ir_view.getTag(arg) orelse return;
        if (arg_tag != .arrow_function and arg_tag != .function_expr) return;
        const func = self.ir_view.getFunction(arg) orelse return;
        if (func.params_count == 0) return;
        if (self.bindAnnotatedCallbackParams(arg, func)) return;
        const pool = self.env.pool;
        if (info.parts.key == pool.idx_never) return;
        if (std.mem.eql(u8, info.name, "dictFold")) {
            _ = self.bindCallbackParam(func, 1, info.parts.value);
            _ = self.bindCallbackParam(func, 2, info.parts.key);
            const seed_source = self.inferType(self.ir_view.getListIndex(c.args_start, 2));
            // A refused accumulator stays untyped and the fold result is unknown.
            _ = self.bindSeededAccumulator(arg, func, seed_source);
        } else {
            _ = self.bindCallbackParam(func, 0, info.parts.value);
            _ = self.bindCallbackParam(func, 1, info.parts.key);
        }
    }

    /// Bind parameter `position` of `func` to `type_idx`. Returns the binding,
    /// or null when the function has no such parameter.
    fn bindCallbackParam(self: *TypeChecker, func: ir.Node.FunctionExpr, position: u16, type_idx: TypeIndex) ?ir.BindingRef {
        if (position >= func.params_count) return null;
        const param_idx = self.ir_view.getListIndex(func.params_start, position);
        const binding = self.ir_view.paramBinding(param_idx) orelse return null;
        self.param_types.put(self.allocator, bindingKey(binding), type_idx) catch self.markAllocationFailure();
        self.env.bindVarType(binding.scope_id, binding.name_atom, type_idx) catch self.markAllocationFailure();
        return binding;
    }

    fn unbindCallbackParam(self: *TypeChecker, binding: ir.BindingRef) void {
        _ = self.param_types.remove(bindingKey(binding));
        self.env.unbindVarType(binding.scope_id, binding.name_atom);
    }

    /// What `bindSeededAccumulator` did with the accumulator parameter.
    const AccumulatorBinding = union(enum) {
        /// The parameter is bound to the widened seed.
        kept,
        /// The parameter stays untyped: the seed or the callback return has no
        /// definite type.
        untyped,
        /// The callback returns this type, which the seed type does not hold.
        refused: struct { returned: TypeIndex, seed: TypeIndex },
    };

    /// The runtime passes the accumulator of `reduce` as the initial value
    /// first, and as each callback result after that. The widened initial
    /// value type (the element type when there is no initial value) describes
    /// the accumulator on every call only when the callback returns a value
    /// of that type. So the checker binds the accumulator to that type, reads
    /// the callback's return type under the binding, and keeps the binding
    /// only when the return type is known and assignable to it. A return type
    /// that is not assignable is reported (ZTS200). A return type that is not
    /// known leaves the accumulator untyped.
    fn bindReduceAccumulator(self: *TypeChecker, c: Node.CallExpr, arg: NodeIndex, func: ir.Node.FunctionExpr, elem: TypeIndex) void {
        const seed_source = if (c.args_count >= 2) self.inferType(self.ir_view.getListIndex(c.args_start, 1)) else elem;
        switch (self.bindSeededAccumulator(arg, func, seed_source)) {
            .refused => |refusal| self.reportReduceAccumulator(arg, refusal.returned, refusal.seed),
            // exhaustive: a kept or untyped accumulator reports nothing.
            .kept, .untyped => {},
        }
    }

    /// Bind the first parameter of the inline callback `func` to the widened
    /// type of `seed_source`, read the callback's return type under the
    /// binding, and keep the binding only when that return type is known and
    /// assignable to it. The caller reports a refused return.
    fn bindSeededAccumulator(self: *TypeChecker, arg: NodeIndex, func: ir.Node.FunctionExpr, seed_source: TypeIndex) AccumulatorBinding {
        const pool = self.env.pool;
        if (seed_source == null_type_idx) return .untyped;
        const seed = pool.widenLiteral(seed_source);
        if (!self.isDefiniteType(seed, 0)) return .untyped;
        const binding = self.bindCallbackParam(func, 0, seed) orelse return .untyped;
        const callback_type = self.functionExprType(arg);
        const returned = if (callback_type == null_type_idx) null_type_idx else self.callbackReturnType(callback_type);
        if (returned == null_type_idx) {
            self.unbindCallbackParam(binding);
            return .untyped;
        }
        if (self.env.isAssignableTo(returned, seed)) return .kept;
        self.unbindCallbackParam(binding);
        return .{ .refused = .{ .returned = returned, .seed = seed } };
    }

    fn reportReduceAccumulator(self: *TypeChecker, callback: NodeIndex, returned: TypeIndex, accumulator: TypeIndex) void {
        for (self.diagnostics.items) |existing| {
            if (existing.node == callback and existing.kind == .type_mismatch) return;
        }
        var buf: [256]u8 = undefined;
        const returned_str = self.env.pool.formatType(returned, buf[0..128]);
        const accumulator_str = self.env.pool.formatType(accumulator, buf[128..256]);
        const message = self.allocator.print(
            "reduce callback returns '{s}', but its accumulator is '{s}'",
            .{ returned_str, accumulator_str },
        ) catch {
            self.markAllocationFailure();
            return;
        };
        const help = self.allocator.print(
            "annotate the accumulator with a type that holds both, or return a '{s}'",
            .{accumulator_str},
        ) catch {
            self.allocator.free(message);
            self.markAllocationFailure();
            return;
        };
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .type_mismatch,
            .node = callback,
            .message = message,
            .help = help,
            .allocated = true,
            .help_owned = true,
        });
    }

    fn sourceFunctionSignature(
        self: *const TypeChecker,
        owner: NodeIndex,
    ) ?type_env_mod.FunctionSig {
        const reference = self.env.functionTypeRef(self.ir_view, owner) orelse return null;
        return self.env.getFunctionSignature(reference);
    }

    /// What a call may rely on for the callee a `const` or declaration binds.
    ///
    /// The parameter nodes of a source function are the authority on how many
    /// arguments it takes. The annotation-built signature can hold fewer
    /// entries (a parameter left unannotated adds none), so the count comes
    /// from the function and rides on the signature as `max_arg_count`. A
    /// function with no annotation at all still has a count, and keeps it.
    fn sourceFunctionMetadata(func: ir.Node.FunctionExpr, sig: ?type_env_mod.FunctionSig) CallableMetadata {
        var with_count = sig orelse return .{ .arity = func.params_count };
        with_count.max_arg_count = func.params_count;
        return .{ .signature = with_count };
    }

    /// `exact_arity` says the binding cannot be reassigned, so the parameter
    /// count of the function it was first given still holds at every call. A
    /// `let` keeps the older, weaker reading.
    fn callableMetadataForExpression(
        self: *const TypeChecker,
        node: NodeIndex,
        inferred: TypeIndex,
        exact_arity: bool,
    ) CallableMetadata {
        const tag = self.ir_view.getTag(node) orelse return .unavailable;
        return switch (tag) {
            .identifier => blk: {
                const binding = self.ir_view.getBinding(node) orelse break :blk .unavailable;
                // An alias of a bound callable keeps everything known of it,
                // including a bare parameter count.
                if (self.boundCallableMetadata(binding)) |bound| break :blk bound;
                const sig = self.callableSignatureForBinding(binding) orelse break :blk .unavailable;
                break :blk .{ .signature = sig };
            },
            .function_expr, .arrow_function => blk: {
                const sig = self.sourceFunctionSignature(node);
                if (exact_arity) {
                    if (self.ir_view.getFunction(node)) |func| break :blk sourceFunctionMetadata(func, sig);
                }
                break :blk .{ .signature = sig orelse break :blk .unavailable };
            },
            else => self.callableMetadataFromType(inferred),
        };
    }

    fn callableMetadataFromType(self: *const TypeChecker, type_idx: TypeIndex) CallableMetadata {
        if (self.env.pool.getTag(type_idx) != .t_function) return .unavailable;
        const info = self.env.pool.getFunctionInfo(type_idx);
        if (info.params.len > 16) return .unavailable;

        var sig: type_env_mod.FunctionSig = .{};
        sig.param_count = @intCast(info.params.len);
        sig.return_type = info.ret;
        var required_param_count: u8 = 0;
        for (info.params, 0..) |param, i| {
            sig.param_types[i] = param.type_idx;
            if (!param.optional) required_param_count += 1;
        }
        sig.required_param_count = required_param_count;
        return .{ .signature = sig };
    }

    fn declaredTypeForBinding(self: *const TypeChecker, binding: ir.BindingRef) TypeIndex {
        // A captured binding has the type its declaration has. A closure can run
        // at any time, so the narrowing the walk holds at the closure's position
        // does not describe a captured `let` or parameter: those can change.
        // A `const` cannot change, and the closure is created on the path where
        // the guard ran, so a narrowing of a `const` reaches the closure. After
        // `check` returns the overlay is closed and the declared type answers.
        if (binding.kind == .upvalue) {
            const declaration = self.captureSource(binding) orelse return null_type_idx;
            if (self.captureSourceIsConst(binding)) {
                if (self.narrowed.get(bindingKey(declaration))) |t| return t;
            }
            return self.typeOfDeclaration(declaration);
        }

        if (self.env.getVarTypeByBinding(binding.scope_id, binding.name_atom)) |declared| {
            return declared;
        }

        if (binding.kind == .undeclared_global) {
            const name = self.resolveAtomName(binding.name_atom) orelse return null_type_idx;
            return self.env.getVarTypeByName(name) orelse null_type_idx;
        }
        return null_type_idx;
    }

    /// The type a declaration holds, never the narrowing the walk has put on
    /// it: the declared or inferred type of a `const`, `let`, `for...of` or
    /// pattern binding, then the annotation in the environment, then the
    /// parameter type. `declaration` is not an `upvalue`.
    fn typeOfDeclaration(self: *const TypeChecker, declaration: ir.BindingRef) TypeIndex {
        const key = bindingKey(declaration);
        if (self.binding_types.get(key)) |t| return t;
        const declared = self.declaredTypeForBinding(declaration);
        if (declared != null_type_idx) return declared;
        return self.param_types.get(key) orelse null_type_idx;
    }

    /// The type a value assigned to `target` must satisfy, or `null_type_idx`
    /// when the target has none. One lookup for every identifier target: a
    /// captured target resolves to its declaration first, so a `let` or a
    /// parameter is checked the same way inside a closure and outside it.
    fn assignmentTargetType(self: *const TypeChecker, target: ir.BindingRef) TypeIndex {
        const declaration = self.captureSource(target) orelse return null_type_idx;
        return self.typeOfDeclaration(declaration);
    }

    fn walkMatchWithNarrowing(self: *TypeChecker, me: ir.Node.MatchExpr) void {
        // Check if discriminant is an identifier with a union type
        const disc_tag = self.ir_view.getTag(me.discriminant) orelse return;
        var disc_type: TypeIndex = null_type_idx;
        const disc_key: ?u64 = if (disc_tag == .identifier) blk: {
            const binding = self.ir_view.getBinding(me.discriminant) orelse break :blk null;
            // The same fallback chain every other guard extractor uses. Reading
            // `binding_types` alone sees `const` and `let` only, so a `match`
            // over a function parameter - the shape the corpus is written in -
            // found no union and narrowed no arm.
            disc_type = self.currentBindingType(binding) orelse null_type_idx;
            break :blk bindingKey(binding);
        } else null;
        // A scrutinee that is not a plain name still has a type. Without it,
        // the arms bound nothing and a `when { q: v }` arm read `v` untyped.
        if (disc_key == null) {
            const previous = self.report_inference_diagnostics;
            self.report_inference_diagnostics = false;
            disc_type = self.inferType(me.discriminant);
            self.report_inference_diagnostics = previous;
        }

        const pool = self.env.pool;
        // Over `T | undefined`, a `when undefined` arm sees `undefined` and
        // every other arm sees `T`, with its bindings typed from `T`.
        const disc_absent = self.admitsUndefined(disc_type);
        var present_type: TypeIndex = null_type_idx;
        if (disc_absent and disc_type != null_type_idx) {
            const resolved = pool.unwrapNominal(self.env.resolveRef(disc_type));
            switch (pool.getTag(resolved) orelse .t_never) {
                .t_nullable => present_type = pool.getNullableInner(resolved),
                .t_union => {
                    var kept: std.ArrayListUnmanaged(TypeIndex) = .empty;
                    defer kept.deinit(self.allocator);
                    for (pool.getUnionMembers(resolved)) |m| {
                        const mt = pool.getTag(m) orelse continue;
                        if (mt == .t_undefined) continue;
                        if (mt == .t_nullable) {
                            kept.append(self.allocator, pool.getNullableInner(m)) catch self.markAllocationFailure();
                            continue;
                        }
                        kept.append(self.allocator, m) catch self.markAllocationFailure();
                    }
                    if (kept.items.len > 0) present_type = pool.addUnion(self.allocator, kept.items);
                },
                // exhaustive: only `T?` and a union carry a present part to
                // narrow to; any other type keeps the scrutinee's own type
                // and its arm bindings fall back to `unknown`.
                else => {},
            }
        }
        const base_type = if (present_type != null_type_idx) present_type else disc_type;
        const base_resolved = pool.unwrapNominal(self.env.resolveRef(base_type));
        const is_union = if (pool.getTag(base_resolved)) |tag| tag == .t_union else false;

        // Each arm is an alternative path, so it runs in its own narrow scope
        // and the arms do not see each other's kills. The scope undoes the
        // arm's narrowing of the scrutinee and its kills; the kills of every
        // arm come back after the `match`.
        var join: KillSet = .{};
        for (0..me.arms_count) |i| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, @intCast(i));
            const arm = self.ir_view.getMatchArm(arm_idx) orelse continue;

            const mark = self.beginNarrowScope();
            // Unless the arm narrows a union, it sees the scrutinee's own type.
            // A binding still needs its field type: without one it infers
            // nothing, and a call that misuses it is checked against nothing.
            var scrutinee = disc_type;
            const is_undefined_arm = arm.pattern != ir.null_node and self.ir_view.getTag(arm.pattern) == .lit_undefined;
            if (present_type != null_type_idx and arm.pattern != ir.null_node) {
                scrutinee = if (is_undefined_arm) pool.idx_undefined else present_type;
                if (disc_key) |k| self.putNarrowed(k, scrutinee);
            }
            if (is_union and arm.pattern != ir.null_node and !is_undefined_arm) {
                const narrowed_type = self.findUnionMemberForPattern(base_resolved, arm.pattern);
                if (narrowed_type != null_type_idx) {
                    if (disc_key) |k| self.putNarrowed(k, narrowed_type);
                    scrutinee = narrowed_type;
                }
            }
            self.bindPatternBindings(arm.pattern, scrutinee);
            self.walkExpr(arm.body);
            join.merge(self.endNarrowScope(mark));
        }
        self.applyKills(join);
    }

    /// Give every field a record pattern binds the type that field has in the
    /// arm's narrowed scrutinee (spec 5.5). Without this the bound name infers
    /// nothing, and every use of it is checked against nothing - which is the
    /// fail-open shape, not a missing feature: `take(text)` with a `number`
    /// parameter and a `string` field would pass.
    fn bindPatternBindings(self: *TypeChecker, pattern: ir.NodeIndex, scrutinee: TypeIndex) void {
        if (pattern == ir.null_node or scrutinee == null_type_idx) return;
        const pool = self.env.pool;
        const resolved = pool.unwrapNominal(self.env.resolveRef(scrutinee));
        if (self.ir_view.getTag(pattern) == .array_pattern) {
            // An array pattern over a typed array or tuple keeps the bindings
            // it had before: untyped. Over any other type (`unknown`, a union),
            // its nested bindings are opaque.
            const scrutinee_tag = pool.getTag(resolved) orelse return;
            if (scrutinee_tag == .t_array or scrutinee_tag == .t_tuple) return;
            self.markPatternBindingsOpaque(pattern, 0);
            return;
        }
        if (self.ir_view.getTag(pattern) != .match_pattern) return;
        const record = self.ir_view.getMatchPattern(pattern) orelse return;
        if (pool.getTag(resolved) != .t_record) {
            // The scrutinee has a type, but no record this arm can read. Every
            // binding the pattern introduces, at any depth, is `unknown`, and a
            // read of one is refused.
            self.markPatternBindingsOpaque(pattern, 0);
            return;
        }

        for (0..record.props_count) |i| {
            const prop_idx = self.ir_view.getListIndex(record.props_start, @intCast(i));
            const prop = self.ir_view.getProperty(prop_idx) orelse continue;
            if (prop.value == ir.null_node) continue;
            if (self.ir_view.getTag(prop.value) != .identifier) continue;
            const binding = self.ir_view.getBinding(prop.value) orelse continue;

            const key_str_idx = self.ir_view.getStringIdx(prop.key) orelse continue;
            const key_str = self.ir_view.getString(key_str_idx) orelse continue;

            for (pool.getRecordFields(resolved)) |field| {
                if (!std.mem.eql(u8, pool.getName(field.name_start, field.name_len), key_str)) continue;
                self.binding_types.put(self.allocator, bindingKey(binding), self.recordFieldReadType(resolved, field)) catch self.markAllocationFailure();
                break;
            }
        }
    }

    /// Type one pattern binding `unknown` and mark it opaque.
    fn markOpaqueBinding(self: *TypeChecker, binding: ir.BindingRef) void {
        self.binding_types.put(self.allocator, bindingKey(binding), self.env.pool.idx_unknown) catch self.markAllocationFailure();
        self.opaque_pattern_bindings.put(self.allocator, bindingKey(binding), {}) catch self.markAllocationFailure();
    }

    /// Type every binding that `pattern` introduces as `unknown`, and mark it
    /// opaque so that a read of it is recorded. The walk descends through
    /// nested record patterns and array patterns, so `when { name: { first: f } }`
    /// marks `f`, and not only a flat binding.
    fn markPatternBindingsOpaque(self: *TypeChecker, pattern: ir.NodeIndex, depth: u8) void {
        if (pattern == ir.null_node or depth > 32) return;
        const tag = self.ir_view.getTag(pattern) orelse return;
        switch (tag) {
            .identifier => {
                const binding = self.ir_view.getBinding(pattern) orelse return;
                self.markOpaqueBinding(binding);
            },
            .match_pattern => {
                const record = self.ir_view.getMatchPattern(pattern) orelse return;
                for (0..record.props_count) |i| {
                    const prop_idx = self.ir_view.getListIndex(record.props_start, @intCast(i));
                    const prop = self.ir_view.getProperty(prop_idx) orelse continue;
                    self.markPatternBindingsOpaque(prop.value, depth + 1);
                }
            },
            .array_pattern => {
                const array = self.ir_view.getArray(pattern) orelse return;
                for (0..array.elements_count) |i| {
                    const element = self.ir_view.getListIndex(array.elements_start, @intCast(i));
                    self.markPatternBindingsOpaque(element, depth + 1);
                }
            },
            .pattern_element => {
                const elem = self.ir_view.getPatternElem(pattern) orelse return;
                self.markOpaqueBinding(elem.binding);
            },
            // exhaustive: a literal, a type test, and a wildcard bind no name,
            // so there is nothing to mark. Every tag that can carry a binding
            // is listed above.
            else => {},
        }
    }

    fn findUnionMemberForPattern(self: *const TypeChecker, union_type: TypeIndex, pattern: ir.NodeIndex) TypeIndex {
        const analysis = match_analysis_mod.MatchAnalysis.init(self.allocator, self.ir_view, self.env.pool, self.env);
        return analysis.narrowTypeForPattern(union_type, pattern) catch {
            @constCast(self).markAllocationFailure();
            return null_type_idx;
        };
    }

    /// Register a function's declared parameter types under their binding keys
    /// (into the dedicated `param_types` map; see its doc comment for why this
    /// stays out of general identifier inference). Entries are keyed by
    /// (scope_id, slot), which is unique per function scope, so no
    /// save/restore is needed.
    fn registerParamTypes(self: *TypeChecker, func: ir.Node.FunctionExpr, sig: type_env_mod.FunctionSig) void {
        for (0..func.params_count) |i| {
            const param_idx = self.ir_view.getListIndex(func.params_start, @intCast(i));
            const binding = self.ir_view.paramBinding(param_idx) orelse continue;
            const param_type = if (i < sig.param_count) sig.param_types[i] else null_type_idx;
            // A parameter typed `(x: number) => number` has exactly the
            // parameters its annotation lists, so the annotation bounds the
            // arguments of a call to it. A function type inferred from an
            // expression is not trusted this way: an arrow written at a call
            // site is typed with an empty parameter list.
            var callable = self.callableMetadataFromType(param_type);
            switch (callable) {
                .signature => |*declared| declared.max_arg_count = declared.param_count,
                .unavailable, .arity => {},
            }
            self.bindCallableMetadata(binding, callable);
            if (param_type == null_type_idx) continue;
            const key = bindingKey(binding);
            self.param_types.put(self.allocator, key, param_type) catch self.markAllocationFailure();
            self.env.bindVarType(binding.scope_id, binding.name_atom, param_type) catch self.markAllocationFailure();
        }
    }

    /// Declared type of an identifier that is a function parameter, or
    /// null_type_idx. Fallback for sites where the declared type is
    /// load-bearing and general inference cannot see it.
    fn paramDeclaredType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        if (tag != .identifier) return null_type_idx;
        const binding = self.ir_view.getBinding(node) orelse return null_type_idx;
        const key = bindingKey(binding);
        return self.param_types.get(key) orelse null_type_idx;
    }

    /// Coverage of a match: whether its arms are proved exhaustive, the first
    /// missing case, and the first arm no value reaches. The strict checker asks
    /// this same question, so both checkers answer from one analysis. The
    /// witness is owned by the caller's `deinit`, with `self.allocator`.
    pub fn matchCoverage(self: *const TypeChecker, me: ir.Node.MatchExpr, want_redundancy: bool) match_analysis_mod.Coverage {
        // A catch-all arm makes the match exhaustive by construction, regardless
        // of whether the discriminant type resolves.
        // General inference does not resolve a plain parameter reference; fall
        // back to the declared parameter type so a full-variant
        // `match (param)` without a default is recognized as exhaustive.
        // The statement walk already reported anything inference found wrong
        // with the discriminant, so this query reports nothing.
        const mutable = @constCast(self);
        const previous = mutable.report_inference_diagnostics;
        mutable.report_inference_diagnostics = false;
        var disc_type = self.inferType(me.discriminant);
        mutable.report_inference_diagnostics = previous;
        if (disc_type == null_type_idx) disc_type = self.paramDeclaredType(me.discriminant);
        const analysis = match_analysis_mod.MatchAnalysis.init(self.allocator, self.ir_view, self.env.pool, self.env);
        return analysis.analyze(self.allocator, disc_type, me, want_redundancy) catch {
            mutable.markAllocationFailure();
            return .{ .incomplete = .budget };
        };
    }

    /// Report a match that is not provably exhaustive (ZTS205) and the first
    /// arm that no value reaches (ZTS216). Both are warnings. `check` drops
    /// ZTS205 again when the strict checker follows and reports ZTS603.
    fn reportMatchCoverage(self: *TypeChecker, node: NodeIndex, me: ir.Node.MatchExpr) void {
        var coverage = self.matchCoverage(me, true);
        defer coverage.deinit(self.allocator);

        if (!coverage.exhaustive) {
            const help = match_analysis_mod.missingCaseHelp(self.allocator, coverage) catch {
                self.markAllocationFailure();
                return;
            };
            self.addDiagnostic(.{
                .severity = .warning,
                .kind = .non_exhaustive_match,
                .node = node,
                .message = "match expression is not provably exhaustive",
                .help = help,
                .help_owned = true,
            });
        }

        if (coverage.redundant) |redundant| {
            const arm_idx = self.ir_view.getListIndex(me.arms_start, redundant.arm);
            self.addDiagnostic(.{
                .severity = .warning,
                .kind = .redundant_match_arm,
                .node = arm_idx,
                .message = if (redundant.is_default)
                    "default arm is unreachable"
                else
                    "match arm is unreachable",
                .help = if (redundant.is_default)
                    "the arms above cover every value of the matched type; remove the 'default:' arm"
                else
                    "earlier arms already match every value this arm matches, or the matched type excludes them; remove the arm",
            });
        }
    }

    // -------------------------------------------------------------------
    // Generic instantiation
    //
    // One pass, argument-driven, no return-type propagation (D1 section 4).
    // A call to a generic signature binds every type parameter here, and the
    // bindings are then substituted into the parameter types before the
    // arguments are checked and into the return type before it is inferred.
    // A parameter no argument position determines is an error, not a silent
    // widening to `unknown`.
    // -------------------------------------------------------------------

    const MAX_TYPE_PARAMS = type_env_mod.MAX_TYPE_PARAMS;

    const TypeBindings = struct {
        names: [MAX_TYPE_PARAMS][]const u8 = @splat(""),
        types: [MAX_TYPE_PARAMS]TypeIndex = @splat(null_type_idx),
        count: u8 = 0,

        fn indexOf(self: *const TypeBindings, name: []const u8) ?usize {
            for (0..self.count) |i| {
                if (std.mem.eql(u8, self.names[i], name)) return i;
            }
            return null;
        }
    };

    const Instantiation = union(enum) {
        /// The signature is monomorphic; nothing to substitute.
        none,
        ok: TypeBindings,
        arity: struct { expected: u8, got: u8 },
        ambiguous: []const u8,
        violated: struct { name: []const u8, arg: TypeIndex, constraint: TypeIndex },
    };

    /// Explicit type arguments written at this call, if any. The direct type
    /// environment keys them by the call's runtime owner node.
    fn explicitTypeArgs(self: *const TypeChecker, node: NodeIndex) ?type_env_mod.CallTypeArgs {
        return self.env.getCallTypeArgsForCall(self.ir_view, node);
    }

    /// Bind every type parameter of `sig` for this call. Pure: it reports what
    /// it found and leaves the diagnostics to the caller, so the same answer
    /// serves both the argument check and the return-type inference.
    fn instantiateSignature(
        self: *const TypeChecker,
        node: NodeIndex,
        sig: type_env_mod.FunctionSig,
        call: Node.CallExpr,
    ) Instantiation {
        const type_params = sig.typeParams();
        if (type_params.len == 0) return .none;

        var bindings: TypeBindings = .{};
        for (type_params) |param| {
            bindings.names[bindings.count] = param.name;
            bindings.count += 1;
        }

        if (self.explicitTypeArgs(node)) |explicit| {
            // Explicit arguments skip inference entirely (D1 section 4).
            if (explicit.count != type_params.len) {
                return .{ .arity = .{ .expected = @intCast(type_params.len), .got = explicit.count } };
            }
            for (0..bindings.count) |i| bindings.types[i] = explicit.args[i];
        } else {
            var i: u8 = 0;
            while (i < sig.param_count and i < call.args_count) : (i += 1) {
                const arg_idx = self.ir_view.getListIndex(call.args_start, i);
                const arg_type = self.argumentTypeForInference(arg_idx);
                if (arg_type == null_type_idx) continue;
                self.unify(type_params, sig.param_types[i], arg_type, &bindings, 0);
            }
            for (0..bindings.count) |bi| {
                if (bindings.types[bi] == null_type_idx) return .{ .ambiguous = bindings.names[bi] };
            }
        }

        for (type_params, 0..) |param, pi| {
            if (param.constraint == null_type_idx) continue;
            const arg = bindings.types[pi];
            if (arg == null_type_idx) continue;
            if (!self.env.isAssignableTo(arg, param.constraint)) {
                return .{ .violated = .{ .name = param.name, .arg = arg, .constraint = param.constraint } };
            }
        }

        return .{ .ok = bindings };
    }

    /// The type of a function written as an expression. A value that is a
    /// function must not pass where a number, a record, or JSON is required,
    /// so `inferType` answers a function type and not "unknown".
    ///
    /// The parameter list has one entry for each parameter node, so a call
    /// through a value of this type (`o.f(1, 2)`) is checked for arity like
    /// any call through a declared function type. See `functionTypeWithParams`
    /// for the parameter types. `functionExprType` keeps its empty list, because
    /// generic inference unifies a callback only as far as both sides carry
    /// parameters. A return the body does not determine is `unknown`.
    ///
    /// The body is read to find its return type, and the walk of the function
    /// reports its own diagnostics, so inference reports none here.
    fn functionValueType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const mutable = @constCast(self);
        const previous = mutable.report_inference_diagnostics;
        mutable.report_inference_diagnostics = false;
        defer mutable.report_inference_diagnostics = previous;
        const built = self.functionExprType(node);
        const returned = if (built != null_type_idx) self.env.pool.getFunctionInfo(built).ret else null_type_idx;
        const unknown_return = if (returned == null_type_idx) self.env.pool.idx_unknown else returned;
        const func = self.ir_view.getFunction(node) orelse return self.emptyFunctionType(unknown_return);
        return self.functionTypeWithParams(func.params_count, self.sourceFunctionSignature(node), unknown_return);
    }

    fn emptyFunctionType(self: *const TypeChecker, returned: TypeIndex) TypeIndex {
        return self.env.pool.addFunctionWithReturn(self.allocator, &.{}, returned);
    }

    /// A function type with `count` parameters. The count always comes from the
    /// parameter nodes, or from `max_arg_count`. A signature built from
    /// annotations can hold fewer entries than the function has parameters, so
    /// its types are used only when its count equals `count`; otherwise each
    /// parameter is `unknown`. A generic signature gives every parameter
    /// `unknown` and no return, so a type parameter never reaches an
    /// assignability check unresolved. Past 16 parameters the list stays empty.
    fn functionTypeWithParams(
        self: *const TypeChecker,
        count: usize,
        sig: ?type_env_mod.FunctionSig,
        returned: TypeIndex,
    ) TypeIndex {
        const pool = self.env.pool;
        const generic = if (sig) |s| s.type_param_count > 0 else false;
        const final_return = if (generic) null_type_idx else returned;
        if (count > 16) return self.emptyFunctionType(final_return);
        var params: [16]type_pool_mod.FuncParam = undefined;
        for (0..count) |i| {
            var param_type = pool.idx_unknown;
            var optional = false;
            if (sig) |s| {
                if (!generic and s.param_count == count and s.param_types[i] != null_type_idx) {
                    param_type = s.param_types[i];
                }
                if (s.required_param_count) |required| optional = i >= required;
            }
            params[i] = .{ .name_start = 0, .name_len = 0, .type_idx = param_type, .optional = optional };
        }
        return pool.addFunctionWithReturn(self.allocator, params[0..count], final_return);
    }

    /// The type of an identifier that names a function and holds no recorded
    /// type: a function declaration, or a binding whose callable was recorded.
    /// The return is the signature's, or `unknown` when the signature declares
    /// none. `null_type_idx` when the binding is not known to be a function.
    ///
    /// The by-name signature answers only for a module-level binding. A local
    /// or a parameter can share a name with a module function.
    fn functionBindingType(self: *const TypeChecker, binding: ir.BindingRef) TypeIndex {
        const pool = self.env.pool;
        if (self.boundCallableMetadata(binding)) |metadata| {
            return switch (metadata) {
                .unavailable => null_type_idx,
                .arity => |count| self.functionTypeWithParams(count, null, pool.idx_unknown),
                .signature => |sig| self.functionTypeOfSignature(sig),
            };
        }
        const declaration = self.captureSource(binding) orelse return null_type_idx;
        if (declaration.kind != .global) return null_type_idx;
        const name = self.resolveAtomName(binding.name_atom) orelse return null_type_idx;
        const sig = self.env.getFnSigByName(name) orelse return null_type_idx;
        return self.functionTypeOfSignature(sig);
    }

    fn functionTypeOfSignature(self: *const TypeChecker, sig: type_env_mod.FunctionSig) TypeIndex {
        const pool = self.env.pool;
        const returned = self.env.stripProofMarkers(sig.return_type);
        const count: usize = sig.max_arg_count orelse sig.param_count;
        return self.functionTypeWithParams(count, sig, if (returned == null_type_idx) pool.idx_unknown else returned);
    }

    /// The type of one call argument, for the purpose of binding type
    /// parameters.
    ///
    /// `inferType` gives a function value a function type whose return is
    /// `unknown` when nothing determines it. Generic inference must not read
    /// that as evidence: a callback passed as an argument is the only evidence
    /// a signature like `run(key: string, fn: () => T): T` has for what `T`
    /// is, and an unresolved one leaves `T` unbound so that the call is
    /// reported as ambiguous. A function literal therefore gets
    /// `functionExprType`, which is null when the body decides nothing, and a
    /// named function whose return is `unknown` is treated the same way.
    fn argumentTypeForInference(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        if (tag == .arrow_function or tag == .function_expr) return self.functionExprType(node);
        const inferred = self.inferType(node);
        if (tag == .identifier and self.hasUnknownReturn(inferred)) return null_type_idx;
        return inferred;
    }

    fn hasUnknownReturn(self: *const TypeChecker, type_idx: TypeIndex) bool {
        if (self.env.pool.getTag(type_idx) != .t_function) return false;
        return self.env.pool.getFunctionInfo(type_idx).ret == self.env.pool.idx_unknown;
    }

    /// The argument type used for assignability checks. Generic inference may
    /// leave an untyped callback unresolved so it can report ambiguity. A
    /// concrete callback contract must instead fail closed, so an unresolved
    /// function return becomes `unknown` and is rejected by a boolean target.
    fn argumentTypeForChecking(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const inferred = self.argumentTypeForInference(node);
        if (inferred != null_type_idx) return inferred;
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        // A named function with no determined return keeps the `unknown`
        // return `inferType` gave it, so a number target still refuses it.
        if (tag != .arrow_function and tag != .function_expr) return self.inferType(node);
        return self.env.pool.addFunctionWithReturn(self.allocator, &.{}, self.env.pool.idx_unknown);
    }

    /// A function type for a function expression written at a call site: its
    /// declared signature when one was recorded, otherwise an empty parameter
    /// list and the type its body returns.
    ///
    /// The parameter list is left empty when nothing declared it. `unify` walks
    /// a function pattern only as far as both sides carry parameters and then
    /// unifies the return types, so an empty list costs nothing here and
    /// guessing parameter types from a body would be a second inference with no
    /// caller asking for it.
    fn functionExprType(self: *const TypeChecker, node: NodeIndex) TypeIndex {
        const func = self.ir_view.getFunction(node) orelse return null_type_idx;
        const declared = self.sourceFunctionSignature(node);
        if (declared) |sig| {
            if (sig.return_type != null_type_idx) {
                return self.env.pool.addFunctionWithReturn(self.allocator, &.{}, sig.return_type);
            }
        }
        const returned = self.bodyReturnType(func.body, 0);
        if (returned == null_type_idx) return null_type_idx;
        return self.env.pool.addFunctionWithReturn(self.allocator, &.{}, returned);
    }

    /// The type a function body returns: the join of every `return` value the
    /// body reaches, or `null_type_idx` when no `return` carries a value.
    ///
    /// Nested function bodies are not entered - their `return` answers their
    /// own contract, not this one. A body whose returns disagree joins to a
    /// union, which is the same answer the checker gives a match expression
    /// whose arms disagree.
    ///
    /// Two statements return without a `return` statement or inside a loop.
    /// A failed `assert c, e` returns `e`, so the join includes the type of
    /// `e`. A `return` inside a `for...of` or `for...in` body is reached only
    /// when the loop runs at least once, so the loop can also fall through
    /// with no value. See `bodyReturnTypeIn`.
    fn bodyReturnType(self: *const TypeChecker, node: NodeIndex, depth: u8) TypeIndex {
        return self.bodyReturnTypeIn(node, depth, false);
    }

    /// `bodyReturnType` with `covered`: true when a statement after this node
    /// returns on every path, so control cannot leave the function from this
    /// node by falling through. A loop or an `if` that holds a `return` adds
    /// `undefined` to the join unless it is covered, because a loop that runs
    /// zero times, and an `if` whose branch does not return, leave the function
    /// with no value. An `if` that returns on every path adds nothing. A loop
    /// body is covered, since falling off its end goes back to the loop and not
    /// out of the function.
    fn bodyReturnTypeIn(self: *const TypeChecker, node: NodeIndex, depth: u8, covered: bool) TypeIndex {
        if (depth > 8 or node == null_node) return null_type_idx;
        const tag = self.ir_view.getTag(node) orelse return null_type_idx;
        switch (tag) {
            .return_stmt => {
                const value = self.ir_view.getOptValue(node) orelse return null_type_idx;
                return self.inferType(value);
            },
            .assert_stmt => {
                const assert = self.ir_view.getAssertStmt(node) orelse return null_type_idx;
                if (assert.error_expr == null_node) return null_type_idx;
                return self.inferType(assert.error_expr);
            },
            .program, .block => {
                const block = self.ir_view.getBlock(node) orelse return null_type_idx;
                // A statement is covered when a later one returns on every
                // path, so find the last such statement first.
                var last_returning: ?usize = null;
                for (0..block.stmts_count) |i| {
                    const stmt = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
                    if (self.returnsOnEveryPath(stmt)) last_returning = i;
                }
                var result: TypeIndex = null_type_idx;
                for (0..block.stmts_count) |i| {
                    const stmt = self.ir_view.getListIndex(block.stmts_start, @intCast(i));
                    const stmt_covered = covered or (if (last_returning) |last| i < last else false);
                    result = self.joinReturnType(result, self.bodyReturnTypeIn(stmt, depth + 1, stmt_covered));
                }
                return result;
            },
            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return null_type_idx;
                const then_type = self.bodyReturnTypeIn(if_s.then_branch, depth + 1, covered);
                const else_type = if (if_s.else_branch != null_node)
                    self.bodyReturnTypeIn(if_s.else_branch, depth + 1, covered)
                else
                    null_type_idx;
                const branches = self.joinReturnType(then_type, else_type);
                if (branches == null_type_idx or covered or self.returnsOnEveryPath(node)) return branches;
                return self.joinReturnType(branches, self.env.pool.idx_undefined);
            },
            .for_of_stmt => {
                const fi = self.ir_view.getForIter(node) orelse return null_type_idx;
                const body_type = self.bodyReturnTypeIn(fi.body, depth + 1, true);
                if (body_type == null_type_idx or covered) return body_type;
                return self.joinReturnType(body_type, self.env.pool.idx_undefined);
            },
            // exhaustive: the listed statement shapes are the ones that can
            // carry a `return` for this function. Every other tag is an
            // expression or a declaration, which holds no `return` for this
            // function, or it opens a nested function, whose returns answer
            // its own contract. Answering nothing here is not a swallowed
            // verdict: the caller infers no type for the argument and the type
            // parameter stays unbound, which `instantiateSignature` reports as
            // ambiguous.
            else => return null_type_idx,
        }
    }

    /// True when every path through `node` ends in a `return`: a `return`, a
    /// block with a statement that does, and an `if` with an `else` where both
    /// branches do. A loop never does, since it can run zero times.
    fn returnsOnEveryPath(self: *const TypeChecker, node: NodeIndex) bool {
        const tag = self.ir_view.getTag(node) orelse return false;
        switch (tag) {
            .return_stmt => return true,
            .block => {
                const block = self.ir_view.getBlock(node) orelse return false;
                for (0..block.stmts_count) |i| {
                    if (self.returnsOnEveryPath(self.ir_view.getListIndex(block.stmts_start, @intCast(i)))) return true;
                }
                return false;
            },
            .if_stmt => {
                const if_s = self.ir_view.getIfStmt(node) orelse return false;
                if (if_s.else_branch == null_node) return false;
                return self.returnsOnEveryPath(if_s.then_branch) and self.returnsOnEveryPath(if_s.else_branch);
            },
            // exhaustive: every other statement can be left by falling through
            // or holds no `return` of this function, so none returns on every
            // path. Answering false adds `undefined` to a join, which is the
            // fail-closed direction.
            else => return false,
        }
    }

    fn joinReturnType(self: *const TypeChecker, left: TypeIndex, right: TypeIndex) TypeIndex {
        if (left == null_type_idx) return right;
        if (right == null_type_idx or right == left) return left;
        return self.env.pool.addUnion(self.allocator, &.{ left, right });
    }

    /// The declared type parameter `pattern` names, or null when `pattern` is
    /// not a type-parameter reference. A parameter annotation reaches the pool
    /// two ways - a bare `T` resolves to the `t_generic_param` node in scope,
    /// while a `T` nested in `T[]` stays a `t_ref` the type-expression parser
    /// built - so both tags are matched by name, which is also how
    /// `TypePool.instantiate` substitutes.
    fn typeParamNameOf(
        self: *const TypeChecker,
        type_params: []const type_env_mod.GenericParam,
        pattern: TypeIndex,
    ) ?[]const u8 {
        const tag = self.env.pool.getTag(pattern) orelse return null;
        if (tag != .t_generic_param and tag != .t_ref) return null;
        const name = self.env.pool.getRefName(pattern);
        if (name.len == 0) return null;
        for (type_params) |param| {
            if (std.mem.eql(u8, param.name, name)) return param.name;
        }
        return null;
    }

    fn constraintFor(
        type_params: []const type_env_mod.GenericParam,
        name: []const u8,
    ) TypeIndex {
        for (type_params) |param| {
            if (std.mem.eql(u8, param.name, name)) return param.constraint;
        }
        return null_type_idx;
    }

    /// Walk a parameter type and the argument type it was given side by side,
    /// binding each type parameter the walk reaches.
    fn unify(
        self: *const TypeChecker,
        type_params: []const type_env_mod.GenericParam,
        pattern: TypeIndex,
        actual: TypeIndex,
        bindings: *TypeBindings,
        depth: u8,
    ) void {
        if (depth > 8) return;
        if (pattern == null_type_idx or actual == null_type_idx) return;
        const pool = self.env.pool;

        if (self.typeParamNameOf(type_params, pattern)) |name| {
            self.bindTypeParam(type_params, name, actual, bindings);
            return;
        }

        const pattern_tag = pool.getTag(pattern) orelse return;
        const actual_tag = pool.getTag(actual) orelse return;

        switch (pattern_tag) {
            .t_record => {
                if (actual_tag != .t_record) return;
                // Fields present in the pattern only: a field the argument
                // carries and the parameter does not says nothing about any
                // type parameter.
                const pattern_fields = pool.getRecordFields(pattern);
                var i: usize = 0;
                while (i < pattern_fields.len) : (i += 1) {
                    // Re-read each iteration: a nested unify can add to the
                    // pool's shared fields list and move the slice.
                    const live = pool.getRecordFields(pattern);
                    if (i >= live.len) break;
                    const field = live[i];
                    const field_name = pool.getName(field.name_start, field.name_len);
                    const actual_field = pool.lookupRecordField(actual, field_name) orelse continue;
                    self.unify(type_params, field.type_idx, actual_field.type_idx, bindings, depth + 1);
                }
            },
            .t_array => {
                const elem = pool.getArrayElement(pattern);
                if (actual_tag == .t_array) {
                    self.unify(type_params, elem, pool.getArrayElement(actual), bindings, depth + 1);
                } else if (actual_tag == .t_tuple) {
                    // `["a", "b"]` types as a tuple of literals, so `T[]` sees
                    // each element and the joins in `bindTypeParam` produce
                    // one element type for T.
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const live = pool.getTupleElements(actual);
                        if (i >= live.len) break;
                        self.unify(type_params, elem, live[i], bindings, depth + 1);
                    }
                }
            },
            .t_tuple => {
                if (actual_tag == .t_tuple) {
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const p_live = pool.getTupleElements(pattern);
                        const a_live = pool.getTupleElements(actual);
                        if (i >= p_live.len or i >= a_live.len) break;
                        self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                    }
                } else if (actual_tag == .t_array) {
                    const actual_elem = pool.getArrayElement(actual);
                    var i: usize = 0;
                    while (true) : (i += 1) {
                        const p_live = pool.getTupleElements(pattern);
                        if (i >= p_live.len) break;
                        self.unify(type_params, p_live[i], actual_elem, bindings, depth + 1);
                    }
                }
            },
            .t_function => {
                if (actual_tag != .t_function) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_info = pool.getFunctionInfo(pattern);
                    const a_info = pool.getFunctionInfo(actual);
                    if (i >= p_info.params.len or i >= a_info.params.len) break;
                    self.unify(type_params, p_info.params[i].type_idx, a_info.params[i].type_idx, bindings, depth + 1);
                }
                self.unify(
                    type_params,
                    pool.getFunctionInfo(pattern).ret,
                    pool.getFunctionInfo(actual).ret,
                    bindings,
                    depth + 1,
                );
            },
            .t_nullable => {
                const inner = pool.getNullableInner(pattern);
                const actual_inner = if (actual_tag == .t_nullable) pool.getNullableInner(actual) else actual;
                self.unify(type_params, inner, actual_inner, bindings, depth + 1);
            },
            .t_union => {
                // D1 section 4: a union pattern with exactly one type-parameter
                // member binds it to the whole argument. `x: T | undefined`
                // given `string | undefined` binds T to `string | undefined`,
                // which is what the declaration asked about.
                var generic_member: ?[]const u8 = null;
                var generic_count: usize = 0;
                const members = pool.getUnionMembers(pattern);
                for (members) |member| {
                    if (self.typeParamNameOf(type_params, member)) |name| {
                        generic_member = name;
                        generic_count += 1;
                    }
                }
                if (generic_count == 1) {
                    self.bindTypeParam(type_params, generic_member.?, actual, bindings);
                    return;
                }
                if (actual_tag != .t_union) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_live = pool.getUnionMembers(pattern);
                    const a_live = pool.getUnionMembers(actual);
                    if (i >= p_live.len or i >= a_live.len) break;
                    self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                }
            },
            .t_intersection => {
                if (actual_tag != .t_intersection) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_live = pool.getIntersectionMembers(pattern);
                    const a_live = pool.getIntersectionMembers(actual);
                    if (i >= p_live.len or i >= a_live.len) break;
                    self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                }
            },
            .t_generic_app => {
                if (actual_tag != .t_generic_app) return;
                var i: usize = 0;
                while (true) : (i += 1) {
                    const p_live = pool.getGenericAppInfo(pattern).args;
                    const a_live = pool.getGenericAppInfo(actual).args;
                    if (i >= p_live.len or i >= a_live.len) break;
                    self.unify(type_params, p_live[i], a_live[i], bindings, depth + 1);
                }
            },
            // exhaustive: every remaining tag is a leaf the walk cannot
            // decompose, so it contributes no binding. Assignability checks it
            // after substitution.
            else => {},
        }
    }

    /// Bind, or join with what a previous argument position already bound.
    fn bindTypeParam(
        self: *const TypeChecker,
        type_params: []const type_env_mod.GenericParam,
        name: []const u8,
        actual: TypeIndex,
        bindings: *TypeBindings,
    ) void {
        const slot = bindings.indexOf(name) orelse return;
        const contribution = self.widenForBinding(constraintFor(type_params, name), actual);
        const existing = bindings.types[slot];
        bindings.types[slot] = if (existing == null_type_idx)
            contribution
        else
            self.joinTypes(existing, contribution);
    }

    /// A literal argument binds its base type, so `first(["a"])` returns
    /// `string` rather than `"a"`. The exception is a constraint the base type
    /// does not satisfy - `T extends "a" | "b"` is asking for the literal, and
    /// widening it would make every call violate its own bound.
    fn widenForBinding(self: *const TypeChecker, constraint: TypeIndex, actual: TypeIndex) TypeIndex {
        const widened = self.env.pool.widenLiteral(actual);
        if (widened == actual) return actual;
        if (constraint != null_type_idx and !self.env.isAssignableTo(widened, constraint)) {
            return actual;
        }
        return widened;
    }

    /// Substitute the bindings into a type. Returns the type unchanged when the
    /// call is not generic.
    fn substitute(self: *const TypeChecker, inst: Instantiation, idx: TypeIndex) TypeIndex {
        const bindings = switch (inst) {
            .ok => |b| b,
            // exhaustive: `.none` is a monomorphic signature and the three
            // refusals were already reported. Each has no bindings to apply,
            // so the type is returned as declared.
            else => return idx,
        };
        if (bindings.count == 0 or idx == null_type_idx) return idx;
        return self.env.pool.instantiate(
            self.env.allocator,
            idx,
            bindings.names[0..bindings.count],
            bindings.types[0..bindings.count],
            0,
        );
    }

    /// Report whatever `instantiateSignature` refused, and return the bindings
    /// when it accepted. A refusal returns `.none`, so the argument check that
    /// follows compares against the uninstantiated parameter types rather than
    /// stacking a second diagnostic on the first.
    fn reportInstantiation(self: *TypeChecker, node: NodeIndex, inst: Instantiation) Instantiation {
        switch (inst) {
            .none, .ok => return inst,
            .arity => |a| self.addGenericDiagnostic(
                .type_argument_count_mismatch,
                node,
                "wrong number of type arguments: expected {d}, got {d}",
                .{ a.expected, a.got },
                "wrong number of type arguments",
                "Give one type argument for each declared type parameter.",
            ),
            .ambiguous => |name| self.addGenericDiagnostic(
                .ambiguous_type_argument,
                node,
                "no argument determines type parameter '{s}'",
                .{name},
                "a type parameter is not determined by any argument",
                "Name the type argument at the call site.",
            ),
            .violated => |v| {
                var arg_buf: [128]u8 = undefined;
                var constraint_buf: [128]u8 = undefined;
                self.addGenericDiagnostic(
                    .type_constraint_violation,
                    node,
                    "type argument {s} for '{s}' does not satisfy constraint {s}",
                    .{
                        self.env.pool.formatType(v.arg, &arg_buf),
                        v.name,
                        self.env.pool.formatType(v.constraint, &constraint_buf),
                    },
                    "a type argument does not satisfy its constraint",
                    "Pass a type argument that satisfies the constraint, or relax the constraint.",
                );
            },
        }
        return .none;
    }

    /// Message ownership matches `addArgCountMismatch`: the formatted text is
    /// owned when it was allocated, and the static fallback never is.
    fn addGenericDiagnostic(
        self: *TypeChecker,
        kind: DiagnosticKind,
        node: NodeIndex,
        comptime fmt: []const u8,
        args: anytype,
        fallback: []const u8,
        help: ?[]const u8,
    ) void {
        const msg = self.allocator.print(fmt, args) catch fallback;
        self.addDiagnostic(.{
            .severity = .err,
            .kind = kind,
            .node = node,
            .message = msg,
            .help = help,
            .allocated = msg.ptr != fallback.ptr,
        });
    }

    // -------------------------------------------------------------------
    // Call argument checking
    // -------------------------------------------------------------------

    /// The first member of `idx` that JSON cannot carry, or null when nothing
    /// in it is definitely unencodable.
    ///
    /// Spec 6.4 states the rule the other way round - admit only scalars,
    /// arrays, tuples, fixed records, and string-keyed `Dict` - and this
    /// refuses what is definitely wrong instead. The difference is `unknown`,
    /// which the strict reading rejects and which is what a `Result` payload
    /// and a parsed document both type as today. Rejecting it would refuse
    /// `Response.json(parsed.value)` in every handler that has one, so the
    /// checker takes the direction that cannot reject a true program: it
    /// reports where it knows, and stays quiet where it does not. Phase 7's
    /// cutover can tighten this once those positions carry real types.
    ///
    /// A function is the case worth catching. `valueToJsonString` throws on
    /// one, `http.zig` calls it with `try`, and the subset has no `try/catch` -
    /// so the failure that exists today has no way to be handled, which is the
    /// concrete argument for deciding it at compile time.
    fn firstUnencodable(self: *const TypeChecker, idx: TypeIndex, depth: u8) ?TypeIndex {
        if (idx == null_type_idx or depth >= 16) return null;
        const pool = self.env.pool;
        const tag = pool.getTag(idx) orelse return null;
        return switch (tag) {
            .t_function => idx,
            // A Bytes is an octet buffer, not a JSON value. Spec 6.3 keeps the
            // two apart, and `encodeBase64` is the conversion an author writes
            // when they mean to send one.
            .t_bytes => idx,
            .t_array => self.firstUnencodable(pool.getArrayElement(idx), depth + 1),
            .t_nullable => self.firstUnencodable(pool.getNullableInner(idx), depth + 1),
            // The encoder fails on a key that is not a string, so the Dict
            // itself is what JSON cannot carry.
            .t_dict => if (self.dictKeyAdmitsNonString(pool.getDictKey(idx), depth + 1))
                idx
            else
                self.firstUnencodable(pool.getDictValue(idx), depth + 1),
            .t_record => blk: {
                for (pool.getRecordFields(idx)) |field| {
                    if (self.firstUnencodable(field.type_idx, depth + 1)) |bad| break :blk bad;
                }
                break :blk null;
            },
            .t_tuple => blk: {
                for (pool.getTupleElements(idx)) |element| {
                    if (self.firstUnencodable(element, depth + 1)) |bad| break :blk bad;
                }
                break :blk null;
            },
            .t_union => blk: {
                for (pool.getUnionMembers(idx)) |member| {
                    if (self.firstUnencodable(member, depth + 1)) |bad| break :blk bad;
                }
                break :blk null;
            },
            // exhaustive: every remaining tag is a JSON scalar, a literal, a
            // name the pool did not resolve, or `unknown`. The scalars and
            // literals encode; the other two are types this walk has no
            // information about, and reporting one would refuse a program on
            // the absence of knowledge rather than on knowledge. Refusing what
            // is definitely wrong is the direction this rule takes, so an
            // unmodelled tag arriving here is admitted and reported by
            // whatever does know it.
            else => null,
        };
    }

    /// Whether the Dict key type `key` has a member that is definitely not a
    /// string. The JSON encoder fails the whole payload on such a key. A
    /// string, a string literal, a template literal, `never`, and `unknown`
    /// are accepted. A type the walk cannot resolve is accepted too: like
    /// `firstUnencodable`, this refuses only what it knows is wrong.
    fn dictKeyAdmitsNonString(self: *const TypeChecker, key: TypeIndex, depth: u8) bool {
        if (key == null_type_idx or depth >= 16) return false;
        const pool = self.env.pool;
        const tag = pool.getTag(key) orelse return false;
        return switch (tag) {
            .t_string, .t_literal_string, .t_template_literal, .t_never, .t_unknown_type => false,
            .t_boolean,
            .t_number,
            .t_null,
            .t_undefined,
            .t_void,
            .t_dict,
            .t_bytes,
            .t_record,
            .t_array,
            .t_tuple,
            .t_function,
            .t_literal_number,
            .t_literal_bool,
            .t_nullable,
            => true,
            .t_union => blk: {
                for (pool.getUnionMembers(key)) |member| {
                    if (self.dictKeyAdmitsNonString(member, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            .t_ref => blk: {
                const resolved = self.env.resolveRef(key);
                if (resolved == key) break :blk false;
                break :blk self.dictKeyAdmitsNonString(resolved, depth + 1);
            },
            .t_intersection, .t_generic_param, .t_generic_app, .t_error => false,
        };
    }

    /// `Response.json(payload)`: refuse a payload whose type JSON cannot carry.
    ///
    /// Spec 7.2 wants `responseJson<T>` to return `Result<Response, JsonError>`
    /// so the failure is handled rather than thrown. Making the shipped global
    /// fallible rewrites the return statement of every handler in the
    /// repository, which is what phase 7's direct cutover is for. This is the
    /// half that costs no migration and closes the same hole wherever `T`
    /// decides it; the residual - the size limit, which no payload type
    /// discharges - stays a run-time fault.
    fn checkResponseJsonPayload(self: *TypeChecker, call: Node.CallExpr) void {
        const method = self.responseConstructorName(call) orelse return;
        if (!std.mem.eql(u8, method, "json")) return;
        if (call.args_count == 0) return;

        const arg_idx = self.ir_view.getListIndex(call.args_start, 0);
        self.reportIfUnencodable(arg_idx, "Response.json");
    }

    /// `Response.json(body, init)`: refuse an init member that the runtime
    /// does not send.
    ///
    /// The helpers `json`, `text`, `html`, and `rawJson` read `init.status` and
    /// nothing else (`http.zig` `statusFromInitObject`), and flow analysis
    /// models the same (`flow_interp.zig` `makeResponse`). A `headers` member
    /// passed this check and the runtime dropped it, so the response lacked a
    /// header that the source named. The init parameter is the closed record
    /// `{ status?: number }`, and an argument with another member does not
    /// match it: ZTS203. `redirect` takes a status number and no init.
    ///
    /// An object literal gets one diagnostic at each member, where the edit
    /// is. Any other expression is judged by its type and gets one diagnostic.
    /// Like `firstUnencodable`, the type walk refuses only what it knows is
    /// wrong: an init whose type the checker cannot resolve is admitted.
    fn checkResponseInit(self: *TypeChecker, call: Node.CallExpr) void {
        const method = self.responseConstructorName(call) orelse return;
        if (std.mem.eql(u8, method, "redirect")) return;
        if (call.args_count < 2) return;

        const init_arg = self.ir_view.getListIndex(call.args_start, 1);
        if (self.ir_view.getTag(init_arg) != .object_literal) return self.checkResponseInitType(init_arg, method);
        const literal = self.ir_view.getObject(init_arg) orelse return;
        for (0..literal.properties_count) |i| {
            const member = self.ir_view.getListIndex(literal.properties_start, @intCast(i));
            if (self.ir_view.getTag(member) == .object_spread) {
                if (self.ir_view.getOptValue(member)) |operand| self.checkResponseInitType(operand, method);
                continue;
            }
            const property = self.ir_view.getProperty(member) orelse continue;
            // The parser refuses a computed key and a numeric key (ZTS001). A
            // key with no readable name is not `status`, so it is refused too.
            const name = self.propertyKeyName(property.key) orelse "";
            if (!std.mem.eql(u8, name, response_init_status)) self.reportResponseInitMember(property.key, method, name);
        }
    }

    /// Report ZTS203 when the type of `node` has a member that is not `status`.
    fn checkResponseInitType(self: *TypeChecker, node: NodeIndex, method: []const u8) void {
        const name = self.firstUnsupportedInitField(self.inferType(node), 0) orelse return;
        self.reportResponseInitMember(node, method, name);
    }

    /// The name of the first member of `idx` that is not `status`. Null when
    /// `idx` has no such member, or when the checker cannot resolve `idx`.
    fn firstUnsupportedInitField(self: *const TypeChecker, idx: TypeIndex, depth: u8) ?[]const u8 {
        if (idx == null_type_idx or depth >= 16) return null;
        const pool = self.env.pool;
        const tag = pool.getTag(idx) orelse return null;
        return switch (tag) {
            .t_record => blk: {
                for (pool.getRecordFields(idx)) |field| {
                    const name = pool.getName(field.name_start, field.name_len);
                    if (!std.mem.eql(u8, name, response_init_status)) break :blk name;
                }
                break :blk null;
            },
            .t_union => blk: {
                for (pool.getUnionMembers(idx)) |member| {
                    if (self.firstUnsupportedInitField(member, depth + 1)) |name| break :blk name;
                }
                break :blk null;
            },
            .t_intersection => blk: {
                for (pool.getIntersectionMembers(idx)) |member| {
                    if (self.firstUnsupportedInitField(member, depth + 1)) |name| break :blk name;
                }
                break :blk null;
            },
            .t_nullable => self.firstUnsupportedInitField(pool.getNullableInner(idx), depth + 1),
            .t_ref => blk: {
                const resolved = self.env.resolveRef(idx);
                if (resolved == idx) break :blk null;
                break :blk self.firstUnsupportedInitField(resolved, depth + 1);
            },
            // A type with no record members names no member to refuse. A type
            // that this walk cannot resolve is admitted.
            .t_boolean,
            .t_number,
            .t_string,
            .t_null,
            .t_dict,
            .t_bytes,
            .t_undefined,
            .t_void,
            .t_never,
            .t_unknown_type,
            .t_array,
            .t_tuple,
            .t_function,
            .t_literal_string,
            .t_literal_number,
            .t_literal_bool,
            .t_generic_param,
            .t_generic_app,
            .t_template_literal,
            .t_error,
            => null,
        };
    }

    fn reportResponseInitMember(self: *TypeChecker, node: NodeIndex, method: []const u8, member: []const u8) void {
        if (self.allocator.print("Response.{s} does not support the init member '{s}'", .{ method, member })) |msg| {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .arg_type_mismatch,
                .node = node,
                .message = msg,
                .help = response_init_help_text,
                .allocated = true,
            });
        } else |_| self.markAllocationFailure();
    }

    /// The name that a record literal key spells, or null when the key is
    /// neither an identifier nor a string literal.
    fn propertyKeyName(self: *const TypeChecker, key: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(key) == .identifier) {
            const binding = self.ir_view.getBinding(key) orelse return null;
            return self.resolveAtomName(binding.name_atom);
        }
        return self.literalKeyName(key);
    }

    /// Report ZTS213 when the value at `arg_idx` has a type JSON cannot carry.
    /// Shared by `Response.json` and by every module export that marks an
    /// argument `json_encodable_args` - one rule at both sites, which is what
    /// makes it a rule rather than a special case.
    fn reportIfUnencodable(self: *TypeChecker, arg_idx: NodeIndex, site: []const u8) void {
        const arg_type = self.inferType(arg_idx);
        const bad = self.firstUnencodable(arg_type, 0) orelse return;

        var buf: [1024]u8 = undefined;
        const bad_str = self.env.pool.formatType(bad, &buf);
        const msg = self.allocator.print("{s} cannot encode this payload: {s} is not a JSON value", .{ site, bad_str }) catch "this payload is not JSON-encodable";
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .unencodable_json_payload,
            .node = arg_idx,
            .message = msg,
            .help = "JSON carries scalars, arrays, tuples, records, and string-keyed Dict values. Encode a Bytes with encodeBase64, and call a function rather than sending it.",
            .allocated = !std.mem.eql(u8, msg, "this payload is not JSON-encodable"),
        });
    }

    /// The module export a call's callee names, resolved through the import
    /// that introduced it rather than by the local spelling.
    ///
    /// A bare-name lookup was wrong in both directions. `import { send as
    /// publish }` never matched, so the export's checks were skipped under an
    /// alias; and a handler's own `function send(...)` matched, so a local
    /// function was checked against a module export's declaration. The import
    /// shared record carries the original export name and module specifier,
    /// which together identify the export exactly.
    fn resolveImportedExport(
        self: *const TypeChecker,
        callee_binding: ir.BindingRef,
    ) ?@import("zts-base").module_descriptors.ExportDescriptor {
        const facts = self.import_facts orelse
            if (self.owned_import_facts) |*owned| owned else return null;
        return facts.builtinDescriptorForNamedReference(callee_binding);
    }

    /// The `json_encodable_args` positions of the module export `call` names,
    /// checked with the same rule. A queue payload and a response body are
    /// serialized by the same encoder, so they answer to the same question.
    fn checkModuleEncodableArgs(self: *TypeChecker, call: Node.CallExpr) void {
        if (self.ir_view.getTag(call.callee) != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const entry = self.resolveImportedExport(binding) orelse return;
        for (entry.function.json_encodable_args) |position| {
            if (position >= call.args_count) continue;
            const arg_idx = self.ir_view.getListIndex(call.args_start, position);
            var site_buf: [128]u8 = undefined;
            const site = std.fmt.bufPrint(&site_buf, "{s}.{s}", .{ entry.module.specifier, entry.function.name }) catch entry.function.name;
            self.reportIfUnencodable(arg_idx, site);
        }
    }

    /// Whether `call` is a call of `dictFold`, `dictMapValues`, or `dictFilter`
    /// whose first argument is one Dict type.
    fn isSingleDictCall(self: *TypeChecker, call: Node.CallExpr) bool {
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        return self.dictCallbackCall(call) != null;
    }

    fn checkModuleBooleanPredicate(self: *TypeChecker, call: Node.CallExpr) void {
        if (self.ir_view.getTag(call.callee) != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const entry = self.resolveImportedExport(binding) orelse return;
        if (!std.mem.eql(u8, entry.module.specifier, "zttp:collections") or
            !std.mem.eql(u8, entry.function.name, "dictFilter") or
            call.args_count < 2)
        {
            return;
        }

        const callback = self.ir_view.getListIndex(call.args_start, 1);
        const expected = self.env.pool.addFunctionWithReturn(self.allocator, &.{}, self.env.pool.idx_boolean);
        // Over one Dict type, `checkDictCallbackParams` owns the parameters of
        // the callback, so a named function compares by its return type, as a
        // predicate of an array method does.
        const actual = if (self.isSingleDictCall(call))
            self.predicateArgumentType(callback, expected)
        else
            self.argumentTypeForChecking(callback);
        if (actual == null_type_idx or !self.env.isAssignableTo(actual, expected)) {
            self.addArgTypeMismatch(callback, expected, actual);
        }
    }

    /// Whether `type_idx` is a Result that the checker built (`isResultRecord`),
    /// or a union whose every member is one. The test is the pool identity of
    /// the record and never its shape, so a record literal and a record that a
    /// handler declares are not Results.
    fn isResultType(self: *const TypeChecker, type_idx: TypeIndex, depth: u8) bool {
        if (type_idx == null_type_idx or depth >= 4) return false;
        const pool = self.env.pool;
        const resolved = self.resolvedType(self.env.stripProofMarkers(type_idx));
        if (pool.isResultRecord(resolved)) return true;
        if (pool.getTag(resolved) != .t_union) return false;
        const members = pool.getUnionMembers(resolved);
        if (members.len == 0) return false;
        for (members) |member| {
            if (!self.isResultType(member, depth + 1)) return false;
        }
        return true;
    }

    /// The declared type of the field `name` of a Result type: the field of a
    /// marked record, or the join of the field over the members of a union of
    /// them. Null when `type_idx` is not a Result type or lacks the field.
    fn resultFieldType(self: *const TypeChecker, type_idx: TypeIndex, name: []const u8, depth: u8) TypeIndex {
        if (!self.isResultType(type_idx, 0) or depth >= 4) return null_type_idx;
        const pool = self.env.pool;
        const resolved = self.resolvedType(self.env.stripProofMarkers(type_idx));
        if (pool.isResultRecord(resolved)) {
            for (pool.getRecordFields(resolved)) |field| {
                if (std.mem.eql(u8, pool.getName(field.name_start, field.name_len), name)) return field.type_idx;
            }
            return null_type_idx;
        }
        var joined: TypeIndex = null_type_idx;
        for (pool.getUnionMembers(resolved)) |member| {
            const field = self.resultFieldType(member, name, depth + 1);
            if (field == null_type_idx) return null_type_idx;
            joined = if (joined == null_type_idx) field else self.joinTypes(joined, field);
        }
        return joined;
    }

    /// Whether `type_idx` is an array of Results, a tuple of Results, or a
    /// union of those. An array whose element has no type, or is `never`
    /// (the empty array literal), is accepted: nothing in it can be a
    /// non-Result.
    fn isResultListType(self: *const TypeChecker, type_idx: TypeIndex, depth: u8) bool {
        if (depth >= 4) return false;
        const pool = self.env.pool;
        const resolved = self.resolvedType(self.env.stripProofMarkers(type_idx));
        const tag = pool.getTag(resolved) orelse return false;
        switch (tag) {
            .t_array => {
                const element = pool.getArrayElement(resolved);
                if (element == null_type_idx or element == pool.idx_never) return true;
                return self.isResultType(element, 0);
            },
            .t_tuple => {
                for (pool.getTupleElements(resolved)) |element| {
                    if (!self.isResultType(element, 0)) return false;
                }
                return true;
            },
            .t_union => {
                const members = pool.getUnionMembers(resolved);
                if (members.len == 0) return false;
                for (members) |member| {
                    if (!self.isResultListType(member, depth + 1)) return false;
                }
                return true;
            },
            // exhaustive: any other type is not a list of Results.
            else => return false,
        }
    }

    /// The type `ok(x)` and `err(e)` store: the widened type of the argument,
    /// or `unknown` when the argument has no type.
    fn resultPayloadType(self: *const TypeChecker, arg: NodeIndex) TypeIndex {
        const pool = self.env.pool;
        const arg_type = self.inferType(arg);
        if (arg_type == null_type_idx or pool.mentionsError(arg_type)) return pool.idx_unknown;
        return pool.widenLiteral(arg_type);
    }

    /// The type of a call of `ok`, `err`, or `unwrapOr` from `zttp:result`,
    /// resolved through the import so that a local function of the same name
    /// keeps its own type. Null for any other callee, and for an `unwrapOr`
    /// whose operands carry no type.
    fn resultExportCallType(self: *const TypeChecker, binding: ir.BindingRef, call: Node.CallExpr) ?TypeIndex {
        const entry = self.resolveImportedExport(binding) orelse return null;
        if (!std.mem.eql(u8, entry.module.specifier, "zttp:result")) return null;
        const pool = self.env.pool;
        const name = entry.function.name;
        if (std.mem.eql(u8, name, "ok") and call.args_count == 1) {
            const payload = self.resultPayloadType(self.ir_view.getListIndex(call.args_start, 0));
            return self.typedResultType(payload, pool.idx_never, pool.idx_never);
        }
        if (std.mem.eql(u8, name, "err") and call.args_count == 1) {
            const payload = self.resultPayloadType(self.ir_view.getListIndex(call.args_start, 0));
            return self.typedResultType(pool.idx_never, payload, pool.idx_never);
        }
        if (std.mem.eql(u8, name, "unwrapOr") and call.args_count == 2) {
            const result_type = self.inferType(self.ir_view.getListIndex(call.args_start, 0));
            const value_type = self.resultFieldType(result_type, "value", 0);
            if (value_type == null_type_idx or value_type == pool.idx_json_value or pool.mentionsError(value_type)) return null;
            const fallback = self.inferType(self.ir_view.getListIndex(call.args_start, 1));
            if (fallback == null_type_idx or pool.mentionsError(fallback)) return null;
            return self.joinTypes(value_type, pool.widenLiteral(fallback));
        }
        if (isCallbackCombinator(name) and call.args_count == 2) return self.combinatorCallType(name, call);
        if (std.mem.eql(u8, name, "collectAll") and call.args_count == 1) return self.collectAllCallType(call);
        return null;
    }

    /// The type that a `const` or `let` binding takes from an array literal
    /// initializer with no annotation. `inferred` is `inferArrayLiteralType`'s
    /// result for `initializer`. Each element type is widened, as in TypeScript: the
    /// binding is an array when the widened element types are equal and a tuple
    /// otherwise, and `[]` is `unknown[]`. A literal that is not bound keeps its
    /// inferred type, so only the `.var_decl` arm calls this. An initializer that
    /// is not an array literal is returned unchanged.
    fn arrayLiteralBindingType(self: *TypeChecker, initializer: NodeIndex, inferred: TypeIndex) TypeIndex {
        if (self.ir_view.getTag(initializer) != .array_literal) return inferred;
        const pool = self.env.pool;
        if (inferred == null_type_idx) {
            const arr = self.ir_view.getArray(initializer) orelse return inferred;
            if (arr.elements_count != 0) return inferred;
            return self.unknownArrayType();
        }
        switch (pool.getTag(inferred) orelse return inferred) {
            .t_tuple => {
                var widened: [32]TypeIndex = undefined;
                const elements = pool.getTupleElements(inferred);
                if (elements.len == 0 or elements.len > widened.len) return inferred;
                var all_equal = true;
                for (elements, 0..) |element, i| {
                    widened[i] = pool.widenLiteral(element);
                    if (widened[i] != widened[0]) all_equal = false;
                }
                if (all_equal) return pool.addArray(self.allocator, widened[0]);
                return pool.addTuple(self.allocator, widened[0..elements.len]);
            },
            .t_array => {
                const element = pool.getArrayElement(inferred);
                if (pool.getTag(element) == .t_union) {
                    // A literal longer than the inference buffer is an array of
                    // a union. One join over the widened members keeps the
                    // member storage linear; a join per member grew it
                    // quadratically and exhausted the pool's u16 range. The
                    // add can move the pool's member list, so the members are
                    // copied into scratch storage first.
                    const member_count = pool.getUnionMembers(element).len;
                    var widened: std.ArrayListUnmanaged(TypeIndex) = .empty;
                    defer widened.deinit(self.allocator);
                    widened.ensureTotalCapacity(self.allocator, member_count) catch {
                        self.markAllocationFailure();
                        return null_type_idx;
                    };
                    for (0..member_count) |i| {
                        const member = pool.getUnionMembers(element)[i];
                        widened.appendAssumeCapacity(pool.widenLiteral(member));
                    }
                    const joined = pool.addUnion(self.allocator, widened.items);
                    if (joined == null_type_idx) return null_type_idx;
                    return pool.addArray(self.allocator, joined);
                }
                return pool.addArray(self.allocator, pool.widenLiteral(element));
            },
            // exhaustive: only a tuple or an array initializer type has elements to widen, and any other type is already the binding type.
            else => return inferred,
        }
    }

    /// `type_idx`, or `Dict<unknown, unknown>` when it is a Dict whose key type
    /// is `never`. An unannotated `let` holds the empty Dict of `dictEmpty()`
    /// and takes a Dict with entries later, so it needs the wide type. A Dict
    /// with a known key keeps its type, as an array does at a `let`.
    fn widenEmptyDict(self: *const TypeChecker, type_idx: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        if (pool.getTag(type_idx) != .t_dict) return type_idx;
        if (pool.getDictKey(type_idx) != pool.idx_never) return type_idx;
        return pool.addDict(self.allocator, pool.idx_unknown, pool.idx_unknown);
    }

    /// The type that a `zttp:collections` call stores or reads for the value
    /// `arg`: its widened type, or `unknown` when it has no type.
    fn dictComponentType(self: *const TypeChecker, arg: NodeIndex) TypeIndex {
        const pool = self.env.pool;
        const arg_type = self.inferType(arg);
        if (arg_type == null_type_idx or pool.mentionsError(arg_type)) return pool.idx_unknown;
        return pool.widenLiteral(arg_type);
    }

    /// The join of a Dict key or value type with a stored one. A `never`
    /// component holds nothing, so the stored type stands alone.
    fn dictJoinComponent(self: *const TypeChecker, held: TypeIndex, stored: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        if (held == pool.idx_never) return stored;
        return pool.addUnion(self.allocator, &.{ held, stored });
    }

    /// The type of a call of a `zttp:collections` export that builds or reads
    /// a Dict, resolved through the import so that a local function of the same
    /// name keeps its own type. The first argument is read as one `Dict<K, V>`;
    /// when it is a union, `unknown`, or has no type, the declared return type
    /// of the binding stays. No rule refuses an argument.
    fn collectionsExportCallType(self: *const TypeChecker, binding: ir.BindingRef, call: Node.CallExpr) ?TypeIndex {
        const entry = self.resolveImportedExport(binding) orelse return null;
        if (!std.mem.eql(u8, entry.module.specifier, "zttp:collections")) return null;
        const pool = self.env.pool;
        const name = entry.function.name;
        if (std.mem.eql(u8, name, "dictEmpty") and call.args_count == 0) {
            return pool.addDict(self.allocator, pool.idx_never, pool.idx_never);
        }
        const arity = collectionsDictArity(name) orelse return null;
        if (call.args_count != arity) return null;

        const parts = self.dictParts(self.ir_view.getListIndex(call.args_start, 0)) orelse return null;
        const source = parts.source;
        const held_key = parts.key;
        const held_value = parts.value;

        if (std.mem.eql(u8, name, "dictFilter")) return source;
        if (std.mem.eql(u8, name, "dictMapValues")) return self.dictMapValuesType(call, parts);
        if (std.mem.eql(u8, name, "dictFold")) return self.dictFoldType(call, parts);
        if (std.mem.eql(u8, name, "dictSet")) {
            const stored_key = self.dictComponentType(self.ir_view.getListIndex(call.args_start, 1));
            const stored_value = self.dictComponentType(self.ir_view.getListIndex(call.args_start, 2));
            return pool.addDict(
                self.allocator,
                self.dictJoinComponent(held_key, stored_key),
                self.dictJoinComponent(held_value, stored_value),
            );
        }
        if (std.mem.eql(u8, name, "dictGet")) {
            if (held_key == pool.idx_never) return pool.idx_undefined;
            return pool.withUndefined(self.allocator, held_value);
        }
        if (std.mem.eql(u8, name, "dictHas")) return pool.idx_boolean;
        if (std.mem.eql(u8, name, "dictRemove")) return source;
        const pair = pool.addTuple(self.allocator, &.{ held_key, held_value });
        return pool.addArray(self.allocator, pair);
    }

    /// The argument count of the `zttp:collections` export `name` that reads a
    /// Dict as its first argument, or null for any other export.
    fn collectionsDictArity(name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "dictSet") or std.mem.eql(u8, name, "dictFold")) return 3;
        const two = [_][]const u8{ "dictGet", "dictHas", "dictRemove", "dictMapValues", "dictFilter" };
        for (two) |known| {
            if (std.mem.eql(u8, known, name)) return 2;
        }
        if (std.mem.eql(u8, name, "dictEntries")) return 1;
        return null;
    }

    /// A Dict type and its key and value types, with `unknown` for a part that
    /// the Dict type does not name.
    const DictParts = struct { source: TypeIndex, key: TypeIndex, value: TypeIndex };

    /// The Dict that the argument `arg` holds, read as one `Dict<K, V>`. Null
    /// when the argument has no type, is not a Dict type, or is a union.
    fn dictParts(self: *const TypeChecker, arg: NodeIndex) ?DictParts {
        const pool = self.env.pool;
        const first = self.inferType(arg);
        if (first == null_type_idx) return null;
        const source = self.resolvedType(self.env.stripProofMarkers(first));
        if (pool.getTag(source) != .t_dict or pool.mentionsError(source)) return null;
        const key_type = pool.getDictKey(source);
        const value_type = pool.getDictValue(source);
        return .{
            .source = source,
            .key = if (key_type == null_type_idx) pool.idx_unknown else key_type,
            .value = if (value_type == null_type_idx) pool.idx_unknown else value_type,
        };
    }

    /// A call of `dictFold`, `dictMapValues`, or `dictFilter` from
    /// `zttp:collections` whose first argument is one Dict type.
    const DictCallbackCall = struct { name: []const u8, parts: DictParts, callback: NodeIndex };

    fn dictCallbackCall(self: *const TypeChecker, call: Node.CallExpr) ?DictCallbackCall {
        if (self.ir_view.getTag(call.callee) != .identifier) return null;
        const binding = self.ir_view.getBinding(call.callee) orelse return null;
        const entry = self.resolveImportedExport(binding) orelse return null;
        if (!std.mem.eql(u8, entry.module.specifier, "zttp:collections")) return null;
        const name = entry.function.name;
        const is_callback_export = std.mem.eql(u8, name, "dictFold") or
            std.mem.eql(u8, name, "dictMapValues") or
            std.mem.eql(u8, name, "dictFilter");
        if (!is_callback_export) return null;
        const arity = collectionsDictArity(name) orelse return null;
        if (call.args_count != arity) return null;
        const parts = self.dictParts(self.ir_view.getListIndex(call.args_start, 0)) orelse return null;
        return .{ .name = name, .parts = parts, .callback = self.ir_view.getListIndex(call.args_start, 1) };
    }

    /// `dictMapValues(d, f)` over `Dict<K, V>` is `Dict<K, R>`, where `R` is
    /// the widened type that `f` returns under the bound parameters. `R` is
    /// `unknown` when that type is not known or the callback does not accept
    /// `(V, K)`. A Dict with no key holds no entry, so the callback never runs
    /// and the result is that Dict.
    fn dictMapValuesType(self: *const TypeChecker, call: Node.CallExpr, parts: DictParts) TypeIndex {
        const pool = self.env.pool;
        if (parts.key == pool.idx_never) return parts.source;
        const mutable = @constCast(self);
        const previous = mutable.report_inference_diagnostics;
        mutable.report_inference_diagnostics = false;
        defer mutable.report_inference_diagnostics = previous;

        var result = pool.idx_unknown;
        const callback = self.callbackFunctionType(self.ir_view.getListIndex(call.args_start, 1));
        if (callback != null_type_idx) {
            const returned = self.callbackReturnType(callback);
            if (returned != null_type_idx and self.callbackAccepts(callback, &.{ parts.value, parts.key })) result = returned;
        }
        return pool.addDict(self.allocator, parts.key, result);
    }

    /// `dictFold(d, f, init)` is the widened type of `init` when `f` returns a
    /// value of that type and accepts `(accumulator, V, K)`, as the seeded
    /// `reduce` does (`bindSeededAccumulator`). Otherwise it is `unknown`. The
    /// fold over a Dict with no key is the seed, whatever `f` is.
    fn dictFoldType(self: *const TypeChecker, call: Node.CallExpr, parts: DictParts) TypeIndex {
        const pool = self.env.pool;
        const mutable = @constCast(self);
        const previous = mutable.report_inference_diagnostics;
        mutable.report_inference_diagnostics = false;
        defer mutable.report_inference_diagnostics = previous;

        const seed_source = self.inferType(self.ir_view.getListIndex(call.args_start, 2));
        if (seed_source == null_type_idx) return pool.idx_unknown;
        const seed = pool.widenLiteral(seed_source);
        if (!self.isDefiniteType(seed, 0)) return pool.idx_unknown;
        // A Dict with no key holds no entry, so the fold returns its seed.
        if (parts.key == pool.idx_never) return seed;
        const callback = self.callbackFunctionType(self.ir_view.getListIndex(call.args_start, 1));
        if (callback == null_type_idx) return pool.idx_unknown;
        const returned = self.callbackReturnType(callback);
        if (returned == null_type_idx or !self.env.isAssignableTo(returned, seed)) return pool.idx_unknown;
        if (!self.callbackAccepts(callback, &.{ seed, parts.value, parts.key })) return pool.idx_unknown;
        return seed;
    }

    /// The `zttp:result` export that `call` names, resolved through the
    /// import so that a local function of the same name keeps its own type.
    fn resultExportName(self: *const TypeChecker, call: Node.CallExpr) ?[]const u8 {
        if (self.ir_view.getTag(call.callee) != .identifier) return null;
        const binding = self.ir_view.getBinding(call.callee) orelse return null;
        const entry = self.resolveImportedExport(binding) orelse return null;
        if (!std.mem.eql(u8, entry.module.specifier, "zttp:result")) return null;
        return entry.function.name;
    }

    /// The combinators whose second argument is a callback that the runtime
    /// calls with one argument: the payload of the Result.
    fn isCallbackCombinator(name: []const u8) bool {
        const names = [_][]const u8{ "mapResult", "mapError", "andThen", "orElse" };
        for (names) |known| {
            if (std.mem.eql(u8, known, name)) return true;
        }
        return false;
    }

    /// The combinators that call the callback with the error payload. The
    /// payload is whatever sits under `error` or under `errors`.
    fn passesErrorPayload(name: []const u8) bool {
        return std.mem.eql(u8, name, "mapError") or std.mem.eql(u8, name, "orElse");
    }

    /// The type of the one value that the runtime passes to the callback of
    /// the combinator `name` in `call`: the `value` type of the first
    /// argument for `mapResult` and `andThen`, and the join of its `error`
    /// and `errors` types for `mapError` and `orElse`. Null when the first
    /// argument is not a Result, or a field has no type. The type can be
    /// `unknown` or raw JSON: the acceptance check compares against it as it
    /// stands, and the binding skips those two (`bindableType`).
    fn combinatorPassedType(self: *const TypeChecker, name: []const u8, call: Node.CallExpr) TypeIndex {
        if (call.args_count < 2) return null_type_idx;
        const parts = self.resultParts(self.inferType(self.ir_view.getListIndex(call.args_start, 0))) orelse return null_type_idx;
        if (passesErrorPayload(name)) return self.joinTypes(parts.error_type, parts.errors_type);
        return parts.value_type;
    }

    /// `type_idx` when a parameter can take it as its type, and null when the
    /// type is `unknown`, raw JSON, or refused: a binding of those would not
    /// describe the value, and would make an arithmetic check refuse code that
    /// runs today.
    fn bindableType(self: *const TypeChecker, type_idx: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        if (type_idx == null_type_idx or type_idx == pool.idx_unknown or type_idx == pool.idx_json_value) return null_type_idx;
        if (pool.mentionsError(type_idx)) return null_type_idx;
        return type_idx;
    }

    /// The three field types of a Result type, or of a union of them. Null
    /// when `type_idx` is not a Result type, when a field has no type, or when
    /// a field mentions a refused expression.
    const ResultParts = struct { value_type: TypeIndex, error_type: TypeIndex, errors_type: TypeIndex };

    fn resultParts(self: *const TypeChecker, type_idx: TypeIndex) ?ResultParts {
        if (!self.isResultType(type_idx, 0)) return null;
        const pool = self.env.pool;
        const parts = ResultParts{
            .value_type = self.resultFieldType(type_idx, "value", 0),
            .error_type = self.resultFieldType(type_idx, "error", 0),
            .errors_type = self.resultFieldType(type_idx, "errors", 0),
        };
        if (parts.value_type == null_type_idx or parts.error_type == null_type_idx or parts.errors_type == null_type_idx) return null;
        if (pool.mentionsError(parts.value_type) or pool.mentionsError(parts.error_type) or pool.mentionsError(parts.errors_type)) return null;
        return parts;
    }

    /// The function type of a combinator callback: the type its body returns
    /// for an inline function, read after the walk bound its parameters, and
    /// the type of the name for any other argument. Null when the argument is
    /// not a function or has no type.
    fn combinatorCallbackType(self: *const TypeChecker, arg: NodeIndex) TypeIndex {
        const tag = self.ir_view.getTag(arg) orelse return null_type_idx;
        if (tag == .arrow_function or tag == .function_expr) return self.functionExprType(arg);
        const resolved = self.resolvedType(self.inferType(arg));
        if (resolved == null_type_idx or self.env.pool.getTag(resolved) != .t_function) return null_type_idx;
        return resolved;
    }

    /// A marked Result that has the three field types of `type_idx`, which is
    /// a Result type or a union of them. Null when `type_idx` is not one.
    fn normalizedResultType(self: *const TypeChecker, type_idx: TypeIndex) TypeIndex {
        const parts = self.resultParts(type_idx) orelse return null_type_idx;
        return self.typedResultType(parts.value_type, parts.error_type, parts.errors_type);
    }

    /// The type of a call of `mapResult`, `mapError`, `andThen`, or `orElse`
    /// from `zttp:result`. Each row needs the types of its first argument
    /// and the return type of its callback; null keeps the table record.
    ///
    /// `mapError` stores the callback result under the field that the input
    /// used, so `error` is the result and `errors` is the result when the
    /// input's `errors` is not `never`.
    fn combinatorCallType(self: *const TypeChecker, name: []const u8, call: Node.CallExpr) ?TypeIndex {
        const mutable = @constCast(self);
        const previous = mutable.report_inference_diagnostics;
        mutable.report_inference_diagnostics = false;
        defer mutable.report_inference_diagnostics = previous;

        const pool = self.env.pool;
        const parts = self.resultParts(self.inferType(self.ir_view.getListIndex(call.args_start, 0))) orelse return null;
        const callback_type = self.combinatorCallbackType(self.ir_view.getListIndex(call.args_start, 1));
        if (callback_type == null_type_idx) return null;
        const callback_return = pool.getFunctionInfo(callback_type).ret;

        if (std.mem.eql(u8, name, "mapResult")) {
            const returned = self.callbackReturnType(callback_type);
            if (returned == null_type_idx) return null;
            return self.typedResultType(returned, parts.error_type, parts.errors_type);
        }
        if (std.mem.eql(u8, name, "mapError")) {
            const returned = self.callbackReturnType(callback_type);
            if (returned == null_type_idx) return null;
            const errors_type = if (parts.errors_type == pool.idx_never) pool.idx_never else returned;
            return self.typedResultType(parts.value_type, returned, errors_type);
        }
        if (std.mem.eql(u8, name, "andThen")) {
            const next = self.normalizedResultType(callback_return);
            if (next == null_type_idx) return null;
            return self.joinTypes(next, self.typedResultType(pool.idx_never, parts.error_type, parts.errors_type));
        }
        if (std.mem.eql(u8, name, "orElse")) {
            const next = self.normalizedResultType(callback_return);
            if (next == null_type_idx) return null;
            return self.joinTypes(self.typedResultType(parts.value_type, pool.idx_never, pool.idx_never), next);
        }
        return null;
    }

    /// The type of a call of `collectAll`: the array of the joined value types
    /// of the elements, and the joined error types. Null for an argument that
    /// is not an array or a tuple of Results, and for an array with no element
    /// type or a `never` element (the empty array literal).
    fn collectAllCallType(self: *const TypeChecker, call: Node.CallExpr) ?TypeIndex {
        const mutable = @constCast(self);
        const previous = mutable.report_inference_diagnostics;
        mutable.report_inference_diagnostics = false;
        defer mutable.report_inference_diagnostics = previous;

        const pool = self.env.pool;
        const list_type = self.inferType(self.ir_view.getListIndex(call.args_start, 0));
        if (list_type == null_type_idx) return null;
        const resolved = self.resolvedType(self.env.stripProofMarkers(list_type));
        var joined: ?ResultParts = null;
        switch (pool.getTag(resolved) orelse return null) {
            .t_array => {
                const element = pool.getArrayElement(resolved);
                if (element == null_type_idx or element == pool.idx_never) return null;
                joined = self.resultParts(element) orelse return null;
            },
            .t_tuple => {
                const elements = pool.getTupleElements(resolved);
                if (elements.len == 0) return null;
                for (elements) |element| {
                    const parts = self.resultParts(element) orelse return null;
                    joined = if (joined) |so_far| .{
                        .value_type = self.joinTypes(so_far.value_type, parts.value_type),
                        .error_type = self.joinTypes(so_far.error_type, parts.error_type),
                        .errors_type = self.joinTypes(so_far.errors_type, parts.errors_type),
                    } else parts;
                }
            },
            // exhaustive: any other argument type is not a list of Results.
            else => return null,
        }
        const parts = joined orelse return null;
        return self.typedResultType(pool.addArray(self.allocator, parts.value_type), parts.error_type, parts.errors_type);
    }

    /// Compare the parameters of the callback of a `zttp:result` combinator
    /// with the one value that the runtime passes (T4), as the array methods
    /// do: the passed type stands as it is, `unknown` and raw JSON included,
    /// and only a position with no type at all accepts anything. A parameter
    /// past the first must be optional or accept `undefined`. Returns true
    /// after it reports a mismatch, so the call is reported once.
    fn checkCombinatorCallbackParam(self: *TypeChecker, call: Node.CallExpr) bool {
        const name = self.resultExportName(call) orelse return false;
        if (!isCallbackCombinator(name) or call.args_count != 2) return false;
        const pool = self.env.pool;

        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;

        const arg = self.ir_view.getListIndex(call.args_start, 1);
        const arg_tag = self.ir_view.getTag(arg) orelse return false;
        var callback_type: TypeIndex = null_type_idx;
        var func: ?ir.Node.FunctionExpr = null;
        if (arg_tag == .arrow_function or arg_tag == .function_expr) {
            const parsed = self.ir_view.getFunction(arg) orelse return false;
            func = parsed;
            callback_type = self.functionTypeWithParams(parsed.params_count, self.sourceFunctionSignature(arg), null_type_idx);
        } else {
            callback_type = self.resolvedType(self.inferType(arg));
        }
        if (callback_type == null_type_idx or pool.getTag(callback_type) != .t_function) return false;

        const passed = self.combinatorPassedType(name, call);
        const refused = self.firstRefusedCallbackParam(callback_type, &.{passed}) orelse return false;
        const passed_type = if (refused == 0) passed else pool.idx_undefined;
        self.reportCallbackParam(arg, func, callback_type, refused, name, passed_type);
        return true;
    }

    /// Compare the parameters of the callback of `dictFold`, `dictMapValues`,
    /// or `dictFilter` over one Dict type with the values that the runtime
    /// passes: `(accumulator, value, key)` for the fold and `(value, key)` for
    /// the others. The accumulator is the widened seed type, and the
    /// callback's own return type must fit an annotated accumulator. A
    /// position with no known type accepts anything, and a parameter past
    /// those the runtime passes must be optional or accept `undefined`.
    /// Returns true after it reports a mismatch, so the call is reported once.
    /// A non-boolean result of the `dictFilter` callback is reported by
    /// `checkModuleBooleanPredicate`.
    fn checkDictCallbackParams(self: *TypeChecker, call: Node.CallExpr) bool {
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;

        const info = self.dictCallbackCall(call) orelse return false;
        const pool = self.env.pool;
        const arg = info.callback;
        const arg_tag = self.ir_view.getTag(arg) orelse return false;
        const inline_callback = arg_tag == .arrow_function or arg_tag == .function_expr;

        var callback_type: TypeIndex = null_type_idx;
        var func: ?ir.Node.FunctionExpr = null;
        if (inline_callback) {
            const parsed = self.ir_view.getFunction(arg) orelse return false;
            func = parsed;
            callback_type = self.functionTypeWithParams(parsed.params_count, self.sourceFunctionSignature(arg), null_type_idx);
        } else {
            callback_type = self.resolvedType(self.inferType(arg));
        }
        if (callback_type == null_type_idx or pool.getTag(callback_type) != .t_function) return false;

        const is_fold = std.mem.eql(u8, info.name, "dictFold");
        var passed: [3]TypeIndex = undefined;
        var passed_count: usize = 2;
        if (is_fold) {
            const seed = self.inferType(self.ir_view.getListIndex(call.args_start, 2));
            const accumulator = if (seed != null_type_idx and self.isDefiniteType(pool.widenLiteral(seed), 0))
                pool.widenLiteral(seed)
            else
                null_type_idx;
            passed = .{ accumulator, info.parts.value, info.parts.key };
            passed_count = 3;
        } else {
            passed = .{ info.parts.value, info.parts.key, null_type_idx };
        }

        var param_position: usize = 0;
        var passed_type: TypeIndex = pool.idx_undefined;
        if (self.firstRefusedCallbackParam(callback_type, passed[0..passed_count])) |position| {
            param_position = position;
            if (position < passed_count) passed_type = passed[position];
        } else if (is_fold) {
            // An annotated accumulator must also accept each callback result.
            const params = pool.getFunctionInfo(callback_type).params;
            if (params.len == 0) return false;
            const accumulator_type = params[0].type_idx;
            if (accumulator_type == null_type_idx or accumulator_type == pool.idx_unknown) return false;
            const result_type = if (inline_callback) self.functionExprType(arg) else callback_type;
            if (result_type == null_type_idx) return false;
            const returned = self.callbackReturnType(result_type);
            if (returned == null_type_idx) return false;
            if (self.env.isAssignableTo(returned, accumulator_type)) return false;
            passed_type = returned;
        } else return false;

        self.reportCallbackParam(arg, func, callback_type, param_position, info.name, passed_type);
        return true;
    }

    /// The Result arguments of a `zttp:*` export, checked by the kind that the
    /// export declares for each position. A `.result` position takes a
    /// Result, a `.result_fn` position takes a function whose return is a
    /// Result, and a `.result_list` position takes an array of Results. The
    /// runtime hands any other value back unchanged, or turns it into
    /// `undefined` or `err(undefined)`, so a Result type read from the call
    /// would be false. An argument with no type is not refused. At most one
    /// diagnostic is reported for the call, and the return value says so.
    fn checkModuleResultArgs(self: *TypeChecker, call: Node.CallExpr) bool {
        if (self.ir_view.getTag(call.callee) != .identifier) return false;
        const binding = self.ir_view.getBinding(call.callee) orelse return false;
        const entry = self.resolveImportedExport(binding) orelse return false;
        if (call.args_count > entry.function.arg_count) return false;
        const pool = self.env.pool;

        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;

        for (entry.function.param_types, 0..) |kind, position| {
            if (position >= call.args_count) break;
            const arg = self.ir_view.getListIndex(call.args_start, @intCast(position));
            switch (kind) {
                .result => {
                    const arg_type = self.inferType(arg);
                    if (arg_type == null_type_idx or self.isResultType(arg_type, 0)) continue;
                    self.reportResultShape(arg, entry.function.name, position, "must be a Result", arg_type);
                    return true;
                },
                .result_list => {
                    const arg_type = self.inferType(arg);
                    if (arg_type == null_type_idx or self.isResultListType(arg_type, 0)) continue;
                    self.reportResultShape(arg, entry.function.name, position, "must be an array of Results", arg_type);
                    return true;
                },
                .result_fn => {
                    const arg_tag = self.ir_view.getTag(arg) orelse continue;
                    const inline_callback = arg_tag == .arrow_function or arg_tag == .function_expr;
                    const callback_type = if (inline_callback)
                        self.functionExprType(arg)
                    else
                        self.resolvedType(self.inferType(arg));
                    if (callback_type == null_type_idx or pool.getTag(callback_type) != .t_function) continue;
                    const returned = pool.getFunctionInfo(callback_type).ret;
                    // A return with no type keeps today's behavior. `unknown` and raw
                    // JSON are types that may hold a value that is not a Result,
                    // so they are refused, as at a `.result` position.
                    if (returned == null_type_idx) continue;
                    if (returned == pool.idx_never or pool.mentionsError(returned)) continue;
                    if (self.isResultType(returned, 0)) continue;
                    var buf: [1024]u8 = undefined;
                    const got = pool.formatType(returned, &buf);
                    const msg = self.allocator.print("{s} callback must return a Result, got '{s}'", .{ entry.function.name, got }) catch "a Result argument has the wrong type";
                    self.addResultShapeDiagnostic(arg, msg);
                    return true;
                },
                // exhaustive: no other kind of parameter holds a Result.
                else => {},
            }
        }
        return false;
    }

    fn reportResultShape(
        self: *TypeChecker,
        arg: NodeIndex,
        export_name: []const u8,
        position: usize,
        requirement: []const u8,
        got: TypeIndex,
    ) void {
        var buf: [1024]u8 = undefined;
        const got_str = self.env.pool.formatType(got, &buf);
        const msg = self.allocator.print("{s} argument {d} {s}, got '{s}'", .{ export_name, position + 1, requirement, got_str }) catch "a Result argument has the wrong type";
        self.addResultShapeDiagnostic(arg, msg);
    }

    fn addResultShapeDiagnostic(self: *TypeChecker, arg: NodeIndex, msg: []const u8) void {
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .arg_type_mismatch,
            .node = arg,
            .message = msg,
            .help = "pass a Result that ok, err, or a module export returns",
            .allocated = !std.mem.eql(u8, msg, result_shape_fallback),
        });
    }

    /// How the runtime calls the callback of `name` on an array, as the
    /// values that `checkArrayCallbackParams` compares.
    const CallbackMethod = enum { element_methods, comparator, reduce };

    fn callbackMethod(name: []const u8) ?CallbackMethod {
        return switch (callbackShape(name) orelse return null) {
            .element_index_array => .element_methods,
            .comparator => .comparator,
            .reduce => .reduce,
            // exhaustive: `flatMap` is not installed, so no row types it.
            .element_only => null,
        };
    }

    /// The element type and the passed array type of an array-method
    /// receiver: an array, a tuple (through `tupleToArrayType`), or a union
    /// whose every member is one of those. Null elements mean the receiver is
    /// any other type, or has no element type.
    const CallbackReceiver = struct { element: TypeIndex, array: TypeIndex };

    fn callbackReceiver(self: *const TypeChecker, receiver: TypeIndex) ?CallbackReceiver {
        if (receiver == null_type_idx) return null;
        const pool = self.env.pool;
        const resolved = self.resolvedType(receiver);
        if (pool.getTag(resolved) == .t_union) {
            const members = pool.getUnionMembers(resolved);
            if (members.len == 0 or members.len > MAX_UNION_MEMBERS) return null;
            var elements: [MAX_UNION_MEMBERS]TypeIndex = undefined;
            for (members, 0..) |member, i| {
                const member_array = self.arrayReceiverType(member);
                if (member_array == null_type_idx) return null;
                elements[i] = pool.getArrayElement(member_array);
            }
            const element = pool.addUnion(self.allocator, elements[0..members.len]);
            if (element == null_type_idx) return null;
            return .{ .element = element, .array = resolved };
        }
        const array = self.arrayReceiverType(resolved);
        if (array == null_type_idx) return null;
        const element = pool.getArrayElement(array);
        if (element == null_type_idx) return null;
        return .{ .element = element, .array = array };
    }

    /// `element` without `undefined`: the runtime sorts an `undefined`
    /// element last and never passes it to a comparator.
    fn withoutUndefined(self: *const TypeChecker, element: TypeIndex) TypeIndex {
        const pool = self.env.pool;
        const resolved = self.resolvedType(element);
        return switch (pool.getTag(resolved) orelse return null_type_idx) {
            .t_nullable => pool.getNullableInner(resolved),
            .t_undefined => null_type_idx,
            .t_union => pool.excludeUnionMember(self.allocator, resolved, pool.idx_undefined),
            // exhaustive: any other element type cannot hold `undefined`, so it is passed as is.
            else => element,
        };
    }

    /// Whether the callback type `callback_type` accepts the value that the
    /// runtime passes in each position, and `undefined` in each position
    /// past `passed`. A `null_type_idx` in `passed` is a value with no known
    /// type, and its position accepts anything. Returns the index of the
    /// first parameter that fails, or null.
    fn firstRefusedCallbackParam(self: *const TypeChecker, callback_type: TypeIndex, passed: []const TypeIndex) ?usize {
        const pool = self.env.pool;
        const params = pool.getFunctionInfo(callback_type).params;
        for (params, 0..) |param, i| {
            if (param.type_idx == null_type_idx or param.type_idx == pool.idx_unknown) continue;
            if (i < passed.len) {
                if (passed[i] == null_type_idx) continue;
                if (!self.env.isAssignableTo(passed[i], param.type_idx)) return i;
            } else {
                if (param.optional) continue;
                if (!self.env.isAssignableTo(pool.idx_undefined, param.type_idx)) return i;
            }
        }
        return null;
    }

    /// Compare the parameters of the callback argument of an array method
    /// with the values that the runtime passes (T1). Returns true after it
    /// reports a mismatch, so the call is reported once.
    fn checkArrayCallbackParams(self: *TypeChecker, call: Node.CallExpr) bool {
        if (call.args_count == 0) return false;
        const member = self.ir_view.getMember(call.callee) orelse return false;
        if (member.computed != null_node) return false;
        const name = self.resolveAtomName(member.property) orelse return false;
        const method = callbackMethod(name) orelse return false;
        const pool = self.env.pool;

        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;

        const receiver = self.callbackReceiver(self.inferType(member.object)) orelse return false;
        const arg = self.ir_view.getListIndex(call.args_start, 0);
        const arg_tag = self.ir_view.getTag(arg) orelse return false;
        const inline_callback = arg_tag == .arrow_function or arg_tag == .function_expr;

        var callback_type: TypeIndex = null_type_idx;
        var func: ?ir.Node.FunctionExpr = null;
        if (inline_callback) {
            const parsed = self.ir_view.getFunction(arg) orelse return false;
            func = parsed;
            callback_type = self.functionTypeWithParams(parsed.params_count, self.sourceFunctionSignature(arg), null_type_idx);
        } else {
            callback_type = self.resolvedType(self.inferType(arg));
        }
        if (callback_type == null_type_idx or pool.getTag(callback_type) != .t_function) return false;

        var passed: [4]TypeIndex = undefined;
        var passed_count: usize = 0;
        switch (method) {
            .element_methods => {
                passed = .{ receiver.element, pool.idx_number, receiver.array, null_type_idx };
                passed_count = 3;
            },
            .comparator => {
                const element = self.withoutUndefined(receiver.element);
                if (element == null_type_idx) return false;
                passed = .{ element, element, null_type_idx, null_type_idx };
                passed_count = 2;
            },
            .reduce => {
                var accumulator = receiver.element;
                if (call.args_count >= 2) {
                    const seed = self.inferType(self.ir_view.getListIndex(call.args_start, 1));
                    accumulator = if (seed != null_type_idx and self.isDefiniteType(seed, 0)) pool.widenLiteral(seed) else null_type_idx;
                }
                passed = .{ accumulator, receiver.element, pool.idx_number, receiver.array };
                passed_count = 4;
            },
        }

        const refused = self.firstRefusedCallbackParam(callback_type, passed[0..passed_count]);
        var param_position: usize = 0;
        var passed_type: TypeIndex = pool.idx_undefined;
        if (refused) |position| {
            param_position = position;
            if (position < passed_count) passed_type = passed[position];
        } else if (method == .reduce) {
            // An annotated accumulator must also accept each callback result.
            // An inline callback's result is the type its body returns; a
            // named function's is its declared return.
            const params = pool.getFunctionInfo(callback_type).params;
            if (params.len == 0) return false;
            const accumulator_type = params[0].type_idx;
            if (accumulator_type == null_type_idx or accumulator_type == pool.idx_unknown) return false;
            const result_type = if (inline_callback) self.functionExprType(arg) else callback_type;
            if (result_type == null_type_idx) return false;
            const returned = self.callbackReturnType(result_type);
            if (returned == null_type_idx) return false;
            if (self.env.isAssignableTo(returned, accumulator_type)) return false;
            passed_type = returned;
        } else return false;

        self.reportCallbackParam(arg, func, callback_type, param_position, name, passed_type);
        return true;
    }

    /// Whether `call` is `filter`, `find`, `findIndex`, `some`, or `every` on
    /// an array receiver: the calls whose callback parameters
    /// `checkArrayCallbackParams` owns. Any other member call keeps the full
    /// function type check, parameters included.
    fn isArrayPredicateCall(self: *TypeChecker, call: Node.CallExpr) bool {
        const member = self.ir_view.getMember(call.callee) orelse return false;
        if (member.computed != null_node) return false;
        const name = self.resolveAtomName(member.property) orelse return false;
        const predicates = [_][]const u8{ "filter", "find", "findIndex", "some", "every" };
        var known = false;
        for (predicates) |predicate| {
            if (std.mem.eql(u8, predicate, name)) known = true;
        }
        if (!known) return false;
        const previous = self.report_inference_diagnostics;
        self.report_inference_diagnostics = false;
        defer self.report_inference_diagnostics = previous;
        return self.callbackReceiver(self.inferType(member.object)) != null;
    }

    /// The argument type compared with the parameter type `param_type`. A
    /// predicate parameter (`() => boolean`) constrains the callback's
    /// return type only: `checkArrayCallbackParams` owns its parameters. So a
    /// named function with parameters compares by its return type, as an
    /// inline callback does.
    fn predicateArgumentType(self: *const TypeChecker, arg: NodeIndex, param_type: TypeIndex) TypeIndex {
        const arg_type = self.argumentTypeForChecking(arg);
        const pool = self.env.pool;
        if (arg_type == null_type_idx or param_type == null_type_idx) return arg_type;
        if (pool.getTag(arg_type) != .t_function or pool.getTag(param_type) != .t_function) return arg_type;
        if (pool.getFunctionInfo(param_type).params.len != 0) return arg_type;
        const info = pool.getFunctionInfo(arg_type);
        if (info.params.len == 0) return arg_type;
        return pool.addFunctionWithReturn(self.allocator, &.{}, info.ret);
    }

    fn reportCallbackParam(
        self: *TypeChecker,
        arg: NodeIndex,
        func: ?ir.Node.FunctionExpr,
        callback_type: TypeIndex,
        position: usize,
        method: []const u8,
        passed_type: TypeIndex,
    ) void {
        const pool = self.env.pool;
        const param = pool.getFunctionInfo(callback_type).params[position];
        // A named function type holds no parameter name, so the position
        // stands in: `#1` is the first parameter.
        var source_name: ?[]const u8 = null;
        if (func) |parsed| {
            if (position < parsed.params_count) {
                const param_idx = self.ir_view.getListIndex(parsed.params_start, @intCast(position));
                if (self.ir_view.paramBinding(param_idx)) |binding| source_name = self.resolveAtomName(binding.name_atom);
            }
        }
        var buf: [2048]u8 = undefined;
        const expected_str = pool.formatType(param.type_idx, buf[0..1024]);
        const passed_str = pool.formatType(passed_type, buf[1024..2048]);
        const printed = if (source_name) |label|
            self.allocator.print(
                "callback parameter '{s}' is '{s}', but {s} passes '{s}'",
                .{ label, expected_str, method, passed_str },
            )
        else
            self.allocator.print(
                "callback parameter '#{d}' is '{s}', but {s} passes '{s}'",
                .{ position + 1, expected_str, method, passed_str },
            );
        if (printed) |msg| {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .arg_type_mismatch,
                .node = arg,
                .message = msg,
                .help = "annotate the parameter with the type that the method passes, or remove the annotation",
                .allocated = true,
            });
        } else |_| self.markAllocationFailure();
    }

    fn checkCallArgs(self: *TypeChecker, node: NodeIndex, call: Node.CallExpr) void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        // Before the branches on the callee tag: `responseConstructorName`
        // reads every spelling of the callee.
        self.checkResponseInit(call);
        if (callee_tag == .identifier) {
            self.checkModuleEncodableArgs(call);
            self.checkModuleBooleanPredicate(call);
            if (self.checkModuleResultArgs(call)) return;
            if (self.checkCombinatorCallbackParam(call)) return;
            if (self.checkDictCallbackParams(call)) return;
        }
        if (callee_tag == .member_access) {
            self.checkResponseJsonPayload(call);
            if (self.checkArrayCallbackParams(call)) return;
            const callee_type = self.inferType(call.callee);
            const tag = self.env.pool.getTag(callee_type) orelse return;
            if (tag == .t_function) {
                const info = self.env.pool.getFunctionInfo(callee_type);
                // Optional (trailing) params may be omitted: the arg count must fall
                // between the required-param count and the total param count.
                var required: usize = 0;
                for (info.params) |param| {
                    if (!param.optional) required += 1;
                }
                if (call.args_count < required or call.args_count > info.params.len) {
                    self.addArgCountMismatch(node, info.params.len, @intCast(call.args_count));
                    return;
                }
                const predicate_call = self.isArrayPredicateCall(call);
                for (info.params, 0..) |param, i| {
                    if (i >= call.args_count) break;
                    const arg_idx = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    const arg_type = if (i == 0 and predicate_call)
                        self.predicateArgumentType(arg_idx, param.type_idx)
                    else
                        self.argumentTypeForChecking(arg_idx);
                    if (arg_type != null_type_idx and param.type_idx != null_type_idx and !self.env.isAssignableTo(arg_type, param.type_idx)) {
                        self.addArgTypeMismatch(arg_idx, param.type_idx, arg_type);
                    }
                }
            } else if (tag == .t_union) {
                const members = self.env.pool.getUnionMembers(callee_type);
                if (members.len == 0) return;

                var shared_param_count: ?usize = null;
                var param_types: [MAX_UNION_MEMBERS]TypeIndex = undefined;
                var param_count: usize = 0;

                for (members) |member_type| {
                    if (self.env.pool.getTag(member_type) != .t_function) return;
                    const info = self.env.pool.getFunctionInfo(member_type);
                    if (shared_param_count == null) {
                        shared_param_count = info.params.len;
                        param_count = info.params.len;
                        if (param_count > param_types.len) return;
                        for (info.params, 0..) |param, i| {
                            param_types[i] = param.type_idx;
                        }
                    } else if (shared_param_count.? != info.params.len) {
                        return;
                    } else {
                        for (info.params, 0..) |param, i| {
                            if (param_types[i] != param.type_idx) return;
                        }
                    }
                }

                if (call.args_count != param_count) {
                    self.addArgCountMismatch(node, param_count, @intCast(call.args_count));
                    return;
                }

                for (0..param_count) |i| {
                    const arg_idx = self.ir_view.getListIndex(call.args_start, @intCast(i));
                    const arg_type = self.argumentTypeForChecking(arg_idx);
                    if (arg_type != null_type_idx and param_types[i] != null_type_idx and !self.env.isAssignableTo(arg_type, param_types[i])) {
                        self.addArgTypeMismatch(arg_idx, param_types[i], arg_type);
                    }
                }
            }
            return;
        }
        if (callee_tag != .identifier) return;

        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const bound_metadata = self.boundCallableMetadata(binding);
        const unbound_name = if (bound_metadata == null)
            self.resolveAtomName(binding.name_atom)
        else
            null;

        // A `zttp:*` export is identified by the import that names it, not by
        // its local name, so an alias and a same-named export of another module
        // each answer to their own declared parameter count. Every call supplies
        // every declared argument (spec: fixed arity), so a surplus is a defect
        // whatever the types are. The lower bound is checked below.
        if (bound_metadata == null) {
            if (self.resolveImportedExport(binding)) |entry| {
                if (call.args_count > entry.function.arg_count) {
                    self.addArgCountMismatch(node, entry.function.arg_count, @intCast(call.args_count));
                    return;
                }
            }
        }

        const sig = if (bound_metadata) |metadata|
            switch (metadata) {
                .unavailable => return,
                .arity => |declared| {
                    // Only the parameter list is known. Every call supplies
                    // every declared argument (spec: fixed arity), so a
                    // surplus is a defect whatever the types are.
                    if (call.args_count > declared) {
                        self.addArgCountMismatch(node, declared, @intCast(call.args_count));
                    }
                    return;
                },
                .signature => |signature| signature,
            }
        else
            self.env.getFnSigByName(unbound_name orelse return) orelse return;

        // Check argument count
        const required_param_count = sig.required_param_count orelse sig.param_count;
        if (call.args_count < required_param_count) {
            self.addArgCountMismatch(node, required_param_count, @intCast(call.args_count));
            return;
        }
        // The upper bound, where the callee's own parameter list is known. A
        // signature without that list (a module export, a global) is checked
        // against its own table elsewhere. A source function has no optional
        // parameter (the parser refuses `?:`), so the bound is one count.
        if (sig.max_arg_count) |max_arg_count| {
            if (call.args_count > max_arg_count) {
                self.addArgCountMismatch(node, max_arg_count, @intCast(call.args_count));
                return;
            }
        }

        // Bind the type parameters before the arguments are compared, so every
        // instantiation is checked against its substituted parameter types
        // rather than against a type variable that accepts anything.
        const attempted = self.instantiateSignature(node, sig, call);
        const failed = switch (attempted) {
            .none, .ok => false,
            .arity, .ambiguous, .violated => true,
        };
        const inst = self.reportInstantiation(node, attempted);

        // A call whose type parameters could not be bound is already reported.
        // Comparing its arguments against parameter types that still contain an
        // unsubstituted `T` says nothing further about the program - under D1
        // amendment A1 a type variable is assignable to nothing, so every
        // argument of a refused call would be reported a second time for the
        // same defect. This is the cascade `instantiatedReturnType` avoids on
        // the return side.
        if (failed) return;

        // Check argument types
        var i: u8 = 0;
        while (i < sig.param_count and i < call.args_count) : (i += 1) {
            const arg_idx = self.ir_view.getListIndex(call.args_start, i);
            const arg_type = self.argumentTypeForChecking(arg_idx);
            const param_type = self.substitute(inst, sig.param_types[i]);
            if (arg_type != null_type_idx and param_type != null_type_idx) {
                if (!self.env.isAssignableTo(arg_type, param_type)) {
                    self.addArgTypeMismatch(arg_idx, param_type, arg_type);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // Diagnostic helpers
    // -------------------------------------------------------------------

    /// The name a plain identifier node reads, borrowed from the atom table.
    fn identifierName(self: *const TypeChecker, node: NodeIndex) ?[]const u8 {
        if (self.ir_view.getTag(node) != .identifier) return null;
        const binding = self.ir_view.getBinding(node) orelse return null;
        return self.resolveAtomName(binding.name_atom);
    }

    fn addDiagnostic(self: *TypeChecker, diag: Diagnostic) void {
        self.diagnostics.append(self.allocator, diag) catch {
            if (diag.allocated) self.allocator.free(diag.message);
            if (diag.help_owned) {
                if (diag.help) |help| self.allocator.free(help);
            }
            self.markAllocationFailure();
        };
    }

    fn addInferenceDiagnostic(self: *const TypeChecker, diag: Diagnostic) void {
        const mutable = @constCast(self);
        if (!mutable.report_inference_diagnostics) {
            if (diag.allocated) mutable.allocator.free(diag.message);
            return;
        }
        mutable.addDiagnostic(diag);
    }

    /// Report ZTS212 when a declared annotation names an alias whose cycle no
    /// data constructor guards (spec 5.7). The alias is decided once in
    /// `TypeEnv`; this is the site that gives the verdict a source location,
    /// since the declaration has no runtime node after direct parsing.
    fn reportIfNonContractive(self: *TypeChecker, declared: TypeIndex, node: NodeIndex) void {
        if (declared == null_type_idx or node == null_node) return;
        if (!self.env.isNonContractiveType(declared)) return;
        const name = if (self.env.pool.getTag(declared) == .t_ref)
            self.env.pool.getRefName(declared)
        else
            self.env.nameOfNonContractive(declared) orelse "";
        if (name.len == 0) return;

        const msg = self.allocator.print("recursive type alias '{s}' has a cycle no data constructor guards", .{name}) catch {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .non_contractive_alias,
                .node = node,
                .message = "recursive type alias has a cycle no data constructor guards",
                .help = null,
            });
            return;
        };
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .non_contractive_alias,
            .node = node,
            .message = msg,
            .help = "route the recursion through a record, a tuple, or an array, the way `type JsonValue = ... | readonly JsonValue[]` does; a union or intersection edge does not guard it",
            .allocated = true,
        });
    }

    /// Refuse a mutating method call on a `readonly` array.
    ///
    /// `readonly` was enforced only through assignability, which decides what
    /// may cross a call boundary and says nothing about what happens to a value
    /// that never crosses one. `const ro: readonly string[] = ["x"]; ro.push("y")`
    /// checked clean and appended at runtime, so the modifier documented an
    /// intention the compiler did not hold anyone to.
    ///
    /// Keyed on the method, not the receiver: `ro.join(",")` and `ro.slice(0, 1)`
    /// read a readonly array and stay legal.
    fn reportReadonlyMutation(self: *TypeChecker, node: NodeIndex, call: Node.CallExpr) void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .member_access and callee_tag != .optional_chain) return;
        const member = self.ir_view.getMember(call.callee) orelse return;
        const method = self.resolveAtomName(member.property) orelse return;

        if (!isMutatingArrayMethod(method)) return;

        const receiver = self.inferType(member.object);
        if (receiver == null_type_idx) return;
        if (!self.env.pool.isReadonlyArray(receiver)) return;

        self.addReadonlyMutation(node, method);
    }

    fn addReadonlyMutation(self: *TypeChecker, node: NodeIndex, method: []const u8) void {
        const msg = self.allocator.print("`{s}` writes through a readonly array", .{method}) catch {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .readonly_mutation,
                .node = node,
                .message = "a readonly array cannot be mutated",
                .help = "drop `readonly` from the declared type, or build a new array instead of writing to this one",
            });
            return;
        };
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .readonly_mutation,
            .node = node,
            .message = msg,
            .help = "drop `readonly` from the declared type, or build a new array instead of writing to this one",
            .allocated = true,
        });
    }

    /// Which slot of a container a write reaches.
    const WriteSlot = union(enum) {
        /// A record field named by `o.f` or `o["f"]`.
        field: []const u8,
        /// An element at an integer literal index.
        index_at: usize,
        /// An element at an index with no known value.
        index_any,
    };

    const WriteSlots = struct {
        items: []TypeIndex,
        /// The full allocation, before `items` is compacted to found slots.
        heap_storage: ?[]TypeIndex,
        has_tuple: bool,

        fn deinit(self: WriteSlots, allocator: std.mem.Allocator) void {
            if (self.heap_storage) |storage| allocator.free(storage);
        }
    };

    /// The type of one slot of a non-union container type, or null when the
    /// container has no such slot.
    fn slotOfMember(self: *const TypeChecker, member_type: TypeIndex, slot: WriteSlot) ?TypeIndex {
        const pool = self.env.pool;
        const resolved = pool.unwrapNominal(self.env.resolveRef(member_type));
        const tag = pool.getTag(resolved) orelse return null;
        if (tag == .t_record) {
            if (slot != .field) return null;
            const field = pool.lookupRecordField(resolved, slot.field) orelse return null;
            return self.fieldReadType(field);
        }
        if (tag == .t_array) {
            if (slot == .field) return null;
            const element = pool.getArrayElement(resolved);
            return if (element == null_type_idx) null else element;
        }
        if (tag == .t_tuple) {
            const elements = pool.getTupleElements(resolved);
            if (elements.len == 0) return null;
            switch (slot) {
                .field => return null,
                .index_at => |at| return if (at < elements.len) elements[at] else null,
                .index_any => return pool.addUnion(self.allocator, elements),
            }
        }
        return null;
    }

    /// Widen a slot type that an unannotated binding holds, to its base types.
    /// A literal, a record field, and a union member widen.
    /// An array and a tuple keep their types, because inference widens a literal array already.
    /// A literal in a field or element keeps no meaning for a later write.
    fn widenWriteSlot(self: *const TypeChecker, slot: TypeIndex, depth: u8) TypeIndex {
        const pool = self.env.pool;
        const tag = pool.getTag(slot) orelse return slot;
        if (depth > 4) return slot;
        switch (tag) {
            .t_literal_string, .t_literal_number, .t_literal_bool => return pool.widenLiteral(slot),
            .t_record => {
                var widened: [32]type_pool_mod.RecordField = undefined;
                const fields = pool.getRecordFields(slot);
                if (fields.len > widened.len) return slot;
                @memcpy(widened[0..fields.len], fields);
                for (widened[0..fields.len]) |*field| {
                    field.type_idx = self.widenWriteSlot(field.type_idx, depth + 1);
                }
                return pool.addRecord(self.allocator, widened[0..fields.len]);
            },
            .t_union => {
                var stack: [MAX_UNION_MEMBERS]TypeIndex = undefined;
                const members = pool.getUnionMembers(slot);
                var heap_storage: ?[]TypeIndex = null;
                const snapshot = if (members.len <= stack.len)
                    stack[0..members.len]
                else blk: {
                    const storage = self.allocator.alloc(TypeIndex, members.len) catch {
                        @constCast(self).markAllocationFailure();
                        return null_type_idx;
                    };
                    heap_storage = storage;
                    break :blk storage;
                };
                defer if (heap_storage) |storage| self.allocator.free(storage);
                @memcpy(snapshot, members);
                for (snapshot) |*member| {
                    member.* = self.widenWriteSlot(member.*, depth + 1);
                }
                return pool.addUnion(self.allocator, snapshot);
            },
            // exhaustive: any other tag holds no literal to widen, and keeps its type.
            else => return slot,
        }
    }

    /// Whether a binding initialized with `node` holds literal types that a
    /// later write may widen: an object or array literal, or a name bound to
    /// such a binding, such as `t` in `const t = table`. A binding from any
    /// other value, such as `const alias = s` with `s: S` or `const r = mk()`,
    /// holds a declared type that a write through it must keep.
    fn initializerHoldsLiteralTypes(self: *const TypeChecker, node: NodeIndex) bool {
        if (node == null_node) return false;
        const tag = self.ir_view.getTag(node) orelse return false;
        if (tag == .object_literal or tag == .array_literal) return true;
        if (tag != .identifier) return false;
        const binding = self.ir_view.getBinding(node) orelse return false;
        const declaration = self.captureSource(binding) orelse return false;
        return self.unannotated_decls.contains(bindingKey(declaration));
    }

    /// Whether the root of a write target is a `const` or `let` with no type
    /// annotation and an initializer that holds literal types. The root is the
    /// identifier at the start of the chain of member, computed, and index
    /// reads.
    fn writeRootIsUnannotated(self: *const TypeChecker, target: NodeIndex) bool {
        var current = target;
        var steps: u8 = 0;
        while (steps < 64) : (steps += 1) {
            const tag = self.ir_view.getTag(current) orelse return false;
            if (tag == .identifier) {
                const binding = self.ir_view.getBinding(current) orelse return false;
                const declaration = self.captureSource(binding) orelse return false;
                return self.unannotated_decls.contains(bindingKey(declaration));
            }
            if (tag != .member_access and tag != .optional_chain and tag != .computed_access) return false;
            const member = self.ir_view.getMember(current) orelse return false;
            current = member.object;
        }
        return false;
    }

    /// Collect the slot of each member of `receiver` that a write through
    /// `slot` reaches. A union receiver gives one slot for each member that
    /// has one. A tuple member sets `has_tuple`.
    ///
    /// Copy every union member before a slot lookup. A lookup can grow the
    /// pool and invalidate a slice borrowed from `pool.members`.
    fn collectWriteSlots(
        self: *TypeChecker,
        receiver: TypeIndex,
        slot: WriteSlot,
        stack: *[MAX_UNION_MEMBERS]TypeIndex,
    ) ?WriteSlots {
        const pool = self.env.pool;
        const resolved = pool.unwrapNominal(self.env.resolveRef(receiver));
        if (pool.getTag(resolved) == .t_union) {
            const members = pool.getUnionMembers(resolved);
            var heap_storage: ?[]TypeIndex = null;
            const copied = if (members.len <= stack.len)
                stack[0..members.len]
            else blk: {
                const storage = self.allocator.alloc(TypeIndex, members.len) catch {
                    self.markAllocationFailure();
                    return null;
                };
                heap_storage = storage;
                break :blk storage;
            };
            @memcpy(copied, members);

            var count: usize = 0;
            var has_tuple = false;
            for (copied) |member| {
                if (pool.getTag(pool.unwrapNominal(self.env.resolveRef(member))) == .t_tuple) has_tuple = true;
                const found = self.slotOfMember(member, slot) orelse continue;
                copied[count] = found;
                count += 1;
            }
            return .{
                .items = copied[0..count],
                .heap_storage = heap_storage,
                .has_tuple = has_tuple,
            };
        }
        const has_tuple = pool.getTag(resolved) == .t_tuple;
        const found = self.slotOfMember(resolved, slot) orelse return .{
            .items = stack[0..0],
            .heap_storage = null,
            .has_tuple = has_tuple,
        };
        stack[0] = found;
        return .{
            .items = stack[0..1],
            .heap_storage = null,
            .has_tuple = has_tuple,
        };
    }

    /// The slot that a write through `member` reaches, or null when the
    /// target is not a field with a string literal key, nor an index.
    fn writeSlotOf(self: *const TypeChecker, tag: ir.NodeTag, member: Node.MemberExpr) ?WriteSlot {
        if (tag == .member_access) {
            const name = self.resolveAtomName(member.property) orelse return null;
            return .{ .field = name };
        }
        if (tag != .computed_access or member.computed == null_node) return null;
        if (self.ir_view.getTag(member.computed) == .lit_string) {
            const key = self.getLiteralString(member.computed) orelse return .index_any;
            return .{ .field = key };
        }
        if (self.ir_view.getTag(member.computed) == .lit_int) {
            const at = self.ir_view.getIntValue(member.computed) orelse return .index_any;
            return if (at >= 0) .{ .index_at = @intCast(at) } else .index_any;
        }
        return .index_any;
    }

    /// Refuse a write `o.f = v`, `o["f"] = v`, or `xs[i] = v` whose value does
    /// not fit the slot, and a write to the length of a tuple.
    fn reportContainerWrite(self: *TypeChecker, node: NodeIndex, asgn: Node.AssignExpr) void {
        const target_tag = self.ir_view.getTag(asgn.target) orelse return;
        const member = self.ir_view.getMember(asgn.target) orelse return;
        // A fresh array literal has no other holder, so a write to it breaks no type.
        if (self.ir_view.getTag(member.object) == .array_literal) return;
        const slot = self.writeSlotOf(target_tag, member) orelse return;
        const receiver = self.inferType(member.object);
        if (receiver == null_type_idx) return;

        var stack: [MAX_UNION_MEMBERS]TypeIndex = undefined;
        const slots = self.collectWriteSlots(receiver, slot, &stack) orelse return;
        defer slots.deinit(self.allocator);
        if (slots.has_tuple and slot == .field and std.mem.eql(u8, slot.field, "length")) {
            self.addTupleLengthChange(node, true);
            return;
        }
        if (slots.items.len == 0) return;
        const value_type = self.inferType(asgn.value);
        if (value_type == null_type_idx) return;
        const widen = self.writeRootIsUnannotated(member.object);
        for (slots.items) |found| {
            const expected = if (widen) self.widenWriteSlot(found, 0) else found;
            if (self.env.isAssignableTo(value_type, expected)) continue;
            self.addTypeMismatch(node, expected, value_type);
            return;
        }
    }

    /// Refuse an element of a `push`, `unshift`, or `splice` call that does
    /// not fit the element type, and any mutating call on a tuple.
    fn reportContainerMutation(self: *TypeChecker, node: NodeIndex, call: Node.CallExpr) void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .member_access and callee_tag != .optional_chain) return;
        const member = self.ir_view.getMember(call.callee) orelse return;
        const method = self.resolveAtomName(member.property) orelse return;
        if (!isMutatingArrayMethod(method)) return;

        // A fresh array literal has no other holder, so a change to it breaks no type.
        if (self.ir_view.getTag(member.object) == .array_literal) return;
        const receiver = self.inferType(member.object);
        if (receiver == null_type_idx) return;
        const pool = self.env.pool;
        if (pool.isReadonlyArray(receiver)) return;

        var stack: [MAX_UNION_MEMBERS]TypeIndex = undefined;
        const slots = self.collectWriteSlots(receiver, .index_any, &stack) orelse return;
        defer slots.deinit(self.allocator);
        if (slots.has_tuple) {
            self.addTupleLengthChange(node, false);
            return;
        }
        const first_value: usize = if (std.mem.eql(u8, method, "push") or std.mem.eql(u8, method, "unshift")) 0 else if (std.mem.eql(u8, method, "splice")) 2 else return;
        if (slots.items.len == 0) return;
        const widen = self.writeRootIsUnannotated(member.object);
        var arg: usize = first_value;
        while (arg < call.args_count) : (arg += 1) {
            const value_type = self.inferType(self.ir_view.getListIndex(call.args_start, @intCast(arg)));
            if (value_type == null_type_idx) continue;
            for (slots.items) |found| {
                const expected = if (widen) self.widenWriteSlot(found, 0) else found;
                if (self.env.isAssignableTo(value_type, expected)) continue;
                self.addArgTypeMismatch(node, expected, value_type);
                break;
            }
        }
    }

    fn addTupleLengthChange(self: *TypeChecker, node: NodeIndex, is_length_write: bool) void {
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .type_mismatch,
            .node = node,
            .message = if (is_length_write)
                "a write to `length` changes the length of a tuple, and a tuple type names its length"
            else
                "this call changes the length of a tuple, and a tuple type names its length",
            .help = "annotate the binding as an array, such as `string[]`, when the length must change",
        });
    }

    /// Refuse a nominal type name used in call position.
    ///
    /// `UserId("u-1")` would check clean and then fault at runtime with
    /// `NotCallable`. Inference answers the call's type from the alias table
    /// and nothing lowers it, so codegen would emit an ordinary call to a name
    /// no function defines. Erasing it in codegen is not available:
    /// `parser/codegen.zig` receives its node types from
    /// `packages/tools/src/precompile.zig` and from nowhere else, so an erasure
    /// keyed on them would work under `zttp build` and fault under `zttp dev`.
    ///
    /// Refusing costs nothing. The form is unusable, and the annotated
    /// declaration is the construction path that replaces it.
    fn reportNominalConstructorCall(self: *TypeChecker, node: NodeIndex, call: Node.CallExpr) void {
        const callee_tag = self.ir_view.getTag(call.callee) orelse return;
        if (callee_tag != .identifier) return;
        const binding = self.ir_view.getBinding(call.callee) orelse return;
        const name = self.resolveAtomName(binding.name_atom) orelse return;
        const alias_type = self.env.getTypeAlias(name) orelse return;
        if (!self.env.pool.isNominal(alias_type)) return;
        self.addNominalConstructorCall(node, name);
    }

    fn addNominalConstructorCall(self: *TypeChecker, node: NodeIndex, name: []const u8) void {
        const msg = self.allocator.print("`{s}` is a nominal type, not a constructor", .{name}) catch {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .nominal_constructor_call,
                .node = node,
                .message = "a nominal type is not a constructor",
                .help = "brand at an annotated declaration: `const x: Name = value;`",
            });
            return;
        };
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .nominal_constructor_call,
            .node = node,
            .message = msg,
            .help = "brand at an annotated declaration: `const x: Name = value;`",
            .allocated = true,
        });
    }

    /// Whether an explicitly annotated declaration brands its initializer.
    ///
    /// A nominal type has to be creatable or it is a type no program can
    /// produce a value of, and the annotated declaration is the site chosen for
    /// it: `const id: UserId = "u-1";` brands, and nothing else does. The
    /// admission deliberately stops here rather than living in
    /// `isAssignableTo`, because a general rule would also admit
    /// `takesUserId("u-1")` at every call site and leave the brand describing
    /// nothing.
    ///
    /// The initializer must be assignable to the brand's own base. That keeps a
    /// `nominal Port = number` from accepting a string, and keeps one brand
    /// from accepting another - `unwrapNominal` answers the base, and a
    /// different nominal is not assignable to it.
    fn brandsAtDeclaration(self: *TypeChecker, declared: TypeIndex, inferred: TypeIndex) bool {
        if (!self.env.pool.isNominal(declared)) return false;
        if (self.env.pool.isNominal(inferred)) return false;
        const base = self.env.pool.unwrapNominal(declared);
        if (base == declared) return false;
        return self.env.isAssignableTo(inferred, base);
    }

    /// Whether `raw` names `undefined` itself: `undefined`, `void`, `T | undefined`,
    /// or a union with such a member. `unknown` and a generic parameter do not
    /// count: the help below is advice for a value that has an absent case.
    fn namesUndefined(self: *const TypeChecker, raw: TypeIndex, depth: u8) bool {
        if (raw == null_type_idx or depth > 8) return false;
        const pool = self.env.pool;
        const t = pool.unwrapNominal(self.env.resolveRef(raw));
        const tag = pool.getTag(t) orelse return false;
        return switch (tag) {
            .t_nullable => true,
            // A bare `undefined` is not "may be": only a member of a union is.
            .t_undefined, .t_void => depth > 0,
            .t_union => blk: {
                for (pool.getUnionMembers(t)) |m| {
                    if (self.namesUndefined(m, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            // exhaustive: any other type has no absent case, so it earns no undefined help.
            else => false,
        };
    }

    /// The help line of a ZTS200 or ZTS203 whose source type has an absent case.
    fn undefinedSourceHelp(self: *const TypeChecker, expected: TypeIndex, got: TypeIndex) ?[]const u8 {
        if (self.namesUndefined(expected, 0)) return null;
        if (!self.namesUndefined(got, 0)) return null;
        return undefined_source_help_text;
    }

    fn addTypeMismatch(self: *TypeChecker, node: NodeIndex, expected: TypeIndex, got: TypeIndex) void {
        const help = self.undefinedSourceHelp(expected, got) orelse mismatch_help_text;
        var buf: [256]u8 = undefined;
        const expected_str = self.env.pool.formatType(expected, buf[0..128]);
        const got_str = self.env.pool.formatType(got, buf[128..256]);

        const msg = self.allocator.print("type '{s}' is not assignable to type '{s}'", .{ got_str, expected_str }) catch {
            self.addDiagnostic(.{
                .severity = .err,
                .kind = .type_mismatch,
                .node = node,
                .message = "type mismatch",
                .help = help,
            });
            return;
        };

        self.addDiagnostic(.{
            .severity = .err,
            .kind = .type_mismatch,
            .node = node,
            .message = msg,
            .help = help,
            .allocated = true,
        });
    }

    /// Emit an arg-count mismatch (ZTS202) whose message names the expected and
    /// actual counts, so a caller (human or agent) can fix it without guessing.
    /// The detail rides in `.message` because `deinit` only frees `.message`
    /// when `allocated`; `.help` is never freed, so an owned string there leaks.
    fn addArgCountMismatch(self: *TypeChecker, node: NodeIndex, expected: usize, got: usize) void {
        const msg = self.allocator.print("wrong number of arguments: expected {d}, got {d}", .{ expected, got }) catch "wrong number of arguments";
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .arg_count_mismatch,
            .node = node,
            .message = msg,
            .help = "Pass exactly as many arguments as the function declares parameters.",
            .allocated = !std.mem.eql(u8, msg, "wrong number of arguments"),
        });
    }

    /// Emit an arg-type mismatch (ZTS203) whose message names the expected
    /// parameter type and the actual argument type. Same ownership rule as
    /// `addArgCountMismatch`: the detail goes in `.message`, not `.help`.
    fn addArgTypeMismatch(self: *TypeChecker, node: NodeIndex, expected: TypeIndex, got: TypeIndex) void {
        // A kilobyte a side, not 128 bytes. `formatType` answers "?" when its
        // buffer is too small, so a record with more than a couple of fields
        // printed as `expected ?, got ?` - a diagnostic that names neither
        // type, on exactly the mismatches that are hardest to read from the
        // source. Found when `FetchOptions` became a five-field record.
        var buf: [2048]u8 = undefined;
        const expected_str = self.env.pool.formatType(expected, buf[0..1024]);
        const got_str = self.env.pool.formatType(got, buf[1024..2048]);
        const msg = self.allocator.print("argument type does not match parameter type: expected {s}, got {s}", .{ expected_str, got_str }) catch "argument type does not match parameter type";
        self.addDiagnostic(.{
            .severity = .err,
            .kind = .arg_type_mismatch,
            .node = node,
            .message = msg,
            .help = self.undefinedSourceHelp(expected, got) orelse arg_type_help_text,
            .allocated = !std.mem.eql(u8, msg, "argument type does not match parameter type"),
        });
    }

    fn resolveAtomName(self: *const TypeChecker, atom_idx: u16) ?[]const u8 {
        if (self.atoms) |table| {
            const atom: object.Atom = @fromBackingInt(@intCast(atom_idx));
            if (atom.toPredefinedName()) |name| return name;
            return table.getName(atom);
        }
        if (self.ir_view.getString(atom_idx)) |name| return name;
        const atom: object.Atom = @fromBackingInt(@intCast(atom_idx));
        return atom.toPredefinedName();
    }

    fn jsonLiteralAtomResolver(atom_idx: u16, ctx: *const anyopaque) ?[]const u8 {
        const self: *const TypeChecker = @ptrCast(@alignCast(ctx));
        return self.resolveAtomName(atom_idx);
    }

    fn markAllocationFailure(self: *TypeChecker) void {
        self.allocation_failed = true;
    }
};

/// Binding identity for this checker's flow maps.
///
/// `binding_key.packBindingKey` folds only (scope, slot), and a captured
/// upvalue shares both with a parameter of the capturing function: the upvalue
/// indexes the closure's upvalue array, the parameter indexes its own argument
/// array, and both start at zero in the same function scope. A narrowing
/// installed for the captured binding therefore landed on the inner function's
/// own parameter, so `if (v === undefined) return 0;` over a captured `v` made
/// `return n` read `string` and reported a return-type mismatch on correct
/// code. Folding the kind in separates them.
fn bindingKey(binding: ir.BindingRef) u64 {
    return (@as(u64, binding.scope_id) << 32) |
        (@as(u64, @backingInt(binding.kind)) << 16) |
        @as(u64, binding.slot);
}

test {
    // The census over the builtin result table lives beside the table.
    _ = @import("builtin_results.zig");
}

test "TypeChecker init and deinit" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var node_list = ir.IRStore.init(allocator);
    defer node_list.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();

    _ = try node_list.addBlock(.program, .{ .line = 1, .column = 1, .offset = 0 }, .{ .stmts_start = 0, .stmts_count = 0, .scope_id = ir.null_scope });

    const view = ir.IrView.fromIRStore(&node_list, &constants);
    var checker = TypeChecker.init(allocator, view, null, &env);
    defer checker.deinit();

    try std.testing.expectEqual(@as(usize, 0), checker.diagnostics.items.len);
}

test "TypeChecker fails closed when binding analysis cannot allocate" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "let count = 1;", .compile);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = TypeChecker.init(failing.allocator(), view, null, &env);
    defer checker.deinit();
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
}

test "TypeChecker fails closed when diagnostic storage cannot allocate" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "", .compile);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = TypeChecker.init(failing.allocator(), view, null, &env);
    defer checker.deinit();
    checker.addDiagnostic(.{
        .severity = .err,
        .kind = .type_mismatch,
        .node = root,
        .message = "forced diagnostic",
        .help = null,
    });
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
}

test "TypeChecker ensureHealthy rejects a TypePool poisoned after check" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "", .compile);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    var checker = TypeChecker.init(allocator, view, null, &env);
    defer checker.deinit();

    try std.testing.expectEqual(@as(u32, 0), try checker.check(root));

    const record = pool.addRecord(allocator, &.{.{
        .name_start = 0,
        .name_len = 0,
        .type_idx = pool.idx_string,
        .optional = false,
    }});
    try pool.ensureHealthy();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = pool.makeReadonly(failing.allocator(), record);

    try std.testing.expectError(error.OutOfMemory, checker.ensureHealthy());
}

test "TypeChecker ensureHealthy propagates TypePool capacity exhaustion" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "", .compile);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    var checker = TypeChecker.init(allocator, view, null, &env);
    defer checker.deinit();

    try std.testing.expectEqual(@as(u32, 0), try checker.check(root));
    try pool.fields.resize(allocator, @as(usize, std.math.maxInt(u16)) + 1);
    _ = pool.addRecord(allocator, &.{});

    try std.testing.expectError(error.TypePoolCapacityExceeded, checker.ensureHealthy());
}

fn checkTypedSource(source: []const u8, expect_errors: u32, expect_warnings: ?u32) !void {
    const allocator = std.testing.allocator;
    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });
    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    const errors = try checker.check(root);
    try std.testing.expectEqual(expect_errors, errors);
    if (expect_warnings) |expected| {
        var warnings: u32 = 0;
        for (checker.getDiagnostics()) |diagnostic| {
            if (diagnostic.severity == .warning) warnings += 1;
        }
        try std.testing.expectEqual(expected, warnings);
    }
}

/// `checkTypedSource` plus the text of the diagnostic it expects. A count alone
/// is satisfied by any error at all, including one from a different rule, so a
/// test that means to pin a particular refusal names it.
fn checkTypedSourceSaying(source: []const u8, expect_errors: u32, needle: []const u8) !void {
    return checkTypedSourceHelping(source, expect_errors, needle, null);
}

/// `checkTypedSourceSaying` plus the exact help text of the matched diagnostic,
/// when `expected_help` is given.
fn checkTypedSourceHelping(source: []const u8, expect_errors: u32, needle: []const u8, expected_help: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();

    const errors = try checker.check(root);
    try std.testing.expectEqual(expect_errors, errors);

    for (checker.getDiagnostics()) |diag| {
        if (std.mem.indexOf(u8, diag.message, needle) != null) {
            if (expected_help) |want| try std.testing.expectEqualStrings(want, diag.help orelse "(null)");
            return;
        }
    }
    for (checker.getDiagnostics()) |diag| {
        std.debug.print("diagnostic: {s}\n", .{diag.message});
    }
    return error.TestExpectedDiagnosticText;
}

/// Type the first ternary in `source` and render the result into `buf`. The
/// rendering is returned rather than the `TypeIndex` because the pool dies with
/// this function, so an index would dangle.
fn formatFirstTernaryType(source: []const u8, buf: []u8) ![]const u8 {
    const allocator = std.testing.allocator;
    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(root);

    var node: NodeIndex = 0;
    while (node < ir_view.nodeCount()) : (node += 1) {
        const tag = ir_view.getTag(node) orelse continue;
        if (tag != .ternary) continue;
        return pool.formatType(checker.inferType(node), buf);
    }
    return error.NoTernaryInSource;
}

test "ternary join: identical branch types collapse to that type" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const a: string = req.url; const b: string = req.method; const v = req.method === \"GET\" ? a : b; return Response.text(v); }",
        &buf,
    );
    // Step 2: both branches are `string`, so the join is `string` and no union
    // is formed.
    try std.testing.expectEqualStrings("string", rendered);
}

test "ternary join: distinct literal branches form a literal union" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const x = req.method === \"GET\" ? 1 : 2; return Response.json({ x: x }); }",
        &buf,
    );
    // Step 5, not step 2: `1` and `2` are distinct literal types and neither is
    // assignable to the other, so the join is their union rather than `number`.
    // Widening to `number` would discard information the checker holds.
    try std.testing.expectEqualStrings("1 | 2", rendered);
}

test "ternary join: a literal widens into the receiving branch type" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const s: string = req.url; const v = req.method === \"GET\" ? \"a\" : s; return Response.text(v); }",
        &buf,
    );
    // Step 4: the string literal is assignable to string but not the reverse,
    // so the receiving type wins.
    try std.testing.expectEqualStrings("string", rendered);
}

test "ternary join: disjoint branch types form a union" {
    var buf: [128]u8 = undefined;
    const rendered = try formatFirstTernaryType(
        "function handler(req: Request): Response { const u = req.method === \"GET\" ? 1 : \"a\"; return Response.json({ u: u }); }",
        &buf,
    );
    // Step 5: nothing relates number and string, so the join is their union.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "|") != null);
}

test "ternary join: never on one side is removed" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var node_list = ir.IRStore.init(allocator);
    defer node_list.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const view = ir.IrView.fromIRStore(&node_list, &constants);

    var checker = TypeChecker.init(allocator, view, null, &env);
    defer checker.deinit();

    // Step 1, both directions, plus the both-never case.
    try std.testing.expectEqual(pool.idx_number, checker.joinTypes(pool.idx_never, pool.idx_number));
    try std.testing.expectEqual(pool.idx_number, checker.joinTypes(pool.idx_number, pool.idx_never));
    try std.testing.expectEqual(pool.idx_never, checker.joinTypes(pool.idx_never, pool.idx_never));
}

fn recordWithStringField(pool: *TypePool, allocator: std.mem.Allocator, name: []const u8) TypeIndex {
    const n = pool.addName(allocator, name);
    return pool.addRecord(allocator, &.{
        .{ .name_start = n.start, .name_len = n.len, .type_idx = pool.idx_string, .optional = false },
    });
}

test "narrowing: a bare boolean discriminant read, and its negation" {
    // The Result idiom is written `if (!r.ok) return ...` at least as often as
    // it is written `r.ok === false`, and only the second form narrowed.
    //
    // The union members are written inline rather than as two named aliases.
    // That is not a style choice: a union of named refs does not resolve to
    // records here, so no field lookup finds a discriminant and no guard
    // installs - a version of this test written with aliases passes whether
    // the guard is right, wrong, or absent. This shape selects the wrong
    // member if the guard asks for the `false` arm, and both accesses below
    // then report a missing property.
    try checkTypedSource(
        \\function pick(r: { ok: true; value: string } | { ok: false; error: string }): string {
        \\  if (!r.ok) {
        \\    return r.error;
        \\  }
        \\  return r.value;
        \\}
    , 0, null);
    try checkTypedSource(
        \\function pick(r: { ok: true; value: string } | { ok: false; error: string }): string {
        \\  if (r.ok) {
        \\    return r.value;
        \\  }
        \\  return r.error;
        \\}
    , 0, null);
}

test "an object spread contributes the spread record's fields" {
    // `{ ...base, port: 8080 }` typed as `{ base: unknown; port: 8080 }`: a
    // spread node stores its operand where a property stores its key, so the
    // operand's NAME became a field and the operand's fields were dropped. Every
    // spread object therefore failed to satisfy the record type it was written
    // to produce, which is the whole use of the form.
    try checkTypedSource(
        \\structural Config = { host: string, port: number };
        \\function defaults(): Config {
        \\  return { host: "localhost", port: 80 };
        \\}
        \\function configured(): Config {
        \\  const base: Config = defaults();
        \\  return { ...base, port: 8080 };
        \\}
    , 0, null);
}

test "an object spread does not invent fields the spread record lacks" {
    // The floor. Merging the spread's fields must not turn the check off: a
    // field the target type requires and neither side provides is still a
    // mismatch.
    try checkTypedSourceSaying(
        \\structural Config = { host: string, port: number };
        \\function partial(): { port: number } {
        \\  return { port: 80 };
        \\}
        \\function configured(): Config {
        \\  const base: { port: number } = partial();
        \\  return { ...base, port: 8080 };
        \\}
    , 1, "return type does not match declared return type");
}

test "an annotated let keeps its declared type, so it can be reassigned" {
    // `let total: number = 0` bound the binding to the literal type `0`, from
    // the satisfies-like rule below that keeps a literal under a base-primitive
    // annotation. That rule is right for `const`, whose value cannot change,
    // and wrong for `let`, whose only reason to exist is that it changes: every
    // reassignment of an annotated `let` was refused as "type '7' is not
    // assignable to type '0'". `let` had no legal spelling with a literal
    // initializer.
    try checkTypedSource(
        \\function counter(): number {
        \\  let total: number = 0;
        \\  total = 7;
        \\  return total;
        \\}
    , 0, null);
}

test "an annotated let still refuses a value its declared type does not admit" {
    // The floor. Widening the binding to its annotation must not stop the
    // assignment check, only stop it comparing against the initializer.
    try checkTypedSourceSaying(
        \\function counter(): number {
        \\  let total: number = 0;
        \\  total = "seven";
        \\  return total;
        \\}
    , 1, "not assignable");
}

test "an annotated const still keeps the narrower literal type" {
    // The other side of the same rule, pinned so the fix above cannot be
    // widened into `const`. A `const` under a base-primitive annotation keeps
    // its literal type, which is what makes a match over it exhaustive without
    // a default; widening it to `string` would make the same match
    // non-exhaustive and warn.
    try checkTypedSource(
        \\function label(): number {
        \\  const k: string = "a";
        \\  return match (k) {
        \\    when "a": 1,
        \\  };
        \\}
    , 0, 0);
}

test "narrowing: typeof reaches the authoritative system" {
    try checkTypedSource(
        \\function label(v: string | number): string {
        \\  if (typeof v === "string") {
        \\    return v;
        \\  }
        \\  return "n";
        \\}
    , 0, null);
}

test "narrowing: Array.isArray" {
    try checkTypedSource(
        \\function first(v: string | string[]): string {
        \\  if (Array.isArray(v)) {
        \\    return v[0] ?? "";
        \\  }
        \\  return v;
        \\}
    , 0, null);
}

test "narrowing: the else branch narrows too" {
    try checkTypedSource(
        \\function orDefault(v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  } else {
        \\    return v;
        \\  }
        \\}
    , 0, null);
}

test "narrowing: an assignment kills the narrowing it invalidates" {
    // Kill rule 1. Nothing killed a narrowing before, so the guard installed by
    // the early return survived the reassignment and `v` still read as
    // `string`.
    //
    // The control comes first, and it is what makes the second assertion mean
    // something: with no narrowing at all, both programs report one error and
    // the pair below would pass while checking nothing.
    try checkTypedSource(
        \\function kept(v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  return v;
        \\}
    , 0, null);
    try checkTypedSource(
        \\function reassigned(v: string | undefined, w: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  v = w;
        \\  return v;
        \\}
    , 1, null);
}

test "narrowing: a loop body that reassigns kills the narrowing at entry" {
    // Kill rule 4. The read happens before the assignment in source order, so
    // only the entry half of the rule can catch it: the back edge re-enters
    // with whatever the last iteration left.
    //
    // Control first: a loop that does not assign keeps the narrowing, so the
    // second assertion is about the assignment rather than about loops.
    try checkTypedSource(
        \\function readOnly(xs: string[], v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  for (const x of xs) {
        \\    const y: string = v;
        \\  }
        \\  return "ok";
        \\}
    , 0, null);
    try checkTypedSource(
        \\function looped(xs: string[], v: string | undefined): string {
        \\  if (v === undefined) {
        \\    return "d";
        \\  }
        \\  for (const x of xs) {
        \\    const y: string = v;
        \\    v = undefined;
        \\  }
        \\  return "ok";
        \\}
    , 1, null);
}

/// Counts of the three diagnostics the W4 tests pin: ZTS203, ZTS204, ZTS208.
const KindCounts = struct {
    arg_type: usize,
    return_type: usize,
    ambiguous: usize,
};

fn expectKindCounts(source: []const u8, expected: KindCounts) !void {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator, source, false);
    defer freeSeenDiagnostics(allocator, seen);
    const actual: KindCounts = .{
        .arg_type = countKind(seen, .arg_type_mismatch),
        .return_type = countKind(seen, .return_type_mismatch),
        .ambiguous = countKind(seen, .ambiguous_type_argument),
    };
    if (!std.meta.eql(expected, actual)) {
        for (seen) |d| std.debug.print("diagnostic: {s}\n", .{d.message});
    }
    try std.testing.expectEqual(expected, actual);
}

/// A `count` function whose `x` is narrowed to `string` before a `for...of`
/// loop. `body` follows `needS(x)` in the loop body.
fn narrowedBeforeLoop(comptime body: []const u8) []const u8 {
    const head =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function id(v: string | undefined): number {
        \\  return 1;
        \\}
        \\function count(input: string | undefined): number {
        \\  let x: string | undefined = input;
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  let n = 0;
        \\  for (const i of [1, 2]) {
        \\    n = n + needS(x);
    ;
    const tail =
        \\  }
        \\  return n;
        \\}
    ;
    return head ++ "\n" ++ body ++ "\n" ++ tail;
}

test "narrowing: a loop body that assigns inside an initializer kills the narrowing at entry" {
    // n2_init. The assignment is the initializer of a `const`, which the kill
    // walk did not enter, so `needS(x)` kept the narrowing to `string`.
    //
    // Control first: the same loop with a plain assignment statement, and the
    // same loop with no assignment. The second is what shows the refusals below
    // come from the assignment.
    try expectKindCounts(narrowedBeforeLoop("    n = n + 1;"), .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(narrowedBeforeLoop("    x = undefined;"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(narrowedBeforeLoop("    const y = (x = undefined);"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
}

test "narrowing: a loop body that assigns inside a ternary or an assert kills the narrowing" {
    try expectKindCounts(
        narrowedBeforeLoop("    const t = i > 1 ? (x = undefined) : 1;"),
        .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 },
    );
    try expectKindCounts(
        narrowedBeforeLoop("    assert i > 0, (x = undefined);"),
        .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 },
    );
}

test "narrowing: a closure in a loop body that assigns the narrowed binding kills the narrowing" {
    // A closure can run during the loop. Its `x` is a captured binding, whose
    // key differs from the declaration's, so the walk kills every narrowing.
    try expectKindCounts(
        narrowedBeforeLoop(
            \\    const g = () => {
            \\      x = undefined;
            \\      return 1;
            \\    };
            \\    n = n + g();
        ),
        .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 },
    );
    try expectKindCounts(
        narrowedBeforeLoop(
            \\    function g(): number {
            \\      x = undefined;
            \\      return 1;
            \\    }
        ),
        .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 },
    );
    // Control: a closure that assigns only its own local leaves the narrowing.
    try expectKindCounts(
        narrowedBeforeLoop(
            \\    const g = () => {
            \\      let w = 1;
            \\      w = 2;
            \\      return w;
            \\    };
            \\    n = n + g();
        ),
        .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 },
    );
}

/// A generic `apply` whose callback result is passed to `needS`. `apply`'s own
/// `return f(2)` reports one ZTS204 (a generic-return limitation), so every
/// case below expects `return_type = 1`.
fn callbackReturning(comptime body: []const u8) []const u8 {
    const head =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function apply<T>(f: (n: number) => T): T {
        \\  return f(2);
        \\}
        \\export function handler(req: Request): Response {
        \\  const v = apply((y: number) => {
    ;
    const tail =
        \\  });
        \\  return Response.text(String(needS(v)));
        \\}
    ;
    return head ++ "\n" ++ body ++ "\n" ++ tail;
}

test "callback return type: a return inside an if joins the callback type" {
    // r3_base, the control for the loop and assert cases below.
    try expectKindCounts(
        callbackReturning(
            \\    if (y > 1) {
            \\      return y;
            \\    }
            \\    return "s";
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 0 },
    );
}

test "callback return type: a return inside a for...of joins the callback type" {
    // r3_forof. The loop's `return z` was dropped from the join, so the
    // callback typed as `string` and `needS(v)` was accepted.
    try expectKindCounts(
        callbackReturning(
            \\    for (const z of [y]) {
            \\      return z;
            \\    }
            \\    return "s";
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 0 },
    );
}

test "callback return type: an assert error expression joins the callback type" {
    // A failed `assert c, e` returns `e` from the callback.
    try expectKindCounts(
        callbackReturning(
            \\    assert y > 1, y;
            \\    return "s";
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 0 },
    );
}

/// A callback whose only `return` is inside a loop, passed to a generic
/// function whose result `needN` consumes.
fn loopOnlyCallback(comptime body: []const u8) []const u8 {
    const head =
        \\function needN(n: number): number {
        \\  return n + 1;
        \\}
        \\function apply<T>(f: (xs: number[]) => T): T {
        \\  return f([]);
        \\}
        \\export function handler(req: Request): Response {
        \\  const v = apply((xs: number[]) => {
    ;
    const tail =
        \\  });
        \\  return Response.text(String(needN(v)));
        \\}
    ;
    return head ++ "\n" ++ body ++ "\n" ++ tail;
}

test "callback return type: a callback whose only return is in a loop stays refused" {
    // r5_forof_only. The returned `z` has no type while the callback is first
    // inferred, so `T` is ambiguous (ZTS208), as for any return of a
    // parameter-typed value.
    try expectKindCounts(
        loopOnlyCallback(
            \\    for (const z of xs) {
            \\      return z;
            \\    }
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 1 },
    );
    // A literal return types at once. A loop that runs zero times returns
    // nothing, so the callback type is `number | undefined` and not the
    // loop's `number` alone: `needN(v)` is refused.
    try expectKindCounts(
        loopOnlyCallback(
            \\    for (const z of xs) {
            \\      return 5;
            \\    }
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 0 },
    );
}

test "callback return type: a return after the loop covers the fall-through" {
    // The loop cannot fall out of the function when a later statement returns
    // on every path, so the join is `5 | 6` and `undefined` is not added.
    try expectKindCounts(
        loopOnlyCallback(
            \\    for (const z of xs) {
            \\      return 5;
            \\    }
            \\    return 6;
        ),
        .{ .arg_type = 0, .return_type = 1, .ambiguous = 0 },
    );
}

test "callback return type: an if whose return can be skipped adds undefined" {
    // The only `return` is inside an `if` with no `else`, so the callback
    // returns `undefined` when the condition is false. Typing it as `5` alone
    // let `needN(v)` pass.
    try expectKindCounts(
        loopOnlyCallback(
            \\    if (xs.length > 1) {
            \\      return 5;
            \\    }
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 0 },
    );
    // An `else` that does not return leaves the same path open.
    try expectKindCounts(
        loopOnlyCallback(
            \\    if (xs.length > 1) {
            \\      return 5;
            \\    } else {
            \\      const w = 1;
            \\    }
        ),
        .{ .arg_type = 1, .return_type = 1, .ambiguous = 0 },
    );
}

test "callback return type: a covering return keeps an if from adding undefined" {
    try expectKindCounts(
        loopOnlyCallback(
            \\    if (xs.length > 1) {
            \\      return 5;
            \\    }
            \\    return 6;
        ),
        .{ .arg_type = 0, .return_type = 1, .ambiguous = 0 },
    );
    try expectKindCounts(
        loopOnlyCallback(
            \\    if (xs.length > 1) {
            \\      return 5;
            \\    } else {
            \\      return 6;
            \\    }
        ),
        .{ .arg_type = 0, .return_type = 1, .ambiguous = 0 },
    );
    // Nested: both inner branches return, so the outer `if` is covered too.
    try expectKindCounts(
        loopOnlyCallback(
            \\    if (xs.length > 1) {
            \\      if (xs.length > 2) {
            \\        return 5;
            \\      } else {
            \\        return 6;
            \\      }
            \\    } else {
            \\      return 7;
            \\    }
        ),
        .{ .arg_type = 0, .return_type = 1, .ambiguous = 0 },
    );
}

test "assert error expression: it must match the declared return type" {
    // A failed `assert c, e` returns `e`, so `e` answers the declared return
    // type the way `return e` does.
    try expectKindCounts(
        \\function f(c: boolean): string {
        \\  assert c, 5;
        \\  return "ok";
        \\}
    , .{ .arg_type = 0, .return_type = 1, .ambiguous = 0 });
    try expectKindCounts(
        \\function f(c: boolean): string {
        \\  assert c, "no";
        \\  return "ok";
        \\}
    , .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(
        \\export function handler(req: Request): Response {
        \\  const c = req.method === "GET";
        \\  assert c, Response.text("no");
        \\  return Response.text("ok");
        \\}
    , .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 });
}

test "assert error expression: a Proof capsule return type adds no ZTS204" {
    // cap_base. The declared type is a capsule over `Response`, and the
    // `Response` the assert returns matches it as the final `return` does.
    try expectKindCounts(
        \\import { cacheSet } from "zttp:cache";
        \\structural RetryProof<T> = Proof<T, "retry_safe" | "idempotent">;
        \\function save(): boolean {
        \\  cacheSet("items", "key", "value", 60);
        \\  return true;
        \\}
        \\function handler(req: Request): RetryProof<Response> {
        \\  const ok = save();
        \\  assert ok, Response.text("no");
        \\  return Response.text("ok");
        \\}
    , .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 });
}

test "the join asks for structural identity, not the same pool index" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();

    var node_list = ir.IRStore.init(allocator);
    defer node_list.deinit();
    var constants = ir.ConstantPool.init(allocator);
    defer constants.deinit();
    const view = ir.IrView.fromIRStore(&node_list, &constants);

    var checker = TypeChecker.init(allocator, view, null, &env);
    defer checker.deinit();

    // Step 2. Two branches that each build `{ id: string }` hold different
    // indices, so step 2 answers. Step 3 would reach the same answer by mutual
    // assignability, but step 2 keeps the answer right when one side's field
    // is optional.
    const left = recordWithStringField(&pool, allocator, "id");
    const right = recordWithStringField(&pool, allocator, "id");
    try std.testing.expect(left != right);
    try std.testing.expectEqual(left, checker.joinTypes(left, right));

    // Step 5: two types with nothing in common become the normalized union.
    const joined = checker.joinTypes(pool.idx_string, pool.idx_number);
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(joined).len);

    // Step 4: the receiving type wins when only one direction is assignable.
    const literal = pool.addLiteralString(allocator, "GET");
    try std.testing.expectEqual(pool.idx_string, checker.joinTypes(literal, pool.idx_string));
    try std.testing.expectEqual(pool.idx_string, checker.joinTypes(pool.idx_string, literal));
}

test "union normalization drops never, dedups by key, and subsumes" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // Step 2: `never` contributes no value and leaves.
    const with_never = pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_never, pool.idx_number });
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(with_never).len);
    try std.testing.expectEqual(pool.idx_string, pool.addUnion(allocator, &.{ pool.idx_string, pool.idx_never }));
    try std.testing.expectEqual(pool.idx_never, pool.addUnion(allocator, &.{ pool.idx_never, pool.idx_never }));

    // Step 3: structurally identical members at different indices are one
    // member. Index equality kept both.
    const a = recordWithStringField(&pool, allocator, "id");
    const b = recordWithStringField(&pool, allocator, "id");
    try std.testing.expectEqual(a, pool.addUnion(allocator, &.{ a, b }));

    // Step 5: `"GET" | string` is `string`, and order does not change that.
    const literal = pool.addLiteralString(allocator, "GET");
    try std.testing.expectEqual(pool.idx_string, pool.addUnion(allocator, &.{ literal, pool.idx_string }));
    try std.testing.expectEqual(pool.idx_string, pool.addUnion(allocator, &.{ pool.idx_string, literal }));

    // Step 6: survivors keep the order they were written in, which is what a
    // reader sees. Identity is order-free because the key sorts.
    const written = pool.addUnion(allocator, &.{ pool.idx_number, pool.idx_string });
    const members = pool.getUnionMembers(written);
    try std.testing.expectEqual(pool.idx_number, members[0]);
    try std.testing.expectEqual(pool.idx_string, members[1]);

    // Two literals of the same base do not subsume each other.
    const post = pool.addLiteralString(allocator, "POST");
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(pool.addUnion(allocator, &.{ literal, post })).len);
}

test "normalization does not drop a branded or obligation-carrying member" {
    const allocator = std.testing.allocator;
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    // A `distinct type` is assignable to its base, but the union of the two is
    // not the base: the brand is what a nominal type is for.
    const user_id = pool.addNominalAlias(allocator, pool.idx_string, "UserId");
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(pool.addUnion(allocator, &.{ user_id, pool.idx_string })).len);

    // An intersection is a value shape plus obligations, and it is assignable
    // to its own members. `Effects<string, "env"> | string` resolves to that
    // shape, and dropping the marker branch would leave a type reading as
    // though the author declared no capability ceiling at all.
    const marker_name = pool.addName(allocator, "__zttp_effect__");
    const marker = pool.addRecord(allocator, &.{
        .{ .name_start = marker_name.start, .name_len = marker_name.len, .type_idx = pool.idx_string, .optional = false },
    });
    const carried = pool.addIntersection(allocator, &.{ pool.idx_string, marker });
    try std.testing.expectEqual(@as(usize, 2), pool.getUnionMembers(pool.addUnion(allocator, &.{ carried, pool.idx_string })).len);
}

test "TypeChecker proves literal union match exhaustiveness" {
    try checkTypedSource(
        \\const value: "a" | "b" = "a";
        \\const out = match (value) {
        \\  when "a": 1,
        \\  when "b": 2,
        \\};
    , 0, 0);
}

test "TypeChecker proves discriminated union match exhaustiveness" {
    try checkTypedSource(
        \\const ok = { kind: "ok", value: "x" };
        \\const err = { kind: "err", error: "bad" };
        \\const result = true ? ok : err;
        \\const out = match (result) {
        \\  when { kind: "ok" }: result.value,
        \\  when { kind: "err" }: result.error,
        \\};
    , 0, 0);
}

test "TypeChecker warns on non-exhaustive match over union" {
    try checkTypedSource(
        \\const value: "a" | "b" = "a";
        \\const out = match (value) {
        \\  when "a": 1,
        \\};
    , 0, 1);
}

/// What a test needs to know about one diagnostic. The help is copied, so it
/// outlives the checker that produced it.
const SeenDiagnostic = struct {
    kind: DiagnosticKind,
    severity: Severity,
    message: []const u8,
    help: ?[]const u8,
};

fn freeSeenDiagnostics(allocator: std.mem.Allocator, seen: []SeenDiagnostic) void {
    for (seen) |d| {
        allocator.free(d.message);
        if (d.help) |h| allocator.free(h);
    }
    allocator.free(seen);
}

/// Type check `source` and return its diagnostics. `strict_follows` is the
/// flag the pipeline sets when the strict checker runs after this one.
fn typedDiagnostics(allocator: std.mem.Allocator, source: []const u8, strict_follows: bool) ![]SeenDiagnostic {
    return typedDiagnosticsWithImportFacts(allocator, source, strict_follows, false);
}

fn typedDiagnosticsWithImportFacts(allocator: std.mem.Allocator, source: []const u8, strict_follows: bool, borrow_imports: bool) ![]SeenDiagnostic {
    return typedDiagnosticsImpl(allocator, source, strict_follows, borrow_imports, true);
}

/// `with_scopes` is false for a caller that builds a checker with no parser
/// record. A captured binding then has no type.
fn typedDiagnosticsImpl(
    allocator: std.mem.Allocator,
    source: []const u8,
    strict_follows: bool,
    borrow_imports: bool,
    with_scopes: bool,
) ![]SeenDiagnostic {
    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var import_facts: ?module_facts_mod.ModuleFacts = if (borrow_imports)
        try module_facts_mod.ModuleFacts.build(allocator, ir_view, &atoms, null)
    else
        null;
    defer if (import_facts) |*facts| facts.deinit();
    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    defer checker.deinit();
    checker.import_facts = if (import_facts) |*facts| facts else null;
    checker.strict_checker_follows = strict_follows;
    if (with_scopes) checker.scopes = &parser.scopes;
    _ = try checker.check(root);

    var out = std.ArrayList(SeenDiagnostic).empty;
    errdefer {
        for (out.items) |d| {
            allocator.free(d.message);
            if (d.help) |h| allocator.free(h);
        }
        out.deinit(allocator);
    }
    for (checker.getDiagnostics()) |d| {
        const message = try allocator.dupe(u8, d.message);
        errdefer allocator.free(message);
        const help = if (d.help) |h| try allocator.dupe(u8, h) else null;
        errdefer if (help) |h| allocator.free(h);
        try out.append(allocator, .{ .kind = d.kind, .severity = d.severity, .message = message, .help = help });
    }
    return out.toOwnedSlice(allocator);
}

fn countKind(seen: []const SeenDiagnostic, kind: DiagnosticKind) usize {
    var n: usize = 0;
    for (seen) |d| {
        if (d.kind == kind) n += 1;
    }
    return n;
}

test "TypeChecker: ZTS205 names the first missing case in its help" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\structural C = { kind: "a" } | { kind: "b" } | { kind: "c" };
        \\function run(c: C): number {
        \\  const out = match (c) {
        \\    when { kind: "a" }: 1,
        \\    when { kind: "b" }: 2,
        \\  };
        \\  return 0;
        \\}
    , false);
    defer freeSeenDiagnostics(allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqual(DiagnosticKind.non_exhaustive_match, seen[0].kind);
    try std.testing.expectEqual(Severity.warning, seen[0].severity);
    // The message is the key `edit_simulate` hashes; it never carries the
    // witness, so a partial fix does not turn a diagnostic into a new one.
    try std.testing.expectEqualStrings("match expression is not provably exhaustive", seen[0].message);
    try std.testing.expectEqualStrings(
        "missing case: when { kind: \"c\" }. Add an arm for it, or add a 'default:' arm.",
        seen[0].help.?,
    );
}

test "TypeChecker: ZTS205 stays out of the way of the strict checker" {
    const allocator = std.testing.allocator;
    const source =
        \\structural C = { kind: "a" } | { kind: "b" };
        \\function run(c: C): number {
        \\  const out = match (c) {
        \\    when { kind: "a" }: 1,
        \\  };
        \\  return 0;
        \\}
    ;
    const alone = try typedDiagnostics(allocator, source, false);
    defer freeSeenDiagnostics(allocator, alone);
    try std.testing.expectEqual(@as(usize, 1), countKind(alone, .non_exhaustive_match));

    // The strict checker follows and the match has no type error: ZTS603
    // answers for it, so this checker reports nothing.
    const with_strict = try typedDiagnostics(allocator, source, true);
    defer freeSeenDiagnostics(allocator, with_strict);
    try std.testing.expectEqual(@as(usize, 0), with_strict.len);
}

test "TypeChecker: ZTS205 stays when a type error stops the check before the strict stage" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\structural C = { kind: "a" } | { kind: "b" };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "a" }: "a",
        \\  };
        \\}
    , true);
    defer freeSeenDiagnostics(allocator, seen);
    // The partial match is `string | undefined`, which a `string` return
    // refuses (ZTS204). The check ends there, so ZTS603 never reports and
    // ZTS205 carries the witness.
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .return_type_mismatch));
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .non_exhaustive_match));
}

test "TypeChecker: a match not proved exhaustive has type T or undefined" {
    // Partial: the arms give `number`, and the missing case gives undefined.
    try checkTypedSource(
        \\structural C = { kind: "a" } | { kind: "b" };
        \\function run(c: C): number {
        \\  const out: number = match (c) {
        \\    when { kind: "a" }: 1,
        \\  };
        \\  return out;
        \\}
    , 1, null);
    // The honest declaration takes it: the type is `number | undefined`.
    try checkTypedSource(
        \\structural C = { kind: "a" } | { kind: "b" };
        \\function run(c: C): number | undefined {
        \\  const out: number | undefined = match (c) {
        \\    when { kind: "a" }: 1,
        \\  };
        \\  return out;
        \\}
    , 0, 1);
    // Total: the same declaration is fine once every case is covered.
    try checkTypedSource(
        \\structural C = { kind: "a" } | { kind: "b" };
        \\function run(c: C): number {
        \\  const out: number = match (c) {
        \\    when { kind: "a" }: 1,
        \\    when { kind: "b" }: 2,
        \\  };
        \\  return out;
        \\}
    , 0, 0);
    // A default arm makes it total regardless of the discriminant type.
    try checkTypedSource(
        \\function run(s: string): number {
        \\  const out: number = match (s) {
        \\    when "a": 1,
        \\    default: 2,
        \\  };
        \\  return out;
        \\}
    , 0, 0);
}

test "TypeChecker: a redundant arm is a ZTS216 warning at the first such arm" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\function run(s: "a" | "b"): number {
        \\  const out = match (s) {
        \\    when "a": 1,
        \\    when "b": 2,
        \\    when "a": 3,
        \\    when "b": 4,
        \\  };
        \\  return out;
        \\}
    , false);
    defer freeSeenDiagnostics(allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqual(DiagnosticKind.redundant_match_arm, seen[0].kind);
    try std.testing.expectEqual(Severity.warning, seen[0].severity);
    try std.testing.expectEqualStrings("match arm is unreachable", seen[0].message);
}

test "TypeChecker: a default arm after full coverage is a ZTS216 warning about the default" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\function run(s: "a" | "b"): number {
        \\  const out = match (s) {
        \\    when "a": 1,
        \\    when "b": 2,
        \\    default: 3,
        \\  };
        \\  return out;
        \\}
    , true);
    defer freeSeenDiagnostics(allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqual(DiagnosticKind.redundant_match_arm, seen[0].kind);
    try std.testing.expectEqualStrings("default arm is unreachable", seen[0].message);
}

test "TypeChecker: param-discriminant match with default arm is exhaustive (no warning)" {
    // Regression: inferType does not resolve a plain parameter's declared type,
    // so the discriminant was unknown and a `default` arm was not credited,
    // producing a spurious non-exhaustive warning. A catch-all arm is honored
    // regardless of discriminant type, and it is not redundant when a member of
    // the union (`kind: string`) is wider than the arms above it.
    try checkTypedSource(
        \\structural C = { kind: "echo", text: string } | { kind: "ping", text: string } | { kind: string, text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\    when { kind: "ping" }: "pong",
        \\    default: "u",
        \\  };
        \\}
    , 0, 0);
}

test "TypeChecker: a default arm after full coverage of a closed union is redundant" {
    // Spec 5.5: a closed union MUST NOT include `default`. A warning, not an
    // error (owner decision T1 (a)): it reaches the expert loop as a veto
    // violation and does not stop a build.
    try checkTypedSource(
        \\structural C = { kind: "echo", text: string } | { kind: "ping", text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\    when { kind: "ping" }: "pong",
        \\    default: "u",
        \\  };
        \\}
    , 0, 1);
}

test "TypeChecker: typed return satisfies a marker-carrying declared return type" {
    // `Effects<string, "env">` instantiates to `string & { __zttp_effect__ }`.
    // The phantom marker is a verifier obligation, never a value shape, so a
    // returned `string` must pass the return-type check. Without
    // stripProofMarkers the intersection comparison spuriously failed for any
    // return expression whose type inference resolves (annotated locals).
    try checkTypedSource(
        \\function digest(): Effects<string, "env"> {
        \\  const s: string = "x";
        \\  return s;
        \\}
    , 0, 0);
}

test "TypeChecker: marker stripping still rejects a genuinely wrong return" {
    try checkTypedSource(
        \\function digest(): Effects<string, "env"> {
        \\  const n: number = 1;
        \\  return n;
        \\}
    , 1, 0);
}

test "TypeChecker: full-variant param-discriminant match without a default is exhaustive" {
    // Option B: declared parameter types are registered into binding_types on
    // function entry (registerParamTypes), so the discriminant of a
    // `match (param)` resolves to the declared union and variant-coverage
    // analysis runs. Full coverage without a default arm is exhaustive - no
    // warning. (The canonical profile still separately requires a default arm
    // on every match; this only fixes the type-checker layer's false warn.)
    try checkTypedSource(
        \\structural C = { kind: "echo", text: string } | { kind: "ping", text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\    when { kind: "ping" }: "pong",
        \\  };
        \\}
    , 0, 0);
}

test "TypeChecker: partial param-discriminant match without a default still warns" {
    // The same parameter-type resolution must not silence REAL gaps: one of
    // two variants covered, no default - warn. The match is returned from a
    // `string` function, so its `string | undefined` type is also a ZTS204.
    try checkTypedSource(
        \\structural C = { kind: "echo", text: string } | { kind: "ping", text: string };
        \\function run(c: C): string {
        \\  return match (c) {
        \\    when { kind: "echo" }: c.text,
        \\  };
        \\}
    , 1, 1);
}

test "TypeChecker: annotation preserves narrow inferred type" {
    // const p: number = 3000 should keep type 3000, not widen to number
    try checkTypedSource(
        \\const p: number = 3000;
    , 0, 0);
}

test "TypeChecker: annotation rejects incompatible type" {
    // const bad: number = "oops" should error
    try checkTypedSource(
        \\const bad: number = "oops";
    , 1, 0);
}

test "TypeChecker: exported handler local const rejects incompatible initializer" {
    try checkTypedSource(
        \\export function handler(req: Request): Response {
        \\  const n: number = "not a number";
        \\  return Response.json({});
        \\}
    , 1, 0);
}

test "TypeChecker: exported arrow handler local annotation is checked" {
    try checkTypedSource(
        \\export const handler = () => {
        \\  const n: number = "x";
        \\  return Response.json({});
        \\};
    , 1, 0);
}

test "TypeChecker: exported handler local let annotation is checked" {
    try checkTypedSource(
        \\export function handler(req: Request): Response {
        \\  let n: number = "x";
        \\  return Response.json({});
        \\}
    , 1, 0);
}

test "TypeChecker: nested arrow in exported handler checks local annotation" {
    try checkTypedSource(
        \\export const handler = () => {
        \\  const nested = () => {
        \\    const n: number = "x";
        \\    return n;
        \\  };
        \\  return Response.json({ value: nested() });
        \\};
    , 1, 0);
}

test "TypeChecker: shadowed exported local uses its own scoped annotation" {
    try checkTypedSource(
        \\export const zz: string = "top level";
        \\export function handler(req: Request): Response {
        \\  const zz: number = "not a number";
        \\  return Response.json({ value: zz });
        \\}
    , 1, 0);
}

test "TypeChecker: exported handler argument annotation reaches nested upvalue" {
    try checkTypedSource(
        \\export function handler(req: number): Response {
        \\  const nested = () => {
        \\    const text: string = req;
        \\    return text;
        \\  };
        \\  return Response.json({ value: nested() });
        \\}
    , 1, 0);
}

test "TypeChecker: exported top-level annotation remains checked" {
    try checkTypedSource(
        \\export const top: number = "x";
    , 1, 0);
}

test "TypeChecker: correct local annotation in exported handler passes" {
    try checkTypedSource(
        \\export function handler(req: Request): Response {
        \\  const n: number = 1;
        \\  return Response.json({ value: n });
        \\}
    , 0, 0);
}

test "TypeChecker: colliding locals use their initializer signatures" {
    try checkTypedSource(
        \\function one(value: string): string { return value; }
        \\function none(): string { return "ok"; }
        \\function handler() {
        \\  const request = one;
        \\  const run = none;
        \\  const scope = one;
        \\  const fetch = none;
        \\  request("request");
        \\  run();
        \\  scope("scope");
        \\  fetch();
        \\}
    , 0, 0);
}

test "TypeChecker: non-callable colliding locals do not inherit module signatures" {
    try checkTypedSource(
        \\function handler(send) {
        \\  const request = 42;
        \\  const run = "not callable";
        \\  send();
        \\  request();
        \\  run();
        \\}
    , 0, 0);
}

test "TypeChecker: module signature aliases preserve required parameter count" {
    try checkTypedSource(
        \\import { fetchWithRetry } from "zttp:fetch";
        \\function handler() {
        \\  const request = fetchWithRetry;
        \\  request("https://example.com");
        \\}
    , 0, 0);
}

test "TypeChecker: user function aliases carry the function signature" {
    try checkTypedSource(
        \\function format(value: string, count: number): string { return value; }
        \\function handler() {
        \\  const alias = format;
        \\  alias("ok", 1);
        \\  alias("missing count");
        \\  const nested = (local) => {
        \\    alias("nested missing count");
        \\  };
        \\  nested(42);
        \\}
    , 2, 0);
}

test "TypeChecker: a function and an arrow on one line keep separate signatures" {
    // Annotations were filed under the line they sit on, so the arrow's
    // parameter merged into `bump`'s signature and `bump([1, 2])` was refused
    // for passing one argument to a function of two.
    try checkTypedSource(
        \\function bump(xs: number[]): number[] { return xs.map((x: number): number => x + 1); }
        \\function handler(req: Request): Response {
        \\  const ys = bump([1, 2]);
        \\  return Response.json({ ys: ys });
        \\}
    , 0, 0);
}

test "TypeChecker: nested functions that share a name keep their own signatures" {
    // The later declaration must not win the name for both, in either order.
    try checkTypedSource(
        \\function first(): number {
        \\  function inner(x: number): number { return x; }
        \\  return inner(1);
        \\}
        \\function second(): number {
        \\  function inner(x: number, y: number): number { return x + y; }
        \\  return inner(1, 2);
        \\}
    , 0, 0);
    try checkTypedSource(
        \\function second(): number {
        \\  function inner(x: number, y: number): number { return x + y; }
        \\  return inner(1, 2);
        \\}
        \\function first(): number {
        \\  function inner(x: number): number { return x; }
        \\  return inner(1);
        \\}
    , 0, 0);
}

test "TypeChecker: each nested function of one name is still checked against its own signature" {
    // Sharing a name must not loosen the check: the call that is wrong for its
    // own function is still refused, and only that one.
    try checkTypedSourceSaying(
        \\function first(): number {
        \\  function inner(x: number): number { return x; }
        \\  return inner(1);
        \\}
        \\function second(): number {
        \\  function inner(x: number, y: number): number { return x + y; }
        \\  return inner(1);
        \\}
    , 1, "expected 2, got 1");
}

test "TypeChecker: surplus arguments to a declaration are refused" {
    try checkTypedSourceSaying(
        \\function double(x: number): number { return x * 2; }
        \\function handler(req: Request): Response {
        \\  const n = double(1, 2);
        \\  return Response.json({ n: n });
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: surplus arguments to a zero-parameter function are refused" {
    try checkTypedSourceSaying(
        \\function one(): number { return 1; }
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: one(5) });
        \\}
    , 1, "expected 0, got 1");
}

test "TypeChecker: surplus arguments to a const arrow are refused" {
    try checkTypedSourceSaying(
        \\const inc = (x: number): number => x + 1;
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: inc(1, 2) });
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: surplus arguments to a nested function are refused" {
    try checkTypedSourceSaying(
        \\function handler(req: Request): Response {
        \\  function square(x: number): number { return x * x; }
        \\  return Response.json({ n: square(2, 3) });
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: surplus arguments to a generic function are refused" {
    try checkTypedSourceSaying(
        \\function same<T>(x: T): T { return x; }
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: same(1, 2) });
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: surplus arguments to a recursive call are refused" {
    try checkTypedSourceSaying(
        \\function fact(n: number): number { return n <= 1 ? 1 : n * fact(n - 1, 0); }
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: fact(3) });
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: surplus arguments to a function-typed parameter are refused" {
    try checkTypedSourceSaying(
        \\function apply(f: (x: number) => number, v: number): number { return f(v, v); }
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: apply((x: number): number => x, 3) });
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: surplus arguments are counted against the parameter list, not the annotations" {
    // `(a: number, b)` annotates one of its two parameters. The signature
    // built from the annotations holds one entry, so counting against it
    // accepted `first(1, 2)` and `first(1, 2, 3)` alike.
    try checkTypedSourceSaying(
        \\const first = (a: number, b): number => a;
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: first(1, 2, 3) });
        \\}
    , 1, "expected 2, got 3");
}

test "TypeChecker: surplus arguments to a function with no annotation are refused" {
    try checkTypedSourceSaying(
        \\function pick(a, b) { return a; }
        \\const wrap = (a, b) => a;
        \\function handler(req: Request): Response {
        \\  pick(1, 2, 3);
        \\  wrap(1, 2, 3);
        \\  return Response.json({});
        \\}
    , 2, "expected 2, got 3");
}

test "TypeChecker: surplus arguments to a module export are refused" {
    try checkTypedSourceSaying(
        \\import { sha256 } from "zttp:crypto";
        \\function handler(req: Request): Response {
        \\  return Response.text(sha256("a", "b"));
        \\}
    , 1, "expected 1, got 2");
}

test "TypeChecker: a module export called under another name is still bounded" {
    try checkTypedSourceSaying(
        \\import { sha256 as digest } from "zttp:crypto";
        \\function handler(req: Request): Response {
        \\  return Response.text(digest("a", "b", "c"));
        \\}
    , 1, "expected 1, got 3");
}

test "TypeChecker: a module export is called with its declared arguments" {
    try checkTypedSource(
        \\import { sha256 } from "zttp:crypto";
        \\import { jwtVerify } from "zttp:auth";
        \\function handler(req: Request): Response {
        \\  const a = jwtVerify("t", "s");
        \\  const b = jwtVerify("t", "s", "HS256");
        \\  return Response.text(sha256("a"));
        \\}
    , 0, 0);
}

test "TypeChecker import diagnostics preserve aliases shadows and first successful export" {
    const allocator = std.testing.allocator;
    const Case = struct { source: []const u8, errors: usize, message: []const u8 = "expected 1, got 2" };
    const cases = [_]Case{
        .{ .source = "import { sha256 as digest } from 'zttp:crypto'; digest('a', 'b');", .errors = 1 },
        .{ .source = "import { sha256 as digest } from 'zttp-ext:unknown'; digest('a', 'b');", .errors = 0 },
        .{ .source = "function sha256(a, b) { return a; } sha256('a', 'b');", .errors = 0 },
        .{ .source = "import { sha256 as digest } from 'zttp:crypto'; function run(digest) { return digest('a', 'b'); }", .errors = 0 },
        .{ .source = "import { missing as digest } from 'zttp:crypto'; import { sha256 as digest } from 'zttp:crypto'; digest('a', 'b');", .errors = 1 },
        .{ .source = "import { missing as digest } from 'zttp-ext:unknown'; import { sha256 as digest } from 'zttp:crypto'; digest('a', 'b');", .errors = 1 },
        .{ .source = "import { sha256 as digest } from 'zttp:crypto'; import { jwtVerify as digest } from 'zttp:auth'; digest('a', 'b', 'c');", .errors = 1, .message = "expected 1, got 3" },
    };
    for ([_]bool{ false, true }) |borrow_imports| {
        for (cases) |case| {
            const seen = try typedDiagnosticsWithImportFacts(allocator, case.source, false, borrow_imports);
            defer freeSeenDiagnostics(allocator, seen);
            try std.testing.expectEqual(case.errors, seen.len);
            for (seen) |diagnostic| {
                try std.testing.expectEqual(DiagnosticKind.arg_count_mismatch, diagnostic.kind);
                try std.testing.expectEqual(Severity.err, diagnostic.severity);
                try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, case.message) != null);
            }
        }
    }
}

test "TypeChecker import policy compares named kind and slot without scope or local name" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |borrow_imports| {
        for ([_]Node.ImportSpec.ImportKind{ .named, .default, .namespace }) |import_kind| {
            for ([_]bool{ false, true }) |same_kind| {
                var atoms = context.AtomTable.init(allocator);
                defer atoms.deinit();
                var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "digest('a', 'b');", .compile);
                defer parser.deinit();
                parser.setAtomTable(&atoms);
                const root = try parser.parse();
                const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
                var call_node: NodeIndex = null_node;
                for (0..view.nodeCount()) |index| {
                    const node: NodeIndex = @intCast(index);
                    if (view.getTag(node) == .call) {
                        call_node = node;
                        break;
                    }
                }
                try std.testing.expect(call_node != null_node);
                const call = view.getCall(call_node).?;
                const binding = view.getBinding(call.callee).?;
                try std.testing.expect(binding.kind != .local);
                var import_binding = binding;
                import_binding.scope_id = 9000;
                import_binding.name_atom = @intCast(@backingInt(try atoms.intern("other")));
                if (!same_kind) import_binding.kind = .local;
                const loc = view.getLoc(call_node).?;
                // Append a declaration independently of the source spelling so
                // the exact import-kind and binding-kind policy is exercised.
                const spec = try parser.nodes.addImportSpec(.import_specifier, loc, .{
                    .kind = import_kind,
                    .imported_atom = @intCast(@backingInt(try atoms.intern("sha256"))),
                    .local_binding = import_binding,
                });
                const specs = try parser.nodes.addIndexList(&.{spec});
                _ = try parser.nodes.addImportDecl(loc, .{
                    .module_idx = try parser.constants.addString("zttp:crypto"),
                    .specifiers_start = specs,
                    .specifiers_count = 1,
                });
                var facts = try module_facts_mod.ModuleFacts.build(allocator, view, &atoms, null);
                defer facts.deinit();
                var pool = TypePool.init(allocator);
                defer pool.deinit(allocator);
                var env = TypeEnv.init(allocator, &pool);
                defer env.deinit();
                var checker = TypeChecker.init(allocator, view, &atoms, &env);
                defer checker.deinit();
                if (borrow_imports) checker.import_facts = &facts;
                // Public inference remains usable before check and does not
                // introduce the call-argument diagnostics from the walk.
                try std.testing.expectEqual(null_type_idx, checker.inferTypeWithoutDiagnostics(call_node));
                try std.testing.expectEqual(@as(usize, 0), checker.getDiagnostics().len);
                const expected: u32 = if (import_kind == .named and same_kind) 1 else 0;
                try std.testing.expectEqual(expected, try checker.check(root));
                try std.testing.expectEqual(expected, checker.getDiagnostics().len);
                if (expected == 1) {
                    const diagnostic = checker.getDiagnostics()[0];
                    try std.testing.expectEqual(DiagnosticKind.arg_count_mismatch, diagnostic.kind);
                    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "expected 1, got 2") != null);
                }
            }
        }
    }
}

test "TypeChecker owned import cache survives moving a checked value" {
    const allocator = std.testing.allocator;
    var atoms = context.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "import { sha256 as digest } from 'zttp:crypto'; digest('a', 'b');", .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    const Builder = struct {
        fn checked(a: std.mem.Allocator, ir_view: IrView, table: *context.AtomTable, type_env: *TypeEnv, program: NodeIndex) !TypeChecker {
            var value = TypeChecker.init(a, ir_view, table, type_env);
            errdefer value.deinit();
            try std.testing.expectEqual(@as(u32, 1), try value.check(program));
            return value;
        }
    };
    var checker = try Builder.checked(allocator, view, &atoms, &env, root);
    defer checker.deinit();
    const cached = checker.owned_import_facts.?.imports.items.ptr;
    try std.testing.expectEqual(@as(u32, 2), try checker.check(root));
    try std.testing.expect(cached == checker.owned_import_facts.?.imports.items.ptr);
    try std.testing.expectEqual(DiagnosticKind.arg_count_mismatch, checker.getDiagnostics()[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, checker.getDiagnostics()[1].message, "expected 1, got 2") != null);
}

test "TypeChecker import cache allocation failure stays unproven after allocator recovery" {
    const allocator = std.testing.allocator;
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, "import { sha256 } from 'zttp:crypto'; sha256('a', 'b');", .compile);
    defer parser.deinit();
    const root = try parser.parse();
    const view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var checker = TypeChecker.init(failing.allocator(), view, null, &env);
    defer checker.deinit();
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.OutOfMemory, checker.ensureHealthy());
    try std.testing.expectError(error.OutOfMemory, checker.check(root));
}

test "TypeChecker: a call with exactly the declared arguments is accepted" {
    try checkTypedSource(
        \\function add(x: number, y: number): number { return x + y; }
        \\const inc = (x: number): number => x + 1;
        \\function apply(f: (x: number) => number, v: number): number { return f(v); }
        \\function handler(req: Request): Response {
        \\  const doubled = [1, 2].map((x: number): number => x * 2);
        \\  const total = doubled.reduce((acc: number, x: number): number => acc + x, 0);
        \\  return Response.json({ a: add(1, 2), b: inc(1), c: apply(inc, 3), d: total });
        \\}
    , 0, 0);
}

test "TypeChecker: a function passed by name to an array method is not a call" {
    // The array method supplies more arguments than `dbl` declares. That is
    // the method's contract, not a call written in the source.
    try checkTypedSource(
        \\function dbl(x: number): number { return x * 2; }
        \\function handler(req: Request): Response {
        \\  return Response.json({ ys: [1, 2].map(dbl) });
        \\}
    , 0, 0);
}

test "TypeChecker: a reassignable arrow keeps the weaker reading" {
    // A `let` can be given another function, so the parameter count of the
    // first one does not bound later calls. This is the stated limit of the
    // upper bound, not an endorsement.
    try checkTypedSource(
        \\function handler(req: Request): Response {
        \\  let f = (a: number): number => a;
        \\  return Response.json({ n: f(1, 2) });
        \\}
    , 0, 0);
}

test "TypeChecker: logical and produces boolean" {
    try checkTypedSource(
        \\const x: string = "x";
        \\const y: string = "y";
        \\const s: string = x && y;
    , 1, 0);
}

test "TypeChecker: logical result satisfies boolean annotation" {
    try checkTypedSource(
        \\const x: string = "x";
        \\const y: string = "y";
        \\const b: boolean = x && y;
    , 0, 0);
}

test "TypeChecker: logical operators do not infer operand union" {
    try checkTypedSource(
        \\function combine(x: string, y: number) {
        \\  const and_result: string | number = x && y;
        \\  const or_result: string | number = x || y;
        \\}
    , 2, 0);
}

test "TypeChecker: logical boolean result is admitted by containing union" {
    try checkTypedSource(
        \\const value: string | number = "x";
        \\const flag: boolean = true;
        \\const result: string | number | boolean = value && flag;
    , 0, 0);
}

test "TypeChecker: array predicates require boolean callback results" {
    try checkTypedSource(
        \\const values = [1, 2, 3];
        \\const a = values.filter((value) => value);
        \\const b = values.every((value) => "yes");
        \\const c = values.some((value) => 1);
        \\const d = values.find((value) => value);
        \\const e = values.findIndex((value) => value);
    , 5, 0);
}

test "TypeChecker: array predicates admit boolean callback results" {
    try checkTypedSource(
        \\const values = [1, 2, 3];
        \\const a = values.filter((value) => value > 1);
        \\const b: boolean = values.every((value) => value > 0);
        \\const c: boolean = values.some((value) => value === 2);
        \\const d = values.find((value) => value > 1);
        \\const e: number = values.findIndex((value) => value > 1);
    , 0, 0);
}

test "TypeChecker: dictFilter predicate requires a boolean result" {
    try checkTypedSource(
        \\import { dictEmpty, dictSet, dictFilter } from "zttp:collections";
        \\const values = dictSet(dictEmpty(), "a", 1);
        \\const kept = dictFilter(values, (value) => value);
    , 1, 0);
}

test "TypeChecker: dictFilter admits a boolean predicate result" {
    try checkTypedSource(
        \\import { dictEmpty, dictSet, dictFilter } from "zttp:collections";
        \\const values = dictSet(dictEmpty(), "a", 1);
        \\const kept = dictFilter(values, (value) => value === 1);
    , 0, 0);
}

test "TypeChecker: nullish coalescing includes fallback in nullable result" {
    try checkTypedSource(
        \\function maybe(): string | undefined { return undefined; }
        \\const s: string = maybe() ?? 42;
        \\const v: string | number = maybe() ?? 42;
    , 1, 0);
}

test "TypeChecker: non-nullable nullish coalescing keeps left type" {
    try checkTypedSource(
        \\function defaultValue(value: string) {
        \\  const result: string = value ?? 42;
        \\}
    , 0, 0);
}

test "TypeChecker: undefined nullish coalescing returns fallback type" {
    try checkTypedSource(
        \\function defaultValue(fallback: number) {
        \\  const result: number = undefined ?? fallback;
        \\}
    , 0, 0);
}

test "TypeChecker: rejects assignment to readonly property" {
    try checkTypedSource(
        \\structural Config = { readonly port: number; host: string };
        \\const cfg: Config = { port: 3000, host: "localhost" };
        \\cfg.port = 8080;
    , 1, 0);
}

test "TypeChecker: allows assignment to non-readonly property" {
    try checkTypedSource(
        \\structural Config = { readonly port: number; host: string };
        \\const cfg: Config = { port: 3000, host: "localhost" };
        \\cfg.host = "other";
    , 0, 0);
}

test "TypeChecker: a readonly array refuses a mutating method" {
    // `readonly` was enforced through assignability alone, so a readonly array
    // could not be handed to a mutating parameter and could still be mutated
    // in place. `ro.push("y")` checked clean and appended at runtime, which
    // made the modifier decorative wherever the value never crossed a call
    // boundary.
    for ([_][]const u8{ "push", "pop", "shift", "unshift", "splice" }) |method| {
        const source = try std.testing.allocator.print(
            \\function handler(req: Request): Response {{
            \\  const ro: readonly string[] = ["x"];
            \\  ro.{s}();
            \\  return Response.json({{ n: ro.length }});
            \\}}
        , .{method});
        defer std.testing.allocator.free(source);
        try checkTypedSourceSaying(source, 1, "readonly");
    }
}

test "TypeChecker: a mutable array still takes every method" {
    // The companion direction. Dropping `readonly` must leave every one of
    // those calls alone, or the rule is refusing arrays rather than refusing
    // mutation.
    for ([_][]const u8{ "push", "pop", "shift", "unshift", "splice" }) |method| {
        const source = try std.testing.allocator.print(
            \\function handler(req: Request): Response {{
            \\  const xs: string[] = ["x"];
            \\  xs.{s}();
            \\  return Response.json({{ n: xs.length }});
            \\}}
        , .{method});
        defer std.testing.allocator.free(source);
        try checkTypedSource(source, 0, null);
    }
}

test "TypeChecker: a readonly array still takes a non-mutating method" {
    // `readonly` bans mutation, not use. A rule keyed on the receiver rather
    // than the method would take these with it.
    try checkTypedSource(
        \\function handler(req: Request): Response {
        \\  const ro: readonly string[] = ["x"];
        \\  const joined: string = ro.join(",");
        \\  const first: string[] = ro.slice(0, 1);
        \\  return Response.json({ joined: joined, n: first.length });
        \\}
    , 0, null);
}

test "TypeChecker: a readonly parameter refuses mutation in the body" {
    // The case the assignability rule already covers at the call site, checked
    // from the other side: a function that declares it will not write must not
    // write.
    try checkTypedSourceSaying(
        \\function drain(xs: readonly string[]): number {
        \\  xs.pop();
        \\  return xs.length;
        \\}
        \\function handler(req: Request): Response {
        \\  return Response.json({ n: drain(["a"]) });
        \\}
    , 1, "readonly");
}

test "TypeChecker: nominal construction is the annotated declaration" {
    // The construction path, and the only one. A base-typed value becomes
    // branded at an explicitly annotated declaration, which is the single
    // visible widening point the brand allows.
    try checkTypedSource(
        \\nominal UserId = string;
        \\const uid: UserId = "usr_123";
    , 0, 0);
}

test "TypeChecker: the branded binding keeps its brand" {
    // The declaration must not collapse to the initializer's literal type. A
    // nominal node copies its base node's tag, so the literal-of-base
    // narrowing that keeps `const n: number = 1` at type `1` reads a nominal
    // over string as a plain string and would drop the brand silently. Without
    // the guard this fails on the last line, and for the wrong reason.
    try checkTypedSource(
        \\nominal UserId = string;
        \\function widen(id: UserId): string { return id; }
        \\const uid: UserId = "usr_123";
        \\const out: string = widen(uid);
    , 0, 0);
}

test "TypeChecker: a nominal constructor call is refused" {
    // `UserId("usr_123")` must not type-check and then fault at runtime with
    // NotCallable: the checker answers the call's type from the alias table
    // and nothing lowers it, so codegen would emit a call to a name no function
    // defines. Erasing it in codegen is not available - node types reach the
    // generator on the precompile path only - so the refusal is what converts
    // a 500 into a compile error.
    try checkTypedSourceSaying(
        \\nominal UserId = string;
        \\const uid: UserId = UserId("usr_123");
    , 1, "not a constructor");
}

test "TypeChecker: a raw value is still refused at a call site" {
    // The admission is scoped to an annotated declaration on purpose. Widening
    // it to every position where the expected type is known would admit this
    // line and leave the brand doing nothing at all.
    try checkTypedSource(
        \\nominal UserId = string;
        \\function widen(id: UserId): string { return id; }
        \\const out: string = widen("usr_123");
    , 1, 0);
}

test "TypeChecker: nominal rejects cross-nominal assignment" {
    try checkTypedSource(
        \\nominal UserId = string;
        \\nominal SessionId = string;
        \\const sid: SessionId = "sess_456";
        \\const uid: UserId = sid;
    , 1, 0);
}

test "TypeChecker: a nominal admits its own base and no other" {
    try checkTypedSource(
        \\nominal Port = number;
        \\const p: Port = 8080;
    , 0, 0);
    try checkTypedSource(
        \\nominal Port = number;
        \\const p: Port = "8080";
    , 1, 0);
}

test "TypeChecker: structural is a transparent alias" {
    try checkTypedSource(
        \\structural Config = { port: number; host: string };
        \\const cfg: Config = { port: 3000, host: "localhost" };
    , 0, 0);
}

test "TypeChecker: structural carries type parameters" {
    try checkTypedSource(
        \\structural Box<T> = { value: T };
        \\const boxed: Box<number> = { value: 1 };
    , 0, 0);
}

test "TypeChecker: structural rejects a mismatched member" {
    try checkTypedSource(
        \\structural Config = { port: number };
        \\const cfg: Config = { port: "3000" };
    , 1, 0);
}

test "TypeChecker: template literal type accepts matching string" {
    try checkTypedSource(
        \\structural ApiRoute = `/api/${string}`;
        \\const good: ApiRoute = "/api/users";
    , 0, 0);
}

test "TypeChecker: template literal type rejects non-matching string" {
    try checkTypedSource(
        \\structural ApiRoute = `/api/${string}`;
        \\const bad: ApiRoute = "/other";
    , 1, 0);
}

test "TypeChecker: toSorted with a comparator type-checks clean" {
    // Regression for ENG-9: a comparator argument must not raise ZTS204/ZTS003.
    // toSorted(compareFn?) is modelled as an optional callback returning T[].
    try checkTypedSource(
        \\const nums = [10, 2, 1, 33, 4];
        \\const sorted = nums.toSorted((a, b) => a - b);
    , 0, 0);
}

test "TypeChecker: jwtVerify algorithm parameter is optional" {
    try checkTypedSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret");
    , 0, 0);
}

test "TypeChecker: jwtVerify algorithm parameter is type-checked when present" {
    try checkTypedSource(
        \\import { jwtVerify } from "zttp:auth";
        \\const result = jwtVerify("token", "secret", 123);
    , 1, 0);
}

test "TypeChecker tracks object literal fields beyond 32 properties" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll("const obj = {");
    for (0..33) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("p{d}: \"{d}\"", .{ i, i });
    }
    try aw.writer.writeAll("};\nconst last: string = obj.p32;\n");

    try checkTypedSource(aw.writer.buffered(), 0, 0);
}

test "TypeChecker tracks schema object fields beyond 32 properties" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("big", '{"type":"object","properties":{
    );
    for (0..33) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("\"p{d}\":{{\"type\":\"string\"}}", .{i});
    }
    try aw.writer.writeAll(
        \\},"required":["p32"]}');
        \\const result = validateJson("big", "{}");
        \\const last: string = result.value.p32;
        \\
    );

    try checkTypedSource(aw.writer.buffered(), 0, 0);
}

test "TypeChecker tracks schema enum members beyond 32 values" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try aw.writer.writeAll(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("choice", '{"enum":[
    );
    for (0..33) |i| {
        if (i > 0) try aw.writer.writeAll(",");
        try aw.writer.print("\"v{d}\"", .{i});
    }
    try aw.writer.writeAll(
        \\]}');
        \\
    );

    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, aw.writer.buffered(), .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();

    try std.testing.expectEqual(@as(u32, 0), try checker.check(root));
    try std.testing.expectEqual(@as(usize, 1), checker.compiled_schemas.items.len);
    const schema_type = checker.compiled_schemas.items[0].type_idx;
    try std.testing.expectEqual(type_pool_mod.TypeTag.t_union, pool.getTag(schema_type).?);
    const members = pool.getUnionMembers(schema_type);
    try std.testing.expectEqual(@as(usize, 33), members.len);
    try std.testing.expectEqualStrings("v32", pool.getLiteralStringValue(members[32]).?);
}

test "TypeChecker infers every supported JSON stringify schema literal" {
    try checkTypedSourceSaying(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("matrix", JSON.stringify({
        \\  type: "object",
        \\  "required": ["title", "count", "enabled", "items"],
        \\  properties: {
        \\    title: { type: "string", description: "line\nquote:\" slash:\\ tab:\t" },
        \\    count: { type: "number", minimum: -1.5, maximum: 2.25 },
        \\    enabled: { type: "boolean", default: true },
        \\    items: { type: "array", items: { type: "integer" } },
        \\    absent: null,
        \\    examples: [0, -2, 3.5, false, null],
        \\  },
        \\}));
        \\const parsed = validateJson("matrix", "{}");
        \\const title: string = parsed.value.title;
        \\const count: number = parsed.value.count;
        \\const enabled: boolean = parsed.value.enabled;
        \\const items: number[] = parsed.value.items;
        \\const wrongTitle: number = parsed.value.title;
        \\const wrongCount: string = parsed.value.count;
        \\const wrongEnabled: number = parsed.value.enabled;
        \\const wrongItems: string = parsed.value.items;
    , 4, "type 'string' is not assignable to type 'number'");
}

test "TypeChecker preserves raw schema typing and skips unreadable schemas" {
    try checkTypedSourceSaying(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("raw", ' { "type" : "object", "properties" : { "title" : { "type" : "string" } } } ');
        \\const parsed = validateJson("raw", "{}");
        \\const title: number = parsed.value.title;
    , 1, "type 'string | undefined' is not assignable to type 'number'");

    try checkTypedSource(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\schemaCompile("broken", '{"type":');
        \\const parsed = validateJson("broken", "{}");
        \\const title: number = parsed.value.title;
    , 0, 0);

    try checkTypedSource(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\const schema = { type: "object", properties: { title: { type: "string" } } };
        \\schemaCompile("dynamic", JSON.stringify(schema));
        \\const parsed = validateJson("dynamic", "{}");
        \\const title: number = parsed.value.title;
    , 0, 0);
}

test "TypeChecker refuses a partially written dynamic schema without leaking" {
    try checkTypedSource(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function schemaType() { return "object"; }
        \\schemaCompile("partial", JSON.stringify({
        \\  type: schemaType(),
        \\  properties: { title: { type: "string" } },
        \\}));
        \\const parsed = validateJson("partial", "{}");
        \\const title: number = parsed.value.title;
    , 0, 0);
}

test "TypeChecker keeps the current JSON binding distinction for schemas" {
    try checkTypedSourceSaying(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\const JSON = { stringify: (value) => "ignored" };
        \\schemaCompile("global-shadow", JSON.stringify({
        \\  type: "object",
        \\  properties: { title: { type: "string" } },
        \\}));
        \\const parsed = validateJson("global-shadow", "{}");
        \\const title: number = parsed.value.title;
    , 1, "type 'string | undefined' is not assignable to type 'number'");

    try checkTypedSource(
        \\import { schemaCompile, validateJson } from "zttp:validate";
        \\function register() {
        \\  const JSON = { stringify: (value) => "ignored" };
        \\  schemaCompile("local-shadow", JSON.stringify({
        \\    type: "object",
        \\    properties: { title: { type: "string" } },
        \\  }));
        \\}
        \\register();
        \\const parsed = validateJson("local-shadow", "{}");
        \\const title: number = parsed.value.title;
    , 0, 0);
}

test "TypeChecker: toSorted with no comparator type-checks clean" {
    // The single comparator parameter is optional, so a zero-arg call is valid.
    try checkTypedSource(
        \\const nums = [3, 1, 2];
        \\const sorted = nums.toSorted();
    , 0, 0);
}

test "TypeChecker: toReversed type-checks clean" {
    try checkTypedSource(
        \\const nums = [3, 1, 2];
        \\const rev = nums.toReversed();
    , 0, 0);
}

// ---------------------------------------------------------------------------
// Generic instantiation (D1 section 4)
// ---------------------------------------------------------------------------

/// Type the call to `callee` in `source` and render the result into `buf`.
/// The rendering is returned rather than the `TypeIndex` because the pool dies
/// with this function, so an index would dangle.
fn formatCallType(source: []const u8, callee: []const u8, buf: []u8) ![]const u8 {
    const allocator = std.testing.allocator;
    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);

    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);

    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(root);

    var node: NodeIndex = 0;
    while (node < ir_view.nodeCount()) : (node += 1) {
        if (ir_view.getTag(node) != .call) continue;
        const call = ir_view.getCall(node) orelse continue;
        if (ir_view.getTag(call.callee) != .identifier) continue;
        const binding = ir_view.getBinding(call.callee) orelse continue;
        const name = checker.resolveAtomName(binding.name_atom) orelse continue;
        if (!std.mem.eql(u8, name, callee)) continue;
        return pool.formatType(checker.inferType(node), buf);
    }
    return error.NoSuchCallInSource;
}

const generic_first_decl =
    \\function first<T>(xs: T[]): T | undefined {
    \\    for (const x of xs) { return x; }
    \\    return undefined;
    \\}
    \\
;

test "a literal argument binds the type parameter to its base type" {
    var buf: [128]u8 = undefined;
    // `["a"]` types as `"a"[]`, so binding T to the element verbatim would make
    // the call return `"a" | undefined` and every other string a mismatch.
    const rendered = try formatCallType(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first(["a"]);
            \\    return Response.json({ head: head });
            \\}
        ,
        "first",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "string") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"a\"") == null);
}

test "an inferred type argument is checked against the annotation it flows into" {
    // The positive control for the test above: with no inference this call
    // typed as an unresolved `T` and every annotation accepted it.
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head: number | undefined = first(["a"]);
            \\    return Response.json({ head: head });
            \\}
        ,
        1,
        null,
    );
}

test "an inferred type argument that matches its annotation raises nothing" {
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head: string | undefined = first(["a"]);
            \\    return Response.json({ head: head });
            \\}
        ,
        0,
        null,
    );
}

test "an explicit type argument overrides inference" {
    var buf: [128]u8 = undefined;
    const rendered = try formatCallType(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first<number>([]);
            \\    return Response.json({ head: head });
            \\}
        ,
        "first",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered, "number") != null);
}

test "a type parameter no argument determines is refused, not widened" {
    try checkTypedSource(
        \\function make<T>(n: number): T | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v = make(1);
        \\    return Response.json({ v: v });
        \\}
    ,
        1,
        null,
    );
}

test "naming the type argument answers the ambiguity" {
    try checkTypedSource(
        \\function make<T>(n: number): T | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v = make<string>(1);
        \\    return Response.json({ v: v });
        \\}
    ,
        0,
        null,
    );
}

test "a type argument outside its constraint is refused" {
    try checkTypedSource(
        \\function idOf<T extends { id: string }>(v: T): string {
        \\    return v.id;
        \\}
        \\function handler(req: Request): Response {
        \\    const s = idOf({ name: "no id" });
        \\    return Response.json({ s: s });
        \\}
    ,
        1,
        null,
    );
}

test "a type argument inside its constraint is accepted" {
    try checkTypedSource(
        \\function idOf<T extends { id: string }>(v: T): string {
        \\    return v.id;
        \\}
        \\function handler(req: Request): Response {
        \\    const s = idOf({ id: "u1" });
        \\    return Response.json({ s: s });
        \\}
    ,
        0,
        null,
    );
}

test "explicit type arguments of the wrong count are refused" {
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first<string, number>(["a"]);
            \\    return Response.json({ head: head });
            \\}
        ,
        1,
        null,
    );
}

test "every instantiation re-checks its value arguments" {
    // `first<string>` fixes the parameter at `string[]`, so a number array is
    // a mismatch that the uninstantiated `T[]` accepted.
    try checkTypedSource(
        generic_first_decl ++
            \\function handler(req: Request): Response {
            \\    const head = first<string>([1]);
            \\    return Response.json({ head: head });
            \\}
        ,
        1,
        null,
    );
}

test "a constraint that accepts literals keeps the literal it was given" {
    // Widening `"get"` to `string` would put the argument outside the bound the
    // call satisfies, so the literal survives and the call is clean.
    try checkTypedSource(
        \\function pick<T extends "get" | "put">(m: T): T {
        \\    return m;
        \\}
        \\function handler(req: Request): Response {
        \\    const m = pick("get");
        \\    return Response.json({ m: m });
        \\}
    ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// Narrowing regressions
// ---------------------------------------------------------------------------

test "a write to a readonly field is caught through a narrowing" {
    // The check read `binding_types`, which holds the declaration, so once
    // narrowings moved to their own overlay the guarded shape - the usual way
    // a readonly record is reached - stopped resolving to a record and the
    // write passed in silence.
    try checkTypedSource(
        \\function load(): { readonly id: string } | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: { readonly id: string } | undefined = load();
        \\    if (v !== undefined) {
        \\        v.id = "b";
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        null,
    );
}

test "a narrowing from a nested early return does not escape its conditional" {
    // Kill rule 5 drops narrowings whose binding lives in the closing block's
    // scope, and the binding here is a parameter of the enclosing function, so
    // the forward narrowing survived the outer `if` and described the path
    // where `flag` was false.
    try checkTypedSource(
        \\function f(flag: boolean, v: string | undefined): string {
        \\    if (flag) {
        \\        if (v === undefined) {
        \\            return "x";
        \\        }
        \\    }
        \\    return v;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f(true, "a") });
        \\}
    ,
        1,
        null,
    );
}

test "an unguarded early return still narrows the rest of its own block" {
    // The positive control for the test above: the same guard without the
    // enclosing conditional must still narrow, or the fix would have bought
    // soundness by turning narrowing off.
    try checkTypedSource(
        \\function f(v: string | undefined): string {
        \\    if (v === undefined) {
        \\        return "x";
        \\    }
        \\    return v;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f("a") });
        \\}
    ,
        0,
        null,
    );
}

test "a boolean field that is not a discriminant installs no guard" {
    // The guard took the first member whose field is literal `true` and
    // excluded only that member. A sibling whose field is plain `boolean` can
    // also be true at runtime, so the then-branch was narrowed to the wrong
    // member and a correct field read reported as missing.
    try checkTypedSource(
        \\function f(c: { on: true, a: string } | { on: boolean, b: string }): string {
        \\    if (c.on) {
        \\        return c.b ?? "d";
        \\    }
        \\    return "d";
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f({ on: false, b: "x" }) });
        \\}
    ,
        0,
        null,
    );
}

test "a real boolean discriminant still selects its member" {
    // The positive control: reading the other arm's field inside the guard is
    // still an error, so the fix did not disable the guard.
    try checkTypedSource(
        \\function f(r: { ok: true, value: string } | { ok: false, error: string }): string {
        \\    if (r.ok) {
        \\        return r.error;
        \\    }
        \\    return r.error;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ v: f({ ok: false, error: "x" }) });
        \\}
    ,
        1,
        null,
    );
}

test "a captured binding and a parameter in the same slot narrow separately" {
    // Both pack to (scope, slot) and both are slot 0 of the inner function -
    // an upvalue indexes the closure's upvalue array, a parameter its own
    // argument array - so the narrowing installed for the captured `v` landed
    // on `n` and `return n` was read as `string`.
    try checkTypedSource(
        \\function load(): string | undefined {
        \\    return undefined;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | undefined = load();
        \\    const f = (n: number): number => {
        \\        if (v === undefined) {
        \\            return 0;
        \\        }
        \\        return n;
        \\    };
        \\    return Response.json({ x: f(1) });
        \\}
    ,
        0,
        null,
    );
}

test "an absence guard narrows a union wider than the old scratch buffer" {
    // The partition ran in a sixteen-slot stack buffer and bailed out past it,
    // so exactly the wide enums `addUnion` was changed to represent could not
    // be narrowed: after the early return the value stayed nullable and the
    // return reported a mismatch on correct code.
    try checkTypedSource(
        \\function pick(m: "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" | "m17" | undefined): "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" | "m17" {
        \\    if (m === undefined) {
        \\        return "m1";
        \\    }
        \\    return m;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ m: pick("m1") });
        \\}
    ,
        0,
        null,
    );
}

test "the same guard over a sixteen-member union is the control" {
    try checkTypedSource(
        \\function pick(m: "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" | undefined): "m1" | "m2" | "m3" | "m4" | "m5" | "m6" | "m7" | "m8" | "m9" | "m10" | "m11" | "m12" | "m13" | "m14" | "m15" | "m16" {
        \\    if (m === undefined) {
        \\        return "m1";
        \\    }
        \\    return m;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ m: pick("m1") });
        \\}
    ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// `null` narrowing (spec 5.3 / phase 3 task 2)
// ---------------------------------------------------------------------------

test "a null guard narrows the value it names" {
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | null = req.url;
        \\    if (value !== null) {
        \\        return Response.json({ n: take(value) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "without the guard the same read is refused" {
    // The positive control for the test above: with no narrowing at all, both
    // programs would report the same count and neither would prove anything.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | null = req.url;
        \\    return Response.json({ n: take(value) });
        \\}
    ,
        1,
        "expected string, got string | null",
    );
}

test "an undefined guard does not remove null" {
    // Spec 5.3 keeps the two apart. `v !== undefined` over
    // `string | null | undefined` leaves `string | null`, so the call still
    // reports - the diagnostic is what proves the `null` member survived.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function handler(req: Request): Response {
        \\    const value: string | null | undefined = req.url;
        \\    if (value !== undefined) {
        \\        return Response.json({ n: take(value) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        1,
        "expected string, got string | null",
    );
}

test "a null guard over an optional type narrows nothing" {
    // `t_nullable` is `T | undefined` and carries no `null` member, so a
    // `null` test over it removes nothing and must not strip the optionality
    // the author declared.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function pick(value: string | undefined): Response {
        \\    if (value !== null) {
        \\        return Response.json({ n: take(value) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
        \\function handler(req: Request): Response {
        \\    return pick(req.url);
        \\}
    ,
        1,
        "expected string, got string | undefined",
    );
}

// ---------------------------------------------------------------------------
// `match` field bindings (spec 5.5 / phase 3 task 5)
// ---------------------------------------------------------------------------

const command_union =
    \\structural Command =
    \\  | { kind: "echo"; text: string }
    \\  | { kind: "ping" };
;

test "a shorthand binding carries the field type" {
    try checkTypedSource(
        command_union ++
            \\function take(s: string): number {
            \\    return s.length;
            \\}
            \\function run(command: Command): number {
            \\    return match (command) {
            \\        when { kind: "echo", text }: take(text)
            \\        when { kind: "ping" }: 0
            \\    };
            \\}
            \\function handler(req: Request): Response {
            \\    return Response.json({ n: run({ kind: "ping" }) });
            \\}
        ,
        0,
        null,
    );
}

test "a binding used against the wrong type is refused" {
    // The positive control: with no type on the binding, every use of it is
    // checked against nothing and this program passes too.
    try checkTypedSourceSaying(
        command_union ++
            \\function take(n: number): number {
            \\    return n;
            \\}
            \\function run(command: Command): number {
            \\    return match (command) {
            \\        when { kind: "echo", text }: take(text)
            \\        when { kind: "ping" }: 0
            \\    };
            \\}
            \\function handler(req: Request): Response {
            \\    return Response.json({ n: run({ kind: "ping" }) });
            \\}
        ,
        1,
        "expected number, got string",
    );
}

test "a rename binds the field under the new name" {
    try checkTypedSource(
        command_union ++
            \\function run(command: Command): string {
            \\    return match (command) {
            \\        when { kind: "echo", text: message }: message
            \\        when { kind: "ping" }: "pong"
            \\    };
            \\}
            \\function handler(req: Request): Response {
            \\    return Response.json({ s: run({ kind: "ping" }) });
            \\}
        ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// Type-test patterns (spec 5.5 / phase 3 task 6)
// ---------------------------------------------------------------------------

test "a type test narrows its arm" {
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function label(value: string | number): number {
        \\    return match (value) {
        \\        when string: take(value)
        \\        when number: 0
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: label(1) });
        \\}
    ,
        0,
        null,
    );
}

test "a type test does not narrow the arm it does not name" {
    // The positive control for the test above: if `when number:` narrowed to
    // `string` too, or narrowed nothing, this program would pass.
    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return s.length;
        \\}
        \\function label(value: string | number): number {
        \\    return match (value) {
        \\        when string: 0
        \\        when number: take(value)
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: label(1) });
        \\}
    ,
        1,
        "expected string, got number",
    );
}

test "the null literal and the four type tests exhaust JsonValue without a default" {
    try checkTypedSource(
        \\structural JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[];
        \\function depth(value: JsonValue): number {
        \\    return match (value) {
        \\        when null: 1
        \\        when boolean: 1
        \\        when number: 1
        \\        when string: 1
        \\        when array: 2
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ d: depth([1, "a"]) });
        \\}
    ,
        0,
        null,
    );
}

test "the six arms cover JsonValue with its Dict arm" {
    // Spec 16.3 in full: the null literal pattern plus the five type tests
    // cover the six value kinds exactly, so the match is exhaustive without a
    // `default` - which a closed union is required to do without.
    try checkTypedSource(
        \\structural JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[]
        \\  | Dict<string, JsonValue>;
        \\function kindOf(value: JsonValue): string {
        \\    return match (value) {
        \\        when null: "null"
        \\        when boolean: "boolean"
        \\        when number: "number"
        \\        when string: "string"
        \\        when array: "array"
        \\        when Dict: "dict"
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ k: kindOf(1) });
        \\}
    ,
        0,
        null,
    );
}

test "isDict narrows to the Dict member and leaves the rest to the else branch" {
    try checkTypedSource(
        \\function take(d: Dict<string, number>): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Dict<string, number> = "x";
        \\    if (isDict(v)) {
        \\        return Response.json({ n: take(v) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "without the isDict guard the same call is refused" {
    // The positive control: with no narrowing, both programs report the same
    // count and the test above proves nothing.
    try checkTypedSourceSaying(
        \\function take(d: Dict<string, number>): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Dict<string, number> = "x";
        \\    return Response.json({ n: take(v) });
        \\}
    ,
        1,
        "expected Dict<string, number>",
    );
}

test "a Bytes arm narrows in the arm it guards and not in the others" {
    // The binding's type inside the arm is `Bytes`, so a Bytes-taking helper
    // accepts it there; in a sibling arm the same name is still the union, and
    // the same call is refused. One program, both halves.
    try checkTypedSource(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function sizeOf(value: string | Bytes): number {
        \\    return match (value) {
        \\        when Bytes: take(value)
        \\        when string: 0
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: sizeOf("x") });
        \\}
    ,
        0,
        null,
    );

    try checkTypedSourceSaying(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function sizeOf(value: string | Bytes): number {
        \\    return match (value) {
        \\        when Bytes: 0
        \\        when string: take(value)
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: sizeOf("x") });
        \\}
    ,
        1,
        "expected Bytes",
    );
}

test "the request readers are typed, and their parameter is a Request" {
    // They are globals, so their signatures live in the same name-keyed map
    // the module exports use. Without that a call to one would infer nothing,
    // which is the state `Request` itself was in before this phase.
    try checkTypedSource(
        \\import { bytesLength } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: bytesLength(requestBody(req)) });
        \\}
    ,
        0,
        null,
    );

    // The return type is `Bytes`, which the encodability rule then refuses to
    // send - two rules meeting on one value, which is the check that the
    // reader's declared type is real rather than absent.
    try checkTypedSourceSaying(
        \\function handler(req: Request): Response {
        \\    return Response.json({ raw: requestBody(req) });
        \\}
    ,
        1,
        "Bytes is not a JSON value",
    );

    // The parameter is a `Request` and nothing else.
    try checkTypedSourceSaying(
        \\import { bytesLength } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: bytesLength(requestBody("nope")) });
        \\}
    ,
        1,
        "expected Request",
    );
}

test "Response.json refuses a payload JSON cannot carry" {
    // The failure exists today and has nowhere to go: `http.zig` calls
    // `valueToJsonString` with `try`, so a function-valued field throws, and
    // the subset has no `try/catch`. Deciding it from the type is what turns a
    // run-time throw into a diagnostic.
    try checkTypedSourceSaying(
        \\function helper(n: number): number {
        \\    return n;
        \\}
        \\function handler(req: Request): Response {
        \\    const f: (n: number) => number = helper;
        \\    return Response.json({ f: f });
        \\}
    ,
        1,
        "is not a JSON value",
    );

    // A whole request, whose `text` and `json` fields are functions. Sending
    // one would throw at the first of them.
    try checkTypedSourceSaying(
        \\function handler(req: Request): Response {
        \\    return Response.json({ r: req });
        \\}
    ,
        1,
        "is not a JSON value",
    );

    // A Bytes is an octet buffer, not a JSON value.
    try checkTypedSourceSaying(
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ raw: encodeUtf8("hi") });
        \\}
    ,
        1,
        "is not a JSON value",
    );

    // And nested, because a payload is usually a record of records.
    try checkTypedSourceSaying(
        \\import { encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    return Response.json({ outer: { inner: [encodeUtf8("hi")] } });
        \\}
    ,
        1,
        "is not a JSON value",
    );
}

test "Response.json refuses a bare function name in an object literal with ZTS213" {
    // A function value has a function type, so `{ f: helper }` infers a record
    // whose field is a function, and the encodability walk refuses it.
    try expectOnlyDiagnostic(
        \\function helper(n: number): number {
        \\    return n;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ f: helper });
        \\}
    , .unencodable_json_payload);
}

test "Response.json still admits every payload JSON can carry" {
    // The other half. Without it the test above passes for a checker that
    // refuses everything, and the rule would be unusable rather than wrong.
    try checkTypedSource(
        \\import { encodeBase64, encodeUtf8 } from "zttp:bytes";
        \\function handler(req: Request): Response {
        \\    const nested = { id: "a", counts: [1, 2, 3], flag: true, missing: null };
        \\    return Response.json({ nested: nested, encoded: encodeBase64(encodeUtf8("hi")), n: 1 });
        \\}
    ,
        0,
        null,
    );

    // `unknown` is admitted deliberately: it is what a `Result` payload types
    // as, and refusing it would reject `Response.json(parsed.value)` in every
    // handler that has one. The checker reports where it knows and stays quiet
    // where it does not.
    try checkTypedSource(
        \\import { parseJson } from "zttp:json";
        \\function handler(req: Request): Response {
        \\    const parsed = parseJson("{}");
        \\    if (!parsed.ok) return Response.json({ error: parsed.error });
        \\    return Response.json({ data: parsed.value });
        \\}
    ,
        0,
        null,
    );
}

test "a request field reads its declared type end to end" {
    // `Request` was a name resolving to nothing, so every read off a request
    // answered nothing and a typo was as silent as a correct field. These are
    // the two halves: a declared field types, and passing an absent-capable
    // one where a `string` is wanted now reports.
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: take(req.method), u: take(req.url) });
        \\}
    ,
        0,
        null,
    );

    try checkTypedSourceSaying(
        \\function take(s: string): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: take(req.body) });
        \\}
    ,
        1,
        "expected string, got string | undefined",
    );

    // And the narrowing an author writes discharges it.
    try checkTypedSource(
        \\function take(s: string): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ n: take(req.body ?? "") });
        \\}
    ,
        0,
        null,
    );
}

test "isBytes narrows to the Bytes member and leaves the rest to the else branch" {
    try checkTypedSource(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Bytes = "x";
        \\    if (isBytes(v)) {
        \\        return Response.json({ n: take(v) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "without the isBytes guard the same call is refused" {
    // The positive control: with no narrowing, both programs report the same
    // count and the test above proves nothing.
    try checkTypedSourceSaying(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | Bytes = "x";
        \\    return Response.json({ n: take(v) });
        \\}
    ,
        1,
        "expected Bytes",
    );
}

test "isBytes refines unknown, which is where the guard is written" {
    // A `Result`-returning export types its payload `unknown`, so this is the
    // site the guard exists for. Without the refinement the narrowed value is
    // still `unknown` and every use of it is refused.
    try checkTypedSource(
        \\function take(b: Bytes): number {
        \\    return 1;
        \\}
        \\function handler(req: Request): Response {
        \\    const v: unknown = 1;
        \\    if (isBytes(v)) {
        \\        return Response.json({ n: take(v) });
        \\    }
        \\    return Response.json({ n: 0 });
        \\}
    ,
        0,
        null,
    );
}

test "the recursive fold over JsonValue type-checks" {
    // Spec 16.3 minus its Dict arm: the array arm recurses through the same
    // alias, which is what the contractive rule exists to admit.
    try checkTypedSource(
        \\structural JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[];
        \\function deeper(maximum: number, child: JsonValue): number {
        \\    const childDepth = depth(child);
        \\    return childDepth > maximum ? childDepth : maximum;
        \\}
        \\function depth(value: JsonValue): number {
        \\    return match (value) {
        \\        when null: 1
        \\        when boolean: 1
        \\        when number: 1
        \\        when string: 1
        \\        when array: value.reduce(deeper, 0) + 1
        \\    };
        \\}
        \\function handler(req: Request): Response {
        \\    return Response.json({ d: depth([1, "a"]) });
        \\}
    ,
        0,
        null,
    );
}

// ---------------------------------------------------------------------------
// Contractive recursive aliases (spec 5.7 / phase 3 task 4)
// ---------------------------------------------------------------------------

test "a recursive alias guarded by an array is accepted" {
    try checkTypedSource(
        \\structural JsonValue =
        \\  | null
        \\  | boolean
        \\  | number
        \\  | string
        \\  | readonly JsonValue[];
        \\function handler(req: Request): Response {
        \\    const value: JsonValue = [1, "a", [true, null]];
        \\    return Response.json({ value: value });
        \\}
    ,
        0,
        null,
    );
}

test "a recursive alias guarded by a record is accepted" {
    try checkTypedSource(
        \\structural Tree = { value: number; children: readonly Tree[] };
        \\function handler(req: Request): Response {
        \\    const t: Tree = { value: 1, children: [] };
        \\    return Response.json({ v: t.value });
        \\}
    ,
        0,
        null,
    );
}

test "a direct cycle is refused" {
    try checkTypedSourceSaying(
        \\structural Loop = Loop;
        \\function handler(req: Request): Response {
        \\    const v: Loop = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        "recursive type alias 'Loop' has a cycle no data constructor guards",
    );
}

test "a union edge does not guard a cycle" {
    // The union member is where the recursion sits, and a union is not a data
    // constructor. `type U = number | U` describes no finite value.
    try checkTypedSourceSaying(
        \\structural U = number | U;
        \\function handler(req: Request): Response {
        \\    const v: U = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        "has a cycle no data constructor guards",
    );
}

test "a Bytes member does not disturb a recursive alias either way" {
    // `Bytes` is a leaf: it takes no type parameter and holds no member type,
    // so it can neither guard a cycle nor close one, and the guard set does not
    // mention it. Measured rather than argued - adding `.t_bytes` to the guard
    // set in `type_env.reachesUnguarded` changes neither of these two programs,
    // because in the first the cycle runs through the union and in the second
    // it runs through the record.
    //
    // A record guards, so the alias is contractive and the Bytes field rides
    // along.
    try checkTypedSource(
        \\structural Chunk = { data: Bytes; next: Chunk | null };
        \\function handler(req: Request): Response {
        \\    return Response.json({ ok: true });
        \\}
    ,
        0,
        null,
    );

    // A union does not, so the same member cannot rescue it. ZTS212 fires
    // where a declared annotation names the alias, which is why the binding is
    // here and not just the alias.
    try checkTypedSourceSaying(
        \\structural B = Bytes | B;
        \\function handler(req: Request): Response {
        \\    const v: B = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        "has a cycle no data constructor guards",
    );
}

test "a cycle through two names is refused" {
    try checkTypedSourceSaying(
        \\structural A = B;
        \\structural B = A;
        \\function handler(req: Request): Response {
        \\    const v: A = 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        "has a cycle no data constructor guards",
    );
}

test "negative recursion through a function parameter is refused" {
    try checkTypedSourceSaying(
        \\structural Neg = (value: Neg) => number;
        \\function handler(req: Request): Response {
        \\    const v: Neg = (value) => 1;
        \\    return Response.json({ ok: true });
        \\}
    ,
        1,
        "recursive type alias 'Neg' has a cycle no data constructor guards",
    );
}

// ---------------------------------------------------------------------------
// Type predicates (D1 / plan task 6)
// ---------------------------------------------------------------------------

test "an admitted type predicate narrows at its call site" {
    // The narrowed type is `string`, so assigning it to `number` is the error.
    // Before the predicate was read, the binding stayed `string | number` and
    // the same program reported the same count for the wrong reason - hence the
    // companion test below, which pins that the un-narrowed type is different.
    try checkTypedSource(
        \\function isString(v: string | number): v is string {
        \\    return typeof v === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        0,
        null,
    );
}

test "a predicate whose body calls a function installs no guard" {
    // Two errors: the predicate itself (ZTS211), and the assignment that the
    // missing narrowing leaves unproven. The second is what makes this test
    // non-vacuous - it shows the guard really was withheld, not merely
    // reported.
    try checkTypedSource(
        \\function helper(v: string | number): boolean {
        \\    return typeof v === "string";
        \\}
        \\function isString(v: string | number): v is string {
        \\    return helper(v);
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        null,
    );
}

test "a call that merely carries a callback keeps its mismatch at the outer return" {
    // The counterpart to the test above, and the boundary the relocation must
    // respect. `apply` declares `string`, not a type read from its argument, so
    // the returned value is wrong at line 3 and no edit inside the callback can
    // fix it. Reading only the argument tags relocated this one too, which is
    // the same wrong-attribution defect - pointed at a line whose edit cannot
    // clear the error - for every higher-order helper: mapResult, andThen,
    // dictFold, and any the author writes.
    const allocator = std.testing.allocator;
    const source =
        \\function apply(f: () => string): string { return f(); }
        \\export function handler(req: Request): Response {
        \\  return apply(() => {
        \\    return "x";
        \\  });
        \\}
    ;

    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);

    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });

    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    _ = try checker.check(root);

    var saw = false;
    for (checker.getDiagnostics()) |diag| {
        if (diag.kind != .return_type_mismatch) continue;
        saw = true;
        const loc = ir_view.getLoc(diag.node) orelse return error.TestExpectedLocation;
        // Line 3 is `return apply(...)`; line 4 is the callback's return.
        try std.testing.expectEqual(@as(u32, 3), loc.line);
    }
    try std.testing.expect(saw);
}

test "a predicate that returns a bare literal proves nothing" {
    try checkTypedSource(
        \\function isString(v: string | number): v is string {
        \\    return true;
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        2,
        null,
    );
}

test "a predicate that tests a different parameter is refused" {
    try checkTypedSource(
        \\function isString(v: string | number, other: string | number): v is string {
        \\    return typeof other === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number = 1;
        \\    if (isString(raw, "x")) {
        \\        return Response.json({ ok: true });
        \\    }
        \\    return Response.json({ ok: false });
        \\}
    ,
        1,
        null,
    );
}

test "admitted tests combine with && and !" {
    try checkTypedSource(
        \\function isText(v: string | number | undefined): v is string {
        \\    return v !== undefined && typeof v === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: string | number | undefined = 1;
        \\    if (isText(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    ,
        0,
        null,
    );
}

test "a typeof object test over unknown does not back an object claim" {
    // `typeof null === "object"`, so `typeof x === "object"` over `unknown`
    // does not prove `object`. The test is well formed, and the claim is
    // refused because the test does not prove it.
    try expectOnlyDiagnostic(
        \\function isObject(x: unknown): x is object {
        \\    return typeof x === "object";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: unknown = 1;
        \\    if (isObject(raw)) {
        \\        return Response.json({ ok: true });
        \\    }
        \\    return Response.json({ ok: false });
        \\}
    , .invalid_type_predicate);
}

// T1 (D21): a call in a member base, a computed key, or a spread operand.

/// `mkArr` takes a `string`; `expr` passes it a number in some position.
fn mkArrCall(comptime expr: []const u8) []const u8 {
    return
    \\function mkArr(s: string): number[] {
    \\  return [s.length];
    \\}
    \\function run(): number {
    \\  const r =
    ++ " " ++ expr ++ ";\n" ++
        \\  return 1;
        \\}
    ;
}

test "a call in a member base, a computed key, or a spread operand is checked" {
    // The walk had no arm for these tags and ended in `else => {}`, so the
    // call under them was never checked against `mkArr`'s signature.
    try expectKindCounts(mkArrCall("mkArr(1)"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(mkArrCall("mkArr(1).length"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(mkArrCall("mkArr(1)?.length"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(mkArrCall("[1, 2][mkArr(1).length]"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(mkArrCall("[...mkArr(1)]"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(mkArrCall("{ ...{ v: mkArr(1) } }"), .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 });
    try expectKindCounts(mkArrCall("[...mkArr(\"a\")]"), .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 });
}

// T2 (D16, D23): a kill inside a branch survives the branch.

/// A `run` whose `x` is narrowed to `string` by an early-return guard. `middle`
/// follows the guard and `needS(x)` follows `middle`.
fn narrowedThen(comptime middle: []const u8) []const u8 {
    const head =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined, c: boolean, d: boolean): number {
        \\  let x: string | undefined = input;
        \\  let n = 0;
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
    ;
    const tail =
        \\  return needS(x) + n;
        \\}
    ;
    return head ++ "\n" ++ middle ++ "\n" ++ tail;
}

const refused_once: KindCounts = .{ .arg_type = 1, .return_type = 0, .ambiguous = 0 };
const accepted: KindCounts = .{ .arg_type = 0, .return_type = 0, .ambiguous = 0 };

test "narrowing: a kill in a branch that falls through survives the branch" {
    // br_assign. The branch scope restored the narrowing on the way out, so the
    // kill inside it was undone and `needS(x)` read `string`.
    try expectKindCounts(narrowedThen("  if (c) {\n    x = undefined;\n  }"), refused_once);
    // Control: the branch changes another binding, and `x` stays narrowed.
    try expectKindCounts(narrowedThen("  if (c) {\n    n = 1;\n  }"), accepted);
    // The same kill outside a branch is refused (br_ctrl).
    try expectKindCounts(narrowedThen("  x = undefined;"), refused_once);
}

test "narrowing: a kill in the else branch or in a nested branch survives" {
    try expectKindCounts(narrowedThen("  if (c) {\n    n = 1;\n  } else {\n    x = undefined;\n  }"), refused_once);
    try expectKindCounts(narrowedThen("  if (c) {\n    if (d) {\n      x = undefined;\n    }\n  }"), refused_once);
    try expectKindCounts(
        narrowedThen("  if (c) {\n    if (d) {\n      n = 1;\n    }\n  }"),
        accepted,
    );
}

test "narrowing: a kill in a branch that cannot fall through is not applied at the join" {
    // p11_then_return_kill. The branch returns after the kill, so no path from
    // it reaches `needS(x)`.
    try expectKindCounts(narrowedThen("  if (c) {\n    x = undefined;\n    return 1;\n  }"), accepted);
    // p5_else_leak. Only the then branch reaches the join, and it kills nothing.
    // The else branch returns, and it is walked without the then branch's kills.
    try expectKindCounts(
        narrowedThen("  if (c) {\n    n = 1;\n  } else {\n    x = undefined;\n    return 1;\n  }"),
        accepted,
    );
    try expectKindCounts(
        narrowedThen("  if (c) {\n    x = undefined;\n  } else {\n    return needS(x);\n  }"),
        refused_once, // the then branch falls through with the kill, the else read is fine
    );
}

test "narrowing: a kill in one branch does not reach the other branch" {
    // The else branch reads `x` after the then branch killed it. The read is on
    // a path where the kill never ran.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined, c: boolean): number {
        \\  let x: string | undefined = input;
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  if (c) {
        \\    x = undefined;
        \\    return 1;
        \\  } else {
        \\    return needS(x);
        \\  }
        \\}
    , accepted);
}

test "narrowing: assigning a string in a branch loses the narrowing (accepted precision cost)" {
    // p6_assign_string_in_branch. `x` is a `string` on both paths, but the join
    // keeps no assignment narrowing, so the narrowing is dropped.
    try expectKindCounts(narrowedThen("  if (c) {\n    x = \"other\";\n  }"), refused_once);
}

test "narrowing: a narrowing installed inside a branch is undone after it" {
    const head =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined, c: boolean): number {
        \\  let x: string | undefined = input;
    ;
    try expectKindCounts(
        head ++
            \\
            \\  if (c) {
            \\    if (x === undefined) {
            \\      return 0;
            \\    }
            \\  }
            \\  return needS(x);
            \\}
        ,
        refused_once,
    );
    // Control: the guard is outside the branch.
    try expectKindCounts(
        head ++
            \\
            \\  if (x === undefined) {
            \\    return 0;
            \\  }
            \\  if (c) {
            \\    return 2;
            \\  }
            \\  return needS(x);
            \\}
        ,
        accepted,
    );
}

/// A `run` whose condition is `cond`, where `x` is a `string | undefined`.
fn conditionThen(comptime cond: []const u8) []const u8 {
    return
    \\function needS(s: string): number {
    \\  return s.length;
    \\}
    \\function run(input: string | undefined): number {
    \\  let x: string | undefined = input;
    \\  const ok = 
    ++ cond ++ ";\n" ++
        \\  return ok ? 1 : 0;
        \\}
    ;
}

test "narrowing: a kill inside a left operand voids the guard read from its syntax" {
    // reinstall_and. `installBranchNarrowing` read `x !== undefined` from the
    // left operand's syntax after the operand ran, and put the narrowing back
    // over the kill.
    try expectKindCounts(
        conditionThen("x !== undefined && (x = undefined) === undefined && needS(x) > 0"),
        refused_once,
    );
    // Control: the operand in the middle kills nothing.
    try expectKindCounts(
        conditionThen("x !== undefined && (input === undefined) === false && needS(x) > 0"),
        accepted,
    );
    // The same chain under `||`: the right operand runs when the left is false.
    try expectKindCounts(
        conditionThen("x === undefined || (x = undefined) === undefined || needS(x) > 0"),
        refused_once,
    );
}

test "narrowing: a kill in the right operand of && survives the expression" {
    try expectKindCounts(
        narrowedThen("  const k = c && (x = undefined) === undefined;"),
        refused_once,
    );
    try expectKindCounts(
        narrowedThen("  const k = c && n === 0;"),
        accepted,
    );
}

test "narrowing: a kill in an if condition is seen in the branch and after it" {
    // The condition is a conjunction, so it installs no guard of its own. The
    // kill in its right operand holds in the branch (one refusal) and after
    // the `if` (the second).
    try expectKindCounts(
        narrowedThen("  if (x !== undefined && (x = undefined) === undefined) {\n    n = needS(x);\n  }"),
        .{ .arg_type = 2, .return_type = 0, .ambiguous = 0 },
    );
}

test "narrowing: a kill in a match arm survives the match" {
    // The arm assigns a binding narrowed before the match. Nothing used to
    // restore it, and the kill was already lost to the arm's own scope in the
    // discriminant case below.
    const other =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined, m: { kind: "a" } | { kind: "b" }): number {
        \\  let x: string | undefined = input;
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  const k = match (m) {
        \\    when { kind: "a" }: ARM
        \\    default: 0
        \\  };
        \\  return needS(x) + k;
        \\}
    ;
    try expectKindCounts(replaceArm(other, "((x = undefined) === undefined ? 1 : 2)"), refused_once);
    try expectKindCounts(replaceArm(other, "(x === undefined ? 1 : 2)"), accepted);
}

test "narrowing: an arm that assigns the narrowed scrutinee keeps the kill" {
    // The match restored the discriminant's saved narrowing by hand after the
    // arm, which put it back over the arm's own assignment.
    const disc =
        \\function needAB(m: { kind: "a", v: string } | { kind: "b", n: number }): number {
        \\  return 1;
        \\}
        \\function run(
        \\  p: { kind: "a", v: string } | { kind: "b", n: number } | undefined,
        \\  q: { kind: "a", v: string } | { kind: "b", n: number } | undefined,
        \\): number {
        \\  let m: { kind: "a", v: string } | { kind: "b", n: number } | undefined = p;
        \\  if (m === undefined) {
        \\    return 0;
        \\  }
        \\  const k = match (m) {
        \\    when { kind: "a" }: ARM
        \\    default: 0
        \\  };
        \\  return needAB(m) + k;
        \\}
    ;
    try expectKindCounts(replaceArm(disc, "((m = q) === undefined ? 1 : 2)"), refused_once);
    try expectKindCounts(replaceArm(disc, "1"), accepted);
}

/// Replace the `ARM` marker in `source` with `arm`.
fn replaceArm(comptime source: []const u8, comptime arm: []const u8) []const u8 {
    const at = comptime std.mem.indexOf(u8, source, "ARM").?;
    return source[0..at] ++ arm ++ source[at + 3 ..];
}

test "narrowing: a kill in a for...of body survives the loop" {
    // The loop restores the narrowing from before the body; the kill comes back
    // after the loop.
    try expectKindCounts(
        narrowedThen("  for (const i of [1, 2]) {\n    if (c) {\n      x = undefined;\n    }\n  }"),
        refused_once,
    );
    try expectKindCounts(
        narrowedThen("  for (const i of [1, 2]) {\n    if (c) {\n      n = i;\n    }\n  }"),
        accepted,
    );
}

test "narrowing: a nested function body kills nothing where it is declared" {
    // The body has not run at the declaration. A call that runs it is not
    // modelled here.
    try expectKindCounts(
        narrowedThen("  const clear = (): number => {\n    x = undefined;\n    return 1;\n  };"),
        accepted,
    );
    // What the body installs does not leak out of it either: `y` is narrowed
    // only inside the closure.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  const f = (y: string | undefined): number => {
        \\    if (y === undefined) {
        \\      return 0;
        \\    }
        \\    return needS(y);
        \\  };
        \\  return f(input) + needS(input);
        \\}
    , refused_once);
}

/// A branch that assigns each of `count` bindings, and then `x` when `kill_x`.
fn manyKills(comptime count: usize, comptime kill_x: bool) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime var decls: []const u8 = "";
    comptime var kills: []const u8 = "";
    inline for (0..count) |i| {
        const name = std.fmt.comptimePrint("v{d}", .{i});
        decls = decls ++ "  let " ++ name ++ ": number = 0;\n";
        kills = kills ++ "    " ++ name ++ " = 1;\n";
    }
    if (kill_x) kills = kills ++ "    x = undefined;\n";
    return
    \\function needS(s: string): number {
    \\  return s.length;
    \\}
    \\function run(input: string | undefined, c: boolean): number {
    \\  let x: string | undefined = input;
    \\  if (x === undefined) {
    \\    return 0;
    \\  }
    ++ "\n" ++ decls ++ "  if (c) {\n" ++ kills ++ "  }\n" ++
        \\  return needS(x);
        \\}
    ;
}

test "narrowing: more kills than the join buffer holds still kill every narrowing" {
    // `x` is killed after forty other bindings, so a join that kept only the
    // first keys would lose it. Overflow stands for every key.
    try expectKindCounts(manyKills(40, true), refused_once);
    // Overflow drops every narrowing, so `x` goes too although this branch
    // never assigns it. That is the accepted cost of a bounded buffer.
    try expectKindCounts(manyKills(40, false), refused_once);
    // Control: a few kills fit the buffer, and `x` keeps its narrowing.
    try expectKindCounts(manyKills(3, false), accepted);
    try expectKindCounts(manyKills(3, true), refused_once);
}

/// The `type_mismatch` diagnostics (ZTS200) `source` produces.
fn expectTypeMismatches(source: []const u8, expected: usize) !void {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator, source, false);
    defer freeSeenDiagnostics(allocator, seen);
    const actual = countKind(seen, .type_mismatch);
    if (actual != expected) {
        for (seen) |d| std.debug.print("diagnostic: {s}\n", .{d.message});
    }
    try std.testing.expectEqual(expected, actual);
}

test "capture: an assignment through a captured let is checked against its declared type" {
    // cap_assign.ts. The target is an `upvalue` reference, whose key is not the
    // declaration's, so the assignment lookup found no type and checked nothing.
    const head =
        \\function run(input: string | undefined): number {
        \\  let x: string = "a";
        \\  const f = (): number => {
        \\    x = VALUE;
        \\    return 1;
        \\  };
        \\  return f();
        \\}
    ;
    try expectTypeMismatches(withMarker(head, "VALUE", "input"), 1);
    // A value the declared type admits passes through the capture.
    try expectTypeMismatches(withMarker(head, "VALUE", "\"b\""), 0);
    // Control: the same assignment outside the closure.
    try expectTypeMismatches(
        \\function run(input: string | undefined): number {
        \\  let x: string = "a";
        \\  x = input;
        \\  return 1;
        \\}
    , 1);
}

test "capture: an assignment through a transitive capture is checked" {
    // The inner closure's upvalue names the declaration in `run`, two functions
    // out, through the middle closure's own upvalue.
    const source =
        \\function run(input: string | undefined): number {
        \\  let x: string = "a";
        \\  const outer = (): number => {
        \\    const inner = (): number => {
        \\      x = VALUE;
        \\      return 1;
        \\    };
        \\    return inner();
        \\  };
        \\  return outer();
        \\}
    ;
    try expectTypeMismatches(withMarker(source, "VALUE", "input"), 1);
    try expectTypeMismatches(withMarker(source, "VALUE", "\"b\""), 0);
}

test "capture: an assignment to a captured parameter is checked" {
    const source =
        \\function run(x: string, input: string | undefined): number {
        \\  const f = (): number => {
        \\    x = VALUE;
        \\    return 1;
        \\  };
        \\  return f();
        \\}
    ;
    try expectTypeMismatches(withMarker(source, "VALUE", "input"), 1);
    try expectTypeMismatches(withMarker(source, "VALUE", "\"b\""), 0);
}

test "assignment: a parameter is checked against its declared type" {
    // p16_param_assign.ts. The assignment arm read `binding_types`, which holds
    // no parameter, so the check was skipped.
    const source =
        \\function run(x: string, input: string | undefined): number {
        \\  x = VALUE;
        \\  return 1;
        \\}
    ;
    try expectTypeMismatches(withMarker(source, "VALUE", "input"), 1);
    try expectTypeMismatches(withMarker(source, "VALUE", "\"b\""), 0);
    // Control p16_ctrl.ts: a `let` with the same declared type.
    try expectTypeMismatches(
        \\function run(input: string | undefined): number {
        \\  let x: string = "a";
        \\  x = input;
        \\  return 1;
        \\}
    , 1);
}

/// Replace the first `marker` in `source` with `value`.
fn withMarker(comptime source: []const u8, comptime marker: []const u8, comptime value: []const u8) []const u8 {
    const at = comptime std.mem.indexOf(u8, source, marker).?;
    return source[0..at] ++ value ++ source[at + marker.len ..];
}

test "capture: a closure over a for...of binding reads that binding, not an outer name" {
    // p1_unsound.ts and p1_forof_shadow.ts. `i` is a `for...of` binding, which
    // no name search saw, so the capture resolved to the parameter `i`.
    const source =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(items: ELEM[], i: OUTER): number {
        \\  let n = 0;
        \\  for (const i of items) {
        \\    const g = (): number => needS(i);
        \\    n = n + g();
        \\  }
        \\  return n;
        \\}
    ;
    // The element can be undefined and the outer `i` is a string: refused.
    try expectKindCounts(withMarker(withMarker(source, "ELEM", "(string | undefined)"), "OUTER", "string"), refused_once);
    // The element is a string and the outer `i` is a number: accepted.
    try expectKindCounts(withMarker(withMarker(source, "ELEM", "string"), "OUTER", "number"), accepted);
    // Control p1_unsound_direct.ts: the same call outside the closure.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(items: (string | undefined)[]): number {
        \\  let n = 0;
        \\  for (const i of items) {
        \\    n = n + needS(i);
        \\  }
        \\  return n;
        \\}
    , refused_once);
    // Control p1_ctrl.ts: no outer name to confuse it with.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(items: string[]): number {
        \\  let n = 0;
        \\  for (const i of items) {
        \\    const g = (): number => needS(i);
        \\    n = n + g();
        \\  }
        \\  return n;
        \\}
    , accepted);
}

test "capture: a closure over a match pattern binding reads that binding" {
    // p2_unsound.ts and p2_match_binding.ts. A name search did not see the
    // pattern binding `text`, so the capture resolved to the parameter `text`.
    const source =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(m: { kind: "a"; text: FIELD } | { kind: "b" }, text: OUTER): number {
        \\  return match (m) {
        \\    when { kind: "a", text }: ((): number => needS(text))()
        \\    default: 0
        \\  };
        \\}
    ;
    try expectKindCounts(withMarker(withMarker(source, "FIELD", "string | undefined"), "OUTER", "string"), refused_once);
    try expectKindCounts(withMarker(withMarker(source, "FIELD", "string"), "OUTER", "number"), accepted);
    // Control p2_unsound_direct.ts: the same call outside the closure.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(m: { kind: "a"; text: string | undefined } | { kind: "b" }): number {
        \\  return match (m) {
        \\    when { kind: "a", text }: needS(text)
        \\    default: 0
        \\  };
        \\}
    , refused_once);
    // Control p2_ctrl.ts: no outer name to confuse it with.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(m: { kind: "a"; text: string } | { kind: "b" }): number {
        \\  return match (m) {
        \\    when { kind: "a", text }: ((): number => needS(text))()
        \\    default: 0
        \\  };
        \\}
    , accepted);
}

test "capture: a captured binding is typed from its declaration and not from the narrowing at the closure" {
    // The closure can run when the narrowing no longer holds, so it reads the
    // declared type `string | undefined` and the call is refused.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  if (input === undefined) {
        \\    return 0;
        \\  }
        \\  const g = (): number => needS(input);
        \\  return g();
        \\}
    , refused_once);
    // A guard inside the closure narrows the captured name there.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  const g = (): number => {
        \\    if (input === undefined) {
        \\      return 0;
        \\    }
        \\    return needS(input);
        \\  };
        \\  return g();
        \\}
    , accepted);
}

test "capture: without the parser record a captured binding has no type" {
    // The same source as the refusal above, from a caller that sets no
    // `scopes`. The capture is unknown: nothing is checked and nothing is
    // granted, and no name search finds the parameter instead.
    const allocator = std.testing.allocator;
    const source =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(items: (string | undefined)[], i: string): number {
        \\  let n = 0;
        \\  for (const i of items) {
        \\    const g = (): number => needS(i);
        \\    n = n + g();
        \\  }
        \\  return n;
        \\}
    ;
    const without = try typedDiagnosticsImpl(allocator, source, false, false, false);
    defer freeSeenDiagnostics(allocator, without);
    try std.testing.expectEqual(@as(usize, 0), countKind(without, .arg_type_mismatch));
    const with = try typedDiagnosticsImpl(allocator, source, false, false, true);
    defer freeSeenDiagnostics(allocator, with);
    try std.testing.expectEqual(@as(usize, 1), countKind(with, .arg_type_mismatch));
}

// T4 (D14): a call can run a closure that assigns an outer binding.

/// `narrowedThen` with a closure that clears `x`, then `middle`.
fn narrowedThenClear(comptime middle: []const u8) []const u8 {
    return narrowedThen(
        "  const clear = (): number => {\n    x = undefined;\n    return 1;\n  };\n" ++ middle,
    );
}

test "call kill: a call after a narrowing reads the declared type when a closure clears it" {
    // o1.ts, with the return type written so that ZTS600 does not hide it.
    try expectKindCounts(narrowedThenClear("  n = clear();"), refused_once);
    // The callee need not be the closure: the analyzer cannot tell which
    // closure a call reaches, so any call kills.
    try expectKindCounts(narrowedThenClear("  n = needS(\"a\");"), refused_once);
    try expectKindCounts(narrowedThenClear("  n = [1, 2].length + needS(\"a\");"), refused_once);
}

test "call kill: the arguments run before the call" {
    // `need(clear(), x)`: the inner call kills the narrowing before `x` is read.
    try expectKindCounts(
        \\function need(n: number, s: string): number {
        \\  return n + s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  let x: string | undefined = input;
        \\  const clear = (): number => {
        \\    x = undefined;
        \\    return 1;
        \\  };
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  return need(clear(), x);
        \\}
    , refused_once);
    // Control: the same call with the arguments in an order that reads `x`
    // first still checks `x` before the outer call kills.
    try expectKindCounts(
        \\function need(s: string, n: number): number {
        \\  return n + s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  let x: string | undefined = input;
        \\  const clear = (): number => {
        \\    x = undefined;
        \\    return 1;
        \\  };
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  return need(x, 1);
        \\}
    , accepted);
}

test "call kill: a call inside a loop body or an && chain kills for what follows" {
    // p8_loop_call.ts. The loop body's kill reaches the join after the loop.
    try expectKindCounts(
        narrowedThenClear("  for (const i of [1, 2]) {\n    n = n + clear();\n  }"),
        refused_once,
    );
    // p15_and_chain_reinstall.ts. `clear()` in the middle of the chain voids
    // the guard that the left operand installed.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  let x: string | undefined = input;
        \\  const clear = (): number => {
        \\    x = undefined;
        \\    return 1;
        \\  };
        \\  const ok = x !== undefined && clear() === 1 && needS(x) > 0;
        \\  if (ok) {
        \\    return 1;
        \\  }
        \\  return 0;
        \\}
    , refused_once);
}

test "call kill: a function that assigns a module-level let kills after a call to it" {
    const source =
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\let g: string | undefined = "a";
        \\function reset(): number {
        \\  g = undefined;
        \\  return 1;
        \\}
        \\function run(): number {
        \\  if (g === undefined) {
        \\    return 0;
        \\  }
        \\  const c = reset();
        \\  return needS(g) + c;
        \\}
    ;
    try expectKindCounts(source, refused_once);
}

test "call kill: no closure writes an outer binding, so a call keeps the narrowing" {
    // A closure that writes only its own local, and a function that reads a
    // module-level let, are not writes to an outer binding.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function log(n: number): number {
        \\  const own = n;
        \\  return own;
        \\}
        \\function run(input: string | undefined): number {
        \\  const x: string | undefined = input;
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  const c = log(1);
        \\  return needS(x) + c;
        \\}
    , accepted);
}

test "call kill: a closure that is declared and never called leaves a later read alone" {
    // p12_closure_decl_call.ts. The program-wide flag is set, because `clear`
    // writes `x`. Every call is walked with the kill, but no call comes between
    // the guard and `needS(x)`: the call in `g`'s body is in a nested scope
    // whose kills are discarded at its declaration, and `needS(x)` checks its
    // argument before its own kill.
    try expectKindCounts(
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function log(n: number): number {
        \\  return n;
        \\}
        \\function run(input: string | undefined): number {
        \\  let x: string | undefined = input;
        \\  const clear = (): number => {
        \\    x = undefined;
        \\    return 1;
        \\  };
        \\  if (x === undefined) {
        \\    return 0;
        \\  }
        \\  const g = (): number => {
        \\    return log(1);
        \\  };
        \\  return needS(x);
        \\}
    , accepted);
}

/// Check `source` and return the checker's error count and the pool node count.
fn checkTypedSourceNodes(source: []const u8, nodes: *usize) !u32 {
    const allocator = std.testing.allocator;
    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    const root = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    @import("module_types.zig").populateModuleTypes(&env, &pool, allocator);
    abi_types.populateHandlerAbiTypes(&env, &pool, allocator);
    try env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } });
    var checker = TypeChecker.init(allocator, ir_view, &atoms, &env);
    checker.scopes = &parser.scopes;
    defer checker.deinit();
    const errors = try checker.check(root);
    try checker.ensureHealthy();
    nodes.* = pool.nodes.items.len;
    return errors;
}

fn additionChainSource(allocator: std.mem.Allocator, terms: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "function handler(req: Request): Response {\n  const x = 1");
    for (1..terms) |_| try buf.appendSlice(allocator, "+1");
    try buf.appendSlice(allocator, ";\n  return Response.text(String(x));\n}\n");
    return buf.toOwnedSlice(allocator);
}

test "a 511-term addition chain type-checks" {
    const allocator = std.testing.allocator;
    const source = try additionChainSource(allocator, 511);
    defer allocator.free(source);
    var nodes: usize = 0;
    try std.testing.expectEqual(@as(u32, 0), try checkTypedSourceNodes(source, &nodes));
    // Measured: 83 nodes at 1, 100, and 300 terms. A fresh literal node per prefix gave n(n+1)/2.
    try std.testing.expect(nodes <= 2 * 511);
}

test "a 2500-alias chain reports no ZTS200" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "structural T0 = { a: number };\n");
    for (1..2500) |i| try buf.print(allocator, "structural T{d} = T{d};\n", .{ i, i - 1 });
    try buf.appendSlice(allocator, "function handler(req: Request): Response {\n  const v: T1 = { a: 1 };\n  return Response.text(String(v.a));\n}\n");
    var nodes: usize = 0;
    try std.testing.expectEqual(@as(u32, 0), try checkTypedSourceNodes(buf.items, &nodes));
    try std.testing.expect(nodes <= 2 * 2500);
}

test "an intersection over an alias reference reports no ZTS200" {
    try expectTypeMismatches(
        \\structural A = { a: number };
        \\structural B = A & { b: number };
        \\const value: B = { a: 1, b: 2 };
    , 0);
    try expectTypeMismatches(
        \\structural A = { a: number };
        \\structural B = A & { b: number };
        \\const value: B = { b: 2 };
    , 1);
    try expectTypeMismatches(
        \\structural A = { a: number };
        \\structural B = A & { b: number };
        \\const value: B = { a: "x", b: 2 };
    , 1);
    try expectTypeMismatches(
        \\structural B = Missing & { b: number };
        \\const value: B = { b: 2 };
    , 1);
}

test "field names that differ after byte 255 are distinct types" {
    const allocator = std.testing.allocator;
    const prefix = try allocator.alloc(u8, 255);
    defer allocator.free(prefix);
    @memset(prefix, 'a');
    var xs: [45]u8 = @splat('x');
    var ys: [45]u8 = @splat('y');
    const source = try std.fmt.allocPrint(allocator,
        \\structural A = {{ {s}{s}: number }};
        \\structural B = {{ {s}{s}: number }};
        \\function f(a: A): B {{
        \\  const b: B = a;
        \\  return b;
        \\}}
    , .{ prefix, &xs, prefix, &ys });
    defer allocator.free(source);

    var atoms = @import("zts-engine").atom_table.AtomTable.init(allocator);
    defer atoms.deinit();
    var parser = try @import("zts-engine").parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer parser.deinit();
    parser.setAtomTable(&atoms);
    _ = try parser.parse();
    const ir_view = IrView.fromIRStore(&parser.nodes, &parser.constants);
    var pool = TypePool.init(allocator);
    defer pool.deinit(allocator);
    var env = TypeEnv.init(allocator, &pool);
    defer env.deinit();
    // Before the fix both names were cut to the same 255 bytes and `a` was
    // assignable to `B`. Now the pool refuses the name and the pipeline stops.
    if (env.populateSourceTypes(.{ .direct = .{
        .store = &parser.type_store,
        .ir_view = ir_view,
        .atoms = &atoms,
    } })) |_| {} else |err| try std.testing.expectEqual(error.TypePoolCapacityExceeded, err);
    try std.testing.expectError(error.TypePoolCapacityExceeded, pool.ensureHealthy());
}

// A3 part 2b (Decision 40): a mismatch whose source type admits `undefined`
// carries a help line that names the repair.

const undefined_source_help = "the value may be undefined: check it first, or use `?? fallback`";
// The test text above is a literal on purpose: it must not follow the constant.

test "ZTS200 help names the undefined check when the source type admits undefined" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\function run(input: string | undefined): number {
        \\  const n: string = input;
        \\  return n.length;
        \\}
    , false);
    defer freeSeenDiagnostics(allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .type_mismatch));
    for (seen) |d| {
        if (d.kind != .type_mismatch) continue;
        try std.testing.expectEqualStrings(undefined_source_help, d.help.?);
    }
}

test "ZTS203 help names the undefined check when the source type admits undefined" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\function needS(s: string): number {
        \\  return s.length;
        \\}
        \\function run(input: string | undefined): number {
        \\  return needS(input);
        \\}
    , false);
    defer freeSeenDiagnostics(allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .arg_type_mismatch));
    for (seen) |d| {
        if (d.kind != .arg_type_mismatch) continue;
        try std.testing.expectEqualStrings(undefined_source_help, d.help.?);
    }
}

test "ZTS200 carries the generic mismatch help when the source type cannot be undefined" {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator,
        \\function run(input: number): number {
        \\  const n: string = input;
        \\  return n.length;
        \\}
    , false);
    defer freeSeenDiagnostics(allocator, seen);
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .type_mismatch));
    for (seen) |d| {
        if (d.kind != .type_mismatch) continue;
        try std.testing.expectEqualStrings(mismatch_help_text, d.help orelse "(null)");
    }
}

test "TypeChecker: each type refusal carries a fixed help string" {
    try checkTypedSourceHelping(
        \\function handler(req: Request): Response {
        \\  const s: string = 1 + 2;
        \\  return Response.text(s);
        \\}
    , 1, "is not assignable to type", "Change the value or the declared type so that the two types match.");
    try checkTypedSourceHelping(
        \\function double(x: number): number { return x * 2; }
        \\function handler(req: Request): Response {
        \\  const n = double(1, 2);
        \\  return Response.json({ n: n });
        \\}
    , 1, "wrong number of arguments", "Pass exactly as many arguments as the function declares parameters.");
    try checkTypedSourceHelping(
        \\function double(x: number): number { return x * 2; }
        \\function handler(req: Request): Response {
        \\  const n = double("a");
        \\  return Response.json({ n: n });
        \\}
    , 1, "argument type does not match", "Pass a value of the parameter type, or change the parameter type.");
    try checkTypedSourceHelping(
        \\structural Point = { x: number; y: number };
        \\function handler(req: Request): Response {
        \\  const p: Point = { x: 1, y: 2 };
        \\  const z = p.z;
        \\  return Response.text(String(z));
        \\}
    , 1, "property does not exist", "Read a property that the type declares, or add the property to the type.");
    try checkTypedSourceHelping(
        \\function idOf<T extends { id: string }>(v: T): string { return v.id; }
        \\function handler(req: Request): Response {
        \\  const s = idOf({ name: "no id" });
        \\  return Response.json({ s: s });
        \\}
    , 1, "does not satisfy constraint", "Pass a type argument that satisfies the constraint, or relax the constraint.");
}

// F1 (2026-11-02): a function value has a function type, so a typed position
// that admits no function refuses it with the code it uses for any wrong value.

fn expectOnlyDiagnostic(source: []const u8, kind: DiagnosticKind) !void {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator, source, false);
    defer freeSeenDiagnostics(allocator, seen);
    if (seen.len != 1) for (seen) |d| std.debug.print("diagnostic: {s}\n", .{d.message});
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqual(kind, seen[0].kind);
}

fn expectNoDiagnostics(source: []const u8) !void {
    const allocator = std.testing.allocator;
    const seen = try typedDiagnostics(allocator, source, false);
    defer freeSeenDiagnostics(allocator, seen);
    if (seen.len != 0) for (seen) |d| std.debug.print("diagnostic: {s}\n", .{d.message});
    try std.testing.expectEqual(@as(usize, 0), seen.len);
}

test "function value: returning an arrow from a number function is ZTS204" {
    try expectOnlyDiagnostic(
        \\function f(): number {
        \\  return (x: number): number => x;
        \\}
    , .return_type_mismatch);
}

test "function value: returning a const arrow from a number function is ZTS204" {
    try expectOnlyDiagnostic(
        \\function h(): number {
        \\  const f = (x: number): number => x;
        \\  return f;
        \\}
    , .return_type_mismatch);
}

test "function value: returning a named function from a number function is ZTS204" {
    try expectOnlyDiagnostic(
        \\function g(x: number): number { return x; }
        \\function h(): number {
        \\  return g;
        \\}
    , .return_type_mismatch);
}

test "function value: returning an arrow into number or undefined is ZTS204" {
    try expectOnlyDiagnostic(
        \\function f(): number | undefined {
        \\  return (x: number): number => x;
        \\}
    , .return_type_mismatch);
}

test "function value: a ternary branch that is an arrow is ZTS204" {
    try expectOnlyDiagnostic(
        \\function f(flag: boolean): number {
        \\  return flag ? (x: number): number => x : 1;
        \\}
    , .return_type_mismatch);
}

test "function value: an arrow in a number annotation is ZTS200" {
    try expectOnlyDiagnostic(
        \\function f(): number {
        \\  const n: number = (x: number): number => x;
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: a named function in a number annotation is ZTS200" {
    try expectOnlyDiagnostic(
        \\function g(x: number): number { return x; }
        \\function f(): number {
        \\  const n: number = g;
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: assigning an arrow to a number variable is ZTS200" {
    try expectOnlyDiagnostic(
        \\function f(): number {
        \\  let n: number = 0;
        \\  n = (x: number): number => x;
        \\  return n;
        \\}
    , .type_mismatch);
}

test "function value: an arrow in a number record field is ZTS200" {
    try expectOnlyDiagnostic(
        \\structural Box = { n: number };
        \\function f(): number {
        \\  const b: Box = { n: (x: number): number => x };
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: an arrow in a number array is ZTS200" {
    try expectOnlyDiagnostic(
        \\function f(): number {
        \\  const a: number[] = [(x: number): number => x];
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: an arrow in a number tuple slot is ZTS200" {
    try expectOnlyDiagnostic(
        \\function f(): number {
        \\  const t: [number, string] = [(x: number): number => x, "a"];
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: a named function passed as a number argument is ZTS203" {
    try expectOnlyDiagnostic(
        \\function g(x: number): number { return x; }
        \\function take(n: number): number { return n; }
        \\function f(): number {
        \\  return take(g);
        \\}
    , .arg_type_mismatch);
}

test "function value: a const arrow passed as a number argument is ZTS203" {
    try expectOnlyDiagnostic(
        \\function take(n: number): number { return n; }
        \\function f(): number {
        \\  const g = (x: number): number => x;
        \\  return take(g);
        \\}
    , .arg_type_mismatch);
}

test "function value: an arrow nested in a record argument is ZTS203" {
    try expectOnlyDiagnostic(
        \\structural Box = { n: number };
        \\function take2(b: Box): number { return 1; }
        \\function f(): number {
        \\  return take2({ n: (x: number): number => x });
        \\}
    , .arg_type_mismatch);
}

test "function value: a function in a JSON payload is ZTS213" {
    try expectOnlyDiagnostic(
        \\function g(x: number): number { return x; }
        \\export function handler(req: Request): Response {
        \\  return Response.json({ f: g });
        \\}
    , .unencodable_json_payload);
}

test "function value: calling a const arrow keeps its arity" {
    try expectNoDiagnostics(
        \\function r(): number {
        \\  const f = (x: number): number => x;
        \\  return f(1);
        \\}
    );
    try expectOnlyDiagnostic(
        \\function r(): number {
        \\  const f = (x: number): number => x;
        \\  return f(1, 2);
        \\}
    , .arg_count_mismatch);
}

test "function value: a function stays assignable to a function type" {
    try expectNoDiagnostics(
        \\function g(x: number): number { return x; }
        \\function r(): number {
        \\  const h: (x: number) => number = g;
        \\  return h(1);
        \\}
    );
    try expectNoDiagnostics(
        \\function r(): number {
        \\  const k: (x: number) => number = (x: number): number => x;
        \\  return k(1);
        \\}
    );
}

test "function value: a named function passes to an array callback" {
    try expectNoDiagnostics(
        \\function g(x: number): number { return x; }
        \\function r(): number[] {
        \\  return [1, 2].map(g);
        \\}
    );
}

test "function value: an unannotated object holding an arrow keeps its call arity" {
    try expectNoDiagnostics(
        \\function r(): number {
        \\  const o = { f: (x: number): number => x };
        \\  return o.f(1);
        \\}
    );
    try expectOnlyDiagnostic(
        \\function r(): number {
        \\  const o = { f: (x: number): number => x };
        \\  return o.f(1, 2);
        \\}
    , .arg_count_mismatch);
}

test "function value: an unannotated arrow in a shadowing JSON object takes its argument" {
    try expectNoDiagnostics(
        \\function r(): string {
        \\  const JSON = { stringify: (value) => "ignored" };
        \\  return JSON.stringify({ a: 1 });
        \\}
    );
}

test "function value: a function with an extra parameter is refused at a function type" {
    try expectOnlyDiagnostic(
        \\function r(): number {
        \\  const k: (x: number) => number = (x: number, y: number): number => x;
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: a function with a wrong parameter type is refused at a function type" {
    try expectOnlyDiagnostic(
        \\function r(): number {
        \\  const k: (x: number) => number = (x: string): number => 1;
        \\  return 1;
        \\}
    , .type_mismatch);
}

test "function value: a record holding a function is refused at a number field" {
    try expectOnlyDiagnostic(
        \\structural Box = { n: number };
        \\function g(x: number): number { return x; }
        \\function r(): number {
        \\  const o = { n: g };
        \\  const b: Box = o;
        \\  return 1;
        \\}
    , .type_mismatch);
}

// F2 (2026-11-02): a predicate is admitted only when the type its test proves
// is assignable to the type it claims.

test "predicate claim: a test that proves number does not back a string claim" {
    try expectOnlyDiagnostic(
        \\function isStr(x: unknown): x is string {
        \\    return typeof x === "number";
        \\}
    , .invalid_type_predicate);
}

test "predicate claim: a test that proves string backs a string claim over unknown" {
    try expectNoDiagnostics(
        \\function isStr(x: unknown): x is string {
        \\    return typeof x === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: unknown = "a";
        \\    if (isStr(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    );
}

test "predicate claim: a discriminant test for the other member does not back the claim" {
    try expectOnlyDiagnostic(
        \\structural A = { kind: "a", n: number };
        \\function isA(v: { kind: "a", n: number } | { kind: "b", s: string }): v is A {
        \\    return v.kind === "b";
        \\}
    , .invalid_type_predicate);
}

test "predicate claim: a discriminant test for the claimed member is admitted and narrows" {
    try expectNoDiagnostics(
        \\structural A = { kind: "a", n: number };
        \\function isA(v: { kind: "a", n: number } | { kind: "b", s: string }): v is A {
        \\    return v.kind === "a";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: { kind: "a", n: number } | { kind: "b", s: string } = { kind: "a", n: 1 };
        \\    if (isA(raw)) {
        \\        const a: A = raw;
        \\        return Response.json({ n: a.n });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    );
}

test "predicate claim: a negated typeof test backs the other member of a union" {
    try expectNoDiagnostics(
        \\function isNum(v: string | number): v is number {
        \\    return !(typeof v === "string");
        \\}
    );
}

test "predicate claim: a disjunction proves the union of its sides" {
    try expectNoDiagnostics(
        \\function isSN(x: unknown): x is string | number {
        \\    return typeof x === "string" || typeof x === "number";
        \\}
    );
}

test "predicate claim: an equality with a literal proves that literal" {
    try expectNoDiagnostics(
        \\function isA(x: string): x is "a" {
        \\    return x === "a";
        \\}
    );
}

test "predicate claim: Array.isArray over unknown does not back a string array claim" {
    try expectOnlyDiagnostic(
        \\function isArr(x: unknown): x is string[] {
        \\    return Array.isArray(x);
        \\}
    , .invalid_type_predicate);
}

test "predicate claim: a refused predicate installs no narrowing at its call site" {
    // ZTS211 for the predicate, ZTS200 for `const s: string = v` because the
    // refused predicate narrows nothing.
    const seen = try typedDiagnostics(std.testing.allocator,
        \\function isStr(x: unknown): x is string {
        \\    return typeof x === "number";
        \\}
        \\function handler(req: Request): Response {
        \\    const v: string | number = 7;
        \\    if (isStr(v)) {
        \\        const s: string = v;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    , false);
    defer freeSeenDiagnostics(std.testing.allocator, seen);
    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .invalid_type_predicate));
    try std.testing.expectEqual(@as(usize, 1), countKind(seen, .type_mismatch));
}

// A literal discriminant test selects every member that can hold the literal,
// reads named records and aliases of unions, and keeps the original members.

test "discriminant guard: members sharing the discriminant value are all kept" {
    // Both members have `kind: "a"`, so the then-branch is either one and
    // `v.n` is not proven. The guard took the first match and read `n` as a
    // number.
    try expectOnlyDiagnostic(
        \\function pick(v: { kind: "a", n: number } | { kind: "a", s: string }): number {
        \\    if (v.kind === "a") {
        \\        const k: number = v.n;
        \\        return k;
        \\    }
        \\    return 0;
        \\}
    , .type_mismatch);
}

test "discriminant guard: a member with a wider field stays in the then-branch" {
    try expectOnlyDiagnostic(
        \\function pick(v: { kind: "a", n: number } | { kind: string, s: string }): number {
        \\    if (v.kind === "a") {
        \\        const k: number = v.n;
        \\        return k;
        \\    }
        \\    return 0;
        \\}
    , .type_mismatch);
}

test "discriminant guard: a member with an optional discriminant stays in the else-branch" {
    // `kind?: "a"` can be absent, so `v.kind === "a"` can be false for that
    // member, and the code after the early return can still hold it.
    try expectOnlyDiagnostic(
        \\function pick(v: { kind?: "a", n: number } | { kind: "b", s: string }): number {
        \\    if (v.kind === "a") {
        \\        return 0;
        \\    }
        \\    const k: string = v.s;
        \\    return 1;
        \\}
    , .type_mismatch);
}

test "discriminant guard: named records narrow in the then-branch" {
    try expectNoDiagnostics(
        \\structural A = { kind: "a", n: number };
        \\structural B = { kind: "b", s: string };
        \\function f(v: A | B): number {
        \\    if (v.kind === "a") {
        \\        const a: A = v;
        \\        return a.n;
        \\    }
        \\    return 0;
        \\}
    );
}

test "discriminant guard: named records narrow after an early return" {
    try expectNoDiagnostics(
        \\structural A = { kind: "a", n: number };
        \\structural B = { kind: "b", s: string };
        \\function f(v: A | B): number {
        \\    if (v.kind === "a") {
        \\        return 1;
        \\    }
        \\    const b: B = v;
        \\    return b.s.length;
        \\}
    );
}

test "discriminant guard: an alias of a union of named records narrows" {
    try expectNoDiagnostics(
        \\structural A = { kind: "a", n: number };
        \\structural B = { kind: "b", s: string };
        \\structural AB = A | B;
        \\function f(v: AB): number {
        \\    if (v.kind === "a") {
        \\        const a: A = v;
        \\        return a.n;
        \\    }
        \\    return 0;
        \\}
    );
}

test "predicate claim: a discriminant test over named records is admitted and narrows" {
    try expectNoDiagnostics(
        \\structural A = { kind: "a", n: number };
        \\structural B = { kind: "b", s: string };
        \\function isA(v: A | B): v is A {
        \\    return v.kind === "a";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: A | B = { kind: "a", n: 1 };
        \\    if (isA(raw)) {
        \\        const a: A = raw;
        \\        return Response.json({ n: a.n });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    );
}

test "predicate claim: a discriminant shared by two members does not back a one-member claim" {
    try expectOnlyDiagnostic(
        \\structural A1 = { kind: "a", n: number };
        \\structural A2 = { kind: "a", s: string };
        \\function isA1(v: A1 | A2): v is A1 {
        \\    return v.kind === "a";
        \\}
    , .invalid_type_predicate);
}

// F3 and F4 (2026-11-02): a type predicate is a named module-level function
// declaration, and its target names a parameter. Any other predicate is
// refused with one ZTS211, never ignored.

test "predicate position: a module-level const arrow predicate is ZTS211" {
    try expectOnlyDiagnostic(
        \\const isStr = (x: unknown): x is string => typeof x === "string";
    , .invalid_type_predicate);
}

test "predicate position: a local const arrow predicate is ZTS211" {
    try expectOnlyDiagnostic(
        \\function handler(req: Request): Response {
        \\    const isStr = (x: unknown): x is string => typeof x === "string";
        \\    return Response.json({ ok: true });
        \\}
    , .invalid_type_predicate);
}

test "predicate position: a function declaration nested in a function body is ZTS211" {
    try expectOnlyDiagnostic(
        \\function handler(req: Request): Response {
        \\    function isStr(x: unknown): x is string {
        \\        return typeof x === "string";
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    , .invalid_type_predicate);
}

test "predicate position: an arrow predicate passed as a callback is ZTS211" {
    try expectOnlyDiagnostic(
        \\function apply(f: (x: unknown) => boolean): boolean {
        \\    return f(1);
        \\}
        \\function handler(req: Request): Response {
        \\    const r = apply((x: unknown): x is string => typeof x === "number");
        \\    return Response.json({ r: r });
        \\}
    , .invalid_type_predicate);
}

test "predicate target: a predicate that names no parameter is ZTS211" {
    try expectOnlyDiagnostic(
        \\function isStr(y: unknown): x is string {
        \\    return typeof y === "string";
        \\}
    , .invalid_type_predicate);
}

test "predicate target: an arrow predicate that names no parameter gets one ZTS211" {
    try expectOnlyDiagnostic(
        \\const isStr = (y: unknown): x is string => typeof y === "string";
    , .invalid_type_predicate);
}

test "predicate position: a module-level function declaration predicate is admitted and narrows" {
    try expectNoDiagnostics(
        \\function isStr(x: unknown): x is string {
        \\    return typeof x === "string";
        \\}
        \\function handler(req: Request): Response {
        \\    const raw: unknown = "a";
        \\    if (isStr(raw)) {
        \\        const s: string = raw;
        \\        return Response.json({ s: s });
        \\    }
        \\    return Response.json({ ok: true });
        \\}
    );
}
