//! Facade for the heap-aware flow interpreter.
const std = @import("std");
const engine = @import("zts-engine");
const SourceView = @import("zts-base").source_diagnostics.SourceView;
const diagnostic_catalog = @import("diagnostic_catalog.zig");
const diagnostic_projection = @import("diagnostic_projection.zig");
const evaluator = @import("flow_interp.zig");
const report_types = @import("flow_report.zig");
const type_checker = @import("type_checker.zig");
const ir = engine.parser.ir;
const atom_table = engine.atom_table;
const counterexample = @import("counterexample.zig");
const handler_function_mod = @import("handler_function.zig");
const NodeIndex = ir.NodeIndex;
const IrView = ir.IrView;
const mb = engine.module_binding;
const LabelSet = mb.LabelSet;

/// Version of the flow verdict semantics, included in the policy identity. It
/// also covers the `deterministic` verdict of `effect_inference.zig`, which has
/// no version of its own: version 9 counts a network, SQL, filesystem, or
/// stored-data read as a varying source (`module_binding.exportVaries`).
pub const flow_analyzer_version: u32 = 9;

pub const RepairIntent = report_types.RepairIntent;
pub const Severity = report_types.Severity;
pub const DiagnosticKind = report_types.DiagnosticKind;
pub const Witness = report_types.Witness;
pub const Diagnostic = report_types.Diagnostic;
pub const SafeForm = report_types.SafeForm;
pub const DefendedPath = report_types.DefendedPath;
pub const FlowProperties = report_types.FlowProperties;
pub const propertyTagForKind = report_types.propertyTagForKind;

const unproven: FlowProperties = .{
    .no_secret_leakage = false,
    .no_credential_leakage = false,
    .input_validated = false,
    .pii_contained = false,
    .injection_safe = false,
    .deterministic = false,
};

pub const FlowChecker = struct {
    allocator: std.mem.Allocator,
    ir_view: ir.IrView,
    atoms: ?*engine.atom_table.AtomTable,
    scopes: ?*const engine.parser.ScopeAnalyzer = null,
    captures: ?*const evaluator.CaptureTable = null,
    modules: []const evaluator.ModuleView = &.{},
    initialization_order: []const evaluator.ModuleId = &.{},
    modules_complete: bool = true,
    /// The policy's `env.public` names, borrowed; must outlive the analysis.
    /// Empty means every literal `env` name is secret (D-014).
    env_public: []const []const u8 = &.{},
    type_checker: ?*type_checker.TypeChecker = null,
    evaluation: ?evaluator.FlowInterp = null,
    properties: FlowProperties = unproven,
    diagnostics: []const Diagnostic = &.{},
    defended_paths: []const DefendedPath = &.{},
    unresolved_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, ir_view: ir.IrView, atoms: ?*engine.atom_table.AtomTable) FlowChecker {
        return .{ .allocator = allocator, .ir_view = ir_view, .atoms = atoms };
    }

    pub fn deinit(self: *FlowChecker) void {
        self.clearEvaluation();
    }

    pub fn check(self: *FlowChecker, handler_func: ir.NodeIndex) !u32 {
        self.clearEvaluation();
        var owned_captures: ?evaluator.CaptureTable = null;
        defer if (owned_captures) |*table| table.deinit();
        var analysis = self.newEvaluator();
        errdefer analysis.deinit();
        if (analysis.captures == null) if (self.scopes) |scopes| {
            owned_captures = try evaluator.CaptureTable.init(self.allocator, scopes);
            analysis.captures = &owned_captures.?;
        };

        const result = try analysis.analyzeHandlerReport(handler_func);
        if (self.type_checker) |checker| try checker.ensureHealthy();
        var error_count: u32 = 0;
        for (result.diagnostics) |diagnostic| {
            if (diagnostic.severity == .err) error_count += 1;
        }
        self.properties = result.properties;
        self.diagnostics = result.diagnostics;
        self.defended_paths = result.defended_paths;
        self.unresolved_count = result.evaluation.unresolved.len;
        // Report storage lives in the evaluator arena, while the temporary
        // capture table is needed only during this analysis.
        analysis.captures = null;
        self.evaluation = analysis;
        return error_count;
    }

    pub fn getProperties(self: *const FlowChecker) FlowProperties {
        return self.properties;
    }

    pub fn getDiagnostics(self: *const FlowChecker) []const Diagnostic {
        return self.diagnostics;
    }

    pub fn getDefendedPaths(self: *const FlowChecker) []const DefendedPath {
        return self.defended_paths;
    }

    /// Constructs the last `check` could not follow. Any non-zero count clears
    /// every flow property, so a frozen corpus asserts this stays zero.
    pub fn unresolvedCount(self: *const FlowChecker) usize {
        return self.unresolved_count;
    }

    pub fn setTypeChecker(self: *FlowChecker, checker: *type_checker.TypeChecker) void {
        self.type_checker = checker;
    }

    pub fn formatDiagnostics(self: *const FlowChecker, source: SourceView, writer: anytype) !void {
        try diagnostic_projection.writeAll(.flow, source, self.diagnostics, self.ir_view, writer);
    }

    fn clearEvaluation(self: *FlowChecker) void {
        if (self.evaluation) |*analysis| analysis.deinit();
        self.evaluation = null;
        self.properties = unproven;
        self.diagnostics = &.{};
        self.unresolved_count = 0;
        self.defended_paths = &.{};
    }

    fn newEvaluator(self: *const FlowChecker) evaluator.FlowInterp {
        var analysis = evaluator.FlowInterp.init(self.allocator, self.ir_view, self.atoms);
        analysis.captures = self.captures orelse if (self.modules.len > 0) self.modules[0].captures else null;
        analysis.modules = self.modules;
        analysis.initialization_order = self.initialization_order;
        analysis.modules_complete = self.modules_complete;
        analysis.env_public = self.env_public;
        return analysis;
    }
};

comptime {
    _ = @import("flow_checker_tests.zig");
}
