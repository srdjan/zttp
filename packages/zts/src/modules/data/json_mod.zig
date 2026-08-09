//! zttp:json - the JSON boundary (spec 6.4).
//!
//! `parseJson` returns a `Result<JsonValue, JsonError>`: object nodes are
//! `Dict<string, JsonValue>` in wire order, `null` is data rather than an
//! absence sentinel, duplicate keys are refused rather than last-wins, and
//! every failure names itself with an offset where it has one.
//!
//! It does not share `builtins/json.zig`'s parser. That one builds JS objects
//! with hidden-class shape caching, reports one `InvalidJson` for every
//! failure, and maps JSON `null` to `undefined` - the last of which was true
//! of the language until `null` was admitted and is a fidelity loss now. The
//! shipped `JSON.parse` keeps its behavior; this module is the boundary the
//! canonical profile points at, and it is written to spec 6.4 rather than
//! retrofitted onto a parser with different obligations.
//!
//! `parseJsonBytes` is not declared here. It needs `Bytes`, which arrives in
//! phase 5, and an export whose type does not exist is exactly the fail-open
//! the frozen-signature gate exists to catch.

const std = @import("std");
const context = @import("../../context.zig");
const value = @import("../../value.zig");
const object = @import("../../object.zig");
const dict = @import("../../dict.zig");
const util = @import("../internal/util.zig");
const mb = @import("../../module_binding.zig");
const helpers = @import("../../builtins/helpers.zig");

const JSValue = value.JSValue;
const JSObject = object.JSObject;

/// The limits spec 6.4 says the runtime policy selects. They live in one place
/// rather than as a constant inside the parser so a runtime can lower them;
/// the defaults are what the engine's own JSON parser has always enforced, so
/// admitting this module changes the taxonomy and not the accepted language.
pub const Limits = struct {
    max_depth: u16 = 512,
    max_input_bytes: usize = 8 * 1024 * 1024,
};

pub var limits: Limits = .{};

// Both exports are `replay_pure`: parsing and encoding read only their
// arguments, so running them live during replay is hermetic.
pub const binding = mb.ModuleBinding{
    .specifier = "zttp:json",
    .name = "json",
    .required_capabilities = &.{},
    .exports = &.{
        .{ .name = "parseJson", .func = parseJsonNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.string}, .laws = &.{.pure}, .replay_pure = true },
        .{ .name = "stringifyJson", .func = stringifyJsonNative, .arg_count = 1, .effect = .none, .returns = .result, .param_types = &.{.unknown}, .laws = &.{.pure}, .replay_pure = true },
    },
};

pub const exports = binding.toModuleExports();

/// The closed error taxonomy of spec 6.4. Every parse or encode failure is one
/// of these, so a caller matching on `kind` has a finite set to cover.
const ErrorKind = enum {
    invalid_syntax,
    duplicate_key,
    depth_limit,
    size_limit,
    non_finite_number,
    cycle,

    fn wire(self: ErrorKind) []const u8 {
        return switch (self) {
            .invalid_syntax => "invalid-syntax",
            .duplicate_key => "duplicate-key",
            .depth_limit => "depth-limit",
            .size_limit => "size-limit",
            .non_finite_number => "non-finite-number",
            .cycle => "cycle",
        };
    }
};

const Failure = struct {
    kind: ErrorKind,
    offset: usize = 0,
    key: ?[]const u8 = null,
    limit: usize = 0,
};

const ParseError = error{ Failed, OutOfMemory };

const Parser = struct {
    ctx: *context.Context,
    text: []const u8,
    pos: usize = 0,
    failure: Failure = .{ .kind = .invalid_syntax },
    /// Storage for a duplicate key's text. The decoded key is freed on every
    /// path, so the failure cannot borrow it; a longer key is reported
    /// truncated rather than kept alive past its owner.
    dup_key_buf: [256]u8 = undefined,

    fn fail(self: *Parser, kind: ErrorKind, offset: usize) ParseError {
        self.failure = .{ .kind = kind, .offset = offset };
        return error.Failed;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser, depth: u16) ParseError!JSValue {
        if (depth > limits.max_depth) {
            self.failure = .{ .kind = .depth_limit, .offset = self.pos, .limit = limits.max_depth };
            return error.Failed;
        }
        self.skipWs();
        if (self.pos >= self.text.len) return self.fail(.invalid_syntax, self.pos);

        return switch (self.text[self.pos]) {
            '{' => self.parseObject(depth),
            '[' => self.parseArray(depth),
            '"' => self.parseString(),
            't' => self.parseKeyword("true", JSValue.true_val),
            'f' => self.parseKeyword("false", JSValue.false_val),
            // Spec 6.4: `null` round-trips as data. Phase 3 admitted the value,
            // so the boundary that would have had to erase it no longer does.
            'n' => self.parseKeyword("null", JSValue.null_val),
            '-', '0'...'9' => self.parseNumber(),
            else => self.fail(.invalid_syntax, self.pos),
        };
    }

    fn parseKeyword(self: *Parser, word: []const u8, val: JSValue) ParseError!JSValue {
        if (self.text.len - self.pos < word.len or !std.mem.eql(u8, self.text[self.pos..][0..word.len], word)) {
            return self.fail(.invalid_syntax, self.pos);
        }
        self.pos += word.len;
        return val;
    }

    fn parseNumber(self: *Parser) ParseError!JSValue {
        const start = self.pos;
        if (self.pos < self.text.len and self.text[self.pos] == '-') self.pos += 1;
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break,
            }
        }
        const text = self.text[start..self.pos];
        const parsed = std.fmt.parseFloat(f64, text) catch return self.fail(.invalid_syntax, start);
        // JSON has no syntax for a non-finite number, so one can only arrive
        // through an overflowing literal. It is refused by name rather than
        // silently becoming an infinity.
        if (!std.math.isFinite(parsed)) {
            self.failure = .{ .kind = .non_finite_number, .offset = start };
            return error.Failed;
        }
        return JSValue.fromFloat(parsed);
    }

    /// Read a quoted string, decoding the escapes JSON defines. Returns the
    /// decoded bytes, owned by the context allocator.
    fn readString(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.text.len or self.text[self.pos] != '"') return self.fail(.invalid_syntax, self.pos);
        const open = self.pos;
        self.pos += 1;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.ctx.allocator);

        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '"') {
                self.pos += 1;
                return out.toOwnedSlice(self.ctx.allocator) catch return error.OutOfMemory;
            }
            if (c != '\\') {
                out.append(self.ctx.allocator, c) catch return error.OutOfMemory;
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.text.len) return self.fail(.invalid_syntax, open);
            const esc = self.text[self.pos];
            self.pos += 1;
            const decoded: u8 = switch (esc) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0C,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => {
                    if (self.text.len - self.pos < 4) return self.fail(.invalid_syntax, open);
                    const code = std.fmt.parseInt(u21, self.text[self.pos..][0..4], 16) catch
                        return self.fail(.invalid_syntax, self.pos);
                    self.pos += 4;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(code, &buf) catch return self.fail(.invalid_syntax, open);
                    out.appendSlice(self.ctx.allocator, buf[0..len]) catch return error.OutOfMemory;
                    continue;
                },
                else => return self.fail(.invalid_syntax, self.pos - 1),
            };
            out.append(self.ctx.allocator, decoded) catch return error.OutOfMemory;
        }
        return self.fail(.invalid_syntax, open);
    }

    fn parseString(self: *Parser) ParseError!JSValue {
        const bytes = try self.readString();
        defer self.ctx.allocator.free(bytes);
        return self.ctx.createString(bytes) catch return error.OutOfMemory;
    }

    fn parseArray(self: *Parser, depth: u16) ParseError!JSValue {
        self.pos += 1; // '['
        const out = helpers.createArrayWithPrototype(self.ctx) orelse return error.OutOfMemory;
        var index: u32 = 0;

        self.skipWs();
        if (self.pos < self.text.len and self.text[self.pos] == ']') {
            self.pos += 1;
            return JSValue.fromPtr(out);
        }

        while (true) {
            const element = try self.parseValue(depth + 1);
            out.setIndex(self.ctx.allocator, index, element) catch return error.OutOfMemory;
            index += 1;

            self.skipWs();
            if (self.pos >= self.text.len) return self.fail(.invalid_syntax, self.pos);
            switch (self.text[self.pos]) {
                ',' => self.pos += 1,
                ']' => {
                    self.pos += 1;
                    return JSValue.fromPtr(out);
                },
                else => return self.fail(.invalid_syntax, self.pos),
            }
        }
    }

    /// An object node is a `Dict<string, JsonValue>` in wire order. A repeated
    /// key is refused: spec 6.4 rejects duplicates rather than letting the
    /// last one win, so two documents that differ only in a repeat cannot
    /// silently decode to the same value.
    fn parseObject(self: *Parser, depth: u16) ParseError!JSValue {
        self.pos += 1; // '{'
        var out = dict.empty(self.ctx) catch return error.OutOfMemory;

        self.skipWs();
        if (self.pos < self.text.len and self.text[self.pos] == '}') {
            self.pos += 1;
            return JSValue.fromPtr(out);
        }

        while (true) {
            self.skipWs();
            const key_offset = self.pos;
            const key_bytes = try self.readString();
            const key_val = self.ctx.createString(key_bytes) catch {
                self.ctx.allocator.free(key_bytes);
                return error.OutOfMemory;
            };

            if (dict.has(out, key_val)) {
                const n = @min(key_bytes.len, self.dup_key_buf.len);
                @memcpy(self.dup_key_buf[0..n], key_bytes[0..n]);
                self.ctx.allocator.free(key_bytes);
                self.failure = .{ .kind = .duplicate_key, .offset = key_offset, .key = self.dup_key_buf[0..n] };
                return error.Failed;
            }
            defer self.ctx.allocator.free(key_bytes);

            self.skipWs();
            if (self.pos >= self.text.len or self.text[self.pos] != ':') return self.fail(.invalid_syntax, self.pos);
            self.pos += 1;

            const val = try self.parseValue(depth + 1);
            out = dict.set(self.ctx, out, key_val, val) catch return error.OutOfMemory;

            self.skipWs();
            if (self.pos >= self.text.len) return self.fail(.invalid_syntax, self.pos);
            switch (self.text[self.pos]) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    return JSValue.fromPtr(out);
                },
                else => return self.fail(.invalid_syntax, self.pos),
            }
        }
    }
};

fn parseJsonNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const text = if (args.len > 0) helpers.getStringDataCtx(args[0], ctx) else null;
    if (text == null) return failure(ctx, .{ .kind = .invalid_syntax });

    if (text.?.len > limits.max_input_bytes) {
        return failure(ctx, .{ .kind = .size_limit, .limit = limits.max_input_bytes });
    }

    var parser = Parser{ .ctx = ctx, .text = text.? };
    const parsed = parser.parseValue(0) catch |err| switch (err) {
        error.Failed => return failure(ctx, parser.failure),
        error.OutOfMemory => return error.OutOfMemory,
    };
    parser.skipWs();
    if (parser.pos != text.?.len) return failure(ctx, .{ .kind = .invalid_syntax, .offset = parser.pos });
    return helpers.createResultOk(ctx, parsed);
}

/// Build the typed error value: `{ kind, offset?, key?, limit? }`, carrying
/// exactly the fields spec 6.4 declares for that kind and no others.
fn failure(ctx: *context.Context, f: Failure) JSValue {
    const pool = ctx.hidden_class_pool orelse return helpers.createResultErr(ctx, JSValue.undefined_val);
    const obj = ctx.createObject(null) catch return helpers.createResultErr(ctx, JSValue.undefined_val);

    const kind_atom = ctx.atoms.intern("kind") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
    const kind_text = ctx.createString(f.kind.wire()) catch return helpers.createResultErr(ctx, JSValue.undefined_val);
    obj.setProperty(ctx.allocator, pool, kind_atom, kind_text) catch {};

    switch (f.kind) {
        .invalid_syntax, .non_finite_number => {
            const off_atom = ctx.atoms.intern("offset") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
            obj.setProperty(ctx.allocator, pool, off_atom, JSValue.fromInt(@intCast(f.offset))) catch {};
        },
        .duplicate_key => {
            const off_atom = ctx.atoms.intern("offset") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
            obj.setProperty(ctx.allocator, pool, off_atom, JSValue.fromInt(@intCast(f.offset))) catch {};
            const key_atom = ctx.atoms.intern("key") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
            const key_text = ctx.createString(f.key orelse "") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
            obj.setProperty(ctx.allocator, pool, key_atom, key_text) catch {};
        },
        .depth_limit, .size_limit => {
            const limit_atom = ctx.atoms.intern("limit") catch return helpers.createResultErr(ctx, JSValue.undefined_val);
            obj.setProperty(ctx.allocator, pool, limit_atom, JSValue.fromInt(@intCast(f.limit))) catch {};
        },
        .cycle => {},
    }
    return helpers.createResultErr(ctx, JSValue.fromPtr(obj));
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

const EncodeError = error{ NonFinite, Cycle, Unencodable, OutOfMemory };

fn stringifyJsonNative(ctx_ptr: *anyopaque, _: JSValue, args: []const JSValue) anyerror!JSValue {
    const ctx = util.castContext(ctx_ptr);
    const input = if (args.len > 0) args[0] else JSValue.undefined_val;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    encode(ctx, input, &buf, 0) catch |err| return switch (err) {
        error.NonFinite => failure(ctx, .{ .kind = .non_finite_number }),
        error.Cycle => failure(ctx, .{ .kind = .cycle }),
        error.Unencodable => failure(ctx, .{ .kind = .invalid_syntax }),
        error.OutOfMemory => error.OutOfMemory,
    };

    const out = ctx.createString(buf.items) catch return error.OutOfMemory;
    return helpers.createResultOk(ctx, out);
}

/// Encode one value. Depth stands in for cycle detection: a value graph this
/// profile can build is a tree, since a record's fields are fixed at
/// allocation and a Dict is immutable, so the only way to exceed the depth
/// limit is a structure deeper than any document the parser would have
/// accepted. Reporting that as `cycle` names the shape the caller has.
fn encode(ctx: *context.Context, val: JSValue, buf: *std.ArrayListUnmanaged(u8), depth: u16) EncodeError!void {
    if (depth > limits.max_depth) return error.Cycle;
    const allocator = ctx.allocator;

    if (val.isNull()) return buf.appendSlice(allocator, "null") catch error.OutOfMemory;
    if (val.isTrue()) return buf.appendSlice(allocator, "true") catch error.OutOfMemory;
    if (val.isFalse()) return buf.appendSlice(allocator, "false") catch error.OutOfMemory;
    // Spec 6.4: an `undefined` array element is rejected, and an optional
    // `undefined` record field is omitted - the omission happens at the record
    // walk below, so reaching here with `undefined` is the array case.
    if (val.isUndefined()) return error.Unencodable;

    if (val.isNumber()) {
        const n = val.toNumber() orelse return error.Unencodable;
        if (!std.math.isFinite(n)) return error.NonFinite;
        var tmp: [32]u8 = undefined;
        const text = if (n == @trunc(n) and @abs(n) < 1e15)
            std.fmt.bufPrint(&tmp, "{d}", .{@as(i64, @intFromFloat(n))}) catch return error.OutOfMemory
        else
            std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.OutOfMemory;
        return buf.appendSlice(allocator, text) catch error.OutOfMemory;
    }

    if (helpers.getStringDataCtx(val, ctx)) |text| {
        return encodeString(allocator, text, buf);
    }

    const obj = if (val.isObject()) JSObject.fromValue(val) else return error.Unencodable;

    if (obj.class_id == .dict) {
        buf.append(allocator, '{') catch return error.OutOfMemory;
        const total = dict.count(obj);
        var i: u32 = 0;
        var written: u32 = 0;
        while (i < total) : (i += 1) {
            const key = dict.keyAt(obj, i);
            const key_text = helpers.getStringDataCtx(key, ctx) orelse return error.Unencodable;
            const entry = dict.valueAt(obj, i);
            if (entry.isUndefined()) continue;
            if (written > 0) buf.append(allocator, ',') catch return error.OutOfMemory;
            try encodeString(allocator, key_text, buf);
            buf.append(allocator, ':') catch return error.OutOfMemory;
            try encode(ctx, entry, buf, depth + 1);
            written += 1;
        }
        buf.append(allocator, '}') catch return error.OutOfMemory;
        return;
    }

    if (obj.class_id == .array) {
        buf.append(allocator, '[') catch return error.OutOfMemory;
        const len = obj.getArrayLength();
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            if (i > 0) buf.append(allocator, ',') catch return error.OutOfMemory;
            try encode(ctx, obj.getSlot(@intCast(i + 1)), buf, depth + 1);
        }
        buf.append(allocator, ']') catch return error.OutOfMemory;
        return;
    }

    if (obj.class_id == .object) {
        const pool = ctx.hidden_class_pool orelse return error.Unencodable;
        buf.append(allocator, '{') catch return error.OutOfMemory;
        var it = obj.propertyIterator(pool);
        var written: u32 = 0;
        while (it.next()) |entry| {
            // An optional field holding `undefined` is omitted rather than
            // encoded as null, which is what makes a round trip through an
            // optional field stable.
            if (entry.value.isUndefined()) continue;
            const name = ctx.atoms.getName(entry.atom) orelse return error.Unencodable;
            if (written > 0) buf.append(allocator, ',') catch return error.OutOfMemory;
            try encodeString(allocator, name, buf);
            buf.append(allocator, ':') catch return error.OutOfMemory;
            try encode(ctx, entry.value, buf, depth + 1);
            written += 1;
        }
        buf.append(allocator, '}') catch return error.OutOfMemory;
        return;
    }

    // A function, a Result, or any other class is not JSON. Refusing by name
    // beats encoding it as `{}` and calling the round trip lossless.
    return error.Unencodable;
}

fn encodeString(allocator: std.mem.Allocator, text: []const u8, buf: *std.ArrayListUnmanaged(u8)) EncodeError!void {
    buf.append(allocator, '"') catch return error.OutOfMemory;
    for (text) |c| {
        switch (c) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return error.OutOfMemory,
            '\\' => buf.appendSlice(allocator, "\\\\") catch return error.OutOfMemory,
            '\n' => buf.appendSlice(allocator, "\\n") catch return error.OutOfMemory,
            '\r' => buf.appendSlice(allocator, "\\r") catch return error.OutOfMemory,
            '\t' => buf.appendSlice(allocator, "\\t") catch return error.OutOfMemory,
            0x08 => buf.appendSlice(allocator, "\\b") catch return error.OutOfMemory,
            0x0C => buf.appendSlice(allocator, "\\f") catch return error.OutOfMemory,
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return error.OutOfMemory;
                buf.appendSlice(allocator, hex) catch return error.OutOfMemory;
            },
            else => buf.append(allocator, c) catch return error.OutOfMemory,
        }
    }
    buf.append(allocator, '"') catch return error.OutOfMemory;
}
