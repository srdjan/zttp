//! Handler Trace Recording and Replay
//!
//! Records every I/O boundary during handler execution as JSONL,
//! enabling exact reproduction of any request offline.
//!
//! Since virtual modules are the ONLY I/O boundary in zttp's restricted
//! JS subset, recording their inputs/outputs captures ALL external state
//! a handler depends on. This makes handlers deterministic pure functions
//! of (Request, VirtualModuleResponses).

const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const util = @import("modules/internal/util.zig");

const module_slots = @import("zts-base").module_slots;
const json_utils = @import("zts-base").json_utils;

pub const TRACE_STATE_SLOT = @backingInt(module_slots.Slot.trace);

/// Mutex wrapper compatible with Zig 0.16's Io.Mutex.
pub const TraceMutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *TraceMutex) void {
        self.inner.lockUncancelable(std.Options.debug_io);
    }

    pub fn unlock(self: *TraceMutex) void {
        self.inner.unlock(std.Options.debug_io);
    }
};

/// Per-request trace recorder.
/// Accumulates JSONL lines in a buffer during handler execution,
/// then flushes atomically to the shared output file.
pub const TraceRecorder = struct {
    /// Allocator for buffer operations.
    allocator: std.mem.Allocator,
    /// Buffer accumulating JSONL lines for the current request.
    buf: std.ArrayList(u8),
    /// Shared output file descriptor (owned by the Runtime, not the recorder).
    output_fd: std.c.fd_t,
    /// Mutex protecting concurrent writes to the output file.
    output_mutex: *TraceMutex,
    /// Whether recording is active (allows disabling mid-request on error).
    active: bool,
    /// Sequence counter for I/O calls within this request.
    io_seq: u32,

    pub fn init(allocator: std.mem.Allocator, output_fd: std.c.fd_t, output_mutex: *TraceMutex) TraceRecorder {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .output_fd = output_fd,
            .output_mutex = output_mutex,
            .active = true,
            .io_seq = 0,
        };
    }

    pub fn deinit(self: *TraceRecorder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn deinitOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;
        const self: *TraceRecorder = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Record the incoming HTTP request from raw parts (used by zruntime).
    pub fn recordRequestRaw(
        self: *TraceRecorder,
        method: []const u8,
        url: []const u8,
        header_names: []const []const u8,
        header_values: []const []const u8,
        body: ?[]const u8,
    ) void {
        if (!self.active) return;
        self.io_seq = 0;

        self.append("{\"type\":\"request\",\"method\":\"") orelse return;
        self.appendEscaped(method) orelse return;
        self.append("\",\"url\":\"") orelse return;
        self.appendEscaped(url) orelse return;
        self.append("\",\"headers\":{") orelse return;

        const count = @min(header_names.len, header_values.len);
        for (0..count) |i| {
            if (i > 0) self.appendByte(',') orelse return;
            self.appendByte('"') orelse return;
            self.appendEscaped(header_names[i]) orelse return;
            self.append("\":\"") orelse return;
            self.appendEscaped(header_values[i]) orelse return;
            self.appendByte('"') orelse return;
        }

        self.append("},\"body\":") orelse return;
        if (body) |b| {
            self.appendByte('"') orelse return;
            self.appendEscaped(b) orelse return;
            self.appendByte('"') orelse return;
        } else {
            self.append("null") orelse return;
        }
        self.append("}\n") orelse return;
    }

    /// Record a virtual module I/O call.
    pub fn recordIO(
        self: *TraceRecorder,
        module_name: []const u8,
        fn_name: []const u8,
        ctx_ptr: *context.Context,
        args: []const value.JSValue,
        result: value.JSValue,
    ) void {
        self.recordIOWithProviderPhase(module_name, fn_name, ctx_ptr, args, result, null, null);
    }

    /// Agent provider replay needs the actual transport phase. Ordinary I/O
    /// leaves this absent and retains its existing trace representation.
    pub fn recordIOWithProviderPhase(
        self: *TraceRecorder,
        module_name: []const u8,
        fn_name: []const u8,
        ctx_ptr: *context.Context,
        args: []const value.JSValue,
        result: value.JSValue,
        provider_phase: ?ProviderPhase,
        provider_status: ?u16,
    ) void {
        if (!self.active) return;

        self.append("{\"type\":\"io\",\"seq\":") orelse return;
        self.appendInt(self.io_seq) orelse return;
        self.append(",\"module\":\"") orelse return;
        self.appendEscaped(module_name) orelse return;
        self.append("\",\"fn\":\"") orelse return;
        self.appendEscaped(fn_name) orelse return;
        self.append("\",\"args\":[") orelse return;

        for (args, 0..) |arg, i| {
            if (i > 0) self.appendByte(',') orelse return;
            self.appendJSValue(ctx_ptr, arg) orelse return;
        }

        self.append("],\"result\":") orelse return;
        self.appendJSValue(ctx_ptr, result) orelse return;
        if (provider_phase) |phase| {
            self.append(",\"provider_phase\":\"") orelse return;
            self.append(@tagName(phase)) orelse return;
            self.appendByte('"') orelse return;
        }
        if (provider_status) |status| {
            self.append(",\"provider_status\":") orelse return;
            self.appendInt(status) orelse return;
        }
        self.append("}\n") orelse return;

        self.io_seq += 1;
    }

    /// Record the outgoing HTTP response.
    pub fn recordResponse(
        self: *TraceRecorder,
        status: u16,
        header_names: []const []const u8,
        header_values: []const []const u8,
        body: []const u8,
    ) void {
        if (!self.active) return;

        self.append("{\"type\":\"response\",\"status\":") orelse return;
        self.appendInt(status) orelse return;
        self.append(",\"headers\":{") orelse return;

        const count = @min(header_names.len, header_values.len);
        for (0..count) |i| {
            if (i > 0) self.appendByte(',') orelse return;
            self.appendByte('"') orelse return;
            self.appendEscaped(header_names[i]) orelse return;
            self.append("\":\"") orelse return;
            self.appendEscaped(header_values[i]) orelse return;
            self.appendByte('"') orelse return;
        }

        self.append("},\"body\":\"") orelse return;
        self.appendEscaped(body) orelse return;
        self.append("\"}\n") orelse return;
    }

    /// Record metadata at the end of the request.
    pub fn recordMeta(
        self: *TraceRecorder,
        duration_us: u64,
        handler_name: []const u8,
        pool_slot: u32,
    ) void {
        if (!self.active) return;

        self.append("{\"type\":\"meta\",\"duration_us\":") orelse return;
        self.appendFmt("{d}", .{duration_us}) orelse return;
        self.append(",\"handler\":\"") orelse return;
        self.appendEscaped(handler_name) orelse return;
        self.append("\",\"pool_slot\":") orelse return;
        self.appendInt(pool_slot) orelse return;
        self.append(",\"io_count\":") orelse return;
        self.appendInt(self.io_seq) orelse return;
        self.append("}\n") orelse return;
    }

    /// Flush accumulated trace lines to the output file.
    pub fn flush(self: *TraceRecorder) void {
        if (self.buf.items.len == 0) return;

        self.output_mutex.lock();
        defer self.output_mutex.unlock();

        var remaining = self.buf.items;
        while (remaining.len > 0) {
            const result = std.c.write(self.output_fd, remaining.ptr, remaining.len);
            if (result < 0) break;
            remaining = remaining[@intCast(result)..];
        }

        self.buf.clearRetainingCapacity();
    }

    /// Reset for next request (keep buffer capacity).
    pub fn reset(self: *TraceRecorder) void {
        self.buf.clearRetainingCapacity();
        self.active = true;
        self.io_seq = 0;
    }

    // -- Buffer helpers (return null on OOM to deactivate) --

    fn append(self: *TraceRecorder, data: []const u8) ?void {
        self.buf.appendSlice(self.allocator, data) catch {
            self.active = false;
            return null;
        };
    }

    fn appendByte(self: *TraceRecorder, byte: u8) ?void {
        self.buf.append(self.allocator, byte) catch {
            self.active = false;
            return null;
        };
    }

    fn appendInt(self: *TraceRecorder, val: anytype) ?void {
        self.appendFmt("{d}", .{val}) orelse return null;
    }

    fn appendFmt(self: *TraceRecorder, comptime fmt: []const u8, args: anytype) ?void {
        var tmp: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&tmp, fmt, args) catch {
            self.active = false;
            return null;
        };
        self.append(slice) orelse return null;
    }

    fn appendEscaped(self: *TraceRecorder, data: []const u8) ?void {
        for (data) |c| {
            switch (c) {
                '"' => self.append("\\\"") orelse return null,
                '\\' => self.append("\\\\") orelse return null,
                '\n' => self.append("\\n") orelse return null,
                '\r' => self.append("\\r") orelse return null,
                '\t' => self.append("\\t") orelse return null,
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        self.append("\\u00") orelse return null;
                        self.appendByte(hex[c >> 4]) orelse return null;
                        self.appendByte(hex[c & 0xF]) orelse return null;
                    } else {
                        self.appendByte(c) orelse return null;
                    }
                },
            }
        }
    }

    const MAX_JSON_DEPTH = 32;

    fn appendJSValue(self: *TraceRecorder, ctx: *context.Context, val: value.JSValue) ?void {
        // One serializer serves recording and replay argument checks, so both
        // paths produce byte-identical JSON. On failure, deactivate the recorder like
        // the other append helpers: a partial line must stop all further
        // recording, not let the next record concatenate onto it and corrupt
        // the capsule JSONL.
        return appendJSValueBuf(&self.buf, self.allocator, ctx, val, 0) orelse {
            self.active = false;
            return null;
        };
    }
};

pub fn extractStringData(val: value.JSValue) ?[]const u8 {
    if (val.isString()) return val.toPtr(string.JSString).data();
    if (val.isStringSlice()) return val.toPtr(string.SliceString).data();
    if (val.isRope()) {
        const rope = val.toPtr(string.RopeNode);
        if (rope.asLeaf()) |leaf| return leaf.data();
    }
    return null;
}

fn atomToString(atom: object.Atom, ctx: *context.Context) ?[]const u8 {
    if (atom.isPredefined()) return atom.toPredefinedName();
    return ctx.atoms.getName(atom);
}

// ============================================================================
// Comptime NativeFn Wrapper Generator
// ============================================================================

/// Generate a tracing NativeFn wrapper at compile time.
pub fn makeTracingWrapper(
    comptime module_name: []const u8,
    comptime fn_name: []const u8,
    comptime original_fn: object.NativeFn,
) object.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
            const result = try original_fn(ctx_ptr, this, args);
            const ctx = util.castContext(ctx_ptr);
            if (ctx.getModuleState(TraceRecorder, TRACE_STATE_SLOT)) |recorder| {
                recorder.recordIO(module_name, fn_name, ctx, args, result);
            }
            return result;
        }
    }.call;
}

// ============================================================================
// Replay Support - Trace Parsing
// ============================================================================

pub const TraceEntry = union(enum) {
    witness: void,
    request: RequestTrace,
    io: IoEntry,
    response: ResponseTrace,
    meta: MetaTrace,
    unknown: void,
};

pub const RequestTrace = struct {
    method: []const u8,
    url: []const u8,
    headers_json: []const u8,
    body: ?[]const u8,
};

pub const ProviderPhase = enum { not_started, request_started, head_received, completed };

pub const IoEntry = struct {
    seq: u32,
    module: []const u8,
    func: []const u8,
    args_json: []const u8,
    result_json: []const u8,
    provider_phase: ?ProviderPhase = null,
    provider_status: ?u16 = null,
};

pub const ResponseTrace = struct {
    status: u16,
    headers_json: []const u8,
    body: []const u8,
};

pub const MetaTrace = struct {
    duration_us: u64,
    handler: []const u8,
    pool_slot: u32,
    io_count: u32,
};

pub const RequestTraceGroup = struct {
    request: RequestTrace,
    io_calls: []const IoEntry,
    response: ?ResponseTrace,
    meta: ?MetaTrace,
};

/// Parse a JSONL trace file into grouped request traces.
pub fn parseTraceFile(allocator: std.mem.Allocator, source: []const u8) ![]RequestTraceGroup {
    var groups: std.ArrayList(RequestTraceGroup) = .empty;
    errdefer {
        for (groups.items) |group| allocator.free(group.io_calls);
        groups.deinit(allocator);
    }

    var current_io: std.ArrayList(IoEntry) = .empty;
    defer current_io.deinit(allocator);

    var current_request: ?RequestTrace = null;
    var current_response: ?ResponseTrace = null;
    var current_meta: ?MetaTrace = null;
    var pending_witness = false;
    var current_witness = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!try std.json.validate(allocator, line)) return error.InvalidTraceJson;
        const entry = try parseTraceLine(line);
        switch (entry) {
            .request => |req| {
                if (current_request != null) {
                    if (current_response == null and !current_witness) return error.InvalidTraceEntry;
                    try groups.append(allocator, .{
                        .request = current_request.?,
                        .io_calls = try current_io.toOwnedSlice(allocator),
                        .response = current_response,
                        .meta = current_meta,
                    });
                    current_response = null;
                    current_meta = null;
                }
                current_request = req;
                current_witness = pending_witness;
                pending_witness = false;
            },
            .io => |io| try current_io.append(allocator, io),
            .response => |resp| current_response = resp,
            .meta => |meta| {
                current_meta = meta;
                if (current_request != null) {
                    if (current_response == null and !current_witness) return error.InvalidTraceEntry;
                    try groups.append(allocator, .{
                        .request = current_request.?,
                        .io_calls = try current_io.toOwnedSlice(allocator),
                        .response = current_response,
                        .meta = current_meta,
                    });
                    current_request = null;
                    current_response = null;
                    current_meta = null;
                    current_witness = false;
                }
            },
            .witness => pending_witness = true,
            .unknown => return error.InvalidTraceEntry,
        }
    }

    if (current_request != null) {
        if (current_response == null and !current_witness) return error.InvalidTraceEntry;
        try groups.append(allocator, .{
            .request = current_request.?,
            .io_calls = try current_io.toOwnedSlice(allocator),
            .response = current_response,
            .meta = current_meta,
        });
    }

    return try groups.toOwnedSlice(allocator);
}

pub fn parseTraceLine(line: []const u8) !TraceEntry {
    const type_str = findJsonStringValue(line, "\"type\"") orelse return .unknown;

    if (std.mem.eql(u8, type_str, "witness")) {
        return .witness;
    } else if (std.mem.eql(u8, type_str, "request")) {
        return .{ .request = .{
            .method = findJsonStringValue(line, "\"method\"") orelse "GET",
            .url = findJsonStringValue(line, "\"url\"") orelse "/",
            .headers_json = findJsonObjectValue(line, "\"headers\"") orelse "{}",
            .body = findJsonStringValue(line, "\"body\""),
        } };
    } else if (std.mem.eql(u8, type_str, "io")) {
        return .{ .io = .{
            .seq = std.math.cast(u32, findJsonIntValue(line, "\"seq\"") orelse 0) orelse 0,
            .module = findJsonStringValue(line, "\"module\"") orelse "",
            .func = findJsonStringValue(line, "\"fn\"") orelse "",
            .args_json = findJsonArrayValue(line, "\"args\"") orelse "[]",
            .result_json = findJsonAnyValue(line, "\"result\"") orelse "null",
            .provider_phase = if (findJsonStringValue(line, "\"provider_phase\"")) |phase|
                std.meta.stringToEnum(ProviderPhase, phase)
            else
                null,
            .provider_status = if (findJsonIntValue(line, "\"provider_status\"")) |status|
                std.math.cast(u16, status)
            else
                null,
        } };
    } else if (std.mem.eql(u8, type_str, "response")) {
        return .{ .response = .{
            .status = std.math.cast(u16, findJsonIntValue(line, "\"status\"") orelse 200) orelse 200,
            .headers_json = findJsonObjectValue(line, "\"headers\"") orelse "{}",
            .body = findJsonStringValue(line, "\"body\"") orelse "",
        } };
    } else if (std.mem.eql(u8, type_str, "meta")) {
        return .{ .meta = .{
            .duration_us = std.math.cast(u64, findJsonIntValue(line, "\"duration_us\"") orelse 0) orelse 0,
            .handler = findJsonStringValue(line, "\"handler\"") orelse "",
            .pool_slot = std.math.cast(u32, findJsonIntValue(line, "\"pool_slot\"") orelse 0) orelse 0,
            .io_count = std.math.cast(u32, findJsonIntValue(line, "\"io_count\"") orelse 0) orelse 0,
        } };
    }
    return .unknown;
}

// ============================================================================
// Minimal JSON Field Extraction (zero-copy)
// ============================================================================

/// Find an object KEY at the top level (depth 1) of a JSON object, ignoring
/// occurrences of the key token inside nested structures or string values. `key`
/// is the quoted token (e.g. `"\"result\""`). Returns the index just past the
/// matched key, or null. Replaces a naive std.mem.indexOf that matched the first
/// substring anywhere — which corrupted extraction when an earlier sibling value
/// (e.g. an io arg equal to "result", or a header literally named "body")
/// contained the key token, silently feeding wrong values into replay verification.
fn findTopLevelKeyEnd(json: []const u8, key: []const u8) ?usize {
    if (key.len == 0) return null;
    var depth: u32 = 0;
    var pos: usize = 0;
    var in_string = false;
    while (pos < json.len) {
        const c = json[pos];
        if (in_string) {
            if (c == '\\') {
                pos += 2;
                continue;
            }
            if (c == '"') in_string = false;
            pos += 1;
            continue;
        }
        switch (c) {
            '{', '[' => {
                depth += 1;
                pos += 1;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
                pos += 1;
            },
            '"' => {
                // A quoted token at depth 1 followed by ':' is the key we want.
                if (depth == 1 and pos + key.len <= json.len and
                    std.mem.eql(u8, json[pos .. pos + key.len], key))
                {
                    var after = pos + key.len;
                    while (after < json.len and (json[after] == ' ' or json[after] == '\t')) : (after += 1) {}
                    if (after < json.len and json[after] == ':') return pos + key.len;
                }
                // Otherwise it is a non-matching key or a string value: skip it.
                in_string = true;
                pos += 1;
            },
            else => pos += 1,
        }
    }
    return null;
}

pub fn findJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pos = findTopLevelKeyEnd(json, key) orelse return null;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) : (pos += 1) {}
    if (pos >= json.len) return null;
    if (pos + 4 <= json.len and std.mem.eql(u8, json[pos .. pos + 4], "null")) return null;
    if (json[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (json[pos] == '"') return json[start..pos];
    }
    return null;
}

pub fn findJsonIntValue(json: []const u8, key: []const u8) ?i64 {
    var pos = findTopLevelKeyEnd(json, key) orelse return null;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) : (pos += 1) {}
    if (pos >= json.len) return null;
    const start = pos;
    if (pos < json.len and json[pos] == '-') pos += 1;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}
    if (pos == start) return null;
    return std.fmt.parseInt(i64, json[start..pos], 10) catch null;
}

pub fn findJsonObjectValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pos = findTopLevelKeyEnd(json, key) orelse return null;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '{') return null;
    return findMatchingBrace(json, pos, '{', '}');
}

pub fn findJsonArrayValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pos = findTopLevelKeyEnd(json, key) orelse return null;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '[') return null;
    return findMatchingBrace(json, pos, '[', ']');
}

pub fn findJsonAnyValue(json: []const u8, key: []const u8) ?[]const u8 {
    var pos = findTopLevelKeyEnd(json, key) orelse return null;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) : (pos += 1) {}
    if (pos >= json.len) return null;
    return switch (json[pos]) {
        '"' => blk: {
            var p = pos + 1;
            while (p < json.len) : (p += 1) {
                if (json[p] == '\\') {
                    p += 1;
                    continue;
                }
                if (json[p] == '"') break :blk json[pos .. p + 1];
            }
            break :blk null;
        },
        '{' => findMatchingBrace(json, pos, '{', '}'),
        '[' => findMatchingBrace(json, pos, '[', ']'),
        else => blk: {
            const start = pos;
            while (pos < json.len and json[pos] != ',' and json[pos] != '}' and json[pos] != ']') : (pos += 1) {}
            break :blk json[start..pos];
        },
    };
}

fn findMatchingBrace(json: []const u8, start: usize, open: u8, close: u8) ?[]const u8 {
    var depth: u32 = 0;
    var pos = start;
    var in_string = false;
    while (pos < json.len) : (pos += 1) {
        if (in_string) {
            if (json[pos] == '\\') {
                pos += 1;
                continue;
            }
            if (json[pos] == '"') in_string = false;
            continue;
        }
        if (json[pos] == '"') {
            in_string = true;
            continue;
        }
        if (json[pos] == open) depth += 1 else if (json[pos] == close) {
            depth -= 1;
            if (depth == 0) return json[start .. pos + 1];
        }
    }
    return null;
}

// ============================================================================
// Replay Support - Stub Functions
// ============================================================================

pub const REPLAY_STATE_SLOT = @backingInt(module_slots.Slot.replay);

/// Per-request replay state. Holds the recorded I/O entries and a cursor
/// tracking which entry to return next.
pub const ReplayState = struct {
    io_calls: []const IoEntry,
    cursor: u32,
    divergences: u32,

    /// Consume the next I/O entry, verifying module and function name.
    /// Increments divergence count on mismatch or exhaustion.
    pub fn nextIO(self: *ReplayState, module_name: []const u8, fn_name: []const u8) ?IoEntry {
        if (self.cursor >= self.io_calls.len) {
            self.divergences += 1;
            return null;
        }
        const entry = self.io_calls[self.cursor];
        self.cursor += 1;
        if (!std.mem.eql(u8, entry.module, module_name) or !std.mem.eql(u8, entry.func, fn_name)) {
            self.divergences += 1;
        }
        return entry;
    }

    /// Non-consuming check: does the head entry target this module/function?
    /// Pure-function fallback stubs use this to decide replay-vs-real without
    /// disturbing the cursor (or counting a divergence) when no matching entry
    /// was recorded.
    pub fn peekMatches(self: *const ReplayState, module_name: []const u8, fn_name: []const u8) bool {
        if (self.cursor >= self.io_calls.len) return false;
        const entry = self.io_calls[self.cursor];
        return std.mem.eql(u8, entry.module, module_name) and std.mem.eql(u8, entry.func, fn_name);
    }

    /// Consume the head entry after `peekMatches` confirmed a match. The caller
    /// must have just observed `peekMatches == true` (cursor in bounds, names
    /// equal), so this advances without re-checking bounds or names.
    pub fn consumeHead(self: *ReplayState) IoEntry {
        const entry = self.io_calls[self.cursor];
        self.cursor += 1;
        return entry;
    }

    /// Does any not-yet-consumed entry target this module/function? Used by a
    /// pure-function fallback to tell a genuinely-new call (no recording -> run
    /// real silently) from a recorded call that drifted out of order (-> flag a
    /// divergence so replay verification still fails closed on structural drift).
    pub fn hasEntryAhead(self: *const ReplayState, module_name: []const u8, fn_name: []const u8) bool {
        var i = self.cursor;
        while (i < self.io_calls.len) : (i += 1) {
            const e = self.io_calls[i];
            if (std.mem.eql(u8, e.module, module_name) and std.mem.eql(u8, e.func, fn_name)) return true;
        }
        return false;
    }

    /// Count of recorded I/O entries the replay never consumed. A faithful
    /// replay re-makes every recorded call (each consumes its head entry), so a
    /// non-zero leftover means the edited handler DROPPED a recorded effect
    /// (e.g. a trailing cacheSet/sqlExec). Replay verification must fail closed
    /// on this, otherwise a deleted side effect reads as "reproduced".
    pub fn unconsumedCount(self: *const ReplayState) u32 {
        if (self.cursor >= self.io_calls.len) return 0;
        return @intCast(self.io_calls.len - self.cursor);
    }

    pub fn deinitOpaque(_: *anyopaque, _: std.mem.Allocator) void {
        // ReplayState does not own its io_calls (owned by trace parser).
    }
};

/// Parse a recorded entry's result back to a JSValue and count a divergence if
/// a non-null/undefined recording failed to parse. Shared tail of both replay
/// stubs so the parse-failure heuristic has a single owner.
/// A recorded entry replayed against changed arguments is a behavior drift.
/// Returns true when the live args diverge from what was recorded. Skips when
/// the recording did not pin args ("[]" or empty), so zero-arg calls and
/// hand-written fixtures that omit args are not flagged. Both sides are produced
/// by the same serializer (serializeArgsJson <-> recorded args_json), so a match
/// is byte-exact by construction.
fn argsDrifted(recorded_args_json: []const u8, live_args_json: []const u8) bool {
    if (recorded_args_json.len == 0 or std.mem.eql(u8, recorded_args_json, "[]")) return false;
    return !std.mem.eql(u8, live_args_json, recorded_args_json);
}

fn replayRecordedEntry(state: *ReplayState, ctx: *context.Context, entry: IoEntry, args: []const value.JSValue) value.JSValue {
    // Count a divergence so replay verification fails closed on an argument
    // change at the matched path.
    if (serializeArgsJson(ctx.allocator, ctx, args)) |live| {
        defer ctx.allocator.free(live);
        if (argsDrifted(entry.args_json, live)) state.divergences += 1;
    }
    const result = jsonToJSValue(ctx, entry.result_json);
    if (result.isUndefined() and entry.result_json.len > 0 and
        !std.mem.eql(u8, entry.result_json, "null") and
        !std.mem.eql(u8, entry.result_json, "undefined"))
    {
        state.divergences += 1;
    }
    return result;
}

/// Generate a replay stub NativeFn at compile time.
/// The stub reads the next recorded I/O entry from the ReplayState in
/// module_state and converts the result_json back to a JSValue.
pub fn makeReplayStub(
    comptime module_name: []const u8,
    comptime fn_name: []const u8,
) object.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, _: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
            const ctx = util.castContext(ctx_ptr);
            const state = ctx.getModuleState(ReplayState, REPLAY_STATE_SLOT) orelse {
                return value.JSValue.undefined_val;
            };
            const entry = state.nextIO(module_name, fn_name) orelse {
                return value.JSValue.undefined_val;
            };
            return replayRecordedEntry(state, ctx, entry, args);
        }
    }.call;
}

/// Generate a replay stub that falls through to the real implementation when
/// no matching I/O entry sits at the cursor head. Installed only for pure
/// functions (those declaring `Law.pure`): re-running them is deterministic,
/// so a test or capsule that did not record the call still observes the real
/// result instead of `undefined`. A recorded entry, when present, is consumed
/// and replayed exactly as `makeReplayStub` would, so divergence accounting and
/// existing fixtures are unchanged.
pub fn makeReplayStubWithFallback(
    comptime module_name: []const u8,
    comptime fn_name: []const u8,
    comptime original_fn: object.NativeFn,
) object.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: value.JSValue, args: []const value.JSValue) anyerror!value.JSValue {
            const ctx = util.castContext(ctx_ptr);
            const state = ctx.getModuleState(ReplayState, REPLAY_STATE_SLOT) orelse {
                return original_fn(ctx_ptr, this, args);
            };
            // A recorded entry at the head: consume and replay it (trusting the
            // peek, so no second scan).
            if (state.peekMatches(module_name, fn_name)) {
                return replayRecordedEntry(state, ctx, state.consumeHead(), args);
            }
            // No entry at the head. If one for this call exists further on, the
            // recorded order/count drifted - flag a divergence so replay
            // verification still fails closed. Either way run the real
            // (deterministic) implementation; a genuinely-new call (no recording)
            // stays silent.
            if (state.hasEntryAhead(module_name, fn_name)) state.divergences += 1;
            return original_fn(ctx_ptr, this, args);
        }
    }.call;
}

// ============================================================================
// JSON to JSValue Parser (for replay)
// ============================================================================

const ParseResult = struct {
    val: value.JSValue,
    end: usize,
};

/// Parse a JSON string into a JSValue. Used by replay stubs to reconstruct
/// recorded return values from their JSONL representation.
pub fn jsonToJSValue(ctx: *context.Context, json: []const u8) value.JSValue {
    if (json.len == 0) return value.JSValue.undefined_val;
    const result = parseValue(ctx, json, 0, 0);
    return result.val;
}

// Cap nesting depth so an adversarial/corrupted trace (replay or shared capsule
// files are third-party input) with deeply nested values cannot overflow the
// native stack. Mirrors the serializer's MAX_JSON_DEPTH discipline.
const MAX_PARSE_DEPTH: u32 = 128;

fn parseValue(ctx: *context.Context, json: []const u8, start: usize, depth: u32) ParseResult {
    const pos = skipWhitespace(json, start);
    if (pos >= json.len) return .{ .val = value.JSValue.undefined_val, .end = pos };
    if (depth >= MAX_PARSE_DEPTH) return .{ .val = value.JSValue.undefined_val, .end = pos };

    return switch (json[pos]) {
        '"' => parseString(ctx, json, pos),
        '{' => parseObject(ctx, json, pos, depth),
        '[' => parseArray(ctx, json, pos, depth),
        't' => .{ .val = value.JSValue.true_val, .end = @min(pos + 4, json.len) },
        'f' => .{ .val = value.JSValue.false_val, .end = @min(pos + 5, json.len) },
        'n' => .{ .val = value.JSValue.undefined_val, .end = @min(pos + 4, json.len) },
        '-', '0'...'9' => parseNumber(ctx, json, pos),
        else => .{ .val = value.JSValue.undefined_val, .end = pos + 1 },
    };
}

fn parseString(ctx: *context.Context, json: []const u8, start: usize) ParseResult {
    // start points to opening quote
    var pos = start + 1;
    // Fast path: no escapes
    const content_start = pos;
    var has_escapes = false;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            has_escapes = true;
            pos += 1;
            continue;
        }
        if (json[pos] == '"') {
            if (!has_escapes) {
                const str_data = json[content_start..pos];
                const js_str = ctx.createString(str_data) catch return .{ .val = value.JSValue.undefined_val, .end = pos + 1 };
                return .{ .val = js_str, .end = pos + 1 };
            }
            // Slow path: unescape
            const unescaped = unescapeJson(ctx.allocator, json[content_start..pos]) catch return .{ .val = value.JSValue.undefined_val, .end = pos + 1 };
            defer ctx.allocator.free(unescaped);
            const js_str = ctx.createString(unescaped) catch return .{ .val = value.JSValue.undefined_val, .end = pos + 1 };
            return .{ .val = js_str, .end = pos + 1 };
        }
    }
    return .{ .val = value.JSValue.undefined_val, .end = pos };
}

fn parseNumber(ctx: *context.Context, json: []const u8, start: usize) ParseResult {
    var pos = start;
    var is_float = false;
    if (pos < json.len and json[pos] == '-') pos += 1;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}
    if (pos < json.len and json[pos] == '.') {
        is_float = true;
        pos += 1;
        while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}
    }
    if (pos < json.len and (json[pos] == 'e' or json[pos] == 'E')) {
        is_float = true;
        pos += 1;
        if (pos < json.len and (json[pos] == '+' or json[pos] == '-')) pos += 1;
        while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}
    }

    const num_str = json[start..pos];
    if (!is_float) {
        // Try integer first (i32 range for NaN-boxing)
        if (std.fmt.parseInt(i32, num_str, 10)) |int_val| {
            return .{ .val = value.JSValue.fromInt(int_val), .end = pos };
        } else |_| {}
    }
    // Fall back to float
    const f = std.fmt.parseFloat(f64, num_str) catch {
        return .{ .val = value.JSValue.undefined_val, .end = pos };
    };
    return .{ .val = allocFloat(ctx, f), .end = pos };
}

fn parseArray(ctx: *context.Context, json: []const u8, start: usize, depth: u32) ParseResult {
    const pool = ctx.hidden_class_pool orelse return .{ .val = value.JSValue.undefined_val, .end = start + 1 };
    const arr = object.JSObject.create(ctx.allocator, ctx.root_class_idx, null, pool) catch {
        return .{ .val = value.JSValue.undefined_val, .end = start + 1 };
    };
    arr.class_id = .array;
    ctx.builtin_objects.append(ctx.allocator, arr) catch {};

    var pos = start + 1; // skip '['
    var first = true;
    while (pos < json.len) {
        pos = skipWhitespace(json, pos);
        if (pos >= json.len or json[pos] == ']') {
            pos += 1;
            break;
        }
        if (!first) {
            if (pos < json.len and json[pos] == ',') pos += 1;
            pos = skipWhitespace(json, pos);
        }
        first = false;
        if (pos >= json.len or json[pos] == ']') {
            pos += 1;
            break;
        }
        const elem_start = pos;
        const elem = parseValue(ctx, json, pos, depth + 1);
        pos = elem.end;
        arr.arrayPush(ctx.allocator, elem.val) catch {};
        // Guarantee forward progress. parseValue returns end == start when the
        // MAX_PARSE_DEPTH cap is hit (an adversarial/corrupted trace nested past
        // 128 levels); without this break the loop would re-read the same
        // character forever (100% CPU + unbounded arrayPush). parseObject is
        // immune because its non-string-key escape always advances.
        if (pos <= elem_start) break;
    }
    return .{ .val = arr.toValue(), .end = pos };
}

fn parseObject(ctx: *context.Context, json: []const u8, start: usize, depth: u32) ParseResult {
    const pool = ctx.hidden_class_pool orelse return .{ .val = value.JSValue.undefined_val, .end = start + 1 };
    const obj = object.JSObject.create(ctx.allocator, ctx.root_class_idx, null, pool) catch {
        return .{ .val = value.JSValue.undefined_val, .end = start + 1 };
    };
    ctx.builtin_objects.append(ctx.allocator, obj) catch {};

    var pos = start + 1; // skip '{'
    var first = true;
    while (pos < json.len) {
        pos = skipWhitespace(json, pos);
        if (pos >= json.len or json[pos] == '}') {
            pos += 1;
            break;
        }
        if (!first) {
            if (pos < json.len and json[pos] == ',') pos += 1;
            pos = skipWhitespace(json, pos);
        }
        first = false;
        if (pos >= json.len or json[pos] == '}') {
            pos += 1;
            break;
        }
        // Parse key (must be a string)
        if (json[pos] != '"') {
            pos += 1;
            continue;
        }
        const key_result = parseRawString(json, pos);
        pos = key_result.end;
        const key_str = key_result.data;

        // Skip colon
        pos = skipWhitespace(json, pos);
        if (pos < json.len and json[pos] == ':') pos += 1;

        // Parse value
        const val_result = parseValue(ctx, json, pos, depth + 1);
        pos = val_result.end;

        // Set property on object
        const atom = ctx.atoms.intern(key_str) catch continue;
        obj.setProperty(ctx.allocator, pool, atom, val_result.val) catch {};
    }
    return .{ .val = obj.toValue(), .end = pos };
}

const RawStringResult = struct {
    data: []const u8,
    end: usize,
};

/// Extract the raw content of a JSON string (without unescaping).
/// Returns the slice between the quotes.
fn parseRawString(json: []const u8, start: usize) RawStringResult {
    var pos = start + 1; // skip opening quote
    const content_start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (json[pos] == '"') {
            return .{ .data = json[content_start..pos], .end = pos + 1 };
        }
    }
    return .{ .data = json[content_start..pos], .end = pos };
}

fn skipWhitespace(json: []const u8, start: usize) usize {
    var pos = start;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n' or json[pos] == '\r')) : (pos += 1) {}
    return pos;
}

/// Unescape a JSON string value (convert \" to ", \n to newline, \uXXXX to UTF-8, etc.).
/// Resolve JSON escapes in an optional request body before it reaches a handler.
/// Returns the decoded `slice` plus the allocation to free in `owned` (null when
/// the body was null or allocation failed and the input is aliased). Shared by
/// the test runner and replay runner so both decode a recorded body identically.
pub fn unescapeBody(allocator: std.mem.Allocator, body: ?[]const u8) struct { slice: ?[]const u8, owned: ?[]u8 } {
    const b = body orelse return .{ .slice = null, .owned = null };
    const out = unescapeJson(allocator, b) catch return .{ .slice = b, .owned = null };
    return .{ .slice = out, .owned = out };
}

/// The JSON string unescaper lives in `json_utils.zig`, so a contract
/// parser can unescape a body without importing the trace recorder and the
/// engine behind it. Re-exported because every consumer that decodes a
/// recorded body already reaches it here.
pub const unescapeJson = json_utils.unescapeJson;

fn allocFloat(_: *context.Context, f: f64) value.JSValue {
    // NaN-boxing: all f64 values stored inline, no heap allocation.
    if (!std.math.isNan(f) and !std.math.isInf(f) and @floor(f) == f and f >= -2147483648 and f <= 2147483647) {
        return value.JSValue.fromInt(@intFromFloat(f));
    }
    return value.JSValue.fromFloat(f);
}

// ============================================================================
// Shared JSON serialization
// ============================================================================

fn appendSlice(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) ?void {
    buf.appendSlice(allocator, data) catch return null;
}

fn appendByte(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) ?void {
    buf.append(allocator, byte) catch return null;
}

fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: anytype) ?void {
    var tmp: [64]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return null;
    appendSlice(buf, allocator, slice) orelse return null;
}

fn appendEscapedSlice(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) ?void {
    for (data) |c| {
        switch (c) {
            '"' => appendSlice(buf, allocator, "\\\"") orelse return null,
            '\\' => appendSlice(buf, allocator, "\\\\") orelse return null,
            '\n' => appendSlice(buf, allocator, "\\n") orelse return null,
            '\r' => appendSlice(buf, allocator, "\\r") orelse return null,
            '\t' => appendSlice(buf, allocator, "\\t") orelse return null,
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    appendSlice(buf, allocator, "\\u00") orelse return null;
                    appendByte(buf, allocator, hex[c >> 4]) orelse return null;
                    appendByte(buf, allocator, hex[c & 0xF]) orelse return null;
                } else {
                    appendByte(buf, allocator, c) orelse return null;
                }
            },
        }
    }
}

fn appendJSValueBuf(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, ctx: *context.Context, val: value.JSValue, depth: u32) ?void {
    if (depth >= TraceRecorder.MAX_JSON_DEPTH) {
        appendSlice(buf, allocator, "null") orelse return null;
        return;
    }
    if (val.isNull() or val.isUndefined()) {
        appendSlice(buf, allocator, "null") orelse return null;
    } else if (val.isTrue()) {
        appendSlice(buf, allocator, "true") orelse return null;
    } else if (val.isFalse()) {
        appendSlice(buf, allocator, "false") orelse return null;
    } else if (val.isInt()) {
        appendInt(buf, allocator, val.getInt()) orelse return null;
    } else if (val.isFloat64()) {
        const f = val.getFloat64();
        if (std.math.isNan(f) or std.math.isInf(f)) {
            appendSlice(buf, allocator, "null") orelse return null;
        } else {
            // f64 decimal rendering can need up to ~347 bytes (e.g. a
            // small-magnitude value like 1e-300); a 64-byte buffer overflowed
            // and aborted the record mid-line, corrupting the capsule. Size for
            // the worst case so any finite float serializes.
            var tmp: [512]u8 = undefined;
            const slice = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch return null;
            appendSlice(buf, allocator, slice) orelse return null;
        }
    } else if (val.isAnyString()) {
        appendByte(buf, allocator, '"') orelse return null;
        const data = extractStringData(val) orelse "";
        appendEscapedSlice(buf, allocator, data) orelse return null;
        appendByte(buf, allocator, '"') orelse return null;
    } else if (val.isObject()) {
        const obj = object.JSObject.fromValue(val);
        if (obj.class_id == .array) {
            appendByte(buf, allocator, '[') orelse return null;
            const len = obj.getArrayLength();
            for (0..len) |i| {
                if (i > 0) appendByte(buf, allocator, ',') orelse return null;
                if (obj.getIndex(@intCast(i))) |elem| {
                    appendJSValueBuf(buf, allocator, ctx, elem, depth + 1) orelse return null;
                } else {
                    appendSlice(buf, allocator, "null") orelse return null;
                }
            }
            appendByte(buf, allocator, ']') orelse return null;
        } else {
            appendByte(buf, allocator, '{') orelse return null;
            var first = true;
            const pool = ctx.hidden_class_pool orelse {
                appendByte(buf, allocator, '}') orelse return null;
                return;
            };
            const class_idx = obj.hidden_class_idx;
            if (!class_idx.isNone()) {
                const idx = class_idx.toInt();
                if (idx < pool.count) {
                    const prop_count = pool.property_counts.items[idx];
                    if (prop_count > 0) {
                        const start = pool.properties_starts.items[idx];
                        if (start + prop_count <= pool.property_names.items.len and
                            start + prop_count <= pool.property_offsets.items.len)
                        {
                            for (0..prop_count) |pi| {
                                const atom = pool.property_names.items[start + pi];
                                const offset = pool.property_offsets.items[start + pi];
                                const prop_val = obj.getSlot(offset);
                                if (prop_val.isUndefined()) continue;
                                if (!first) appendByte(buf, allocator, ',') orelse return null;
                                first = false;
                                appendByte(buf, allocator, '"') orelse return null;
                                const name = atomToString(atom, ctx) orelse "?";
                                appendEscapedSlice(buf, allocator, name) orelse return null;
                                appendSlice(buf, allocator, "\":") orelse return null;
                                appendJSValueBuf(buf, allocator, ctx, prop_val, depth + 1) orelse return null;
                            }
                        }
                    }
                }
            }
            appendByte(buf, allocator, '}') orelse return null;
        }
    } else {
        appendSlice(buf, allocator, "null") orelse return null;
    }
}

/// Serialize a call's arguments to the recorded `args_json` shape
/// (`[arg0,arg1,...]`) using the shared value serializer, so the result can be
/// compared byte-for-byte against a recorded `IoEntry.args_json`. The caller
/// owns the returned slice; returns null on allocation failure.
fn serializeArgsJson(allocator: std.mem.Allocator, ctx: *context.Context, args: []const value.JSValue) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    // This function returns ?[]u8 (no error set), so an `errdefer` would never
    // fire - every failure path must free the partial buffer explicitly.
    appendByte(&buf, allocator, '[') orelse {
        buf.deinit(allocator);
        return null;
    };
    for (args, 0..) |arg, i| {
        if (i > 0) appendByte(&buf, allocator, ',') orelse {
            buf.deinit(allocator);
            return null;
        };
        appendJSValueBuf(&buf, allocator, ctx, arg, 0) orelse {
            buf.deinit(allocator);
            return null;
        };
    }
    appendByte(&buf, allocator, ']') orelse {
        buf.deinit(allocator);
        return null;
    };
    return buf.toOwnedSlice(allocator) catch {
        buf.deinit(allocator);
        return null;
    };
}

/// Current wall-clock time in milliseconds since Unix epoch.
/// Freestanding/wasm has no POSIX clock; the analyzer never executes handler
/// I/O, so the clock code is comptime-elided there and the call returns 0.
pub fn unixMillis() i64 {
    if (comptime builtin.target.os.tag != .freestanding) {
        var ts: std.posix.timespec = undefined;
        switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
            .SUCCESS => {
                const secs: i64 = @intCast(ts.sec);
                const nanos: i64 = @intCast(ts.nsec);
                return (secs * 1000) + @divTrunc(nanos, 1_000_000);
            },
            else => return 0,
        }
    }
    return 0;
}

/// Write all bytes to fd, retrying on partial writes.
pub fn writeAll(fd: std.c.fd_t, data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const result = std.c.write(fd, remaining.ptr, remaining.len);
        if (result < 0) {
            if (std.posix.errno(result) == .INTR) continue;
            break;
        }
        remaining = remaining[@intCast(result)..];
    }
}

// ============================================================================
// Tests
// ============================================================================

test "findJsonStringValue" {
    const line = "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/api/test\"}";
    try std.testing.expectEqualStrings("request", findJsonStringValue(line, "\"type\"").?);
    try std.testing.expectEqualStrings("GET", findJsonStringValue(line, "\"method\"").?);
    try std.testing.expectEqualStrings("/api/test", findJsonStringValue(line, "\"url\"").?);
    try std.testing.expect(findJsonStringValue(line, "\"missing\"") == null);
}

test "provider trace phase is a closed optional transport marker" {
    inline for (@typeInfo(ProviderPhase).@"enum".field_names) |field| {
        const line = "{\"type\":\"io\",\"module\":\"fetch\",\"fn\":\"fetch\",\"result\":{\"error\":\"InternalError\"},\"provider_phase\":\"" ++ field ++ "\"}";
        const parsed = (try parseTraceLine(line)).io;
        try std.testing.expectEqual(@as(ProviderPhase, @fromBackingInt(@intCast(@backingInt(@field(ProviderPhase, field))))), parsed.provider_phase.?);
    }
    const absent = (try parseTraceLine("{\"type\":\"io\",\"result\":{\"provider_phase\":\"completed\"}}")).io;
    try std.testing.expect(absent.provider_phase == null);
    const invalid = (try parseTraceLine("{\"type\":\"io\",\"provider_phase\":\"guessed\"}")).io;
    try std.testing.expect(invalid.provider_phase == null);
}

test "provider trace writes its phase and head status without changing ordinary IO" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = try testCreateContext(arena.allocator());
    defer testDestroyContext(ctx);
    var mutex: TraceMutex = .{};
    var recorder = TraceRecorder.init(std.testing.allocator, -1, &mutex);
    defer recorder.deinit();
    recorder.recordIOWithProviderPhase("http", "fetchSync", ctx, &.{}, value.JSValue.undefined_val, .head_received, 202);
    const io = (try parseTraceLine(std.mem.trim(u8, recorder.buf.items, "\n"))).io;
    try std.testing.expectEqual(ProviderPhase.head_received, io.provider_phase.?);
    try std.testing.expectEqual(@as(?u16, 202), io.provider_status);
    recorder.buf.clearRetainingCapacity();
    recorder.recordIO("http", "fetchSync", ctx, &.{}, value.JSValue.undefined_val);
    try std.testing.expect(std.mem.find(u8, recorder.buf.items, "provider_") == null);
}

test "findJsonIntValue" {
    const line = "{\"type\":\"response\",\"status\":200,\"seq\":5}";
    try std.testing.expectEqual(@as(i64, 200), findJsonIntValue(line, "\"status\"").?);
    try std.testing.expectEqual(@as(i64, 5), findJsonIntValue(line, "\"seq\"").?);
}

test "findJsonObjectValue" {
    const line = "{\"type\":\"request\",\"headers\":{\"host\":\"localhost\"},\"body\":null}";
    try std.testing.expectEqualStrings("{\"host\":\"localhost\"}", findJsonObjectValue(line, "\"headers\"").?);
}

test "findJsonArrayValue" {
    const line = "{\"type\":\"io\",\"args\":[\"key\",\"value\"],\"result\":true}";
    try std.testing.expectEqualStrings("[\"key\",\"value\"]", findJsonArrayValue(line, "\"args\"").?);
}

test "parseTraceLine request" {
    const line = "{\"type\":\"request\",\"method\":\"POST\",\"url\":\"/api/users\",\"headers\":{},\"body\":\"hello\"}";
    const entry = try parseTraceLine(line);
    switch (entry) {
        .request => |req| {
            try std.testing.expectEqualStrings("POST", req.method);
            try std.testing.expectEqualStrings("/api/users", req.url);
            try std.testing.expectEqualStrings("hello", req.body.?);
        },
        else => return error.UnexpectedTraceType,
    }
}

test "parseTraceLine io" {
    const line = "{\"type\":\"io\",\"seq\":0,\"module\":\"env\",\"fn\":\"env\",\"args\":[\"API_KEY\"],\"result\":\"sk-123\"}";
    const entry = try parseTraceLine(line);
    switch (entry) {
        .io => |io| {
            try std.testing.expectEqual(@as(u32, 0), io.seq);
            try std.testing.expectEqualStrings("env", io.module);
            try std.testing.expectEqualStrings("env", io.func);
        },
        else => return error.UnexpectedTraceType,
    }
}

test "parseTraceFile groups by request" {
    const source =
        "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/a\",\"headers\":{},\"body\":null}\n" ++
        "{\"type\":\"io\",\"seq\":0,\"module\":\"env\",\"fn\":\"env\",\"args\":[\"K\"],\"result\":\"V\"}\n" ++
        "{\"type\":\"response\",\"status\":200,\"headers\":{},\"body\":\"ok\"}\n" ++
        "{\"type\":\"meta\",\"duration_us\":100,\"handler\":\"h.ts\",\"pool_slot\":0,\"io_count\":1}\n" ++
        "{\"type\":\"request\",\"method\":\"POST\",\"url\":\"/b\",\"headers\":{},\"body\":\"data\"}\n" ++
        "{\"type\":\"response\",\"status\":201,\"headers\":{},\"body\":\"created\"}\n" ++
        "{\"type\":\"meta\",\"duration_us\":200,\"handler\":\"h.ts\",\"pool_slot\":1,\"io_count\":0}\n";

    const groups = try parseTraceFile(std.testing.allocator, source);
    defer {
        for (groups) |g| std.testing.allocator.free(g.io_calls);
        std.testing.allocator.free(groups);
    }

    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqualStrings("GET", groups[0].request.method);
    try std.testing.expectEqual(@as(usize, 1), groups[0].io_calls.len);
    try std.testing.expectEqual(@as(u16, 200), groups[0].response.?.status);
    try std.testing.expectEqualStrings("POST", groups[1].request.method);
    try std.testing.expectEqual(@as(usize, 0), groups[1].io_calls.len);
    try std.testing.expectEqual(@as(u16, 201), groups[1].response.?.status);
}

test "parseTraceFile rejects malformed recorded values" {
    const source =
        "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n" ++
        "{\"type\":\"response\",\"status\":200,\"headers\":{},\"body\":\"ok\"}\n" ++
        "{\"type\":\"meta\",\"duration_us\":1,\"handler\":\"h.ts\",\"pool_slot\":0,\"io_count\":0}\n" ++
        "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/malformed\",\"headers\":{},\"body\":null}\n" ++
        "{\"type\":\"io\",\"seq\":0,\"module\":\"env\",\"fn\":\"env\",\"args\":[],\"result\":not-json}\n";

    try std.testing.expectError(
        error.InvalidTraceJson,
        parseTraceFile(std.testing.allocator, source),
    );
}

test "parseTraceFile rejects unknown trace entry types" {
    const source =
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"respones","status":200,"headers":{},"body":"ok"}
        \\{"type":"meta","duration_us":1,"handler":"handler.ts","pool_slot":0,"io_count":0}
    ;
    try std.testing.expectError(
        error.InvalidTraceEntry,
        parseTraceFile(std.testing.allocator, source),
    );
}

test "parseTraceFile rejects response-less traces without a witness tag" {
    const source =
        \\{"type":"request","method":"GET","url":"/","headers":{},"body":null}
        \\{"type":"meta","duration_us":1,"handler":"handler.ts","pool_slot":0,"io_count":0}
    ;
    try std.testing.expectError(
        error.InvalidTraceEntry,
        parseTraceFile(std.testing.allocator, source),
    );
}

/// A standalone `Context` for the tests below, built from this file's own
/// imports rather than from `root.zig`'s `createContext`.
///
/// Reaching `root.zig` from here was not free. `root.zig` re-exports every
/// module in the package, `builtins/helpers.zig` imports this file, and
/// `builtins/root.zig` imports that - so the four test-only imports made the
/// engine's built-ins transitively import the flow checker, the type checker,
/// and the semantics registry. Removing them drops 26 files out of the engine's
/// import closure. See
/// pre-rebase:docs/archive/plans/2026-08-07-021-zts-three-module-split-plan.md.
///
/// The allocator is expected to be an arena: the GC and heap records are
/// allocated from it and reclaimed when it is torn down, so only the resources
/// their `deinit` methods own are released explicitly.
fn testCreateContext(allocator: std.mem.Allocator) !*context.Context {
    const gc_mod = @import("gc.zig");
    const heap_mod = @import("heap.zig");

    const gc_state = try allocator.create(gc_mod.GC);
    gc_state.* = try gc_mod.GC.init(allocator, .{ .nursery_size = 4096 });
    errdefer gc_state.deinit();

    const heap_state = try allocator.create(heap_mod.Heap);
    heap_state.* = heap_mod.Heap.init(allocator, .{});
    errdefer heap_state.deinit();
    gc_state.setHeap(heap_state);

    return try context.Context.init(allocator, gc_state, .{});
}

fn testDestroyContext(ctx: *context.Context) void {
    const gc_state = ctx.gc_state;
    const heap_state = gc_state.heap_ptr;
    ctx.deinit();
    gc_state.deinit();
    if (heap_state) |h| h.deinit();
}

test "parseTraceFile preserves optional absence and recorded undefined" {
    const source =
        "{\"type\":\"witness\",\"property\":\"optional-values\"}\n" ++
        "{\"type\":\"request\",\"method\":\"GET\",\"url\":\"/\",\"headers\":{},\"body\":null}\n" ++
        "{\"type\":\"io\",\"seq\":0,\"module\":\"env\",\"fn\":\"env\",\"args\":[]}\n" ++
        "{\"type\":\"io\",\"seq\":1,\"module\":\"env\",\"fn\":\"env\",\"args\":[],\"result\":null}\n";

    const groups = try parseTraceFile(std.testing.allocator, source);
    defer {
        for (groups) |group| std.testing.allocator.free(group.io_calls);
        std.testing.allocator.free(groups);
    }

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].io_calls.len);
    try std.testing.expectEqualStrings("null", groups[0].io_calls[0].result_json);
    try std.testing.expectEqualStrings("null", groups[0].io_calls[1].result_json);

    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const ctx = try testCreateContext(test_arena.allocator());
    defer testDestroyContext(ctx);
    try std.testing.expect(jsonToJSValue(ctx, groups[0].io_calls[1].result_json).isUndefined());
}

test "jsonToJSValue primitives" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const ctx = try testCreateContext(allocator);
    defer testDestroyContext(ctx);

    // null -> undefined
    try std.testing.expect(jsonToJSValue(ctx, "null").isUndefined());

    // boolean
    try std.testing.expect(jsonToJSValue(ctx, "true").isTrue());
    try std.testing.expect(jsonToJSValue(ctx, "false").isFalse());

    // integer
    const int_val = jsonToJSValue(ctx, "42");
    try std.testing.expect(int_val.isInt());
    try std.testing.expectEqual(@as(i32, 42), int_val.getInt());

    // negative integer
    const neg_val = jsonToJSValue(ctx, "-7");
    try std.testing.expect(neg_val.isInt());
    try std.testing.expectEqual(@as(i32, -7), neg_val.getInt());

    // float
    const float_val = jsonToJSValue(ctx, "3.14");
    try std.testing.expect(float_val.isFloat64());

    // string
    const str_val = jsonToJSValue(ctx, "\"hello\"");
    try std.testing.expect(str_val.isAnyString());
}

test "jsonToJSValue object" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const ctx = try testCreateContext(allocator);
    defer testDestroyContext(ctx);

    const obj_val = jsonToJSValue(ctx, "{\"ok\":true,\"value\":42}");
    try std.testing.expect(obj_val.isObject());
}

test "jsonToJSValue array" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const ctx = try testCreateContext(allocator);
    defer testDestroyContext(ctx);

    const arr_val = jsonToJSValue(ctx, "[1,2,3]");
    try std.testing.expect(arr_val.isObject());
    const arr_obj = object.JSObject.fromValue(arr_val);
    try std.testing.expectEqual(@as(u32, 3), arr_obj.getArrayLength());
}

test "ReplayState nextIO" {
    const io_calls = [_]IoEntry{
        .{ .seq = 0, .module = "env", .func = "env", .args_json = "[\"K\"]", .result_json = "\"V\"" },
        .{ .seq = 1, .module = "cache", .func = "cacheGet", .args_json = "[\"ns\",\"k\"]", .result_json = "null" },
    };
    var state = ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };

    // Correct call
    const e1 = state.nextIO("env", "env").?;
    try std.testing.expectEqualStrings("env", e1.module);
    try std.testing.expectEqual(@as(u32, 0), state.divergences);

    // Correct call
    const e2 = state.nextIO("cache", "cacheGet").?;
    try std.testing.expectEqualStrings("cache", e2.module);
    try std.testing.expectEqual(@as(u32, 0), state.divergences);

    // Exhausted
    try std.testing.expect(state.nextIO("env", "env") == null);
    try std.testing.expectEqual(@as(u32, 1), state.divergences);
}

test "ReplayState peekMatches does not consume or count divergence" {
    const io_calls = [_]IoEntry{
        .{ .seq = 0, .module = "validate", .func = "validateJson", .args_json = "[]", .result_json = "{\"ok\":true}" },
    };
    var state = ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };

    // Head matches: peek is true and leaves the cursor and divergence untouched.
    try std.testing.expect(state.peekMatches("validate", "validateJson"));
    try std.testing.expectEqual(@as(u32, 0), state.cursor);
    try std.testing.expectEqual(@as(u32, 0), state.divergences);

    // Head does not match this (pure) call: peek is false, still no consume,
    // so a fallback stub can run the real impl and leave the entry for the
    // genuinely-recorded call that follows.
    try std.testing.expect(!state.peekMatches("crypto", "sha256"));
    try std.testing.expectEqual(@as(u32, 0), state.cursor);
    try std.testing.expectEqual(@as(u32, 0), state.divergences);

    // The matching entry is still available to consume normally.
    try std.testing.expect(state.nextIO("validate", "validateJson") != null);
    try std.testing.expectEqual(@as(u32, 1), state.cursor);

    // Exhausted: peek is false without underflow.
    try std.testing.expect(!state.peekMatches("validate", "validateJson"));
}

test "ReplayState consumeHead and hasEntryAhead" {
    const io_calls = [_]IoEntry{
        .{ .seq = 0, .module = "http", .func = "fetchSync", .args_json = "[]", .result_json = "{}" },
        .{ .seq = 1, .module = "validate", .func = "validateJson", .args_json = "[]", .result_json = "{\"ok\":true}" },
    };
    var state = ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };

    // A pure call whose recorded entry sits AHEAD of the head (the head is a
    // different, effectful call): hasEntryAhead is true -> the fallback flags a
    // divergence rather than silently absorbing the drift.
    try std.testing.expect(!state.peekMatches("validate", "validateJson"));
    try std.testing.expect(state.hasEntryAhead("validate", "validateJson"));

    // A genuinely-new pure call appears in no recording: no divergence.
    try std.testing.expect(!state.hasEntryAhead("crypto", "sha256"));

    // consumeHead trusts a prior peek: advances exactly one without touching
    // divergence, returning the head entry.
    try std.testing.expect(state.peekMatches("http", "fetchSync"));
    const head = state.consumeHead();
    try std.testing.expectEqualStrings("http", head.module);
    try std.testing.expectEqual(@as(u32, 1), state.cursor);
    try std.testing.expectEqual(@as(u32, 0), state.divergences);

    // Now validate is at the head and no longer "ahead".
    try std.testing.expect(state.peekMatches("validate", "validateJson"));
}

test "ReplayState unconsumedCount flags a dropped trailing effect" {
    const io_calls = [_]IoEntry{
        .{ .seq = 0, .module = "cache", .func = "cacheGet", .args_json = "[]", .result_json = "{}" },
        .{ .seq = 1, .module = "cache", .func = "cacheSet", .args_json = "[]", .result_json = "{}" },
    };
    var state = ReplayState{ .io_calls = &io_calls, .cursor = 0, .divergences = 0 };

    // Nothing consumed yet: both entries are leftover.
    try std.testing.expectEqual(@as(u32, 2), state.unconsumedCount());

    // Edited handler made only the cacheGet (dropped the trailing cacheSet):
    // one entry stays unconsumed, so replay must fail closed.
    _ = state.consumeHead();
    try std.testing.expectEqual(@as(u32, 1), state.unconsumedCount());

    // Faithful replay consumes every entry: no leftover.
    _ = state.consumeHead();
    try std.testing.expectEqual(@as(u32, 0), state.unconsumedCount());
}

test "argsDrifted flags changed args, skips unpinned recordings" {
    // Same args -> no drift.
    try std.testing.expect(!argsDrifted("[\"AAA\"]", "[\"AAA\"]"));
    // Changed arg -> drift (the matched-path divergence #5 detects).
    try std.testing.expect(argsDrifted("[\"AAA\"]", "[\"BBB\"]"));
    // Different arity -> drift.
    try std.testing.expect(argsDrifted("[\"a\",\"b\"]", "[\"a\"]"));
    // Recording did not pin args ("[]"/empty) -> never flagged, regardless of
    // live args (protects zero-arg calls and hand-written fixtures).
    try std.testing.expect(!argsDrifted("[]", "[\"a\"]"));
    try std.testing.expect(!argsDrifted("", "[\"a\"]"));
    // Zero-arg call against a zero-arg recording -> no drift.
    try std.testing.expect(!argsDrifted("[]", "[]"));
}

test "ReplayState divergence on mismatch" {
    const io_calls = [_]IoEntry{
        .{ .seq = 0, .module = "env", .func = "env", .args_json = "[\"K\"]", .result_json = "\"V\"" },
    };
    var state = ReplayState{
        .io_calls = &io_calls,
        .cursor = 0,
        .divergences = 0,
    };

    // Wrong module name
    const entry = state.nextIO("cache", "env");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, 1), state.divergences);
}
