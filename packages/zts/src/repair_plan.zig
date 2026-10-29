//! Compiler-native repair plan primitives.
//!
//! This module does not edit source. It turns verifier and flow/property
//! failures into small, structured edit intents that an agent can apply, then
//! re-check through the existing compiler veto.

const std = @import("std");
const counterexample = @import("counterexample.zig");
const flow_checker = @import("flow_checker.zig");
const handler_verifier = @import("handler_verifier.zig");
const RepairIntent = @import("repair_intent.zig").RepairIntent;

pub const SourceSpan = counterexample.SourceSpan;

pub const RepairKind = enum {
    check_result_before_value,
    narrow_optional_before_use,
    add_fallback_response,
    redact_sensitive_sink,
    validate_before_egress,
    /// A production diagnostic whose checker-owned repair intent the apply step runs.
    apply_repair_intent,
    /// A production diagnostic with no typed repair: the author follows its help text.
    follow_diagnostic_help,

    pub fn asString(self: RepairKind) []const u8 {
        return @tagName(self);
    }
};

pub const EditIntentKind = enum {
    insert_guard_before_line,
    replace_sink_expression,
    add_trailing_return,
    validate_before_sink,
    /// Advice for the author. No tool applies it.
    manual_edit,

    pub fn asString(self: EditIntentKind) []const u8 {
        return @tagName(self);
    }
};

pub const EditIntent = struct {
    kind: EditIntentKind,
    line: u32,
    column: u32,
    template: []const u8,
    /// Set for `apply_repair_intent`: the intent name the plan writes as its JSON kind.
    repair_intent: ?RepairIntent = null,
};

pub const Plan = struct {
    kind: RepairKind,
    target: SourceSpan,
    behavioral_change: bool,
    summary: []const u8,
    edit_intent: EditIntent,
    /// For `check_result_before_value`: the refused Result shape.
    result_shape: ?handler_verifier.ResultShape = null,

    pub fn closesProperty(self: Plan, tag: counterexample.PropertyTag) bool {
        return switch (self.kind) {
            .redact_sensitive_sink => tag == .no_secret_leakage or tag == .no_credential_leakage,
            .validate_before_egress => tag == .injection_safe,
            else => false,
        };
    }
};

/// The summary of `narrow_optional_before_use` when the read has no binding to
/// name, such as `ps[0].age`. No guard line can name a variable then.
pub const unbound_optional_summary = "Bind the value to a const first, then check it for undefined.";

/// The advice for one refused Result shape. A diagnostic with no shape gets
/// the advice for an unchecked value read.
fn resultSummary(shape: ?handler_verifier.ResultShape) []const u8 {
    const known = shape orelse return "Add an explicit non-2xx early return before reading result.value.";
    return switch (known) {
        .unchecked_value => "Add an explicit non-2xx early return before reading result.value.",
        .unchecked_error => "Read result.error only after if (!result.ok), or write result.error ?? fallback.",
        .error_on_ok_path => "Result.error is undefined on the ok path. Read it after if (result.ok) return ..., or write result.error ?? fallback.",
        .unrecognized_guard => "Replace this check with if (!result.ok) return ... . The proof does not accept === true, isOk(), isErr(), or match as a check.",
        .closure_read => "Check result.ok inside the closure before it reads result.value. A check outside the closure does not reach it.",
        .flat_guard => "Check result.ok in an if statement before the assert, throw, switch, or try statement that reads the Result.",
        .unknown_member, .computed_key => "Read only result.ok, result.value, result.error, or result.errors, each with a plain member name.",
        .method_call => "Use result.ok. A Result has no methods, so replace the method call with if (!result.ok) return ... .",
        .alias_or_reassignment => "Keep the Result in its one const. Check result.ok in this function, then copy result.value.",
        .function_alias => "Call the Result function directly and bind the call to a const.",
        .call_argument => "Check result.ok in this function, then pass result.value, not the Result. Pass the Result itself only to a zttp:result function that takes a Result.",
        .returned => "Check result.ok in this function, then return result.value or a Response, not the Result.",
        .collection_member, .spread => "Check result.ok in this function, then store result.value, not the Result.",
        .match_subject => "Replace match with if (!result.ok) return ... , then read result.value.",
        .unbound_call => "Bind the call to a const, then check its ok before you read its value.",
        .ambiguous_upvalue => "Give each Result binding in the file a unique name.",
        .depth_limit => "Split the expression into const bindings.",
        .other_use => "Use a Result only through result.ok, result.value, result.error, and result.errors.",
    };
}

pub fn fromVerifierDiagnostic(
    diag: handler_verifier.Diagnostic,
    target: SourceSpan,
) ?Plan {
    return switch (diag.kind) {
        .unchecked_result_value => .{
            .kind = .check_result_before_value,
            .target = target,
            .behavioral_change = true,
            .summary = resultSummary(diag.result_shape),
            .result_shape = diag.result_shape,
            .edit_intent = .{
                .kind = .insert_guard_before_line,
                .line = target.line,
                .column = target.column,
                .template = "if (!result.ok) return Response.json({ error: result.error }, { status: 400 });",
            },
        },
        .unchecked_optional_use, .unchecked_optional_access => .{
            .kind = .narrow_optional_before_use,
            .target = target,
            .behavioral_change = true,
            .summary = "Narrow the optional value, provide a fallback, or return before using it.",
            .edit_intent = .{
                .kind = .insert_guard_before_line,
                .line = target.line,
                .column = target.column,
                .template = "if (value === undefined) return Response.json({ error: \"missing value\" }, { status: 400 });",
            },
        },
        .missing_return_path => .{
            .kind = .add_fallback_response,
            .target = target,
            .behavioral_change = true,
            .summary = "Add a fallback Response so every handler path returns.",
            .edit_intent = .{
                .kind = .add_trailing_return,
                .line = target.line,
                .column = target.column,
                .template = "return Response.text(\"Not Found\", { status: 404 });",
            },
        },
        else => null,
    };
}

pub fn fromFlowDiagnostic(
    diag: flow_checker.Diagnostic,
    tag: counterexample.PropertyTag,
    target: SourceSpan,
) ?Plan {
    _ = diag;
    return switch (tag) {
        .no_secret_leakage, .no_credential_leakage => .{
            .kind = .redact_sensitive_sink,
            .target = target,
            .behavioral_change = true,
            .summary = "Return before the witnessed sink so the labelled value is unreachable on this path.",
            // v1 apply only supports line insertions, so we close the sink
            // path with an early return rather than mutating the sink
            // argument. The property (no secret reaches the response) is
            // achieved; the handler's behaviour on the witnessed request
            // changes to a 500. Callers that want the original response
            // shape back should follow up with a semantic repair once
            // replace_sink_expression is apply-supported.
            .edit_intent = .{
                .kind = .insert_guard_before_line,
                .line = target.line,
                .column = target.column,
                .template = "return Response.json({ error: \"redacted to preserve no_secret_leakage\" }, { status: 500 });",
            },
        },
        .injection_safe => .{
            .kind = .validate_before_egress,
            .target = target,
            .behavioral_change = true,
            .summary = "Validate or coerce user input before it reaches the sensitive sink.",
            .edit_intent = .{
                .kind = .validate_before_sink,
                .line = target.line,
                .column = target.column,
                .template = "Decode and validate the request data, then pass only the validated value to this sink.",
            },
        },
        .input_validated, .pii_contained => null,
    };
}

/// Plain fields of one production diagnostic. The caller decides which
/// `supported_intent` the apply step can run, because this tier cannot import
/// the apply step.
pub const ProductionFields = struct {
    line: u32,
    column: u32,
    help: ?[]const u8,
    result_shape: ?handler_verifier.ResultShape,
    supported_intent: ?RepairIntent,
};

/// The summary of `follow_diagnostic_help` when the diagnostic has no help text.
pub const no_help_summary = "Read the diagnostic message and edit the code at this position.";

/// One plan for one production diagnostic. Precedence: a Result shape, then a
/// supported repair intent, then the help text.
pub fn fromProductionDiagnostic(fields: ProductionFields) Plan {
    const target: SourceSpan = .{ .line = fields.line, .column = fields.column };
    if (fields.result_shape) |shape| {
        return .{
            .kind = .check_result_before_value,
            .target = target,
            .behavioral_change = true,
            .summary = resultSummary(shape),
            .result_shape = shape,
            .edit_intent = .{
                .kind = .insert_guard_before_line,
                .line = fields.line,
                .column = fields.column,
                .template = "if (!result.ok) return Response.json({ error: result.error }, { status: 400 });",
            },
        };
    }
    if (fields.supported_intent) |intent| {
        return .{
            .kind = .apply_repair_intent,
            .target = target,
            .behavioral_change = true,
            .summary = fields.help orelse no_help_summary,
            // The plan's JSON kind is `repair_intent`, not this kind.
            .edit_intent = .{
                .kind = .manual_edit,
                .line = fields.line,
                .column = fields.column,
                .template = "",
                .repair_intent = intent,
            },
        };
    }
    return .{
        .kind = .follow_diagnostic_help,
        .target = target,
        .behavioral_change = true,
        .summary = fields.help orelse no_help_summary,
        .edit_intent = .{
            .kind = .manual_edit,
            .line = fields.line,
            .column = fields.column,
            .template = "",
        },
    };
}

test "verifier diagnostics map to narrow repair plans" {
    const diag = handler_verifier.Diagnostic{
        .severity = .err,
        .kind = .unchecked_result_value,
        .node = 0,
        .message = "result.value accessed without checking result.ok first",
        .help = null,
    };
    const plan = fromVerifierDiagnostic(diag, .{ .line = 12, .column = 9 }) orelse return error.MissingPlan;
    try std.testing.expectEqual(RepairKind.check_result_before_value, plan.kind);
    try std.testing.expectEqual(EditIntentKind.insert_guard_before_line, plan.edit_intent.kind);
    try std.testing.expect(plan.behavioral_change);
}

test "flow diagnostics map to property repair plans" {
    const diag = flow_checker.Diagnostic{
        .severity = .err,
        .kind = .secret_in_response,
        .node = 0,
        .message = "secret reaches response",
        .help = null,
    };
    const plan = fromFlowDiagnostic(diag, .no_secret_leakage, .{ .line = 7, .column = 17 }) orelse return error.MissingPlan;
    try std.testing.expectEqual(RepairKind.redact_sensitive_sink, plan.kind);
    try std.testing.expectEqual(EditIntentKind.insert_guard_before_line, plan.edit_intent.kind);
    try std.testing.expect(std.mem.indexOf(u8, plan.edit_intent.template, "return Response") != null);
    try std.testing.expect(plan.closesProperty(.no_secret_leakage));
}
