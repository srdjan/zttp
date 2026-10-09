//! TypeMap: Structured metadata for type annotations stripped by the TypeScript stripper.
//!
//! When the stripper runs, it records every type annotation it strips
//! as a TypeMapEntry. This allows downstream passes (type checker, type environment)
//! to reconstruct type information without modifying the parser or IR.
//!
//! Each entry records:
//! - What kind of annotation it is (type alias, param, return, etc.)
//! - Source byte offsets for the type text in the *original* (pre-strip) source
//! - Context position (line/col) of the owning declaration
//! - Name byte offsets for the identifier being annotated

const std = @import("std");

/// Classification of type annotation sites.
pub const TypeMapKind = enum(u8) {
    /// `structural Foo = { ... }` - type alias declaration
    type_alias,
    /// `nominal Foo = string` - nominal/branded type declaration
    distinct_type,
    /// `const x: Type = ...` or `let x: Type = ...` - variable annotation
    var_annotation,
    /// `function f(x: Type, ...)` - parameter annotation
    param_annotation,
    /// `function f(...): Type` - return type annotation
    return_annotation,
    /// `function f(x: unknown): x is string` - type guard return annotation
    type_guard_annotation,
    /// `function f<T, U>(...)` or `structural Foo<T> = ...` - generic parameters
    generic_params,
    /// `first<string>(xs)` - explicit type arguments at a call site.
    /// Distinct from `generic_params` because the two are otherwise
    /// indistinguishable once stripped: both are an unnamed balanced `<...>`
    /// followed by `(`. Only the stripper can tell them apart, by whether the
    /// `<` follows an operand, so it records which one it saw.
    call_type_arguments,
};

/// A single recorded type annotation.
pub const TypeMapEntry = struct {
    /// What kind of annotation this is.
    kind: TypeMapKind,
    /// Byte offset in original source where the type text starts (after the colon/equals).
    source_start: u32,
    /// Byte offset in original source where the type text ends.
    source_end: u32,
    /// Line number of the owning declaration (1-based).
    context_line: u32,
    /// Column of the owning declaration (1-based).
    context_col: u32,
    /// Byte offset of the name this type annotates (0 = none, e.g. for return types).
    name_start: u32,
    /// Byte offset end of the name.
    name_end: u32,
    /// Zero-based occurrence among variable declarations with the same name.
    /// Present only for variable annotations and independent of locations.
    name_ordinal: ?u32 = null,
    /// Byte offset, in the stripped source the parser reads, of the `(` that
    /// opens the parameter list of the signature this entry belongs to. It is
    /// the identity of a signature: every parameter annotation, the return
    /// annotation, and the type parameters of one function share it, and no
    /// two functions do. A line is not an identity (a function and an arrow
    /// can share one) and neither is a name (nested functions repeat them).
    /// Present only for parameter, return, type-guard, and generic-parameter
    /// annotations of a function or an arrow.
    signature_offset: ?u32 = null,
};

/// One span a later source transform replaced, in both coordinate systems.
/// Both TypeScript folding and TSX lowering use this representation, so their
/// maps compose without either frontend knowing about the other.
pub const SpanEdit = struct {
    /// Offset in the stripped code where the folded value starts.
    stripped_start: u32,
    /// Offset in the stripped code just past the folded value and its padding.
    stripped_end: u32,
    /// Offset in the source where the `comptime` keyword starts.
    source_start: u32,
    /// Offset in the source just past the `comptime(...)` closing paren.
    source_end: u32,
};

/// Map an offset through an ordered set of non-overlapping replacement spans.
pub fn offsetThroughEdits(edits: []const SpanEdit, output_offset: u32) u32 {
    var shift: i64 = 0;
    for (edits) |edit| {
        if (output_offset < edit.stripped_start) break;
        if (output_offset < edit.stripped_end) return edit.source_start;
        shift = @as(i64, edit.source_end) - @as(i64, edit.stripped_end);
    }
    const mapped = @as(i64, output_offset) + shift;
    return @intCast(std.math.clamp(mapped, 0, std.math.maxInt(u32)));
}

/// Collection of type annotations extracted during stripping.
pub const TypeMap = struct {
    entries: std.ArrayListUnmanaged(TypeMapEntry),
    /// Borrowed reference to the original (pre-strip) source text.
    /// Used by getTypeText to extract raw type strings.
    original_source: []const u8,
    /// How the parser's offsets map back to the stripped source this map was
    /// recorded against. Empty unless a later transform (TSX lowering) changed
    /// the text between the stripper and the parser, which is the only case in
    /// which the parser's offset of a function differs from the offset the
    /// stripper recorded for it. Owned by this map.
    parser_edits: []const SpanEdit = &.{},

    pub fn init(original_source: []const u8) TypeMap {
        return .{
            .entries = .empty,
            .original_source = original_source,
        };
    }

    pub fn deinit(self: *TypeMap, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        if (self.parser_edits.len > 0) allocator.free(self.parser_edits);
        self.parser_edits = &.{};
    }

    /// Record the edits a transform applied between the stripper and the
    /// parser. The map keeps its own copy.
    pub fn setParserEdits(self: *TypeMap, allocator: std.mem.Allocator, edits: []const SpanEdit) !void {
        const owned = try allocator.dupe(SpanEdit, edits);
        if (self.parser_edits.len > 0) allocator.free(self.parser_edits);
        self.parser_edits = owned;
    }

    /// The offset, in the stripped source, of a position the parser reports.
    pub fn strippedOffset(self: *const TypeMap, parser_offset: u32) u32 {
        return offsetThroughEdits(self.parser_edits, parser_offset);
    }

    /// Add a type annotation entry.
    pub fn addEntry(self: *TypeMap, allocator: std.mem.Allocator, entry: TypeMapEntry) !void {
        try self.entries.append(allocator, entry);
    }

    /// Extract the raw type text for an entry from the original source.
    pub fn getTypeText(self: *const TypeMap, entry: TypeMapEntry) []const u8 {
        if (entry.source_start >= self.original_source.len or
            entry.source_end > self.original_source.len or
            entry.source_start >= entry.source_end)
        {
            return "";
        }
        return self.original_source[entry.source_start..entry.source_end];
    }

    /// Extract the name text for an entry from the original source.
    pub fn getNameText(self: *const TypeMap, entry: TypeMapEntry) ?[]const u8 {
        if (entry.name_start == 0 and entry.name_end == 0) return null;
        if (entry.name_start >= self.original_source.len or
            entry.name_end > self.original_source.len or
            entry.name_start >= entry.name_end)
        {
            return null;
        }
        return self.original_source[entry.name_start..entry.name_end];
    }

    /// Return the number of recorded entries.
    pub fn count(self: *const TypeMap) usize {
        return self.entries.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TypeMap basic operations" {
    const allocator = std.testing.allocator;
    const source = "const x: number = 42;";

    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .var_annotation,
        .source_start = 9, // "number"
        .source_end = 15,
        .context_line = 1,
        .context_col = 1,
        .name_start = 6, // "x"
        .name_end = 7,
    });

    try std.testing.expectEqual(@as(usize, 1), tm.count());
    try std.testing.expectEqualStrings("number", tm.getTypeText(tm.entries.items[0]));
    try std.testing.expectEqualStrings("x", tm.getNameText(tm.entries.items[0]).?);
}

test "TypeMap type alias" {
    const allocator = std.testing.allocator;
    const source = "structural Config = { port: number; host: string };";

    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    const body_at: u32 = @intCast(std.mem.indexOf(u8, source, "{ port").?);
    const name_at: u32 = @intCast(std.mem.indexOf(u8, source, "Config").?);
    try tm.addEntry(allocator, .{
        .kind = .type_alias,
        .source_start = body_at, // "{ port: number; host: string }"
        .source_end = body_at + 30,
        .context_line = 1,
        .context_col = 1,
        .name_start = name_at, // "Config"
        .name_end = name_at + 6,
    });

    try std.testing.expectEqualStrings("{ port: number; host: string }", tm.getTypeText(tm.entries.items[0]));
    try std.testing.expectEqualStrings("Config", tm.getNameText(tm.entries.items[0]).?);
}

test "TypeMap return annotation has no name" {
    const allocator = std.testing.allocator;
    const source = "function handler(req: Request): Response { }";

    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .return_annotation,
        .source_start = 32, // "Response"
        .source_end = 40,
        .context_line = 1,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    try std.testing.expect(tm.getNameText(tm.entries.items[0]) == null);
    try std.testing.expectEqualStrings("Response", tm.getTypeText(tm.entries.items[0]));
}

test "TypeMap empty source edge cases" {
    const allocator = std.testing.allocator;
    const source = "";

    var tm = TypeMap.init(source);
    defer tm.deinit(allocator);

    try tm.addEntry(allocator, .{
        .kind = .var_annotation,
        .source_start = 100,
        .source_end = 200,
        .context_line = 1,
        .context_col = 1,
        .name_start = 0,
        .name_end = 0,
    });

    try std.testing.expectEqualStrings("", tm.getTypeText(tm.entries.items[0]));
}
