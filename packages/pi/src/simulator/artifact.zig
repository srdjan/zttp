//! Fail-closed flow-cassette artifact loading, validation, and hashing.

const std = @import("std");
const TextBuffer = @import("../text_buffer.zig").TextBuffer;
pub const contract = @import("artifact_contract.zig");

pub const schema_version = contract.schema_version;
pub const Limits = contract.Limits;
pub const Sha256Hex = contract.Sha256Hex;
pub const EvidenceClass = contract.EvidenceClass;
pub const Provider = contract.Provider;
pub const ApprovalDecision = contract.ApprovalDecision;
pub const TurnOutcome = contract.TurnOutcome;
pub const EventKind = contract.EventKind;
pub const TranscriptItemKind = contract.TranscriptItemKind;
pub const WorkspaceChangeKind = contract.WorkspaceChangeKind;
pub const CaseDescriptor = contract.CaseDescriptor;
pub const TurnExpectation = contract.TurnExpectation;
pub const DraftExpectation = contract.DraftExpectation;
pub const ResponseFixture = contract.ResponseFixture;
pub const ApprovalExpectation = contract.ApprovalExpectation;
pub const EventExpectation = contract.EventExpectation;
pub const WorkspaceFixture = contract.WorkspaceFixture;
pub const TurnWorkspaceCheckpoint = contract.TurnWorkspaceCheckpoint;
pub const WorkspaceChange = contract.WorkspaceChange;
pub const ArtifactReference = contract.ArtifactReference;
pub const FlowManifest = contract.FlowManifest;
pub const ModelCheckpoint = contract.ModelCheckpoint;
pub const ApprovalCheckpoint = contract.ApprovalCheckpoint;
pub const TranscriptItem = contract.TranscriptItem;
pub const ApplyReceipt = contract.ApplyReceipt;
pub const InteractionTrace = contract.InteractionTrace;
pub const FixtureRole = contract.FixtureRole;
pub const LoadedFixture = contract.LoadedFixture;

pub const FlowCase = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: CaseDescriptor,
    manifest: FlowManifest,
    trace: InteractionTrace,
    fixtures: []const LoadedFixture,
    flow_version: Sha256Hex,

    pub fn deinit(self: *FlowCase) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FailureKind = enum {
    out_of_memory,
    missing_fixture,
    unreadable_fixture,
    truncated_fixture,
    malformed_json,
    unknown_json_field,
    duplicate_json_field,
    missing_json_field,
    unsupported_schema_version,
    unrecognized_variant,
    unsafe_path,
    path_too_long,
    symlink_component,
    unexpected_fixture,
    duplicate_path,
    invalid_index,
    checkpoint_alignment,
    invalid_inventory,
    invalid_digest,
    hash_mismatch,
    file_too_large,
    case_too_large,
    too_many_files,
    too_many_turns,
    too_many_model_checkpoints,
    too_many_approval_checkpoints,
    no_turns,
    no_model_calls,
};

pub const Component = enum {
    case_descriptor,
    manifest,
    trace,
    response,
    initial_workspace,
    turn_workspace,
    expected_workspace,
    fixture_inventory,
    flow_hash,
};

pub const Diagnostic = struct {
    kind: FailureKind,
    component: Component,
    case_name: [Limits.diagnostic_bytes]u8 = [_]u8{0} ** Limits.diagnostic_bytes,
    case_name_len: u16 = 0,
    path: [Limits.diagnostic_bytes]u8 = [_]u8{0} ** Limits.diagnostic_bytes,
    path_len: u16 = 0,
    turn_index: ?u32 = null,
    call_index: ?u32 = null,
    checkpoint_index: ?u32 = null,

    pub fn caseName(self: *const Diagnostic) []const u8 {
        return self.case_name[0..self.case_name_len];
    }

    pub fn fixturePath(self: *const Diagnostic) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const MismatchDetail = struct {
    component: Component,
    turn_index: ?u32 = null,
    call_index: ?u32 = null,
    checkpoint_index: ?u32 = null,
    first_divergent_event: ?u32 = null,
};

pub const ResponseFixtureFailure = enum {
    missing,
    digest_mismatch,
    malformed,
    unreadable,
};

pub const ResponseFixtureMismatch = struct {
    component: Component = .response,
    turn_index: ?u32 = null,
    call_index: ?u32 = null,
    kind: ResponseFixtureFailure,
};

pub const ReplayMismatch = union(enum) {
    invalid_artifact: Diagnostic,
    non_executable_case: MismatchDetail,
    initial_state_mismatch: MismatchDetail,
    model_context_mismatch: MismatchDetail,
    transcript_or_transient_prompt_mismatch: MismatchDetail,
    request_budget_mismatch: MismatchDetail,
    normalized_input_mismatch: MismatchDetail,
    provider_request_mismatch: MismatchDetail,
    response_underflow: MismatchDetail,
    response_overflow: MismatchDetail,
    response_order_mismatch: MismatchDetail,
    response_fixture_mismatch: ResponseFixtureMismatch,
    approval_mismatch: MismatchDetail,
    turn_outcome_mismatch: MismatchDetail,
    workspace_mismatch: MismatchDetail,
    unconsumed_checkpoint: MismatchDetail,
};

pub const LoadState = union(enum) {
    available: FlowCase,
    failure: Diagnostic,

    pub fn deinit(self: *LoadState) void {
        switch (self.*) {
            .available => |*flow_case| flow_case.deinit(),
            .failure => {},
        }
        self.* = undefined;
    }
};

const LoadInternalError = error{InvalidArtifact} || std.mem.Allocator.Error;

const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    diagnostic: *Diagnostic,
    total_bytes: usize = 0,

    fn fail(self: *Loader, kind: FailureKind, component: Component, path: []const u8) LoadInternalError {
        self.diagnostic.kind = kind;
        self.diagnostic.component = component;
        setBounded(&self.diagnostic.path, &self.diagnostic.path_len, path);
        return error.InvalidArtifact;
    }

    fn readFile(
        self: *Loader,
        relative_path: []const u8,
        max_bytes: usize,
        component: Component,
    ) LoadInternalError![]u8 {
        try validateSafePathOrFail(self, relative_path, component);
        try self.checkPathComponents(relative_path, component);

        const file = self.root.openFile(self.io, relative_path, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return self.fail(.missing_fixture, component, relative_path),
            error.SymLinkLoop => return self.fail(.symlink_component, component, relative_path),
            else => return self.fail(.unreadable_fixture, component, relative_path),
        };
        defer file.close(self.io);

        const stat = file.stat(self.io) catch return self.fail(.unreadable_fixture, component, relative_path);
        if (stat.kind != .file) return self.fail(.unreadable_fixture, component, relative_path);
        if (stat.size > max_bytes) return self.fail(.file_too_large, component, relative_path);
        const size: usize = std.math.cast(usize, stat.size) orelse
            return self.fail(.file_too_large, component, relative_path);
        self.total_bytes = std.math.add(usize, self.total_bytes, size) catch
            return self.fail(.case_too_large, component, relative_path);
        if (self.total_bytes > Limits.case_bytes) return self.fail(.case_too_large, component, relative_path);

        const bytes = try self.allocator.alloc(u8, size);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        reader.interface.readSliceAll(bytes) catch |err| switch (err) {
            error.EndOfStream => return self.fail(.truncated_fixture, component, relative_path),
            else => return self.fail(.unreadable_fixture, component, relative_path),
        };
        _ = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return bytes,
            else => return self.fail(.unreadable_fixture, component, relative_path),
        };
        return self.fail(.truncated_fixture, component, relative_path);
    }

    fn checkPathComponents(
        self: *Loader,
        relative_path: []const u8,
        component: Component,
    ) LoadInternalError!void {
        var end: usize = 0;
        while (end < relative_path.len) {
            end = std.mem.findScalarPos(u8, relative_path, end, '/') orelse relative_path.len;
            const prefix = relative_path[0..end];
            const stat = self.root.statFile(self.io, prefix, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return self.fail(.missing_fixture, component, relative_path),
                else => return self.fail(.unreadable_fixture, component, relative_path),
            };
            if (stat.kind == .sym_link) return self.fail(.symlink_component, component, relative_path);
            if (end < relative_path.len and stat.kind != .directory) {
                return self.fail(.unreadable_fixture, component, relative_path);
            }
            end += 1;
        }
    }
};

/// Load and fully validate one active flow-cassette generation.
///
/// The returned union makes failure a first-class fixture state. No missing,
/// unreadable, or malformed file is represented as empty data or a default.
pub fn loadCase(allocator: std.mem.Allocator, case_root_abs: []const u8) LoadState {
    var diagnostic = Diagnostic{ .kind = .unreadable_fixture, .component = .case_descriptor };
    setBounded(
        &diagnostic.case_name,
        &diagnostic.case_name_len,
        std.fs.path.basename(case_root_abs),
    );
    if (!std.fs.path.isAbsolute(case_root_abs)) {
        diagnostic.kind = .unsafe_path;
        return .{ .failure = diagnostic };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();
    var io_backend = std.Io.Threaded.init(arena_allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    validateCaseRoot(arena_allocator, io, case_root_abs) catch |err| {
        diagnostic.kind = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.SymlinkComponent => .symlink_component,
            error.UnsafePath => .unsafe_path,
            else => .unreadable_fixture,
        };
        setBounded(&diagnostic.path, &diagnostic.path_len, case_root_abs);
        arena.deinit();
        return .{ .failure = diagnostic };
    };
    const root = std.Io.Dir.openDirAbsolute(io, case_root_abs, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch {
        arena.deinit();
        return .{ .failure = diagnostic };
    };
    defer root.close(io);

    var loader = Loader{
        .allocator = arena_allocator,
        .io = io,
        .root = root,
        .diagnostic = &diagnostic,
    };
    const loaded = loadCaseImpl(&loader, &arena) catch |err| {
        if (err == error.OutOfMemory) diagnostic.kind = .out_of_memory;
        arena.deinit();
        return .{ .failure = diagnostic };
    };
    return .{ .available = loaded };
}

fn validateCaseRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const normalized = try std.fs.path.resolve(allocator, &.{path});
    if (!std.mem.eql(u8, normalized, path)) return error.UnsafePath;

    var end: usize = 1;
    while (end < path.len) {
        end = std.mem.findScalarPos(u8, path, end, '/') orelse path.len;
        const prefix = path[0..end];
        const stat = std.Io.Dir.cwd().statFile(io, prefix, .{ .follow_symlinks = false }) catch
            return error.UnreadablePath;
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.UnreadablePath;
        end += 1;
    }
}

fn loadCaseImpl(loader: *Loader, arena: *std.heap.ArenaAllocator) LoadInternalError!FlowCase {
    const descriptor_bytes = try loader.readFile("case.json", Limits.manifest_bytes, .case_descriptor);
    const descriptor = try parseStrict(CaseDescriptor, loader, descriptor_bytes, .case_descriptor, "case.json");
    if (descriptor.schema_version != schema_version) {
        return loader.fail(.unsupported_schema_version, .case_descriptor, "case.json");
    }
    if (!validCaseName(descriptor.case_name)) {
        return loader.fail(.unsafe_path, .case_descriptor, "case.json");
    }
    setBounded(&loader.diagnostic.case_name, &loader.diagnostic.case_name_len, descriptor.case_name);

    const generation = try std.fmt.allocPrint(
        loader.allocator,
        "generations/{s}",
        .{descriptor.active_generation.slice()},
    );
    const manifest_path = try std.fmt.allocPrint(loader.allocator, "{s}/manifest.json", .{generation});
    const manifest_bytes = try loader.readFile(manifest_path, Limits.manifest_bytes, .manifest);
    const manifest = try parseStrict(FlowManifest, loader, manifest_bytes, .manifest, manifest_path);
    if (manifest.schema_version != schema_version) {
        return loader.fail(.unsupported_schema_version, .manifest, manifest_path);
    }
    if (!std.mem.eql(u8, descriptor.case_name, manifest.case_name)) {
        return loader.fail(.invalid_inventory, .manifest, manifest_path);
    }
    if (descriptor.evidence_class != manifest.evidence_class or
        descriptor.executable != manifest.executable)
    {
        return loader.fail(.hash_mismatch, .flow_hash, manifest_path);
    }
    if (!descriptor.active_generation.eql(manifest.flow_version)) {
        return loader.fail(.hash_mismatch, .flow_hash, manifest_path);
    }
    try validateManifest(loader, &manifest);

    var fixtures: std.ArrayList(LoadedFixture) = .empty;
    const trace_path = try generationFixturePath(loader.allocator, generation, manifest.trace.path);
    const trace_bytes = try loader.readFile(trace_path, Limits.trace_or_response_bytes, .trace);
    try expectDigest(loader, trace_bytes, manifest.trace.sha256, .trace, manifest.trace.path);
    try fixtures.append(loader.allocator, .{ .role = .trace, .path = manifest.trace.path, .bytes = trace_bytes });
    const trace = try parseStrict(InteractionTrace, loader, trace_bytes, .trace, trace_path);
    if (trace.schema_version != schema_version) {
        return loader.fail(.unsupported_schema_version, .trace, trace_path);
    }
    try validateTrace(loader, &manifest, &trace);

    for (manifest.model_responses) |response| {
        const path = try generationFixturePath(loader.allocator, generation, response.path);
        const bytes = try loader.readFile(path, Limits.trace_or_response_bytes, .response);
        try expectDigest(loader, bytes, response.sha256, .response, response.path);
        try fixtures.append(loader.allocator, .{ .role = .response, .path = response.path, .bytes = bytes });
    }
    for (manifest.initial_workspace) |workspace_file| {
        const fixture_path = try std.fmt.allocPrint(loader.allocator, "initial/{s}", .{workspace_file.path});
        const path = try generationFixturePath(loader.allocator, generation, fixture_path);
        const bytes = try loader.readFile(path, Limits.workspace_file_bytes, .initial_workspace);
        try expectDigest(loader, bytes, workspace_file.sha256, .initial_workspace, fixture_path);
        try fixtures.append(loader.allocator, .{ .role = .initial_workspace, .path = fixture_path, .bytes = bytes });
    }
    for (manifest.turn_workspaces) |checkpoint| {
        for (checkpoint.files) |workspace_file| {
            const fixture_path = try std.fmt.allocPrint(
                loader.allocator,
                "turns/{d}/{s}",
                .{ checkpoint.turn_index, workspace_file.path },
            );
            const path = try generationFixturePath(loader.allocator, generation, fixture_path);
            const bytes = try loader.readFile(path, Limits.workspace_file_bytes, .turn_workspace);
            try expectDigest(loader, bytes, workspace_file.sha256, .turn_workspace, fixture_path);
            try fixtures.append(loader.allocator, .{ .role = .turn_workspace, .path = fixture_path, .bytes = bytes });
        }
    }
    for (manifest.expected_workspace) |workspace_file| {
        const fixture_path = try std.fmt.allocPrint(loader.allocator, "expected/{s}", .{workspace_file.path});
        const path = try generationFixturePath(loader.allocator, generation, fixture_path);
        const bytes = try loader.readFile(path, Limits.workspace_file_bytes, .expected_workspace);
        try expectDigest(loader, bytes, workspace_file.sha256, .expected_workspace, fixture_path);
        try fixtures.append(loader.allocator, .{ .role = .expected_workspace, .path = fixture_path, .bytes = bytes });
    }

    const fixture_slice = try fixtures.toOwnedSlice(loader.allocator);
    try validateFixturePaths(loader, fixture_slice);
    try validateDiscoveredInventory(loader, generation, fixture_slice);

    const computed = computeFlowVersion(loader.allocator, &manifest, fixture_slice) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return loader.fail(.hash_mismatch, .flow_hash, manifest_path),
    };
    if (!computed.eql(manifest.flow_version)) {
        return loader.fail(.hash_mismatch, .flow_hash, manifest_path);
    }

    return .{
        .arena = arena.*,
        .descriptor = descriptor,
        .manifest = manifest,
        .trace = trace,
        .fixtures = fixture_slice,
        .flow_version = computed,
    };
}

fn parseStrict(
    comptime T: type,
    loader: *Loader,
    bytes: []const u8,
    component: Component,
    path: []const u8,
) LoadInternalError!T {
    return std.json.parseFromSliceLeaky(T, loader.allocator, bytes, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.UnknownField => return loader.fail(.unknown_json_field, component, path),
        error.DuplicateField => return loader.fail(.duplicate_json_field, component, path),
        error.MissingField => return loader.fail(.missing_json_field, component, path),
        error.InvalidEnumTag => return loader.fail(.unrecognized_variant, component, path),
        error.OutOfMemory => return error.OutOfMemory,
        else => return loader.fail(.malformed_json, component, path),
    };
}

fn validateManifest(loader: *Loader, manifest: *const FlowManifest) LoadInternalError!void {
    if (manifest.turns.len == 0) return loader.fail(.no_turns, .manifest, "manifest.json");
    if (manifest.turns.len > Limits.turns) return loader.fail(.too_many_turns, .manifest, "manifest.json");
    if (manifest.model_responses.len > Limits.model_checkpoints) {
        return loader.fail(.too_many_model_checkpoints, .manifest, "manifest.json");
    }
    if (manifest.approvals.len > Limits.approval_checkpoints) {
        return loader.fail(.too_many_approval_checkpoints, .manifest, "manifest.json");
    }
    if (manifest.executable and manifest.model_responses.len == 0) {
        return loader.fail(.no_model_calls, .manifest, "manifest.json");
    }
    var file_count = 1 + manifest.model_responses.len + manifest.initial_workspace.len + manifest.expected_workspace.len;
    for (manifest.turn_workspaces) |checkpoint| file_count += checkpoint.files.len;
    if (file_count > Limits.files) return loader.fail(.too_many_files, .manifest, "manifest.json");
    if (manifest.model.len == 0) return loader.fail(.invalid_inventory, .manifest, "manifest.json");
    if (manifest.model_revision) |revision| {
        if (revision.len == 0 or revision.len > Limits.path_bytes) {
            return loader.fail(.invalid_inventory, .manifest, "manifest.json");
        }
    }
    // A local recording must name the stack that produced it, by one of the
    // two routes a stack offers. MLX-LM reports itself in the response
    // `system_fingerprint`; rapid-mlx reports nothing on the wire, so the
    // operator declares the pair. Neither route present means a cassette that
    // cannot say what generated it, which is not a measurement.
    const named_by_fingerprint = manifest.mlx_lm_version != null;
    const named_by_runtime = manifest.runtime_name != null and manifest.runtime_version != null;
    if (manifest.provider == .local and !named_by_fingerprint and !named_by_runtime) {
        return loader.fail(.invalid_inventory, .manifest, "manifest.json");
    }
    if (manifest.mlx_lm_version) |version| {
        if (manifest.provider != .local or version.len == 0 or version.len > 128) {
            return loader.fail(.invalid_inventory, .manifest, "manifest.json");
        }
    }
    // Half a pair is refused rather than ignored: a name with no version reads
    // as provenance while carrying none.
    if ((manifest.runtime_name == null) != (manifest.runtime_version == null)) {
        return loader.fail(.invalid_inventory, .manifest, "manifest.json");
    }
    if (manifest.runtime_name) |name| {
        if (manifest.provider != .local or name.len == 0 or name.len > 128) {
            return loader.fail(.invalid_inventory, .manifest, "manifest.json");
        }
    }
    if (manifest.runtime_version) |version| {
        if (manifest.provider != .local or version.len == 0 or version.len > 128) {
            return loader.fail(.invalid_inventory, .manifest, "manifest.json");
        }
    }

    for (manifest.turns, 0..) |turn, i| {
        if (turn.index != i or turn.user_input.len == 0) {
            loader.diagnostic.turn_index = turn.index;
            return loader.fail(.invalid_index, .manifest, "manifest.json");
        }
        // Current recordings carry the precise pair. Historical recordings
        // may carry the old aggregate field or no metric at all, but mixing
        // formats or carrying half the pair is ambiguous and refused.
        _ = turn.draftExpectation() catch {
            loader.diagnostic.turn_index = turn.index;
            return loader.fail(.invalid_inventory, .manifest, "manifest.json");
        };
    }
    try validateModelIndexes(loader, manifest.model_responses, manifest.turns.len, .manifest);
    try validateApprovalIndexes(loader, manifest.approvals, manifest.turns.len, .manifest);
    try validateEventIndexes(loader, manifest.events, manifest.turns.len);
    try validateSafePathOrFail(loader, manifest.trace.path, .trace);

    for (manifest.model_responses) |response| {
        try validateSafePathOrFail(loader, response.path, .response);
        if (!std.mem.startsWith(u8, response.path, "responses/")) {
            return loader.fail(.unsafe_path, .response, response.path);
        }
    }
    try validateWorkspaceInventory(loader, manifest.initial_workspace, .initial_workspace);
    if (manifest.turn_workspaces.len != manifest.turns.len - 1) {
        return loader.fail(.checkpoint_alignment, .turn_workspace, "manifest.json");
    }
    for (manifest.turn_workspaces, 0..) |checkpoint, index| {
        if (checkpoint.turn_index != index) {
            loader.diagnostic.turn_index = checkpoint.turn_index;
            return loader.fail(.invalid_index, .turn_workspace, "manifest.json");
        }
        try validateWorkspaceInventory(loader, checkpoint.files, .turn_workspace);
    }
    try validateWorkspaceInventory(loader, manifest.expected_workspace, .expected_workspace);
    try validateWorkspaceChanges(loader, manifest);
}

fn validateTrace(
    loader: *Loader,
    manifest: *const FlowManifest,
    trace: *const InteractionTrace,
) LoadInternalError!void {
    if (trace.model_calls.len > Limits.model_checkpoints) {
        return loader.fail(.too_many_model_checkpoints, .trace, manifest.trace.path);
    }
    if (trace.approvals.len > Limits.approval_checkpoints) {
        return loader.fail(.too_many_approval_checkpoints, .trace, manifest.trace.path);
    }
    try validateModelIndexes(loader, trace.model_calls, manifest.turns.len, .trace);
    try validateApprovalIndexes(loader, trace.approvals, manifest.turns.len, .trace);
    try validateSimpleIndexes(loader, trace.transcript_items, manifest.turns.len);
    try validateSimpleIndexes(loader, trace.apply_receipts, manifest.turns.len);

    if (trace.model_calls.len != manifest.model_responses.len or trace.approvals.len != manifest.approvals.len) {
        return loader.fail(.checkpoint_alignment, .trace, manifest.trace.path);
    }
    for (trace.model_calls, manifest.model_responses) |checkpoint, response| {
        if (checkpoint.index != response.index or checkpoint.turn_index != response.turn_index or
            checkpoint.call_index != response.call_index)
        {
            loader.diagnostic.turn_index = checkpoint.turn_index;
            loader.diagnostic.call_index = checkpoint.call_index;
            return loader.fail(.checkpoint_alignment, .trace, manifest.trace.path);
        }
    }
    for (trace.approvals, manifest.approvals) |checkpoint, approval| {
        if (checkpoint.index != approval.index or checkpoint.turn_index != approval.turn_index or
            checkpoint.checkpoint_index != approval.checkpoint_index)
        {
            loader.diagnostic.turn_index = checkpoint.turn_index;
            loader.diagnostic.checkpoint_index = checkpoint.checkpoint_index;
            return loader.fail(.checkpoint_alignment, .trace, manifest.trace.path);
        }
    }
}

fn validateModelIndexes(loader: *Loader, entries: anytype, turn_count: usize, component: Component) LoadInternalError!void {
    var per_turn = [_]u32{0} ** Limits.turns;
    var previous_turn: u32 = 0;
    for (entries, 0..) |entry, i| {
        if (entry.index != i or entry.turn_index >= turn_count or
            (i != 0 and entry.turn_index < previous_turn) or
            entry.call_index != per_turn[entry.turn_index])
        {
            loader.diagnostic.turn_index = entry.turn_index;
            loader.diagnostic.call_index = entry.call_index;
            return loader.fail(.invalid_index, component, "manifest.json");
        }
        per_turn[entry.turn_index] += 1;
        previous_turn = entry.turn_index;
    }
}

fn validateApprovalIndexes(loader: *Loader, entries: anytype, turn_count: usize, component: Component) LoadInternalError!void {
    var per_turn = [_]u32{0} ** Limits.turns;
    var previous_turn: u32 = 0;
    for (entries, 0..) |entry, i| {
        if (entry.index != i or entry.turn_index >= turn_count or
            (i != 0 and entry.turn_index < previous_turn) or
            entry.checkpoint_index != per_turn[entry.turn_index])
        {
            loader.diagnostic.turn_index = entry.turn_index;
            loader.diagnostic.checkpoint_index = entry.checkpoint_index;
            return loader.fail(.invalid_index, component, "manifest.json");
        }
        per_turn[entry.turn_index] += 1;
        previous_turn = entry.turn_index;
    }
}

fn validateEventIndexes(loader: *Loader, entries: []const EventExpectation, turn_count: usize) LoadInternalError!void {
    try validateSimpleIndexes(loader, entries, turn_count);
}

fn validateSimpleIndexes(loader: *Loader, entries: anytype, turn_count: usize) LoadInternalError!void {
    var previous_turn: u32 = 0;
    for (entries, 0..) |entry, i| {
        if (entry.index != i or entry.turn_index >= turn_count or (i != 0 and entry.turn_index < previous_turn)) {
            loader.diagnostic.turn_index = entry.turn_index;
            return loader.fail(.invalid_index, .trace, "trace.json");
        }
        previous_turn = entry.turn_index;
    }
}

fn validateWorkspaceInventory(
    loader: *Loader,
    files: []const WorkspaceFixture,
    component: Component,
) LoadInternalError!void {
    if (files.len > Limits.files) return loader.fail(.too_many_files, component, "manifest.json");
    for (files, 0..) |file, i| {
        try validateSafePathOrFail(loader, file.path, component);
        for (files[0..i]) |prior| {
            if (std.mem.eql(u8, prior.path, file.path)) return loader.fail(.duplicate_path, component, file.path);
        }
    }
}

fn validateWorkspaceChanges(loader: *Loader, manifest: *const FlowManifest) LoadInternalError!void {
    for (manifest.allowed_workspace_changes, 0..) |change, i| {
        try validateSafePathOrFail(loader, change.path, .manifest);
        for (manifest.allowed_workspace_changes[0..i]) |prior| {
            if (std.mem.eql(u8, prior.path, change.path)) return loader.fail(.duplicate_path, .manifest, change.path);
        }
        const initial = findWorkspace(manifest.initial_workspace, change.path);
        const expected = findWorkspace(manifest.expected_workspace, change.path);
        const actual: ?WorkspaceChangeKind = if (initial == null and expected != null)
            .created
        else if (initial != null and expected == null)
            .deleted
        else if (initial != null and expected != null and !initial.?.sha256.eql(expected.?.sha256))
            .changed
        else
            null;
        if (actual == null or actual.? != change.kind) return loader.fail(.invalid_inventory, .manifest, change.path);
    }
    for (manifest.initial_workspace) |initial| {
        const expected = findWorkspace(manifest.expected_workspace, initial.path);
        const actual: ?WorkspaceChangeKind = if (expected == null)
            .deleted
        else if (!initial.sha256.eql(expected.?.sha256))
            .changed
        else
            null;
        if (actual) |kind| if (!hasChange(manifest.allowed_workspace_changes, initial.path, kind)) {
            return loader.fail(.invalid_inventory, .manifest, initial.path);
        };
    }
    for (manifest.expected_workspace) |expected| {
        if (findWorkspace(manifest.initial_workspace, expected.path) == null and
            !hasChange(manifest.allowed_workspace_changes, expected.path, .created))
        {
            return loader.fail(.invalid_inventory, .manifest, expected.path);
        }
    }
}

pub fn findWorkspace(files: []const WorkspaceFixture, path: []const u8) ?*const WorkspaceFixture {
    for (files) |*file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}

fn hasChange(changes: []const WorkspaceChange, path: []const u8, kind: WorkspaceChangeKind) bool {
    for (changes) |change| if (change.kind == kind and std.mem.eql(u8, change.path, path)) return true;
    return false;
}

fn validateFixturePaths(loader: *Loader, fixtures: []const LoadedFixture) LoadInternalError!void {
    for (fixtures, 0..) |fixture, i| {
        try validateSafePathOrFail(loader, fixture.path, componentForRole(fixture.role));
        for (fixtures[0..i]) |prior| {
            if (std.mem.eql(u8, prior.path, fixture.path)) {
                return loader.fail(.duplicate_path, componentForRole(fixture.role), fixture.path);
            }
        }
    }
}

fn validateDiscoveredInventory(
    loader: *Loader,
    generation: []const u8,
    fixtures: []const LoadedFixture,
) LoadInternalError!void {
    try loader.checkPathComponents(generation, .fixture_inventory);
    var dir = loader.root.openDir(loader.io, generation, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return loader.fail(.unreadable_fixture, .fixture_inventory, generation);
    defer dir.close(loader.io);
    var walker = dir.walk(loader.allocator) catch return error.OutOfMemory;
    defer walker.deinit();

    var discovered: usize = 0;
    while (walker.next(loader.io) catch return loader.fail(.unreadable_fixture, .fixture_inventory, generation)) |entry| {
        if (entry.kind == .sym_link) return loader.fail(.symlink_component, .fixture_inventory, entry.path);
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return loader.fail(.unexpected_fixture, .fixture_inventory, entry.path);
        discovered += 1;
        if (discovered > Limits.files + 1) return loader.fail(.too_many_files, .fixture_inventory, entry.path);
        if (std.mem.eql(u8, entry.path, "manifest.json")) continue;
        var found = false;
        for (fixtures) |fixture| {
            if (std.mem.eql(u8, entry.path, fixture.path)) {
                found = true;
                break;
            }
        }
        if (!found) return loader.fail(.unexpected_fixture, .fixture_inventory, entry.path);
    }
    if (discovered != fixtures.len + 1) return loader.fail(.invalid_inventory, .fixture_inventory, generation);
}

fn validateSafePathOrFail(loader: *Loader, path: []const u8, component: Component) LoadInternalError!void {
    if (path.len > Limits.path_bytes) return loader.fail(.path_too_long, component, path);
    if (!isSafeRelativePath(path)) return loader.fail(.unsafe_path, component, path);
}

/// Workspace state the agent's own tools write, which is never case source and
/// never part of what a replay compares: `pi_goal_check` persists witnesses to
/// `.zttp/witnesses/<hash>/`. Both the recorder's capture and the runner's
/// replay comparison consult this one predicate, because a file that one side
/// skips and the other side counts fails every replay of that case.
pub fn isAgentScratch(path: []const u8) bool {
    return std.mem.eql(u8, path, ".zttp") or std.mem.startsWith(u8, path, ".zttp/");
}

test "agent scratch covers the witness tree and nothing beside it" {
    try std.testing.expect(isAgentScratch(".zttp"));
    try std.testing.expect(isAgentScratch(".zttp/witnesses/f0812d0e79287bb9/handler.path"));
    try std.testing.expect(!isAgentScratch("handler.ts"));
    try std.testing.expect(!isAgentScratch("src/.zttp/handler.ts"));
    try std.testing.expect(!isAgentScratch(".zttprc"));
}

pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > Limits.path_bytes) return false;
    if (std.fs.path.isAbsolute(path) or path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
    for (path) |byte| if (byte == 0 or byte == '\\') return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub fn validCaseName(name: []const u8) bool {
    if (name.len == 0 or name.len > Limits.path_bytes) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

fn generationFixturePath(allocator: std.mem.Allocator, generation: []const u8, fixture_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ generation, fixture_path });
}

fn expectDigest(
    loader: *Loader,
    bytes: []const u8,
    expected: Sha256Hex,
    component: Component,
    path: []const u8,
) LoadInternalError!void {
    if (!Sha256Hex.fromBytes(bytes).eql(expected)) return loader.fail(.invalid_digest, component, path);
}

fn componentForRole(role: FixtureRole) Component {
    return switch (role) {
        .trace => .trace,
        .response => .response,
        .initial_workspace => .initial_workspace,
        .turn_workspace => .turn_workspace,
        .expected_workspace => .expected_workspace,
    };
}

fn setBounded(buffer: []u8, len: *u16, value: []const u8) void {
    const count = @min(buffer.len, value.len);
    @memcpy(buffer[0..count], value[0..count]);
    len.* = @intCast(count);
}

pub fn computeFlowVersion(
    allocator: std.mem.Allocator,
    manifest: *const FlowManifest,
    fixtures: []const LoadedFixture,
) !Sha256Hex {
    var canonical = TextBuffer.init(allocator);
    defer canonical.deinit();
    try std.json.Stringify.value(.{
        .schema_version = manifest.schema_version,
        .case_name = manifest.case_name,
        .evidence_class = manifest.evidence_class,
        .executable = manifest.executable,
        .provider = manifest.provider,
        .model = manifest.model,
        .turns = manifest.turns,
        .model_responses = manifest.model_responses,
        .approvals = manifest.approvals,
        .events = manifest.events,
        .allowed_workspace_changes = manifest.allowed_workspace_changes,
        .initial_workspace = manifest.initial_workspace,
        .turn_workspaces = manifest.turn_workspaces,
        .expected_workspace = manifest.expected_workspace,
        .trace = manifest.trace,
    }, .{}, canonical.writer());

    const ordered = try allocator.dupe(LoadedFixture, fixtures);
    defer allocator.free(ordered);
    std.mem.sort(LoadedFixture, ordered, {}, struct {
        fn lessThan(_: void, a: LoadedFixture, b: LoadedFixture) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zttp-flow-cassette-v1\x00");
    hashFramed(&hasher, canonical.written());
    if (manifest.model_revision) |revision| {
        hashFramed(&hasher, "model-revision-v1");
        hashFramed(&hasher, revision);
    }
    if (manifest.mlx_lm_version) |version| {
        hashFramed(&hasher, "mlx-lm-version-v1");
        hashFramed(&hasher, version);
    }
    // Appended after the fields that came before it, and skipped when absent,
    // so every cassette recorded before this field existed keeps its version.
    if (manifest.runtime_name) |name| {
        hashFramed(&hasher, "runtime-name-v1");
        hashFramed(&hasher, name);
    }
    if (manifest.runtime_version) |version| {
        hashFramed(&hasher, "runtime-version-v1");
        hashFramed(&hasher, version);
    }
    for (ordered) |fixture| {
        hashFramed(&hasher, fixture.path);
        hashFramed(&hasher, fixture.bytes);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .bytes = std.fmt.bytesToHex(digest, .lower) };
}

fn hashFramed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .big);
    hasher.update(&length);
    hasher.update(bytes);
}
