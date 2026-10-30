//! Session startup for `AgentSession`: workspace crash recovery, receipt
//! reconciliation, launch identity, backend construction, and resume.

const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const zts = @import("zts");
const transcript_mod = @import("transcript.zig");
const registry_mod = @import("registry/registry.zig");
const local_client = @import("providers/local/client.zig");
const deepseek_client = @import("providers/deepseek/client.zig");
const settings_mod = @import("settings.zig");
const models_registry = @import("providers/models.zig");
const provider_selection = @import("providers/selection.zig");
const expert_persona = @import("expert_persona.zig");
const meta_bootstrap = @import("meta_bootstrap.zig");
const session_id_mod = @import("session/session_id.zig");
const session_paths = @import("session/paths.zig");
const session_events = @import("session/events.zig");
const protocol_identity = @import("session/protocol_identity.zig");
const reconstructor = @import("session/reconstructor.zig");
const project_context = @import("context/project_context.zig");
const change_transaction = @import("change_transaction.zig");
const ui_payload = @import("ui_payload.zig");
const agent = @import("agent.zig");
const agent_fork = @import("agent_fork.zig");

const Registry = registry_mod.Registry;
const Provider = models_registry.Provider;
const AgentSession = agent.AgentSession;
const SessionConfig = agent.SessionConfig;
const PreparedResume = agent_fork.PreparedResume;

fn recoverWorkspaceSourcesBeforeBackend(allocator: std.mem.Allocator) !void {
    var workspace = try change_transaction.RecoveredWorkspace.acquire(allocator, ".");
    defer workspace.deinit();
}

pub fn transactionIdFromEntry(entry: *const transcript_mod.OwnedEntry) ?[]const u8 {
    return switch (entry.*) {
        .verified_change_set => |message| if (message.ui_payload) |payload| switch (payload) {
            .verified_change_set => |receipt| receipt.transaction_id,
            else => null,
        } else null,
        else => null,
    };
}

fn transcriptHasTransaction(session: *const AgentSession, transaction_id: []const u8) bool {
    for (session.transcript.entries.items) |*entry| {
        const present = transactionIdFromEntry(entry) orelse continue;
        if (std.mem.eql(u8, present, transaction_id)) return true;
    }
    return false;
}

fn appendRecoveredReceipt(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    pending: change_transaction.PendingReceipt,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, pending.json, .{}) catch
        return error.InvalidRecoveredChangeSetReceipt;
    defer parsed.deinit();
    var payload = ui_payload.parse(allocator, parsed.value) catch
        return error.InvalidRecoveredChangeSetReceipt;
    var payload_owned = true;
    defer if (payload_owned) payload.deinit(allocator);
    const receipt = switch (payload) {
        .verified_change_set => |value| value,
        else => return error.InvalidRecoveredChangeSetReceipt,
    };
    if (!std.mem.eql(u8, receipt.transaction_id, &pending.transaction_id))
        return error.InvalidRecoveredChangeSetReceipt;
    const summary = try allocator.print("recovered verified change set: {d} source file{s} ({s})", .{
        receipt.changes.len,
        if (receipt.changes.len == 1) "" else "s",
        receipt.transaction_id,
    });
    errdefer allocator.free(summary);
    try session.transcript.entries.append(allocator, .{ .verified_change_set = .{
        .llm_text = summary,
        .ui_payload = payload,
    } });
    payload_owned = false;
}

pub fn persistTranscriptTail(allocator: std.mem.Allocator, session: *AgentSession) !void {
    const entries = session.transcript.entries.items;
    while (session.last_persisted_len < entries.len) {
        try session.appendPersistedEntry(
            allocator,
            session.transcript.entryIdAt(session.last_persisted_len),
            &entries[session.last_persisted_len],
        );
        session.last_persisted_len += 1;
    }
}

/// Recover source state first, then make every committed receipt durable in the
/// current session before acknowledging it in the workspace journal. If the
/// journal append fails, the receipt remains pending and startup retries it.
pub fn reconcileWorkspaceReceipts(
    allocator: std.mem.Allocator,
    session: *AgentSession,
) !void {
    var workspace = try change_transaction.RecoveredWorkspace.acquire(allocator, ".");
    defer workspace.deinit();
    const pending = try workspace.pendingReceipts();
    defer {
        for (pending) |*receipt| receipt.deinit(allocator);
        allocator.free(pending);
    }
    for (pending) |receipt| {
        if (!transcriptHasTransaction(session, &receipt.transaction_id))
            try appendRecoveredReceipt(allocator, session, receipt);
        if (session.events_path != null) try persistTranscriptTail(allocator, session);
        try workspace.markReceipted(&receipt.transaction_id);
    }
}

/// Resolve session identity, construct only that provider's backend, and,
/// unless `config.no_session` is true, materialize the on-disk session
/// directory and event persistence.
///
/// When `config.resume_latest` is set, the newest existing session for
/// this cwd is loaded and the transcript is replaced with a reconstruction
/// of its events log; the first subsequent turn runs in replay mode.
pub fn initFromEnvWithSessionConfig(
    allocator: std.mem.Allocator,
    registry: ?*const Registry,
    config: SessionConfig,
) !AgentSession {
    return initFromEnvWithPreparedResume(allocator, registry, config, null, null);
}

pub fn initFromEnvWithPreparedResume(
    allocator: std.mem.Allocator,
    registry: ?*const Registry,
    config: SessionConfig,
    prepared_resume: ?*const PreparedResume,
    transferred_writer: ?session_events.JournalWriter,
) !AgentSession {
    var writer_lease = transferred_writer;
    defer if (writer_lease) |*writer| writer.deinit();
    std.debug.assert(!(config.resume_latest and config.session_id != null));
    std.debug.assert(!(config.fork_session_id != null and config.resume_latest));
    std.debug.assert(!(config.fork_session_id != null and config.session_id != null));

    // Crash recovery is a workspace precondition, not a provider feature. Run
    // it before credentials, local-model readiness, project context, or session
    // materialization so no model can observe a partially applied change set.
    try recoverWorkspaceSourcesBeforeBackend(allocator);

    // Resolve the source session and read its identity before credential
    // validation, transport readiness, or any session-directory write.
    var resumed = false;
    var resolved_resume_id: ?[]u8 = null;
    defer if (resolved_resume_id) |id| allocator.free(id);
    if (config.resume_latest) {
        if (prepared_resume) |prepared| {
            resumed = true;
            resolved_resume_id = try allocator.dupe(u8, prepared.session_id);
        } else {
            const root = try session_paths.sessionRoot(allocator);
            defer allocator.free(root);
            const hash = try session_paths.cwdHashFull(allocator);
            const entries = try session_paths.listSessions(allocator, root, hash[0..]);
            defer {
                for (entries) |*entry| entry.deinit(allocator);
                allocator.free(entries);
            }
            if (entries.len > 0) {
                resumed = true;
                resolved_resume_id = try allocator.dupe(u8, entries[0].session_id);
            }
        }
    }

    var owned_stored_meta: ?session_events.Meta = null;
    defer if (owned_stored_meta) |*meta| session_events.freeMeta(allocator, meta);
    var stored_meta: ?*const session_events.Meta = null;
    if (resolved_resume_id) |source_id| {
        if (prepared_resume) |prepared| {
            stored_meta = &prepared.meta;
        } else {
            owned_stored_meta = try readSessionMeta(allocator, source_id);
            if (owned_stored_meta) |*meta| stored_meta = meta;
        }
    } else if (config.session_id) |source_id| {
        owned_stored_meta = readSessionMeta(allocator, source_id) catch |err| switch (err) {
            error.FileNotFound => if (try sessionEventsExist(allocator, source_id))
                return error.MissingSessionMetadata
            else
                null,
            else => return err,
        };
        if (owned_stored_meta != null) {
            if (owned_stored_meta) |*meta| stored_meta = meta;
            resumed = true;
            resolved_resume_id = try allocator.dupe(u8, source_id);
        }
    } else if (config.fork_session_id) |source_id| {
        owned_stored_meta = try readSessionMeta(allocator, source_id);
        if (owned_stored_meta) |*meta| stored_meta = meta;
    }

    const current_protocol_hash_bytes = try protocol_identity.current(allocator, registry);
    const current_protocol_hash = current_protocol_hash_bytes[0..];
    const current_policy_hash_bytes = zts.policyHash();
    const current_policy_hash = current_policy_hash_bytes[0..];
    if (stored_meta) |meta| {
        if (!std.mem.eql(u8, meta.protocol_hash, current_protocol_hash) or
            !std.mem.eql(u8, meta.policy_hash, current_policy_hash))
        {
            return error.SessionProtocolMismatch;
        }
    }

    const resolution: ?provider_selection.Resolution = if (config.model_free)
        null
    else
        try provider_selection.resolve(.{
            .launch_provider = config.provider,
            .launch_model = config.model,
            .stored = if (stored_meta) |meta| .{
                .provider = meta.provider,
                .model = meta.model,
            } else null,
        });

    const settings_model = if (resolution) |resolved|
        resolved.model
    else
        models_registry.defaultForProvider(models_registry.default_provider);
    const loaded_settings = switch (try settings_mod.load(allocator, settings_model)) {
        .loaded => |value| value,
        .invalid => |diagnostic_value| {
            var diagnostic = diagnostic_value;
            defer diagnostic.deinit(allocator);
            if (diagnostic.key) |key| {
                std.debug.print(
                    "invalid compaction settings at {s}: {s} ({s})\n",
                    .{ diagnostic.path, key, @tagName(diagnostic.issue) },
                );
            } else {
                std.debug.print(
                    "invalid compaction settings at {s}: {s}\n",
                    .{ diagnostic.path, @tagName(diagnostic.issue) },
                );
            }
            return error.InvalidCompactionSettingsFile;
        },
    };

    // Load project context (AGENTS.md / CLAUDE.md) from cwd upward unless
    // the caller disabled it. Instruction failures propagate: launching with
    // an incomplete project contract would be less safe than refusing.
    const project_ctx: ?[]u8 = if (config.no_context_files)
        null
    else
        try project_context.loadFromCwdWithOptions(allocator, .{
            .per_file_cap = expert_persona.PROJECT_CONTEXT_CAP_BYTES,
            .total_cap = expert_persona.PROJECT_CONTEXT_CAP_BYTES,
        });
    defer if (project_ctx) |p| allocator.free(p);

    var session = blk: {
        if (config.model_free) break :blk AgentSession.initStub();
        // A null registry is the test-only seam for sessions that exercise
        // persistence and context loading without issuing model requests.
        const active_registry = registry orelse break :blk AgentSession.initStub();
        const resolved = resolution orelse return error.NoActiveProvider;
        switch (resolved.provider) {
            .local => {
                const base_url = local_client.effectiveBaseUrl(envVar("ZTTP_MLX_BASE_URL"));
                try local_client.checkReadiness(allocator, base_url, resolved.model.id);
                const system_prompt = try expert_persona.buildSystemPromptWithContext(allocator, project_ctx);
                defer allocator.free(system_prompt);
                const tools_json = try buildLocalToolsJson(allocator, active_registry);
                defer allocator.free(tools_json);
                break :blk try AgentSession.initLocal(allocator, system_prompt, tools_json, base_url);
            },
            .deepseek => {
                const api_key = envVar("DEEPSEEK_API_KEY") orelse return error.MissingDeepSeekCredential;
                const base_url = deepseek_client.effectiveBaseUrl(envVar("DEEPSEEK_BASE_URL"));
                try deepseek_client.validateBaseUrl(base_url);
                const system_prompt = try expert_persona.buildSystemPromptWithContext(allocator, project_ctx);
                defer allocator.free(system_prompt);
                const tools_json = try buildDeepSeekToolsJson(allocator, active_registry);
                defer allocator.free(tools_json);
                break :blk try AgentSession.initDeepSeek(
                    allocator,
                    api_key,
                    system_prompt,
                    tools_json,
                    base_url,
                );
            },
        }
    };
    errdefer session.deinit(allocator);
    session.compaction_enabled = loaded_settings.compaction.enabled;
    session.compaction_settings = loaded_settings.compaction.core();
    switch (session.backend) {
        .stub => {},
        .provider => |*backend| backend.setReserveTokens(loaded_settings.compaction.reserve_tokens),
    }

    if (resolution) |resolved| {
        session.resolved_provider = resolved.provider;
        session.resolved_model = resolved.model;
        session.identity_override_disclosed = resolved.provider_overridden or resolved.model_overridden;
    }

    // Apply a --model launch override once, here, so every caller
    // (interactive REPL, autoloop, --print) inherits it without each
    // having to remember a separate apply step. Also covers no_session sessions.
    if (resolution) |resolved| {
        switch (session.backend) {
            .stub => {},
            .provider => try session.setModel(allocator, resolved.model.id),
        }
    }

    const bootstrap_note: ?[]u8 = switch (session.backend) {
        .stub => null,
        .provider => try meta_bootstrap.buildFromCwd(allocator),
    };
    defer if (bootstrap_note) |note| allocator.free(note);

    if (config.no_session) {
        if (bootstrap_note) |note| {
            try ensureCurrentMetaBootstrap(allocator, &session, note, false);
        }
        try reconcileWorkspaceReceipts(allocator, &session);
        return session;
    }

    session.persist_opts = .{ .no_persist_tool_output = config.no_persist_tool_output };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    const realpath = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", allocator);
    defer allocator.free(realpath);

    const sid: []u8 = pick: {
        if (config.session_id) |id| break :pick try allocator.dupe(u8, id);
        if (resolved_resume_id) |id| break :pick try allocator.dupe(u8, id);
        break :pick try session_id_mod.generate(allocator);
    };
    session.session_id = sid;

    const dir = try session_paths.sessionDir(allocator, sid);
    session.session_dir = dir;
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, dir);
    session.events_path = try std.fs.path.join(allocator, &.{ dir, "events.jsonl" });
    session.meta_path = try std.fs.path.join(allocator, &.{ dir, "meta.json" });
    const events_path = session.events_path orelse return error.MissingSessionPath;
    const meta_path = session.meta_path orelse return error.MissingSessionPath;
    // Claim the journal before publishing any session files. This prevents two
    // first launches with the same explicit ID from both creating or
    // truncating the journal.
    if (writer_lease) |writer| {
        session.journal_writer = writer;
        writer_lease = null;
    } else if (resumed) {
        session.journal_writer = try session_events.JournalWriter.openExisting(allocator, events_path);
    } else {
        session.journal_writer = try session_events.JournalWriter.open(allocator, events_path);
    }
    try session_paths.writeWorkspacePointer(allocator, dir, realpath);

    const current_hash = current_policy_hash;
    const persisted_provider = if (resolution) |resolved|
        resolved.provider.publicName()
    else if (stored_meta) |meta|
        meta.provider
    else
        null;
    const persisted_model = if (resolution) |resolved|
        resolved.model.id
    else if (stored_meta) |meta|
        meta.model
    else
        null;

    if (resumed) {
        var tr = try reconstructor.reconstructTranscript(allocator, events_path, null);
        session.transcript.deinit(allocator);
        session.transcript = tr;
        session.checkpoint_generation = @intFromBool(tr.projection != null);
        session.last_persisted_len = tr.len();
        session.replay_next_turn = true;

        const resume_meta = stored_meta orelse return error.MissingSessionMetadata;
        restoreStoredApprovalPolicy(&session, resume_meta);
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = resume_meta.session_id,
            .workspace_realpath = resume_meta.workspace_realpath,
            .created_at_unix_ms = resume_meta.created_at_unix_ms,
            .parent_id = resume_meta.parent_id,
            .policy_hash = current_hash,
            .protocol_hash = current_protocol_hash,
            .approval_policy = resume_meta.approval_policy,
            .provider = persisted_provider,
            .model = persisted_model,
        });
        if (bootstrap_note) |note| {
            try ensureCurrentMetaBootstrap(allocator, &session, note, true);
        }
    } else if (config.fork_session_id) |fork_id| {
        const src_dir = try session_paths.sessionDir(allocator, fork_id);
        defer allocator.free(src_dir);
        const src_events = try std.fs.path.join(allocator, &.{ src_dir, "events.jsonl" });
        defer allocator.free(src_events);
        try session_events.copyJournal(allocator, src_events, events_path);
        const destination_writer = if (session.journal_writer) |*writer| writer else return error.MissingJournalWriter;
        try destination_writer.refresh(allocator, events_path);
        const tr = try reconstructor.reconstructTranscript(allocator, events_path, null);
        session.transcript.deinit(allocator);
        session.transcript = tr;
        session.checkpoint_generation = @intFromBool(tr.projection != null);
        session.last_persisted_len = session.transcript.len();
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = sid,
            .workspace_realpath = realpath,
            .created_at_unix_ms = nowUnixMs(),
            .parent_id = fork_id,
            .policy_hash = current_hash,
            .protocol_hash = current_protocol_hash,
            .approval_policy = config.approval_policy_tag,
            .provider = persisted_provider,
            .model = persisted_model,
        });
        if (bootstrap_note) |note| {
            try ensureCurrentMetaBootstrap(allocator, &session, note, true);
        }
    } else {
        try session_events.writeMeta(allocator, meta_path, .{
            .session_id = sid,
            .workspace_realpath = realpath,
            .created_at_unix_ms = nowUnixMs(),
            .policy_hash = current_hash,
            .protocol_hash = current_protocol_hash,
            .approval_policy = config.approval_policy_tag,
            .provider = persisted_provider,
            .model = persisted_model,
        });
        if (bootstrap_note) |note| {
            try ensureCurrentMetaBootstrap(allocator, &session, note, true);
        }
    }

    try reconcileWorkspaceReceipts(allocator, &session);
    return session;
}

fn ensureCurrentMetaBootstrap(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    note: []const u8,
    persist: bool,
) !void {
    for (session.transcript.entries.items) |entry| {
        switch (entry) {
            .system_note => |body| {
                if (std.mem.eql(u8, body, note)) return;
            },
            else => {},
        }
    }

    try session.transcript.append(allocator, .{ .system_note = note });
    if (!persist) return;
    const index = session.transcript.len() - 1;
    try session.appendPersistedEntry(
        allocator,
        session.transcript.entryIdAt(index),
        session.transcript.at(index),
    );
    session.last_persisted_len = session.transcript.len();
}

pub fn readSessionMeta(allocator: std.mem.Allocator, session_id: []const u8) !session_events.Meta {
    const source_dir = try session_paths.sessionDir(allocator, session_id);
    defer allocator.free(source_dir);
    const source_meta_path = try std.fs.path.join(allocator, &.{ source_dir, "meta.json" });
    defer allocator.free(source_meta_path);
    return try session_events.readMeta(allocator, source_meta_path);
}

fn sessionEventsExist(allocator: std.mem.Allocator, session_id: []const u8) !bool {
    const source_dir = try session_paths.sessionDir(allocator, session_id);
    defer allocator.free(source_dir);
    const events_path = try std.fs.path.join(allocator, &.{ source_dir, "events.jsonl" });
    defer allocator.free(events_path);
    return zts.file_io.fileExists(allocator, events_path);
}

fn restoreStoredApprovalPolicy(
    session: *AgentSession,
    meta: *const session_events.Meta,
) void {
    // Restore the stored approval policy (if any) so --resume inherits it.
    // The policy tag string is parsed back to the enum; unknown tags are
    // silently ignored so old sessions without the field do not break.
    if (meta.approval_policy) |tag| {
        if (std.mem.eql(u8, tag, "auto_approve")) {
            session.stored_approval_policy = .auto_approve;
        } else if (std.mem.eql(u8, tag, "auto_reject")) {
            session.stored_approval_policy = .auto_reject;
        } else if (std.mem.eql(u8, tag, "ask")) {
            session.stored_approval_policy = .ask;
        }
    }
}

pub fn restampSessionIdentity(
    allocator: std.mem.Allocator,
    session: *const AgentSession,
    provider: Provider,
    model: []const u8,
) !void {
    const meta_path = session.meta_path orelse return;
    var meta = try session_events.readMeta(allocator, meta_path);
    defer session_events.freeMeta(allocator, &meta);
    try session_events.writeMeta(allocator, meta_path, .{
        .session_id = meta.session_id,
        .workspace_realpath = meta.workspace_realpath,
        .created_at_unix_ms = meta.created_at_unix_ms,
        .parent_id = meta.parent_id,
        .policy_hash = meta.policy_hash,
        .protocol_hash = meta.protocol_hash,
        .approval_policy = meta.approval_policy,
        .provider = provider.publicName(),
        .model = model,
    });
}

fn envVar(name_z: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name_z) orelse return null;
    const value = std.mem.sliceTo(raw, 0);
    // Treat a set-but-blank variable as absent. An empty or whitespace-only
    // API key is never a legitimate credential, so callers (the `expert`
    // fail-fast and `initFromEnvWithSessionConfig`) should both fall through
    // to the missing-backend path rather than build a client that 401s on
    // first request. Trimming is also how a .env loader's accidental
    // padding (e.g. `KEY = "..."`) would otherwise sneak through.
    const trimmed = std.mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn nowUnixMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(@fromBackingInt(@intCast(@backingInt(std.posix.CLOCK.REALTIME))), &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn buildLocalToolsJson(allocator: std.mem.Allocator, registry: *const Registry) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try local_client.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}

fn buildDeepSeekToolsJson(allocator: std.mem.Allocator, registry: *const Registry) ![]u8 {
    var buf = TextBuffer.init(allocator);
    defer buf.deinit();
    try deepseek_client.writeToolsArray(buf.writer(), registry);
    return try buf.toOwnedSlice();
}
