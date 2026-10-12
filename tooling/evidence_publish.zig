//! Native publishers for convergence and coverage evidence.

const std = @import("std");
const evidence_marker = @import("evidence_marker.zig");

const convergence_marker = "[codegen-convergence] ";
const coverage_marker = "[proof-coverage] ";
const seed_marker = "[seed-coverage] ";
const union_marker = @import("coverage_union.zig").marker;

const SeedRow = struct {
    code: []const u8,
    reason: []const u8,
};

const SeedPayload = struct {
    seedsTotal: usize,
    rulesTotal: usize,
    verifiedRules: usize,
    verified: []const []const u8,
    unseeded: []const SeedRow,
};

const UnionPayload = struct {
    corpusVersion: []const u8,
    sourceTreeHash: []const u8,
    observations: usize,
    distinctSets: usize,
    smallestSet: usize,
    largestSet: usize,
    unionCount: usize,
    @"union": []const []const u8,
};

const PublishFailure = error{
    Usage,
    SourceMoved,
    DirtySource,
    InvalidDate,
    InvalidExistingMarkdown,
    DuplicateOrMissingAuxiliaryMarker,
    InvalidSeedEvidence,
    InvalidUnionEvidence,
    EmptyRenderedOutput,
};

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn objectOf(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidFields,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidFields;
    return if (value == .string) value.string else error.InvalidFields;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return error.InvalidFields;
    return if (value == .bool) value.bool else error.InvalidFields;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.InvalidFields;
    return if (value == .integer) value.integer else error.InvalidFields;
}

fn valueStrings(value: std.json.Value) ![]const std.json.Value {
    return if (value == .array) value.array.items else error.InvalidFields;
}

fn sameSource(object: std.json.ObjectMap, commit: []const u8, dirty: bool) PublishFailure!void {
    const marker_commit = stringField(object, "sourceCommit") catch return error.SourceMoved;
    const marker_dirty = boolField(object, "sourceDirty") catch return error.SourceMoved;
    if (!std.mem.eql(u8, marker_commit, commit) or marker_dirty != dirty) return error.SourceMoved;
    if (marker_dirty) return error.DirtySource;
}

fn validDate(date: []const u8) bool {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return false;
    for (date, 0..) |byte, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .escape_unicode = true } };
    try json.write(value);
}

fn writePythonJson(writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |number| try writer.writeAll(number),
        .string => |string| try writeJsonString(writer, string),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |entry, index| {
                if (index != 0) try writer.writeAll(", ");
                try writePythonJson(writer, entry);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writeJsonString(writer, entry.key_ptr.*);
                try writer.writeAll(": ");
                try writePythonJson(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
    }
}

fn renderConvergenceJson(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    short_commit: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    var iterator = object.iterator();
    var first = true;
    while (iterator.next()) |entry| {
        if (!first) try output.writer.writeAll(", ");
        first = false;
        try writeJsonString(&output.writer, entry.key_ptr.*);
        try output.writer.writeAll(": ");
        try writePythonJson(&output.writer, entry.value_ptr.*);
    }
    try output.writer.writeAll(", \"commit\": ");
    try writeJsonString(&output.writer, short_commit);
    try output.writer.writeAll("}\n");
    return output.toOwnedSlice();
}

fn replaceFirst(
    allocator: std.mem.Allocator,
    text: []const u8,
    old: []const u8,
    replacement: []const u8,
) ![]u8 {
    const at = std.mem.indexOf(u8, text, old) orelse return allocator.dupe(u8, text);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(text[0..at]);
    try output.writer.writeAll(replacement);
    try output.writer.writeAll(text[at + old.len ..]);
    return output.toOwnedSlice();
}

fn tableCells(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList([]const u8) {
    var cells: std.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(allocator);
    const trimmed = std.mem.trim(u8, line, "|");
    var split = std.mem.splitScalar(u8, trimmed, '|');
    while (split.next()) |cell| try cells.append(allocator, std.mem.trim(u8, cell, " \t"));
    return cells;
}

fn findCell(cells: []const []const u8, needle: []const u8) ?usize {
    for (cells, 0..) |cell, index| if (std.mem.eql(u8, cell, needle)) return index;
    return null;
}

fn renderTableLine(allocator: std.mem.Allocator, cells: []const []const u8, spaced: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (spaced) try output.writer.writeAll("| ") else try output.writer.writeByte('|');
    for (cells, 0..) |cell, index| {
        if (index != 0) try output.writer.writeAll(if (spaced) " | " else "|");
        try output.writer.writeAll(cell);
    }
    if (spaced) try output.writer.writeAll(" |") else try output.writer.writeByte('|');
    return output.toOwnedSlice();
}

fn insertCell(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList([]const u8),
    index: usize,
    value: []const u8,
) !void {
    try cells.insert(allocator, index, value);
}

const convergence_columns = [_][]const u8{
    "Recorded",
    "Commit",
    "Corpus",
    "Cases",
    "Provider",
    "Model",
    "Policy",
    "Raw first-draft pass",
    "First-attempt green",
    "Median round-trips",
    "Intent pass",
};

fn cellsEqual(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |actual_cell, expected_cell| {
        if (!std.mem.eql(u8, actual_cell, expected_cell)) return false;
    }
    return true;
}

fn validateConvergenceTable(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    header_index: usize,
) !usize {
    if (header_index + 1 >= lines.len) return error.InvalidExistingMarkdown;

    var header = try tableCells(allocator, lines[header_index]);
    defer header.deinit(allocator);
    if (!cellsEqual(header.items, &convergence_columns)) return error.InvalidExistingMarkdown;

    var separator = try tableCells(allocator, lines[header_index + 1]);
    defer separator.deinit(allocator);
    if (separator.items.len != convergence_columns.len) return error.InvalidExistingMarkdown;
    for (separator.items) |cell| {
        if (!std.mem.eql(u8, cell, "---")) return error.InvalidExistingMarkdown;
    }

    var last = header_index + 1;
    var index = header_index + 2;
    while (index < lines.len and std.mem.startsWith(u8, lines[index], "|")) : (index += 1) {
        if (!std.mem.startsWith(u8, lines[index], "| ")) return error.InvalidExistingMarkdown;
        var row = try tableCells(allocator, lines[index]);
        defer row.deinit(allocator);
        if (row.items.len != convergence_columns.len) return error.InvalidExistingMarkdown;
        last = index;
    }
    return last;
}

const old_intro =
    "The headline figure is **first-draft veto-pass rate**: how often the model's\n" ++
    "first attempt at a prompt clears the compiler veto with no retries. It is a\n" ++
    "counted result over a frozen corpus, not an estimate.\n";

const new_intro =
    "The headline figure is **raw first-draft veto-pass rate**: how often the exact\n" ++
    "model-authored bytes clear the compiler veto before normalization, repair, or\n" ++
    "retry. **First-attempt green** is reported beside it and includes compiler\n" ++
    "normalization or repair on that attempt. Both are counted results over a frozen\n" ++
    "corpus, not estimates.\n";

fn renderConvergenceMarkdown(
    allocator: std.mem.Allocator,
    existing: []const u8,
    row: []const u8,
) ![]u8 {
    const intro_migrated = try replaceFirst(allocator, existing, old_intro, new_intro);
    defer allocator.free(intro_migrated);

    // The qualification product leaves with its dedicated measurement section.
    // Retain historical result rows with their original corpus identities.
    const migrated = if (std.mem.indexOf(u8, intro_migrated, "## Repeatability\n")) |start| block: {
        const end = start + (std.mem.indexOf(u8, intro_migrated[start..], "## Results\n") orelse
            return error.InvalidExistingMarkdown);
        break :block try std.fmt.allocPrint(allocator, "{s}{s}", .{ intro_migrated[0..start], intro_migrated[end..] });
    } else try allocator.dupe(u8, intro_migrated);
    defer allocator.free(migrated);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, migrated, '\n');
    while (split.next()) |line| try lines.append(arena, line);
    if (lines.items.len != 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();

    var header: ?usize = null;
    for (lines.items, 0..) |line, index| {
        if (std.mem.startsWith(u8, line, "| Recorded ")) {
            header = index;
            break;
        }
    }
    const header_index = header orelse return error.InvalidExistingMarkdown;
    if (header_index + 1 >= lines.items.len) return error.InvalidExistingMarkdown;

    var header_cells = try tableCells(arena, lines.items[header_index]);
    if (findCell(header_cells.items, "Provider") == null) {
        const model_index = findCell(header_cells.items, "Model") orelse return error.InvalidExistingMarkdown;
        try insertCell(arena, &header_cells, model_index, "Provider");
        lines.items[header_index] = try renderTableLine(arena, header_cells.items, true);

        var separator_cells = try tableCells(arena, lines.items[header_index + 1]);
        if (model_index > separator_cells.items.len) return error.InvalidExistingMarkdown;
        try insertCell(arena, &separator_cells, model_index, "---");
        lines.items[header_index + 1] = try renderTableLine(arena, separator_cells.items, false);
        var index = header_index + 2;
        while (index < lines.items.len and std.mem.startsWith(u8, lines.items[index], "| ")) : (index += 1) {
            var historical = try tableCells(arena, lines.items[index]);
            if (model_index > historical.items.len) return error.InvalidExistingMarkdown;
            try insertCell(arena, &historical, model_index, "anthropic");
            lines.items[index] = try renderTableLine(arena, historical.items, true);
        }
    }

    header_cells = try tableCells(arena, lines.items[header_index]);
    if (findCell(header_cells.items, "First-draft pass")) |first_index| {
        header_cells.items[first_index] = "First-attempt green";
        lines.items[header_index] = try renderTableLine(arena, header_cells.items, true);
    }
    if (findCell(header_cells.items, "Raw first-draft pass") == null) {
        const first_index = findCell(header_cells.items, "First-attempt green") orelse return error.InvalidExistingMarkdown;
        try insertCell(arena, &header_cells, first_index, "Raw first-draft pass");
        lines.items[header_index] = try renderTableLine(arena, header_cells.items, true);

        var separator_cells = try tableCells(arena, lines.items[header_index + 1]);
        if (first_index > separator_cells.items.len) return error.InvalidExistingMarkdown;
        try insertCell(arena, &separator_cells, first_index, "---");
        lines.items[header_index + 1] = try renderTableLine(arena, separator_cells.items, false);
        var index = header_index + 2;
        while (index < lines.items.len and std.mem.startsWith(u8, lines.items[index], "| ")) : (index += 1) {
            var historical = try tableCells(arena, lines.items[index]);
            if (first_index > historical.items.len) return error.InvalidExistingMarkdown;
            try insertCell(arena, &historical, first_index, "not measured");
            lines.items[index] = try renderTableLine(arena, historical.items, true);
        }
    }

    const last = try validateConvergenceTable(arena, lines.items, header_index);
    var duplicate = false;
    for (lines.items[header_index + 2 .. last + 1]) |existing_row| {
        if (std.mem.eql(u8, std.mem.trim(u8, existing_row, " \t"), std.mem.trim(u8, row, " \t"))) {
            duplicate = true;
            break;
        }
    }
    if (!duplicate) try lines.insert(arena, last + 1, try arena.dupe(u8, row));

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (lines.items) |line| {
        try output.writer.writeAll(line);
        try output.writer.writeByte('\n');
    }
    return output.toOwnedSlice();
}

fn renderConvergence(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) !void {
    if (args.len != 8) return error.Usage;
    const log_path, const json_path, const existing_markdown_path, const markdown_path, const recorded_date, const current_commit, const dirty_value = args[1..8].*;
    const log = try readFile(allocator, io, log_path);
    defer allocator.free(log);
    var parsed = try evidence_marker.extract(allocator, log, convergence_marker, .convergence);
    defer parsed.deinit();
    const object = try objectOf(parsed.value);
    const current_dirty = if (std.mem.eql(u8, dirty_value, "true")) true else if (std.mem.eql(u8, dirty_value, "false")) false else return error.Usage;
    try sameSource(object, current_commit, current_dirty);
    if (!validDate(recorded_date)) return error.InvalidDate;
    const source_commit = try stringField(object, "sourceCommit");
    const short_commit = source_commit[0..8];

    const json = try renderConvergenceJson(allocator, object, short_commit);
    defer allocator.free(json);
    const existing = try readFile(allocator, io, existing_markdown_path);
    defer allocator.free(existing);
    const row = try std.fmt.allocPrint(
        allocator,
        "| {s} | `{s}` | `{s}` | {d} | {s} | {s} | `{s}` | {d}% ({d}/{d}) | {d}% ({d}/{d}) | {d} | {d}% ({d}/{d}) |",
        .{
            recorded_date,
            short_commit,
            (try stringField(object, "corpusVersion"))[0..12],
            try integerField(object, "corpusCases"),
            try stringField(object, "provider"),
            try stringField(object, "model"),
            (try stringField(object, "policyHash"))[0..12],
            try integerField(object, "rawFirstDraftPassPercent"),
            try integerField(object, "rawFirstDraftPasses"),
            try integerField(object, "corpusCases"),
            try integerField(object, "firstAttemptGreenPercent"),
            try integerField(object, "firstAttemptGreens"),
            try integerField(object, "corpusCases"),
            try integerField(object, "medianRoundtrips"),
            try integerField(object, "intentPassPercent"),
            try integerField(object, "intentPasses"),
            try integerField(object, "intentChecked"),
        },
    );
    defer allocator.free(row);
    const markdown = try renderConvergenceMarkdown(allocator, existing, row);
    defer allocator.free(markdown);
    if (markdown.len == 0) return error.EmptyRenderedOutput;
    try writeFile(io, json_path, json);
    try writeFile(io, markdown_path, markdown);
}

fn extractAuxiliary(log: []const u8, marker: []const u8) PublishFailure![]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, marker)) continue;
        if (found != null) return error.DuplicateOrMissingAuxiliaryMarker;
        found = std.mem.trim(u8, line[marker.len..], " \t\r");
    }
    return found orelse error.DuplicateOrMissingAuxiliaryMarker;
}

fn parseSeed(allocator: std.mem.Allocator, log: []const u8) !std.json.Parsed(SeedPayload) {
    const encoded = try extractAuxiliary(log, seed_marker);
    return std.json.parseFromSlice(SeedPayload, allocator, encoded, .{}) catch error.InvalidSeedEvidence;
}

fn parseUnion(allocator: std.mem.Allocator, log: []const u8) !std.json.Parsed(UnionPayload) {
    const encoded = try extractAuxiliary(log, union_marker);
    return std.json.parseFromSlice(UnionPayload, allocator, encoded, .{}) catch error.InvalidUnionEvidence;
}

fn isLowerHexHash(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn validateSeedEvidence(seed: SeedPayload, rules_total: usize) PublishFailure!void {
    if (seed.seedsTotal == 0 or seed.verifiedRules == 0 or
        seed.verifiedRules != seed.verified.len or
        seed.seedsTotal < seed.verifiedRules or
        seed.verified.len > rules_total or
        seed.unseeded.len != rules_total - seed.verified.len)
        return error.InvalidSeedEvidence;

    for (seed.verified, 0..) |code, index| {
        if (code.len == 0) return error.InvalidSeedEvidence;
        for (seed.verified[0..index]) |prior| {
            if (std.mem.eql(u8, code, prior)) return error.InvalidSeedEvidence;
        }
    }
    for (seed.unseeded, 0..) |row, index| {
        if (row.code.len == 0 or reasonMeaning(row.reason) == null)
            return error.InvalidSeedEvidence;
        if (containsCode(seed.verified, row.code)) return error.InvalidSeedEvidence;
        for (seed.unseeded[0..index]) |prior| {
            if (std.mem.eql(u8, row.code, prior.code)) return error.InvalidSeedEvidence;
        }
    }
}

fn validateUnionEvidence(
    union_payload: UnionPayload,
    corpus_version: []const u8,
    current_tripped: []const std.json.Value,
) PublishFailure!void {
    if (!std.mem.eql(u8, union_payload.corpusVersion, corpus_version) or
        !isLowerHexHash(union_payload.sourceTreeHash) or
        union_payload.observations == 0 or
        union_payload.distinctSets == 0 or
        union_payload.distinctSets > union_payload.observations or
        union_payload.smallestSet == 0 or
        union_payload.smallestSet > union_payload.largestSet or
        union_payload.largestSet > union_payload.unionCount or
        union_payload.unionCount == 0 or
        union_payload.unionCount != union_payload.@"union".len or
        current_tripped.len < union_payload.smallestSet or
        current_tripped.len > union_payload.largestSet or
        (union_payload.distinctSets == 1 and
            (union_payload.smallestSet != union_payload.largestSet or
                union_payload.unionCount != union_payload.largestSet)))
        return error.InvalidUnionEvidence;

    const minimum_largest = @divFloor(union_payload.unionCount, union_payload.distinctSets) +
        @intFromBool(@rem(union_payload.unionCount, union_payload.distinctSets) != 0);
    if (union_payload.largestSet < minimum_largest) return error.InvalidUnionEvidence;

    for (union_payload.@"union", 0..) |code, index| {
        if (code.len == 0) return error.InvalidUnionEvidence;
        for (union_payload.@"union"[0..index]) |prior| {
            if (std.mem.eql(u8, code, prior)) return error.InvalidUnionEvidence;
        }
    }
    for (current_tripped) |value| {
        if (value != .string or !containsCode(union_payload.@"union", value.string))
            return error.InvalidUnionEvidence;
    }
}

fn containsCode(values: []const []const u8, code: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, code)) return true;
    return false;
}

fn valueArrayContains(values: []const std.json.Value, code: []const u8) bool {
    for (values) |value| if (value == .string and std.mem.eql(u8, value.string, code)) return true;
    return false;
}

fn writeCodes(writer: *std.Io.Writer, values: anytype) !void {
    if (values.len == 0) {
        try writer.writeAll("none");
        return;
    }
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        const code = switch (@TypeOf(value)) {
            std.json.Value => value.string,
            else => value,
        };
        try writer.print("`{s}`", .{code});
    }
}

const ReasonGroup = struct {
    reason: []const u8,
    codes: std.ArrayList([]const u8) = .empty,
};

fn reasonMeaning(reason: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, reason, "no-producer")) return "The registry carries the code and no code path constructs a diagnostic with it, so nothing can emit it";
    if (std.mem.eql(u8, reason, "shadowed")) return "Another checker refuses the construct first, so this rule's diagnostic never reaches the stream";
    if (std.mem.eql(u8, reason, "non-default")) return "Emitted only under an opt-in mode the veto does not run";
    return null;
}

fn renderRemainder(
    allocator: std.mem.Allocator,
    total: usize,
    verified: usize,
    rows: []const SeedRow,
) ![]u8 {
    var groups = [_]ReasonGroup{
        .{ .reason = "no-producer" },
        .{ .reason = "shadowed" },
        .{ .reason = "non-default" },
    };
    defer for (&groups) |*group| group.codes.deinit(allocator);
    for (rows) |row| {
        var matched = false;
        for (&groups) |*group| {
            if (std.mem.eql(u8, group.reason, row.reason)) {
                try group.codes.append(allocator, row.code);
                matched = true;
                break;
            }
        }
        if (!matched) return error.InvalidSeedEvidence;
    }
    std.mem.sort(ReasonGroup, &groups, {}, struct {
        fn lessThan(_: void, a: ReasonGroup, b: ReasonGroup) bool {
            if (a.codes.items.len != b.codes.items.len) return a.codes.items.len > b.codes.items.len;
            return std.mem.order(u8, a.reason, b.reason) == .lt;
        }
    }.lessThan);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (rows.len == 0) {
        try output.writer.print("None. Every one of the {d} advertised rules is verified firing by a\ndefect seed.\n", .{total});
        return output.toOwnedSlice();
    }
    const left = total - verified;
    if (left == 1) {
        const group = for (groups) |group| {
            if (group.codes.items.len != 0) break group;
        } else return error.InvalidSeedEvidence;
        try output.writer.print("One advertised rule of {d} is not verified by a seed: ", .{total});
        try writeCodes(&output.writer, group.codes.items);
        try output.writer.print(", because it is\n`{s}`. {s}.\n\n", .{ group.reason, reasonMeaning(group.reason).? });
    } else {
        try output.writer.print(
            "The {d} advertised rules the section above leaves out, and why each is out.\n" ++
                "This is not a backlog: a rule is listed here only when writing another\n" ++
                "seed cannot reach it.\n\n| Reason | Rules | What it means |\n|---|---|---|\n",
            .{left},
        );
        for (groups) |group| {
            if (group.codes.items.len == 0) continue;
            try output.writer.print("| `{s}` | ", .{group.reason});
            try writeCodes(&output.writer, group.codes.items);
            try output.writer.print(" | {s} |\n", .{reasonMeaning(group.reason).?});
        }
        try output.writer.writeByte('\n');
    }
    var no_producer: usize = 0;
    for (groups) |group| {
        if (std.mem.eql(u8, group.reason, "no-producer")) no_producer = group.codes.items.len;
    }
    if (no_producer != 0) {
        try output.writer.print(
            "The `no-producer` group is the load-bearing one. Each of those {d} codes is\n" ++
                "advertised by `zts describe-rule` and counted in the {d} denominator every\n" ++
                "figure on this page divides by, and no seed and no recorded draft can ever\n" ++
                "trip it. Reading {d} of {d} as \"{d} still to write\" is wrong about them.\n",
            .{ no_producer, total, verified, total, left },
        );
    } else {
        try output.writer.writeAll(
            "Nothing here is waiting on a seed. The registry once advertised codes no\n" ++
                "code path could construct; those were deleted rather than seeded, which is\n" ++
                "why this section is now one line instead of a table of seventeen.\n",
        );
    }
    try output.writer.writeAll(
        "\nThe rows live in `scripts/unseeded-rules.allow` with the probe behind each one.\n" ++
            "The stand-in gate enforces the list in both directions: an advertised rule that\n" ++
            "is neither seeded nor listed fails, and so does a row for a code a seed has\n" ++
            "since covered. Neither list can drift from the registry without failing a build.\n",
    );
    return output.toOwnedSlice();
}

fn writeCoverageJson(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    recorded: []const u8,
    seed: SeedPayload,
    union_payload: UnionPayload,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2, .escape_unicode = true },
    };
    try json.beginObject();
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try json.objectField(entry.key_ptr.*);
        try json.write(entry.value_ptr.*);
    }
    try json.objectField("recorded");
    try json.write(recorded);
    try json.objectField("seedSuite");
    try json.beginObject();
    try json.objectField("seedsTotal");
    try json.write(seed.seedsTotal);
    try json.objectField("verifiedRules");
    try json.write(seed.verifiedRules);
    try json.objectField("verified");
    try json.write(seed.verified);
    try json.objectField("unseeded");
    try json.write(seed.unseeded);
    try json.endObject();
    try json.objectField("corpusUnion");
    try json.write(union_payload);
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn renderCoverageMarkdown(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    recorded: []const u8,
    seed: SeedPayload,
    union_payload: UnionPayload,
) ![]u8 {
    const total: usize = @intCast(try integerField(object, "rulesTotal"));
    const tripped = try valueStrings(object.get("tripped").?);
    const untripped = try valueStrings(object.get("untripped").?);
    const off_registry = try valueStrings(object.get("offRegistry").?);
    var seed_only: usize = 0;
    for (seed.verified) |code| {
        if (valueArrayContains(untripped, code)) seed_only += 1;
    }
    var corpus_only: usize = 0;
    for (tripped) |value| {
        if (!containsCode(seed.verified, value.string)) corpus_only += 1;
    }
    var overlap: usize = 0;
    for (tripped) |value| {
        if (containsCode(seed.verified, value.string)) overlap += 1;
    }
    const combined = seed.verified.len + tripped.len - overlap;
    var union_all = seed.verified.len;
    for (union_payload.@"union") |code| {
        if (!containsCode(seed.verified, code)) union_all += 1;
    }
    const remainder = try renderRemainder(allocator, total, seed.verifiedRules, seed.unseeded);
    defer allocator.free(remainder);
    const version = try stringField(object, "corpusVersion");
    const union_runs_phrase = if (union_payload.observations == 1)
        try allocator.dupe(u8, "the single published run")
    else
        try std.fmt.allocPrint(allocator, "the {d} published runs", .{union_payload.observations});
    defer allocator.free(union_runs_phrase);
    const union_shapes_phrase = if (union_payload.distinctSets == 1)
        try allocator.dupe(u8, "one shape")
    else
        try std.fmt.allocPrint(allocator, "{d} distinct shapes", .{union_payload.distinctSets});
    defer allocator.free(union_shapes_phrase);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.print(
        "<!-- Generated file. Do not edit. Run `bash scripts/update-coverage.sh` to regenerate it. -->\n\n" ++
            "# Coverage\n\nWhat the offline suite proves, and what it does not.\n\n" ++
            "> The offline suite proves two things. The harness is faithful: recorder capture\n" ++
            "> and replay, the loop, veto, apply, retry, salvage, compiler repair, and the\n" ++
            "> hole loop execute correctly over their declared fixtures. And the\n" ++
            "> corpus is load-bearing: of the compiler's {d} advertised rules,\n" ++
            "> {d} are tripped by at least one case. It proves nothing about what a\n" ++
            "> model will draft. Raw first-draft pass, first-attempt green, median\n" ++
            "> round-trips, and intent pass\n" ++
            "> exist only as recordings of a live model, an offline run is structurally unable\n" ++
            "> to produce or update them, and any figure of that shape that does not carry a\n" ++
            "> cassette-derived model column is a defect in\n" ++
            "> [convergence.md](convergence.md).\n\n" ++
            "## What runs with no API key\n\n" ++
            "| Path | Offline | How |\n|---|---|---|\n" ++
            "| Recorder transport and replay | yes | a loopback Chat Completions response passes through the production local record tee, disk cassette, loader, and replay client |\n" ++
            "| Loop, veto, apply | yes | every entry in the declared range, driven through the real server and the real loop |\n" ++
            "| Veto retry | yes | defect seeds whose bad draft the veto rejects and whose good draft lands on the retry |\n" ++
            "| Salvage-on-reject | yes | canonical-band seeds, asserted against the exact bytes normalizing the draft produces |\n" ++
            "| Compiler-authored repair lane | yes | two repairable defect seeds land a verified compiler candidate with no model retry |\n" ++
            "| Hole publisher and fill | yes | the in-process compiler publishes the frame, then `zts_expert_fill_hole` proposes one exact-site replacement |\n" ++
            "| Multi-turn hole loop | yes | a two-hole seed applies one fill per turn, republishes the changed frame, and finishes with both fills composed |\n\n" ++
            "Only model behavior stays live-only. Creating a new empirical cassette and\n" ++
            "publishing first-draft, intent, or round-trip measurements still requires the\n" ++
            "named model. Developing and verifying the harness, veto, salvage, repair, and\n" ++
            "hole-loop machinery does not.\n\n" ++
            "Recorded {s} over corpus `{s}`. The replay fails\n" ++
            "when this page drifts from the run, so it is regenerated in the same commit as\n" ++
            "whatever moved it, and `git log docs/coverage.json` is the history.\n\n" ++
            "## Rule coverage\n\n" ++
            "| Rules advertised | Tripped by at least one case | Untripped |\n|---|---|---|\n" ++
            "| {d} | {d} | {d} |\n\nTripped: ",
        .{ total, tripped.len, recorded, version[0..12], total, tripped.len, untripped.len },
    );
    try writeCodes(writer, tripped);
    try writer.writeAll(
        "\n\nThe list above is a fair description of what these prompts ask for and a poor\n" ++
            "description of what the compiler proves. It is the mechanical form of an\n" ++
            "argument [convergence.md](convergence.md) had been making in prose: a fence no\n" ++
            "case stands on cannot move a published number, and nine consecutive rows reading\n" ++
            "90% over one corpus is what that looks like from outside.\n\n" ++
            "The previous sentence here counted the tripped rules by family in prose, and it\n" ++
            "was wrong the first time the count moved. Nothing in this section restates a\n" ++
            "number the generator computes; the codes are printed, and a reader who wants the\n" ++
            "breakdown reads them.\n\nUntripped: ",
    );
    try writeCodes(writer, untripped);
    try writer.print(
        "\n\n## What this corpus has ever reached\n\n" ++
            "The row above is one draw. Recordings of the same headline corpus have measured\n" ++
            "different sets. A rule is counted only when the recorded model output makes the\n" ++
            "mistake that trips it. Across {s} of corpus `{s}`,\n" ++
            "the tripped set took {s}, the smallest naming {d}\n" ++
            "rules and the largest {d}.\n\n" ++
            "| Union across runs | Smallest single run | Largest single run |\n|---|---|---|\n" ++
            "| {d} | {d} | {d} |\n\nEver tripped: ",
        .{
            union_runs_phrase,
            version[0..12],
            union_shapes_phrase,
            union_payload.smallestSet,
            union_payload.largestSet,
            union_payload.unionCount,
            union_payload.smallestSet,
            union_payload.largestSet,
        },
    );
    try writeCodes(writer, union_payload.@"union");
    try writer.print(
        "\n\nThis is the fairer answer to \"what do these prompts reach\", and no single row\n" ++
            "can give it. It is computed by `zig build coverage-union` from\n" ++
            "`git log docs/coverage.json`, which is this page's own history; a shallow clone\n" ++
            "is refused rather than published as a complete union.\n\n" ++
            "It still measures the model, not the compiler. A rule absent here is one no\n" ++
            "recorded draft has ever violated, which is not the same as one the compiler\n" ++
            "would let pass - that is the next section.\n\n" ++
            "## Rules observed firing at all\n\n" ++
            "A different question, kept on its own so the two are not read as one figure.\n" ++
            "The section above counts rules a recorded model's drafts happened to trip. This\n" ++
            "one counts rules the compiler was *observed* rejecting, from the defect-seed\n" ++
            "suite in `packages/pi/src/standin/defect_seeds.zig`: each seed pairs a\n" ++
            "veto-clean baseline with a draft that introduces exactly one code, and the\n" ++
            "stand-in gate re-derives the outcome through the real veto before this number\n" ++
            "is printed.\n\n" ++
            "| Rules advertised | Verified firing by a seed | Seeds |\n|---|---|---|\n" ++
            "| {d} | {d} | {d} |\n\nVerified: ",
        .{ total, seed.verifiedRules, seed.seedsTotal },
    );
    try writeCodes(writer, seed.verified);
    try writer.print(
        "\n\nNo model is involved, so this figure does not move when a recording draws\n" ++
            "differently. It also proves less: a seed shows the compiler rejects a draft the\n" ++
            "harness supplied, and says nothing about whether a model would ever write one.\n" ++
            "That is the question the section above answers, and only a recording can.\n\n" ++
            "Neither number bounds the other. The corpus leaves {d} of the rules\n" ++
            "verified here untripped; it trips {d} that no seed covers; and the two\n" ++
            "sets share {d}. Together they name {d} of the {d}\n" ++
            "advertised rules, and taking the corpus union above instead of this single run\n" ++
            "raises that to {d} - the closest thing to a combined answer this\n" ++
            "repository can produce, and still two claims added up rather than one\n" ++
            "measurement.\n\n## The rules no seed reaches\n\n{s}\n" ++
            "## Codes the registry does not carry\n\n",
        .{ seed_only, corpus_only, overlap, combined, total, union_all, remainder },
    );
    try writeCodes(writer, off_registry);
    try writer.writeAll(
        "\n\nThese are real diagnostics the corpus trips that no `rule_registry` entry\n" ++
            "carries - the parser, stripper, bool-checker, and type-checker families. The\n" ++
            "policy hash covers the registry, so it cannot see them: a change to any of these\n" ++
            "leaves the hash identical while the corpus behaves differently. A coverage count\n" ++
            "taken over the registry alone would both understate the corpus and hide that.\n\n" ++
            "## How this page is produced\n\n" ++
            "`zig build test-expert-app` replays the committed cassettes and prints one\n" ++
            "`[proof-coverage]` line. `scripts/update-coverage.sh` lifts it, writes\n" ++
            "[coverage.json](coverage.json), and renders this page.\n\n" ++
            "The replay carries three floors and a ratchet. The denominator must be credible,\n" ++
            "the collector must have read something, and the committed baseline in\n" ++
            "`packages/pi/src/expert_codegen_record.zig` must name at least five rules - an\n" ++
            "emptied baseline iterates nothing and reports a clean ratchet over no claim. The\n" ++
            "ratchet is one-directional and headline-model only: a corpus that grows trips\n" ++
            "more and nothing complains, a corpus that stops standing on a fence fails and\n" ++
            "names it.\n",
    );
    return output.toOwnedSlice();
}

fn renderCoverage(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) !void {
    if (args.len != 9) return error.Usage;
    const log_path, const seed_log_path, const union_log_path, const json_path, const markdown_path, const recorded_date, const current_commit, const dirty_value = args[1..9].*;
    const replay_log = try readFile(allocator, io, log_path);
    defer allocator.free(replay_log);
    var evidence = try evidence_marker.extract(allocator, replay_log, coverage_marker, .coverage);
    defer evidence.deinit();
    const object = try objectOf(evidence.value);
    const current_dirty = if (std.mem.eql(u8, dirty_value, "true")) true else if (std.mem.eql(u8, dirty_value, "false")) false else return error.Usage;
    try sameSource(object, current_commit, current_dirty);
    if (!validDate(recorded_date)) return error.InvalidDate;

    const seed_log = try readFile(allocator, io, seed_log_path);
    defer allocator.free(seed_log);
    var seed_parsed = try parseSeed(allocator, seed_log);
    defer seed_parsed.deinit();
    const seed = seed_parsed.value;
    const rules_total: usize = @intCast(try integerField(object, "rulesTotal"));
    if (seed.rulesTotal != rules_total) return error.InvalidSeedEvidence;
    try validateSeedEvidence(seed, rules_total);

    const union_log = try readFile(allocator, io, union_log_path);
    defer allocator.free(union_log);
    var union_parsed = try parseUnion(allocator, union_log);
    defer union_parsed.deinit();
    const union_payload = union_parsed.value;
    const current_tripped = try valueStrings(object.get("tripped").?);
    try validateUnionEvidence(
        union_payload,
        try stringField(object, "corpusVersion"),
        current_tripped,
    );

    const json = try writeCoverageJson(allocator, object, recorded_date, seed, union_payload);
    defer allocator.free(json);
    const markdown = try renderCoverageMarkdown(allocator, object, recorded_date, seed, union_payload);
    defer allocator.free(markdown);
    if (json.len == 0 or markdown.len == 0) return error.EmptyRenderedOutput;
    try writeFile(io, json_path, json);
    try writeFile(io, markdown_path, markdown);
}

fn printCoverageInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) !void {
    if (args.len != 2) return error.Usage;
    const replay_log = try readFile(allocator, io, args[1]);
    defer allocator.free(replay_log);
    var evidence = try evidence_marker.extract(allocator, replay_log, coverage_marker, .coverage);
    defer evidence.deinit();
    const object = try objectOf(evidence.value);
    const tripped = try valueStrings(object.get("tripped").?);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print("{s}\n", .{try stringField(object, "corpusVersion")});
    for (tripped, 0..) |value, index| {
        if (index != 0) try stdout_writer.interface.writeByte(' ');
        try stdout_writer.interface.writeAll(value.string);
    }
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var args_iter = std.process.Args.Iterator.init(args_vector);
    defer args_iter.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }
    while (args_iter.next()) |arg| try list.append(allocator, try allocator.dupe(u8, arg));
    return list.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io_backend.deinit();
    const io = io_backend.io();
    const args = try collectArgs(allocator, init.args);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }
    if (args.len < 2) return error.Usage;
    if (std.mem.eql(u8, args[1], "convergence")) return renderConvergence(allocator, io, args[1..]);
    if (std.mem.eql(u8, args[1], "coverage")) return renderCoverage(allocator, io, args[1..]);
    if (std.mem.eql(u8, args[1], "coverage-inputs")) return printCoverageInputs(allocator, io, args[1..]);
    return error.Usage;
}

test "auxiliary markers require exactly one line" {
    try std.testing.expectEqualStrings("{}", try extractAuxiliary("[seed-coverage] {}\n", seed_marker));
    try std.testing.expectError(error.DuplicateOrMissingAuxiliaryMarker, extractAuxiliary("", seed_marker));
    try std.testing.expectError(error.DuplicateOrMissingAuxiliaryMarker, extractAuxiliary("[seed-coverage] {}\n[seed-coverage] {}\n", seed_marker));
}

test "auxiliary consumers require complete seed and union inputs" {
    const seed_log =
        "[seed-coverage] {\"seedsTotal\":3,\"rulesTotal\":3,\"verifiedRules\":2," ++
        "\"verified\":[\"ZTS001\",\"ZTS002\"],\"unseeded\":[{\"code\":\"ZTS003\",\"reason\":\"non-default\"}]}\n";
    var seed = try parseSeed(std.testing.allocator, seed_log);
    defer seed.deinit();
    try std.testing.expectEqual(@as(usize, 3), seed.value.rulesTotal);
    try std.testing.expectError(
        error.InvalidSeedEvidence,
        parseSeed(std.testing.allocator, "[seed-coverage] {\"seedsTotal\":3}\n"),
    );

    const union_log =
        "[coverage-union] {\"corpusVersion\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"sourceTreeHash\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"observations\":1," ++
        "\"distinctSets\":1,\"smallestSet\":2,\"largestSet\":2,\"unionCount\":2," ++
        "\"union\":[\"ZTS001\",\"ZTS002\"]}\n";
    var union_payload = try parseUnion(std.testing.allocator, union_log);
    defer union_payload.deinit();
    try std.testing.expectEqual(@as(usize, 2), union_payload.value.unionCount);
    try std.testing.expectError(
        error.InvalidUnionEvidence,
        parseUnion(std.testing.allocator, "[coverage-union] {\"observations\":1}\n"),
    );
}

test "source comparison refuses movement and dirty evidence" {
    var clean = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"sourceCommit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sourceDirty\":false}",
        .{},
    );
    defer clean.deinit();
    const clean_object = clean.value.object;
    try sameSource(clean_object, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false);
    try std.testing.expectError(
        error.SourceMoved,
        sameSource(clean_object, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", false),
    );

    var dirty = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"sourceCommit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"sourceDirty\":true}",
        .{},
    );
    defer dirty.deinit();
    try std.testing.expectError(
        error.DirtySource,
        sameSource(dirty.value.object, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", true),
    );
}

test "convergence renderer appends only inside the results table" {
    const source =
        "# Convergence\n\n## Results\n\n" ++
        "| Recorded | Commit | Corpus | Cases | Provider | Model | Policy | Raw first-draft pass | First-attempt green | Median round-trips | Intent pass |\n" ++
        "|---|---|---|---|---|---|---|---|---|---|---|\n" ++
        "| old | row | here | 19 | deepseek | model | hash | 1 | 1 | 1 | 1 |\n\n" ++
        "| Other | Table |\n|---|---|\n| stays | last |\n";
    const row = "| new | row | here | 19 | deepseek | model | hash | 2 | 2 | 2 | 2 |";
    const rendered = try renderConvergenceMarkdown(std.testing.allocator, source, row);
    defer std.testing.allocator.free(rendered);
    const new_at = std.mem.indexOf(u8, rendered, row).?;
    const other_at = std.mem.indexOf(u8, rendered, "| Other | Table |").?;
    try std.testing.expect(new_at < other_at);
    const rendered_twice = try renderConvergenceMarkdown(std.testing.allocator, rendered, row);
    defer std.testing.allocator.free(rendered_twice);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered_twice, row));
}

test "publication JSON keeps Python ASCII escaping" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeJsonString(&output.writer, "caf\xc3\xa9 \xf0\x9f\x98\x80");
    try std.testing.expectEqualStrings("\"caf\\u00e9 \\ud83d\\ude00\"", output.written());
}
