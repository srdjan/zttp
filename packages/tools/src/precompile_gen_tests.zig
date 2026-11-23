//! Test generation: one JSONL test case per proven behavioral path.

const std = @import("std");
const zts = @import("zts");
const json_diag = @import("json_diagnostics.zig");
const readFilePosix = zts.file_io.readFile;
const findHandlerFunction = zts.findHandlerFunction;
const stderr_mod = @import("precompile_stderr.zig");
const debugPrint = stderr_mod.debugPrint;
const readFailureReason = stderr_mod.readFailureReason;
const debugPrintStripError = stderr_mod.debugPrintStripError;
const printParseErrors = stderr_mod.printParseErrors;

/// Parse handler source and write one JSONL test case per proven behavioral path.
/// Returns the number of test cases written. Returns 0 when no handler function
/// is found. Callers should check for parse errors via stderr.
pub fn runGenTests(
    allocator: std.mem.Allocator,
    handler_path: []const u8,
    writer: anytype,
) !u32 {
    const source = readFilePosix(allocator, handler_path, 10 * 1024 * 1024) catch |err| {
        debugPrint("Error reading handler file '{s}': {s}\n", .{ handler_path, readFailureReason(err) });
        return err;
    };
    defer allocator.free(source);

    const source_kind = zts.classifySourcePath(handler_path);
    if (source_kind == .unsupported) {
        debugPrintStripError(handler_path, error.UnsupportedSourceExtension, null);
        return error.UnsupportedSourceExtension;
    }
    var atoms = zts.AtomTable.init(allocator);
    defer atoms.deinit();
    var js_parser = try zts.parser.JsParser.initAdmission(allocator, allocator, source, .compile);
    defer js_parser.deinit();
    js_parser.setAtomTable(&atoms);
    var source_view = zts.SourceView.of(source);
    source_view.name = handler_path;
    source_view.normalize_positions = source_kind.isTyped();
    const root = if (source_kind.isTyped()) typed: {
        const outcome = js_parser.parseAdmission() catch {
            printParseErrors(allocator, source_view, js_parser.getProjectedErrors());
            return error.ParseError;
        };
        break :typed switch (outcome) {
            .accepted => |root| root,
            .parser_refused => {
                printParseErrors(allocator, source_view, js_parser.getProjectedErrors());
                return error.ParseError;
            },
            .terminal_admission_refused => |failure| {
                zts.logAdmissionFailure(source, failure);
                const err = zts.prepareErrorForAdmissionFailure(failure);
                const diagnostic = if (js_parser.getLastAdmissionObservation()) |found|
                    json_diag.stripDiagnosticFromAdmission(source, found)
                else
                    null;
                debugPrintStripError(handler_path, err, diagnostic);
                return switch (err) {
                    error.OutOfMemory => err,
                    else => error.AdmissionRefused,
                };
            },
            .recovered_admission_refused => return error.AdmissionRefused,
        };
    } else js_parser.parse() catch {
        printParseErrors(allocator, source_view, js_parser.getErrors());
        return error.ParseError;
    };

    const parsed = zts.pipeline.ParsedModule.fromAdmittedParser(&js_parser, root, &atoms, handler_path);
    const handler_fn = findHandlerFunction(parsed.ir_view, root) orelse return 0;

    var analysis: zts.pipeline.ModuleAnalysisSession = .{};
    try analysis.initContractOnly(allocator, parsed, .{});
    defer analysis.deinit();
    try analysis.complete();

    var gen = zts.PathGenerator.init(allocator, analysis.parsed.ir_view, &atoms, try analysis.pathEffectFacts());
    defer gen.deinit();
    try gen.generate(handler_fn);
    try gen.writeJsonl(writer);
    return @intCast(gen.getHandlerTests().len);
}
