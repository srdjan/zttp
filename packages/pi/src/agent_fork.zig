//! Fork and in-place rebuild of an `AgentSession`, used by `/fork`, `/resume`
//! and `/new`.

const std = @import("std");
const registry_mod = @import("registry/registry.zig");
const provider_selection = @import("providers/selection.zig");
const session_id_mod = @import("session/session_id.zig");
const session_paths = @import("session/paths.zig");
const session_events = @import("session/events.zig");
const agent = @import("agent.zig");
const agent_bootstrap = @import("agent_bootstrap.zig");

const Registry = registry_mod.Registry;
const AgentSession = agent.AgentSession;
const SessionConfig = agent.SessionConfig;
const initFromEnvWithPreparedResume = agent_bootstrap.initFromEnvWithPreparedResume;
const nowUnixMs = agent_bootstrap.nowUnixMs;
const readSessionMeta = agent_bootstrap.readSessionMeta;

/// Branch the current session: create a new session directory, copy the
/// current transcript's persisted events to it, write a meta.json with
/// `parent_id` pointing at the current session, then update the session's
/// on-disk handles to the new location. The in-memory transcript is unchanged.
/// Returns an owned summary message; caller frees.
pub fn fork(
    allocator: std.mem.Allocator,
    session: *AgentSession,
) ![]u8 {
    const old_sid = session.session_id orelse {
        return allocator.dupe(u8, "Session is ephemeral (--no-session); nothing to fork.\n");
    };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    const io = io_backend.io();
    const realpath = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, ".", allocator);
    defer allocator.free(realpath);

    const new_sid = try session_id_mod.generate(allocator);
    errdefer allocator.free(new_sid);
    const new_dir = try session_paths.sessionDir(allocator, new_sid);
    errdefer allocator.free(new_dir);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, new_dir);

    const new_events_path = try std.fs.path.join(allocator, &.{ new_dir, "events.jsonl" });
    errdefer allocator.free(new_events_path);
    const new_meta_path = try std.fs.path.join(allocator, &.{ new_dir, "meta.json" });
    errdefer allocator.free(new_meta_path);
    var next_writer = try session_events.JournalWriter.open(allocator, new_events_path);
    var next_writer_owned = true;
    errdefer if (next_writer_owned) next_writer.deinit();
    try session_paths.writeWorkspacePointer(allocator, new_dir, realpath);

    const old_events_path = session.events_path orelse return error.MissingSessionPath;
    while (session.last_persisted_len < session.transcript.len()) : (session.last_persisted_len += 1) {
        try session.appendPersistedEntry(
            allocator,
            session.transcript.entryIdAt(session.last_persisted_len),
            session.transcript.at(session.last_persisted_len),
        );
    }
    if (session.journal_writer != null) {
        try session_events.copyJournalClaimed(allocator, old_events_path, new_events_path);
    } else {
        try session_events.copyJournal(allocator, old_events_path, new_events_path);
    }
    try next_writer.refresh(allocator, new_events_path);

    const old_meta_path = session.meta_path orelse return error.MissingSessionPath;
    var old_meta = try session_events.readMeta(allocator, old_meta_path);
    defer session_events.freeMeta(allocator, &old_meta);

    try session_events.writeMeta(allocator, new_meta_path, .{
        .session_id = new_sid,
        .workspace_realpath = realpath,
        .created_at_unix_ms = nowUnixMs(),
        .parent_id = old_sid,
        .policy_hash = old_meta.policy_hash,
        .protocol_hash = old_meta.protocol_hash,
        .approval_policy = old_meta.approval_policy,
        .provider = if (session.activeProvider()) |provider| provider.publicName() else null,
        .model = session.currentModel(),
    });

    const result = try allocator.print("Forked to new session: {s}\nParent: {s}\n", .{ new_sid, old_sid });
    errdefer allocator.free(result);
    if (session.journal_writer) |*writer| writer.deinit();
    session.journal_writer = null;

    if (session.session_id) |s| allocator.free(s);
    if (session.session_dir) |s| allocator.free(s);
    if (session.events_path) |s| allocator.free(s);
    if (session.meta_path) |s| allocator.free(s);

    session.session_id = new_sid;
    session.session_dir = new_dir;
    session.events_path = new_events_path;
    session.meta_path = new_meta_path;
    session.journal_writer = next_writer;
    next_writer_owned = false;
    session.last_persisted_len = session.transcript.len();

    return result;
}

/// Tear down `session` and rebuild it in place from the same environment.
/// Used by `/resume` and `/new`.
pub const PreparedResume = struct {
    session_id: []u8,
    meta: session_events.Meta,

    fn deinit(self: *PreparedResume, allocator: std.mem.Allocator) void {
        session_events.freeMeta(allocator, &self.meta);
        allocator.free(self.session_id);
        self.* = undefined;
    }
};

fn prepareLatestResume(allocator: std.mem.Allocator) !?PreparedResume {
    const root = try session_paths.sessionRoot(allocator);
    defer allocator.free(root);
    const hash = try session_paths.cwdHashFull(allocator);
    const entries = try session_paths.listSessions(allocator, root, hash[0..]);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    if (entries.len == 0) return null;

    const session_id = try allocator.dupe(u8, entries[0].session_id);
    errdefer allocator.free(session_id);
    return .{
        .session_id = session_id,
        .meta = try readSessionMeta(allocator, session_id),
    };
}

pub fn rebuildSession(
    allocator: std.mem.Allocator,
    session: *AgentSession,
    registry: *const Registry,
    config: SessionConfig,
) !void {
    var prepared_resume = if (config.resume_latest)
        try prepareLatestResume(allocator)
    else
        null;
    defer if (prepared_resume) |*prepared| prepared.deinit(allocator);
    if (prepared_resume) |*prepared| {
        const target = try provider_selection.resolve(.{
            .launch_provider = config.provider,
            .launch_model = config.model,
            .stored = .{
                .provider = prepared.meta.provider,
                .model = prepared.meta.model,
            },
        });
        if (target.provider != session.activeProvider()) {
            return error.CrossProviderResume;
        }
    }
    const same_session = if (prepared_resume) |*prepared|
        if (session.session_id) |current_id| std.mem.eql(u8, current_id, prepared.session_id) else false
    else
        false;
    var transferred_writer: ?session_events.JournalWriter = null;
    if (same_session) {
        session.writeSessionSummary(allocator);
        const current_writer = if (session.journal_writer) |*writer| writer else return error.MissingJournalWriter;
        if (current_writer.poisoned) {
            const path = session.events_path orelse return error.MissingSessionPath;
            current_writer.refresh(allocator, path) catch return error.SessionLockRecoveryFailed;
        }
        transferred_writer = try current_writer.duplicate();
    }
    var next = initFromEnvWithPreparedResume(
        allocator,
        registry,
        config,
        if (prepared_resume) |*prepared| prepared else null,
        transferred_writer,
    ) catch |err| {
        if (same_session) {
            const path = session.events_path orelse return error.MissingSessionPath;
            const writer = if (session.journal_writer) |*present| present else return error.MissingJournalWriter;
            writer.refresh(allocator, path) catch return error.SessionLockRecoveryFailed;
        }
        return err;
    };
    errdefer next.deinit(allocator);
    if (config.resume_latest and next.activeProvider() != session.activeProvider()) {
        return error.CrossProviderResume;
    }

    // Commit the swap only after the target session and provider constraint are
    // fully validated. A failed resume leaves the current session untouched.
    if (!same_session) session.writeSessionSummary(allocator);
    if (same_session) {
        const current_writer = if (session.journal_writer) |*writer| writer else return error.MissingJournalWriter;
        const next_writer = if (next.journal_writer) |*writer| writer else return error.MissingJournalWriter;
        try session_events.JournalWriter.transferLockOwnership(current_writer, next_writer);
    }
    session.deinit(allocator);
    session.* = next;
}
