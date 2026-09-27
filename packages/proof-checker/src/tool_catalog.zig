//! The canonical tool catalog, `ZTCAT1`.
//!
//! A tool-profile handler ships its catalog as canonical bytes, and the
//! executable graph commits to them as member `tool_catalog`. The kernel decodes
//! the bytes itself, recomputes their domain-separated digest, and compares it
//! with the member. The decoder is zero-copy and allocation-free: every slice it
//! returns points into the bytes the caller holds.
//!
//! The kernel does not check that a schema is inside the supported subset. That
//! needs an allocating parser; the runtime compiles every schema from the
//! accepted bytes and refuses to start when one does not compile.
//!
//! Layout (integers little-endian, strings u32-length-prefixed UTF-8):
//!
//! ```text
//! magic            8 bytes  "ZTCAT1\0\0"
//! schema           u16      4
//! entry_count      u16      1..64
//! entry, entry_count times, strictly increasing by name bytes:
//!   kind             u8      0 tool, 1 agent
//!   name             string  1..64
//!   method           string  1..16, uppercase ASCII A-Z
//!   path             string  1..512, starts with "/"
//!   description      string  1..4096
//!   tool, when kind is 0, keeps the schema 3 layout:
//!     input_name       string  1..64
//!     input_schema     string  1..65536
//!     output_name      string  1..64
//!     output_schema    string  1..65536
//!     max_input_bytes  u32     1..1048576
//!     scope_tenant     string  0, or 1..64
//!     scope_subject    string  0, or 1..64
//!     export_count     u16     0..256
//!     exports          export_count pairs of module string, name string
//!     credential_count u16     0..64
//!     credentials      credential_count name strings
//!   agent, when kind is 1:
//!     max_input_bytes  u32     1..1048576
//!     export_count     u16     0..256
//!     exports          export_count pairs of module string, name string
//!                      each 1..64 bytes, strictly increasing by (module, name)
//!     tool_count       u16     1..64
//!     tool_name        string  1..64, tool_count times, strictly increasing
//!     endpoint         string  1..512, normalized scheme://host:port
//!     credential       string  1..64
//!     rounds           u32     1..64
//!     tool_calls       u32     1..256
//!     calls_per_round  u32     1..tool_calls
//!     argument_bytes   u32     1..1048576
//!     result_bytes     u32     1..1048576
//!     turn_deadline_ms u32     1..600000
//! trailing bytes: refused
//! ```
//!
//! No two entries share a (method, path) route. A scope field of length 0 is
//! absent; it is the only string in the layout that may be empty. The kernel
//! checks a scope field's length and encoding only: that it names a required
//! string property of the input schema is a build rule, and the runtime finds
//! the field in the compiled schema it validates with.
//!
//! Schema 2 (M4 T5) added scope fields. Schema 3 (M4 T6) added credential
//! names. Schema 4 (M5 A1) adds the entry kind and agent entry layout. Older
//! schemas are refused.

const std = @import("std");
const residual = @import("residual.zig");
const wire = @import("wire.zig");

const Reader = wire.Reader;

pub const magic = "ZTCAT1\x00\x00";
pub const schema_version: u16 = 4;
pub const header_size: usize = magic.len + 2 + 2;

pub const digest_domain = "zttp-tool-catalog-v1";

pub const min_entries: u16 = 1;
pub const max_entries: u16 = 64;
pub const max_name_bytes: u32 = 64;
pub const max_method_bytes: u32 = 16;
pub const max_path_bytes: u32 = 512;
pub const max_description_bytes: u32 = 4096;
pub const max_schema_name_bytes: u32 = 64;
pub const max_schema_bytes: u32 = 65536;
pub const min_max_input_bytes: u32 = 1;
pub const max_max_input_bytes: u32 = 1048576;
pub const max_scope_field_bytes: u32 = 64;
pub const max_exports: u16 = 256;
pub const max_export_field_bytes: u32 = 64;
pub const max_credentials: u16 = 64;
pub const max_credential_name_bytes: u32 = 64;
pub const max_agent_tools: u16 = max_entries;
pub const max_endpoint_bytes: u32 = @intCast(residual.max_endpoint_bytes);
pub const max_agent_rounds: u32 = 64;
pub const max_agent_tool_calls: u32 = 256;
pub const max_agent_argument_bytes: u32 = max_max_input_bytes;
pub const max_agent_result_bytes: u32 = max_max_input_bytes;
pub const max_agent_turn_deadline_ms: u32 = 600000;

/// Every refusal the decoder can report. Closed, and each member names one
/// distinct defect so a diagnostic can say which rule the bytes broke.
pub const DecodeError = error{
    Truncated,
    BadMagic,
    UnsupportedSchema,
    EntryKindInvalid,
    EntryCountOutOfRange,
    NameLength,
    MethodInvalid,
    PathInvalid,
    DescriptionLength,
    SchemaNameLength,
    SchemaLength,
    MaxInputBytesOutOfRange,
    /// A scope field longer than `max_scope_field_bytes`.
    ScopeFieldLength,
    ExportCountOutOfRange,
    ExportFieldLength,
    /// Names must be strictly increasing by byte order, which also refuses a
    /// duplicate name.
    NamesNotOrdered,
    /// Two entries name the same method and path.
    RouteDuplicate,
    /// Exports must be strictly increasing by (module, name), which also
    /// refuses a duplicate export.
    ExportsNotOrdered,
    CredentialCountOutOfRange,
    CredentialNameLength,
    /// Credential names must be strictly increasing by byte order, which also
    /// refuses a duplicate.
    CredentialsNotOrdered,
    AgentToolCountOutOfRange,
    AgentToolNameLength,
    AgentToolsNotOrdered,
    AgentToolUnknown,
    AgentToolIsAgent,
    AgentEndpointLength,
    AgentEndpointNotNormalized,
    AgentCredentialNameLength,
    AgentRoundsOutOfRange,
    AgentToolCallsOutOfRange,
    AgentToolCallsPerRoundOutOfRange,
    AgentToolCallsPerRoundExceedsToolCalls,
    AgentArgumentBytesOutOfRange,
    AgentResultBytesOutOfRange,
    AgentTurnDeadlineMsOutOfRange,
    InvalidUtf8,
    TrailingData,
};

pub const Export = struct {
    module: []const u8,
    name: []const u8,

    pub fn order(a: Export, b: Export) std.math.Order {
        @setRuntimeSafety(true);
        const by_module = std.mem.order(u8, a.module, b.module);
        if (by_module != .eq) return by_module;
        return std.mem.order(u8, a.name, b.name);
    }
};

pub const EntryKind = enum(u8) { tool = 0, agent = 1 };

pub const AgentLimits = struct {
    rounds: u32,
    tool_calls: u32,
    tool_calls_per_round: u32,
    argument_bytes: u32,
    result_bytes: u32,
    turn_deadline_ms: u32,
};

pub const ExportIterator = wire.Iterator(Export, DecodeError, readExport);
/// Length-prefixed names, one after another.
pub const NameIterator = wire.Iterator([]const u8, DecodeError, readCredential);
pub const AgentToolIterator = wire.Iterator([]const u8, DecodeError, readAgentTool);
pub const EntryIterator = wire.Iterator(Entry, DecodeError, readEntry);

pub const Agent = struct {
    tools: AgentToolIterator,
    provider_endpoint: []const u8,
    provider_credential: []const u8,
    limits: AgentLimits,
};

pub const Entry = struct {
    kind: EntryKind,
    name: []const u8,
    method: []const u8,
    path: []const u8,
    description: []const u8,
    input_name: []const u8,
    input_schema: []const u8,
    output_name: []const u8,
    output_schema: []const u8,
    max_input_bytes: u32,
    /// The input field bound to the verified tenant, or null.
    scope_tenant: ?[]const u8,
    /// The input field bound to the verified subject, or null.
    scope_subject: ?[]const u8,
    exports: ExportIterator,
    /// The credential names the tool may use (schema 3).
    credentials: NameIterator,
    agent: ?Agent,
};

/// A decoded catalog. Only `decode` builds one, so the bytes it holds have
/// passed every rule above.
pub const Catalog = struct {
    bytes: []const u8,
    entry_count: u16,

    pub fn entries(self: Catalog) EntryIterator {
        @setRuntimeSafety(true);
        return .{ .bytes = self.bytes, .pos = header_size, .remaining = self.entry_count };
    }
};

fn readExport(reader: *Reader) DecodeError!Export {
    @setRuntimeSafety(true);
    const module = try reader.string(u32, 1, max_export_field_bytes, error.ExportFieldLength);
    const name = try reader.string(u32, 1, max_export_field_bytes, error.ExportFieldLength);
    return .{ .module = module, .name = name };
}

fn readCredential(reader: *Reader) DecodeError![]const u8 {
    @setRuntimeSafety(true);
    return reader.string(u32, 1, max_credential_name_bytes, error.CredentialNameLength);
}

fn readAgentTool(reader: *Reader) DecodeError![]const u8 {
    @setRuntimeSafety(true);
    return reader.string(u32, 1, max_name_bytes, error.AgentToolNameLength);
}

/// A scope field: length 0 means absent.
fn readScope(reader: *Reader) DecodeError!?[]const u8 {
    @setRuntimeSafety(true);
    const out = try reader.string(u32, 0, max_scope_field_bytes, error.ScopeFieldLength);
    return if (out.len == 0) null else out;
}

fn emptyExports(bytes: []const u8, pos: usize) ExportIterator {
    @setRuntimeSafety(true);
    return .{ .bytes = bytes[0..pos], .pos = pos, .remaining = 0 };
}

fn emptyNames(bytes: []const u8, pos: usize) NameIterator {
    @setRuntimeSafety(true);
    return .{ .bytes = bytes[0..pos], .pos = pos, .remaining = 0 };
}

fn readAgent(reader: *Reader) DecodeError!Agent {
    @setRuntimeSafety(true);
    const tool_count = try reader.int(u16);
    if (tool_count == 0 or tool_count > max_agent_tools) return error.AgentToolCountOutOfRange;
    var tools = AgentToolIterator{ .bytes = reader.bytes, .pos = reader.pos, .remaining = tool_count };
    try tools.skipAll(reader);
    tools.bytes = reader.bytes[0..reader.pos];
    const provider_endpoint = try reader.string(u32, 1, max_endpoint_bytes, error.AgentEndpointLength);
    const provider_credential = try reader.string(u32, 1, max_credential_name_bytes, error.AgentCredentialNameLength);
    const limits = AgentLimits{
        .rounds = try reader.int(u32),
        .tool_calls = try reader.int(u32),
        .tool_calls_per_round = try reader.int(u32),
        .argument_bytes = try reader.int(u32),
        .result_bytes = try reader.int(u32),
        .turn_deadline_ms = try reader.int(u32),
    };
    return .{ .tools = tools, .provider_endpoint = provider_endpoint, .provider_credential = provider_credential, .limits = limits };
}

/// Read one entry's fields with length bounds and step over its variable lists.
fn readEntry(reader: *Reader) DecodeError!Entry {
    @setRuntimeSafety(true);
    const kind: EntryKind = switch (try reader.int(u8)) {
        0 => .tool,
        1 => .agent,
        else => return error.EntryKindInvalid,
    };
    const name = try reader.string(u32, 1, max_name_bytes, error.NameLength);
    const method = try reader.string(u32, 1, max_method_bytes, error.MethodInvalid);
    const path = try reader.string(u32, 1, max_path_bytes, error.PathInvalid);
    const description = try reader.string(u32, 1, max_description_bytes, error.DescriptionLength);
    const empty = reader.bytes[reader.pos..reader.pos];
    var entry = Entry{
        .kind = kind,
        .name = name,
        .method = method,
        .path = path,
        .description = description,
        .input_name = empty,
        .input_schema = empty,
        .output_name = empty,
        .output_schema = empty,
        .max_input_bytes = 0,
        .scope_tenant = null,
        .scope_subject = null,
        .exports = emptyExports(reader.bytes, reader.pos),
        .credentials = emptyNames(reader.bytes, reader.pos),
        .agent = null,
    };
    if (kind == .tool) {
        entry.input_name = try reader.string(u32, 1, max_schema_name_bytes, error.SchemaNameLength);
        entry.input_schema = try reader.string(u32, 1, max_schema_bytes, error.SchemaLength);
        entry.output_name = try reader.string(u32, 1, max_schema_name_bytes, error.SchemaNameLength);
        entry.output_schema = try reader.string(u32, 1, max_schema_bytes, error.SchemaLength);
    }
    entry.max_input_bytes = try reader.int(u32);
    if (entry.max_input_bytes < min_max_input_bytes or entry.max_input_bytes > max_max_input_bytes) {
        return error.MaxInputBytesOutOfRange;
    }
    if (kind == .tool) {
        entry.scope_tenant = try readScope(reader);
        entry.scope_subject = try readScope(reader);
    }
    const export_count = try reader.int(u16);
    if (export_count > max_exports) return error.ExportCountOutOfRange;
    entry.exports = .{ .bytes = reader.bytes, .pos = reader.pos, .remaining = export_count };
    try entry.exports.skipAll(reader);
    entry.exports.bytes = reader.bytes[0..reader.pos];
    switch (kind) {
        .tool => {
            const credential_count = try reader.int(u16);
            if (credential_count > max_credentials) return error.CredentialCountOutOfRange;
            entry.credentials = .{ .bytes = reader.bytes, .pos = reader.pos, .remaining = credential_count };
            try entry.credentials.skipAll(reader);
            entry.credentials.bytes = reader.bytes[0..reader.pos];
        },
        .agent => entry.agent = try readAgent(reader),
    }
    return entry;
}

fn validUtf8(bytes: []const u8) DecodeError!void {
    @setRuntimeSafety(true);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
}

fn validateEntry(entry: Entry) DecodeError!void {
    @setRuntimeSafety(true);
    for (entry.method) |byte| {
        if (byte < 'A' or byte > 'Z') return error.MethodInvalid;
    }
    if (entry.path[0] != '/') return error.PathInvalid;

    try validUtf8(entry.name);
    try validUtf8(entry.path);
    try validUtf8(entry.description);
    if (entry.kind == .tool) {
        try validUtf8(entry.input_name);
        try validUtf8(entry.input_schema);
        try validUtf8(entry.output_name);
        try validUtf8(entry.output_schema);
    }
    if (entry.scope_tenant) |field| try validUtf8(field);
    if (entry.scope_subject) |field| try validUtf8(field);

    var exports = entry.exports;
    var export_order = wire.Ascending(Export, Export.order){};
    while (try exports.next()) |item| {
        try validUtf8(item.module);
        try validUtf8(item.name);
        if (export_order.step(item) != .lt) return error.ExportsNotOrdered;
    }

    var credentials = entry.credentials;
    var credential_order = wire.Ascending([]const u8, wire.bytesOrder){};
    while (try credentials.next()) |name| {
        try validUtf8(name);
        if (credential_order.step(name) != .lt) return error.CredentialsNotOrdered;
    }

    if (entry.agent) |agent| {
        var tools = agent.tools;
        var tool_order = wire.Ascending([]const u8, wire.bytesOrder){};
        while (try tools.next()) |name| {
            try validUtf8(name);
            if (tool_order.step(name) != .lt) return error.AgentToolsNotOrdered;
        }
        try validUtf8(agent.provider_endpoint);
        try validUtf8(agent.provider_credential);
        var normalized_buf: [max_endpoint_bytes]u8 = undefined;
        const normalized = residual.normalize(.endpoint_v1, agent.provider_endpoint, &normalized_buf) catch return error.AgentEndpointNotNormalized;
        if (!std.mem.eql(u8, normalized, agent.provider_endpoint)) return error.AgentEndpointNotNormalized;
        if (agent.limits.rounds == 0 or agent.limits.rounds > max_agent_rounds) return error.AgentRoundsOutOfRange;
        if (agent.limits.tool_calls == 0 or agent.limits.tool_calls > max_agent_tool_calls) return error.AgentToolCallsOutOfRange;
        if (agent.limits.tool_calls_per_round == 0 or agent.limits.tool_calls_per_round > max_agent_tool_calls) return error.AgentToolCallsPerRoundOutOfRange;
        if (agent.limits.tool_calls_per_round > agent.limits.tool_calls) return error.AgentToolCallsPerRoundExceedsToolCalls;
        if (agent.limits.argument_bytes == 0 or agent.limits.argument_bytes > max_agent_argument_bytes) return error.AgentArgumentBytesOutOfRange;
        if (agent.limits.result_bytes == 0 or agent.limits.result_bytes > max_agent_result_bytes) return error.AgentResultBytesOutOfRange;
        if (agent.limits.turn_deadline_ms == 0 or agent.limits.turn_deadline_ms > max_agent_turn_deadline_ms) return error.AgentTurnDeadlineMsOutOfRange;
    }
}

/// Decode and validate canonical catalog bytes.
pub fn decode(bytes: []const u8) DecodeError!Catalog {
    @setRuntimeSafety(true);
    var reader = try wire.header(bytes, magic, schema_version);
    const entry_count = try reader.int(u16);
    if (entry_count < min_entries or entry_count > max_entries) return error.EntryCountOutOfRange;

    var entries = EntryIterator{ .bytes = bytes, .pos = reader.pos, .remaining = entry_count };
    var name_order = wire.Ascending([]const u8, wire.bytesOrder){};
    while (try entries.next()) |entry| {
        try validateEntry(entry);
        if (name_order.step(entry.name) != .lt) return error.NamesNotOrdered;
    }
    reader.pos = entries.pos;
    if (!reader.atEnd()) return error.TrailingData;

    const catalog = Catalog{ .bytes = bytes, .entry_count = entry_count };

    // An agent may refer only to tool entries in this same catalog.
    var agent_entries = catalog.entries();
    while (try agent_entries.next()) |entry| {
        const agent = entry.agent orelse continue;
        var names = agent.tools;
        while (try names.next()) |name| {
            var candidates = catalog.entries();
            var found: ?EntryKind = null;
            while (try candidates.next()) |candidate| {
                if (std.mem.eql(u8, name, candidate.name)) {
                    found = candidate.kind;
                    break;
                }
            }
            const kind = found orelse return error.AgentToolUnknown;
            if (kind == .agent) return error.AgentToolIsAgent;
        }
    }

    // Routes: at most 64 entries, so a pairwise scan bounds the work without a
    // table. Every read below is over bytes the loop above already accepted.
    var outer = catalog.entries();
    var outer_index: u16 = 0;
    while (try outer.next()) |a| : (outer_index += 1) {
        var inner = catalog.entries();
        var inner_index: u16 = 0;
        while (inner_index <= outer_index) : (inner_index += 1) _ = try inner.next();
        while (try inner.next()) |b| {
            if (std.mem.eql(u8, a.method, b.method) and std.mem.eql(u8, a.path, b.path)) {
                return error.RouteDuplicate;
            }
        }
    }
    return catalog;
}

/// Domain-separated SHA-256 over the whole encoding. The digest a graph member
/// carries for these bytes.
pub fn digest(bytes: []const u8) [32]u8 {
    @setRuntimeSafety(true);
    return wire.domainDigest(digest_domain, bytes);
}

// ---------------------------------------------------------------------------
// Test support
// ---------------------------------------------------------------------------

/// A writer for building catalogs in tests, over a fixed buffer. It writes what
/// it is told, valid or not, so a test can build each refusal directly.
pub const test_support = struct {
    pub const Writer = wire.Writer;

    pub const SampleExport = struct { module: []const u8, name: []const u8 };

    pub const SampleAgent = struct {
        exports: []const SampleExport = &.{},
        tools: []const []const u8,
        provider_endpoint: []const u8 = "https://api.example.com:443",
        provider_credential: []const u8 = "provider",
        limits: AgentLimits = .{
            .rounds = 4,
            .tool_calls = 8,
            .tool_calls_per_round = 4,
            .argument_bytes = 4096,
            .result_bytes = 16384,
            .turn_deadline_ms = 20000,
        },
    };

    pub const SampleEntry = struct {
        kind: u8 = @intFromEnum(EntryKind.tool),
        name: []const u8,
        method: []const u8 = "POST",
        path: []const u8,
        description: []const u8 = "Echo the input text.",
        input_name: []const u8 = "EchoInput",
        input_schema: []const u8 = "{\"type\":\"object\"}",
        output_name: []const u8 = "EchoOutput",
        output_schema: []const u8 = "{\"type\":\"object\"}",
        max_input_bytes: u32 = 4096,
        scope_tenant: ?[]const u8 = null,
        scope_subject: ?[]const u8 = null,
        exports: []const SampleExport = &.{},
        credentials: []const []const u8 = &.{},
        agent: ?SampleAgent = null,
    };

    pub fn writeEntry(w: *Writer, entry: SampleEntry) void {
        @setRuntimeSafety(true);
        w.int(u8, entry.kind);
        w.string(entry.name);
        w.string(entry.method);
        w.string(entry.path);
        w.string(entry.description);
        if (entry.kind == @intFromEnum(EntryKind.agent)) {
            w.int(u32, entry.max_input_bytes);
            const agent = entry.agent orelse @panic("agent test entry needs agent fields");
            w.int(u16, @intCast(agent.exports.len));
            for (agent.exports) |item| {
                w.string(item.module);
                w.string(item.name);
            }
            w.int(u16, @intCast(agent.tools.len));
            for (agent.tools) |name| w.string(name);
            w.string(agent.provider_endpoint);
            w.string(agent.provider_credential);
            w.int(u32, agent.limits.rounds);
            w.int(u32, agent.limits.tool_calls);
            w.int(u32, agent.limits.tool_calls_per_round);
            w.int(u32, agent.limits.argument_bytes);
            w.int(u32, agent.limits.result_bytes);
            w.int(u32, agent.limits.turn_deadline_ms);
            return;
        }
        w.string(entry.input_name);
        w.string(entry.input_schema);
        w.string(entry.output_name);
        w.string(entry.output_schema);
        w.int(u32, entry.max_input_bytes);
        w.string(entry.scope_tenant orelse "");
        w.string(entry.scope_subject orelse "");
        w.int(u16, @intCast(entry.exports.len));
        for (entry.exports) |item| {
            w.string(item.module);
            w.string(item.name);
        }
        w.int(u16, @intCast(entry.credentials.len));
        for (entry.credentials) |name| w.string(name);
    }

    pub fn writeCatalog(w: *Writer, entries: []const SampleEntry) void {
        @setRuntimeSafety(true);
        w.raw(magic);
        w.int(u16, schema_version);
        w.int(u16, @intCast(entries.len));
        for (entries) |entry| writeEntry(w, entry);
    }

    pub const sample_entries = [_]SampleEntry{
        .{
            .name = "echo",
            .path = "/tools/echo",
            .exports = &.{
                .{ .module = "zttp:json", .name = "parse" },
                .{ .module = "zttp:result", .name = "ok" },
            },
        },
        .{
            .name = "lookup",
            .method = "GET",
            .path = "/tools/lookup",
            .description = "Look up one record.",
            .input_name = "LookupInput",
            .input_schema = "{\"type\":\"string\"}",
            .output_name = "LookupOutput",
            .output_schema = "{\"type\":\"number\"}",
            .max_input_bytes = 1048576,
            .scope_tenant = "tenant_id",
            .credentials = &.{ "billing", "weather" },
        },
    };

    /// The two-entry sample catalog, written into `buf`.
    pub fn sample(buf: []u8) []const u8 {
        @setRuntimeSafety(true);
        var w = Writer{ .buf = buf };
        writeCatalog(&w, &sample_entries);
        return w.bytes();
    }
};

const testing = std.testing;

test "a valid two-entry catalog decodes and iterates every field" {
    var buf: [1024]u8 = undefined;
    const bytes = test_support.sample(&buf);
    const catalog = try decode(bytes);
    try testing.expectEqual(@as(u16, 2), catalog.entry_count);

    var it = catalog.entries();
    const echo = (try it.next()).?;
    try testing.expectEqualStrings("echo", echo.name);
    try testing.expectEqualStrings("POST", echo.method);
    try testing.expectEqualStrings("/tools/echo", echo.path);
    try testing.expectEqualStrings("Echo the input text.", echo.description);
    try testing.expectEqualStrings("EchoInput", echo.input_name);
    try testing.expectEqualStrings("{\"type\":\"object\"}", echo.input_schema);
    try testing.expectEqualStrings("EchoOutput", echo.output_name);
    try testing.expectEqualStrings("{\"type\":\"object\"}", echo.output_schema);
    try testing.expectEqual(@as(u32, 4096), echo.max_input_bytes);
    try testing.expectEqual(@as(?[]const u8, null), echo.scope_tenant);
    try testing.expectEqual(@as(?[]const u8, null), echo.scope_subject);
    var exports = echo.exports;
    const first = (try exports.next()).?;
    try testing.expectEqualStrings("zttp:json", first.module);
    try testing.expectEqualStrings("parse", first.name);
    const second = (try exports.next()).?;
    try testing.expectEqualStrings("zttp:result", second.module);
    try testing.expectEqualStrings("ok", second.name);
    try testing.expectEqual(@as(?Export, null), try exports.next());

    const lookup = (try it.next()).?;
    try testing.expectEqualStrings("lookup", lookup.name);
    try testing.expectEqualStrings("GET", lookup.method);
    try testing.expectEqualStrings("/tools/lookup", lookup.path);
    try testing.expectEqualStrings("Look up one record.", lookup.description);
    try testing.expectEqualStrings("LookupInput", lookup.input_name);
    try testing.expectEqualStrings("{\"type\":\"string\"}", lookup.input_schema);
    try testing.expectEqualStrings("LookupOutput", lookup.output_name);
    try testing.expectEqualStrings("{\"type\":\"number\"}", lookup.output_schema);
    try testing.expectEqual(@as(u32, 1048576), lookup.max_input_bytes);
    try testing.expectEqualStrings("tenant_id", lookup.scope_tenant orelse return error.TestMissingScope);
    try testing.expectEqual(@as(?[]const u8, null), lookup.scope_subject);
    var no_exports = lookup.exports;
    try testing.expectEqual(@as(?Export, null), try no_exports.next());
    var lookup_credentials = lookup.credentials;
    try testing.expectEqualStrings("billing", (try lookup_credentials.next()).?);
    try testing.expectEqualStrings("weather", (try lookup_credentials.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try lookup_credentials.next());
    var echo_credentials = echo.credentials;
    try testing.expectEqual(@as(?[]const u8, null), try echo_credentials.next());

    try testing.expectEqual(@as(?Entry, null), try it.next());

    // Zero-copy: every slice points into the input.
    const base = @intFromPtr(bytes.ptr);
    try testing.expect(@intFromPtr(echo.name.ptr) >= base);
    try testing.expect(@intFromPtr(lookup.output_schema.ptr) + lookup.output_schema.len <= base + bytes.len);
}

test "the catalog digest is stable and domain-separated" {
    var buf: [1024]u8 = undefined;
    const bytes = test_support.sample(&buf);
    const a = digest(bytes);
    const b = digest(bytes);
    try testing.expectEqualSlices(u8, &a, &b);

    var plain: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &plain, .{});
    try testing.expect(!std.mem.eql(u8, &a, &plain));

    var tampered_buf: [1024]u8 = undefined;
    @memcpy(tampered_buf[0..bytes.len], bytes);
    tampered_buf[bytes.len - 1] ^= 1;
    try testing.expect(!std.mem.eql(u8, &a, &digest(tampered_buf[0..bytes.len])));
}

test "GET and POST may share one path" {
    const entries = [_]test_support.SampleEntry{
        .{ .name = "get", .method = "GET", .path = "/shared" },
        .{ .name = "post", .method = "POST", .path = "/shared" },
    };
    var buf: [1024]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeCatalog(&w, &entries);

    const catalog = try decode(w.bytes());
    try testing.expectEqual(@as(u16, 2), catalog.entry_count);
    var it = catalog.entries();
    const get = (try it.next()).?;
    try testing.expectEqualStrings("GET", get.method);
    try testing.expectEqualStrings("/shared", get.path);
    const post = (try it.next()).?;
    try testing.expectEqualStrings("POST", post.method);
    try testing.expectEqualStrings("/shared", post.path);
    try testing.expectEqual(@as(?Entry, null), try it.next());
}

test "an agent at every limit maximum decodes through its zero-copy view" {
    const limits = AgentLimits{
        .rounds = max_agent_rounds,
        .tool_calls = max_agent_tool_calls,
        .tool_calls_per_round = max_agent_tool_calls,
        .argument_bytes = max_agent_argument_bytes,
        .result_bytes = max_agent_result_bytes,
        .turn_deadline_ms = max_agent_turn_deadline_ms,
    };
    const entries = [_]test_support.SampleEntry{
        .{
            .kind = @intFromEnum(EntryKind.agent),
            .name = "agent",
            .path = "/agent",
            .max_input_bytes = max_max_input_bytes,
            .agent = .{
                .tools = &.{ "alpha", "zeta" },
                .provider_endpoint = "https://[2001:db8::1]:443",
                .limits = limits,
            },
        },
        .{ .name = "alpha", .path = "/alpha" },
        .{ .name = "zeta", .path = "/zeta" },
    };
    var buf: [2048]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeCatalog(&w, &entries);
    const catalog = try decode(w.bytes());
    var iterator = catalog.entries();
    const entry = (try iterator.next()) orelse return error.TestMissingEntry;
    try testing.expectEqual(EntryKind.agent, entry.kind);
    try testing.expectEqualStrings("", entry.input_name);
    try testing.expectEqualStrings("", entry.output_schema);
    try testing.expect(entry.scope_tenant == null and entry.scope_subject == null);
    var exports = entry.exports;
    try testing.expectEqual(@as(?Export, null), try exports.next());
    var credentials = entry.credentials;
    try testing.expectEqual(@as(?[]const u8, null), try credentials.next());
    const agent = entry.agent orelse return error.TestMissingAgent;
    try testing.expectEqualStrings("https://[2001:db8::1]:443", agent.provider_endpoint);
    try testing.expectEqual(limits, agent.limits);
    var names = agent.tools;
    try testing.expectEqualStrings("alpha", (try names.next()) orelse return error.TestMissingName);
    try testing.expectEqualStrings("zeta", (try names.next()) orelse return error.TestMissingName);
    try testing.expectEqual(@as(?[]const u8, null), try names.next());
}

test "agent exports decode in order" {
    const expected = [_]test_support.SampleExport{
        .{ .module = "zttp:fetch", .name = "fetch" },
        .{ .module = "zttp:fetch", .name = "fetchWithRetry" },
        .{ .module = "zttp:tool", .name = "callTool" },
    };
    var buf: [2048]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeCatalog(&w, &.{
        .{ .kind = @intFromEnum(EntryKind.agent), .name = "agent", .path = "/agent", .agent = .{
            .exports = &expected,
            .tools = &.{"lookup"},
        } },
        .{ .name = "lookup", .path = "/lookup" },
    });
    const catalog = try decode(w.bytes());
    var entries = catalog.entries();
    const entry = (try entries.next()) orelse return error.TestMissingEntry;
    var exports = entry.exports;
    for (expected) |pair| {
        const actual = (try exports.next()) orelse return error.TestMissingExport;
        try testing.expectEqualStrings(pair.module, actual.module);
        try testing.expectEqualStrings(pair.name, actual.name);
    }
    try testing.expectEqual(@as(?Export, null), try exports.next());
}

test "unordered agent exports are refused" {
    const unordered = [_][2]test_support.SampleExport{
        .{ .{ .module = "z", .name = "a" }, .{ .module = "a", .name = "a" } },
        .{ .{ .module = "a", .name = "z" }, .{ .module = "a", .name = "a" } },
        .{ .{ .module = "a", .name = "a" }, .{ .module = "a", .name = "a" } },
    };
    for (unordered) |pairs| {
        var buf: [2048]u8 = undefined;
        var w = test_support.Writer{ .buf = &buf };
        test_support.writeCatalog(&w, &.{
            .{ .kind = @intFromEnum(EntryKind.agent), .name = "agent", .path = "/agent", .agent = .{
                .exports = &pairs,
                .tools = &.{"lookup"},
            } },
            .{ .name = "lookup", .path = "/lookup" },
        });
        try testing.expectError(error.ExportsNotOrdered, decode(w.bytes()));
    }
}

test "agent export counts above the bound are refused" {
    const exports = [_]test_support.SampleExport{.{ .module = "a", .name = "a" }} ** (max_exports + 1);
    var buf: [8192]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeCatalog(&w, &.{
        .{ .kind = @intFromEnum(EntryKind.agent), .name = "agent", .path = "/agent", .agent = .{
            .exports = &exports,
            .tools = &.{"lookup"},
        } },
        .{ .name = "lookup", .path = "/lookup" },
    });
    try testing.expectError(error.ExportCountOutOfRange, decode(w.bytes()));
}

const DecodeSite = enum {
    short_header,
    integer_body,
    string_body,
    magic,
    schema,
    entry_kind,
    entry_count,
    name_length,
    method_length,
    path_length,
    description_length,
    input_name_length,
    input_schema_length,
    output_name_length,
    output_schema_length,
    max_input_bytes,
    tenant_scope_length,
    subject_scope_length,
    export_count,
    export_module_length,
    export_name_length,
    credential_count,
    credential_name_length,
    method_characters,
    path_prefix,
    name_utf8,
    path_utf8,
    description_utf8,
    input_name_utf8,
    input_schema_utf8,
    output_name_utf8,
    output_schema_utf8,
    tenant_scope_utf8,
    subject_scope_utf8,
    export_module_utf8,
    export_name_utf8,
    credential_utf8,
    export_order,
    credential_order,
    name_order,
    trailing_data,
    duplicate_route,
    agent_tool_count,
    agent_tool_name_length,
    agent_tool_order,
    agent_tool_unknown,
    agent_tool_is_agent,
    agent_endpoint_length,
    agent_endpoint_normalization,
    agent_credential_name_length,
    agent_rounds,
    agent_tool_calls,
    agent_tool_calls_per_round,
    agent_tool_calls_relation,
    agent_argument_bytes,
    agent_result_bytes,
    agent_turn_deadline_ms,
};

const Case = struct {
    site: DecodeSite,
    expected: DecodeError,
    entries: []const test_support.SampleEntry = &.{},
    /// When set, the case is written by hand instead of from `entries`.
    custom: ?*const fn (w: *test_support.Writer) void = null,
};

fn shortHeader(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw("ZTCAT");
}

fn truncatedInteger(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
}

fn truncatedString(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, @intFromEnum(EntryKind.tool));
    w.int(u32, 1);
}

fn sampleWithTrailingByte(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    test_support.writeCatalog(w, &test_support.sample_entries);
    w.raw(&.{0});
}

fn sampleTruncated(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    test_support.writeCatalog(w, &test_support.sample_entries);
    w.len -= 1;
}

fn badMagic(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw("ZTCAT2\x00\x00");
    w.int(u16, schema_version);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// Schema 1, the layout before the scope fields, is refused outright.
fn unsupportedSchema(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, 1);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// Schema 2, the layout before the credential names, is refused too.
fn schemaTwo(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, 2);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// Schema 3 is the immediately previous layout and is refused outright.
fn schemaThree(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, 3);
    w.int(u16, 1);
    test_support.writeEntry(w, test_support.sample_entries[0]);
}

/// An entry with no exports that claims one credential more than the bound.
fn tooManyCredentials(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, @intFromEnum(EntryKind.tool));
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields) |value| w.string(value);
    w.int(u32, 1);
    w.string("");
    w.string("");
    w.int(u16, 0);
    w.int(u16, max_credentials + 1);
}

const credential_65 = "c" ** (max_credential_name_bytes + 1);

fn zeroEntries(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 0);
}

fn tooManyEntries(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_entries + 1);
}

/// An entry whose fields up to `field` are valid and whose field `field` claims
/// `len` bytes without carrying them. The length bound fires before the body is
/// required.
fn claimLength(w: *test_support.Writer, field: usize, len: u32) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, @intFromEnum(EntryKind.tool));
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields[0..field]) |value| w.string(value);
    w.int(u32, len);
}

fn descriptionTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    claimLength(w, 3, max_description_bytes + 1);
}

fn schemaTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    claimLength(w, 5, max_schema_bytes + 1);
}

fn nameTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    claimLength(w, 0, max_name_bytes + 1);
}

fn tooManyExports(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, @intFromEnum(EntryKind.tool));
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields) |value| w.string(value);
    w.int(u32, 1);
    w.string("");
    w.string("");
    w.int(u16, max_exports + 1);
}

/// A scope field that claims one byte more than the bound, without carrying
/// it. The length bound fires before the body is required.
fn scopeTooLong(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, @intFromEnum(EntryKind.tool));
    const fields = [_][]const u8{ "echo", "POST", "/x", "d", "I", "{}", "O", "{}" };
    for (fields) |value| w.string(value);
    w.int(u32, 1);
    w.string("");
    w.int(u32, max_scope_field_bytes + 1);
}

const scope_65 = "s" ** (max_scope_field_bytes + 1);
const scope_64 = "s" ** max_scope_field_bytes;
const agent_name_65 = "n" ** (max_name_bytes + 1);
const endpoint_513 = "e" ** (max_endpoint_bytes + 1);

const valid_agent_limits = AgentLimits{
    .rounds = 4,
    .tool_calls = 8,
    .tool_calls_per_round = 4,
    .argument_bytes = 4096,
    .result_bytes = 16384,
    .turn_deadline_ms = 20000,
};
const valid_z_tool = test_support.SampleEntry{ .name = "z", .path = "/z" };

fn sampleAgent(tools: []const []const u8, limits: AgentLimits) test_support.SampleAgent {
    @setRuntimeSafety(true);
    return .{ .tools = tools, .limits = limits };
}

fn sampleAgentEntry(name: []const u8, path: []const u8, tools: []const []const u8, limits: AgentLimits) test_support.SampleEntry {
    @setRuntimeSafety(true);
    return .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = name,
        .path = path,
        .agent = sampleAgent(tools, limits),
    };
}

fn tooManyAgentTools(w: *test_support.Writer) void {
    @setRuntimeSafety(true);
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, 1);
    w.int(u8, @intFromEnum(EntryKind.agent));
    w.string("a");
    w.string("POST");
    w.string("/agent");
    w.string("agent");
    w.int(u32, 4096);
    w.int(u16, 0);
    w.int(u16, max_agent_tools + 1);
}

const e = test_support.sample_entries;

const cases = [_]Case{
    .{ .site = .short_header, .expected = error.Truncated, .custom = shortHeader },
    .{ .site = .integer_body, .expected = error.Truncated, .custom = truncatedInteger },
    .{ .site = .string_body, .expected = error.Truncated, .custom = truncatedString },
    .{ .site = .string_body, .expected = error.Truncated, .custom = sampleTruncated },
    .{ .site = .magic, .expected = error.BadMagic, .custom = badMagic },
    .{ .site = .schema, .expected = error.UnsupportedSchema, .custom = unsupportedSchema },
    .{ .site = .schema, .expected = error.UnsupportedSchema, .custom = schemaTwo },
    .{ .site = .schema, .expected = error.UnsupportedSchema, .custom = schemaThree },
    .{ .site = .entry_kind, .expected = error.EntryKindInvalid, .entries = &.{.{ .kind = 2, .name = "a", .path = "/x" }} },
    .{ .site = .entry_count, .expected = error.EntryCountOutOfRange, .custom = zeroEntries },
    .{ .site = .entry_count, .expected = error.EntryCountOutOfRange, .custom = tooManyEntries },
    .{ .site = .name_length, .expected = error.NameLength, .entries = &.{.{ .name = "", .path = "/x" }} },
    .{ .site = .name_length, .expected = error.NameLength, .custom = nameTooLong },
    .{ .site = .method_characters, .expected = error.MethodInvalid, .entries = &.{.{ .name = "a", .method = "get", .path = "/x" }} },
    .{ .site = .method_length, .expected = error.MethodInvalid, .entries = &.{.{ .name = "a", .method = "", .path = "/x" }} },
    .{ .site = .method_length, .expected = error.MethodInvalid, .entries = &.{.{ .name = "a", .method = "POSTPOSTPOSTPOSTX", .path = "/x" }} },
    .{ .site = .path_prefix, .expected = error.PathInvalid, .entries = &.{.{ .name = "a", .path = "x" }} },
    .{ .site = .path_length, .expected = error.PathInvalid, .entries = &.{.{ .name = "a", .path = "" }} },
    .{ .site = .description_length, .expected = error.DescriptionLength, .entries = &.{.{ .name = "a", .path = "/x", .description = "" }} },
    .{ .site = .description_length, .expected = error.DescriptionLength, .custom = descriptionTooLong },
    .{ .site = .input_name_length, .expected = error.SchemaNameLength, .entries = &.{.{ .name = "a", .path = "/x", .input_name = "" }} },
    .{ .site = .output_name_length, .expected = error.SchemaNameLength, .entries = &.{.{ .name = "a", .path = "/x", .output_name = "" }} },
    .{ .site = .input_schema_length, .expected = error.SchemaLength, .entries = &.{.{ .name = "a", .path = "/x", .input_schema = "" }} },
    .{ .site = .output_schema_length, .expected = error.SchemaLength, .entries = &.{.{ .name = "a", .path = "/x", .output_schema = "" }} },
    .{ .site = .input_schema_length, .expected = error.SchemaLength, .custom = schemaTooLong },
    .{ .site = .max_input_bytes, .expected = error.MaxInputBytesOutOfRange, .entries = &.{.{ .name = "a", .path = "/x", .max_input_bytes = 0 }} },
    .{ .site = .max_input_bytes, .expected = error.MaxInputBytesOutOfRange, .entries = &.{.{ .name = "a", .path = "/x", .max_input_bytes = max_max_input_bytes + 1 }} },
    .{ .site = .tenant_scope_length, .expected = error.ScopeFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .scope_tenant = scope_65 }} },
    .{ .site = .subject_scope_length, .expected = error.ScopeFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .scope_subject = scope_65 }} },
    .{ .site = .subject_scope_length, .expected = error.ScopeFieldLength, .custom = scopeTooLong },
    .{ .site = .export_count, .expected = error.ExportCountOutOfRange, .custom = tooManyExports },
    .{ .site = .export_module_length, .expected = error.ExportFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "", .name = "f" }} }} },
    .{ .site = .export_name_length, .expected = error.ExportFieldLength, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "m", .name = "" }} }} },
    .{ .site = .name_order, .expected = error.NamesNotOrdered, .entries = &.{ e[1], e[0] } },
    .{ .site = .name_order, .expected = error.NamesNotOrdered, .entries = &.{ .{ .name = "a", .path = "/x" }, .{ .name = "a", .path = "/y" } } },
    .{ .site = .duplicate_route, .expected = error.RouteDuplicate, .entries = &.{ .{ .name = "a", .path = "/x" }, .{ .name = "b", .path = "/x" } } },
    .{ .site = .duplicate_route, .expected = error.RouteDuplicate, .entries = &.{ .{ .name = "a", .path = "/x" }, .{ .name = "b", .path = "/y" }, .{ .name = "c", .path = "/x" } } },
    .{ .site = .export_order, .expected = error.ExportsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{ .{ .module = "m", .name = "g" }, .{ .module = "m", .name = "f" } } }} },
    .{ .site = .export_order, .expected = error.ExportsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{ .{ .module = "n", .name = "a" }, .{ .module = "m", .name = "z" } } }} },
    .{ .site = .export_order, .expected = error.ExportsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{ .{ .module = "m", .name = "f" }, .{ .module = "m", .name = "f" } } }} },
    .{ .site = .credential_count, .expected = error.CredentialCountOutOfRange, .custom = tooManyCredentials },
    .{ .site = .credential_name_length, .expected = error.CredentialNameLength, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{""} }} },
    .{ .site = .credential_name_length, .expected = error.CredentialNameLength, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{credential_65} }} },
    .{ .site = .credential_order, .expected = error.CredentialsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{ "weather", "billing" } }} },
    .{ .site = .credential_order, .expected = error.CredentialsNotOrdered, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{ "weather", "weather" } }} },
    .{ .site = .credential_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .credentials = &.{"\xfe"} }} },
    .{ .site = .name_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "\xff", .path = "/x" }} },
    .{ .site = .path_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/\xff" }} },
    .{ .site = .description_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .description = "\xff" }} },
    .{ .site = .input_name_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .input_name = "\xff" }} },
    .{ .site = .input_schema_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .input_schema = "{\"\xc3\"}" }} },
    .{ .site = .output_name_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .output_name = "\xff" }} },
    .{ .site = .output_schema_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .output_schema = "\xff" }} },
    .{ .site = .tenant_scope_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .scope_tenant = "\xff" }} },
    .{ .site = .subject_scope_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .scope_subject = "\xff" }} },
    .{ .site = .export_module_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "\x80", .name = "f" }} }} },
    .{ .site = .export_name_utf8, .expected = error.InvalidUtf8, .entries = &.{.{ .name = "a", .path = "/x", .exports = &.{.{ .module = "m", .name = "\x80" }} }} },
    .{ .site = .trailing_data, .expected = error.TrailingData, .custom = sampleWithTrailingByte },
    .{ .site = .agent_tool_count, .expected = error.AgentToolCountOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{}, valid_agent_limits), valid_z_tool } },
    .{ .site = .agent_tool_count, .expected = error.AgentToolCountOutOfRange, .custom = tooManyAgentTools },
    .{ .site = .agent_tool_name_length, .expected = error.AgentToolNameLength, .entries = &.{ sampleAgentEntry("a", "/agent", &.{""}, valid_agent_limits), valid_z_tool } },
    .{ .site = .agent_tool_name_length, .expected = error.AgentToolNameLength, .entries = &.{ sampleAgentEntry("a", "/agent", &.{agent_name_65}, valid_agent_limits), valid_z_tool } },
    .{ .site = .agent_tool_order, .expected = error.AgentToolsNotOrdered, .entries = &.{
        .{ .name = "a", .path = "/a" },
        .{ .name = "b", .path = "/b" },
        sampleAgentEntry("c", "/agent", &.{ "b", "a" }, valid_agent_limits),
    } },
    .{ .site = .agent_tool_order, .expected = error.AgentToolsNotOrdered, .entries = &.{
        sampleAgentEntry("a", "/agent", &.{ "z", "z" }, valid_agent_limits),
        valid_z_tool,
    } },
    .{ .site = .agent_tool_unknown, .expected = error.AgentToolUnknown, .entries = &.{
        .{ .name = "a", .path = "/a" },
        sampleAgentEntry("b", "/agent", &.{"missing"}, valid_agent_limits),
    } },
    .{ .site = .agent_tool_is_agent, .expected = error.AgentToolIsAgent, .entries = &.{
        sampleAgentEntry("a", "/agent-a", &.{"b"}, valid_agent_limits),
        sampleAgentEntry("b", "/agent-b", &.{"z"}, valid_agent_limits),
        .{ .name = "z", .path = "/z" },
    } },
    .{ .site = .agent_endpoint_length, .expected = error.AgentEndpointLength, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_endpoint = endpoint_513 },
    }, valid_z_tool } },
    .{ .site = .agent_endpoint_length, .expected = error.AgentEndpointLength, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_endpoint = "" },
    }, valid_z_tool } },
    .{ .site = .agent_endpoint_normalization, .expected = error.AgentEndpointNotNormalized, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_endpoint = "HTTPS://API.EXAMPLE.COM" },
    }, valid_z_tool } },
    .{ .site = .agent_endpoint_normalization, .expected = error.AgentEndpointNotNormalized, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_endpoint = "ftp://api.example.com:21" },
    }, valid_z_tool } },
    .{ .site = .agent_endpoint_normalization, .expected = error.AgentEndpointNotNormalized, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_endpoint = "https://api.example.com:00443" },
    }, valid_z_tool } },
    .{ .site = .agent_endpoint_normalization, .expected = error.AgentEndpointNotNormalized, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_endpoint = "https://api.example.com/path" },
    }, valid_z_tool } },
    .{ .site = .agent_credential_name_length, .expected = error.AgentCredentialNameLength, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_credential = credential_65 },
    }, valid_z_tool } },
    .{ .site = .agent_credential_name_length, .expected = error.AgentCredentialNameLength, .entries = &.{ .{
        .kind = @intFromEnum(EntryKind.agent),
        .name = "a",
        .path = "/agent",
        .agent = .{ .tools = &.{"z"}, .provider_credential = "" },
    }, valid_z_tool } },
    .{ .site = .agent_rounds, .expected = error.AgentRoundsOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 0,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_rounds, .expected = error.AgentRoundsOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = max_agent_rounds + 1,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_tool_calls, .expected = error.AgentToolCallsOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 0,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_tool_calls, .expected = error.AgentToolCallsOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = max_agent_tool_calls + 1,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_tool_calls_per_round, .expected = error.AgentToolCallsPerRoundOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 0,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_tool_calls_per_round, .expected = error.AgentToolCallsPerRoundOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = max_agent_tool_calls,
        .tool_calls_per_round = max_agent_tool_calls + 1,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_tool_calls_relation, .expected = error.AgentToolCallsPerRoundExceedsToolCalls, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 9,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_argument_bytes, .expected = error.AgentArgumentBytesOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = max_agent_argument_bytes + 1,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_argument_bytes, .expected = error.AgentArgumentBytesOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 0,
        .result_bytes = 16384,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_result_bytes, .expected = error.AgentResultBytesOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 0,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_result_bytes, .expected = error.AgentResultBytesOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = max_agent_result_bytes + 1,
        .turn_deadline_ms = 20000,
    }), valid_z_tool } },
    .{ .site = .agent_turn_deadline_ms, .expected = error.AgentTurnDeadlineMsOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = 0,
    }), valid_z_tool } },
    .{ .site = .agent_turn_deadline_ms, .expected = error.AgentTurnDeadlineMsOutOfRange, .entries = &.{ sampleAgentEntry("a", "/agent", &.{"z"}, .{
        .rounds = 4,
        .tool_calls = 8,
        .tool_calls_per_round = 4,
        .argument_bytes = 4096,
        .result_bytes = 16384,
        .turn_deadline_ms = max_agent_turn_deadline_ms + 1,
    }), valid_z_tool } },
};

test "every refusal case decodes to its exact error" {
    for (cases, 0..) |case, index| {
        var buf: [2048]u8 = undefined;
        var w = test_support.Writer{ .buf = &buf };
        if (case.custom) |write| {
            write(&w);
        } else {
            test_support.writeCatalog(&w, case.entries);
        }
        const result = decode(w.bytes());
        if (result) |_| {
            std.debug.print("case {d}: expected {s}, decoded\n", .{ index, @errorName(case.expected) });
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != case.expected) {
                std.debug.print("case {d}: expected {s}, got {s}\n", .{ index, @errorName(case.expected), @errorName(err) });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "every decode site and error is driven by a refusal case" {
    const sites = @typeInfo(DecodeSite).@"enum".fields;
    inline for (sites) |site_field| {
        const site: DecodeSite = @enumFromInt(site_field.value);
        var driven = false;
        for (cases) |case| {
            if (case.site == site) driven = true;
        }
        if (!driven) {
            std.debug.print("DecodeSite.{s} has no refusal case\n", .{site_field.name});
            return error.TestUnexpectedResult;
        }
    }

    const members = @typeInfo(DecodeError).error_set.?;
    inline for (members) |member| {
        var driven = false;
        for (cases) |case| {
            if (std.mem.eql(u8, @errorName(case.expected), member.name)) driven = true;
        }
        if (!driven) {
            std.debug.print("DecodeError.{s} has no refusal case\n", .{member.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "a scope field at its bound decodes and carries both bindings" {
    var buf: [1024]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    test_support.writeCatalog(&w, &.{.{ .name = "a", .path = "/x", .scope_tenant = scope_64, .scope_subject = "user_id" }});
    const catalog = try decode(w.bytes());
    var it = catalog.entries();
    const entry = (try it.next()).?;
    try testing.expectEqualStrings(scope_64, entry.scope_tenant orelse return error.TestMissingScope);
    try testing.expectEqualStrings("user_id", entry.scope_subject orelse return error.TestMissingScope);
}

test "a catalog at the entry and export bounds decodes" {
    var buf: [65536]u8 = undefined;
    var w = test_support.Writer{ .buf = &buf };
    w.raw(magic);
    w.int(u16, schema_version);
    w.int(u16, max_entries);
    var index: u16 = 0;
    while (index < max_entries) : (index += 1) {
        const name: [2]u8 = .{ 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) };
        const path: [3]u8 = .{ '/', name[0], name[1] };
        if (index == 0) {
            w.int(u8, @intFromEnum(EntryKind.tool));
            const fields = [_][]const u8{ &name, "POST", &path, "d", "I", "{}", "O", "{}" };
            for (fields) |value| w.string(value);
            w.int(u32, 1);
            w.string("");
            w.string("");
            w.int(u16, max_exports);
            var export_index: u16 = 0;
            while (export_index < max_exports) : (export_index += 1) {
                const export_name: [2]u8 = .{
                    'a' + @as(u8, @intCast(export_index / 26)),
                    'a' + @as(u8, @intCast(export_index % 26)),
                };
                w.string("m");
                w.string(&export_name);
            }
            w.int(u16, 0);
        } else {
            test_support.writeEntry(&w, .{ .name = &name, .path = &path });
        }
    }
    const catalog = try decode(w.bytes());
    try testing.expectEqual(max_entries, catalog.entry_count);
    var entries = catalog.entries();
    const first = (try entries.next()).?;
    var exports = first.exports;
    var export_count: u16 = 0;
    while (try exports.next()) |item| : (export_count += 1) {
        try testing.expectEqualStrings("m", item.module);
        if (export_count == 0) try testing.expectEqualStrings("aa", item.name);
        if (export_count == max_exports - 1) try testing.expectEqualStrings("jv", item.name);
    }
    try testing.expectEqual(max_exports, export_count);
}
