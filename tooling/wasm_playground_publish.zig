//! Publish the analyzer WASM to the official website under an immutable name.

const std = @import("std");

const max_text_bytes = 8 * 1024 * 1024;
const max_wasm_bytes = 256 * 1024 * 1024;
const wasm_prefix = "zts-analyzer.";
const wasm_suffix = ".wasm";
const wasm_url_prefix = "const WASM_URL = \"";
const cache_prefix = "src=\"/playground.js?v=";

const Phase = enum {
    journal_written,
    new_wasm_created,
    playground_written,
    index_written,
    old_wasm_deleted,
    final_validation,
};

const Hooks = struct {
    context: ?*anyopaque = null,
    after: *const fn (?*anyopaque, Phase) anyerror!void = noOpHook,
};

const Destination = struct {
    root: [:0]u8,
    static: [:0]u8,
    playground_path: []u8,
    playground: []u8,
    index_path: []u8,
    index: []u8,
    cache_version: u64,
    wasm_path: []u8,
    wasm_name: []const u8,
    wasm_content: []u8,

    fn deinit(self: *Destination, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.static);
        allocator.free(self.playground_path);
        allocator.free(self.playground);
        allocator.free(self.index_path);
        allocator.free(self.index);
        allocator.free(self.wasm_path);
        allocator.free(self.wasm_name);
        allocator.free(self.wasm_content);
        self.* = undefined;
    }
};

const Result = struct {
    changed: bool,
    wasm_name: []u8,
    byte_count: usize,

    fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.wasm_name);
        self.* = undefined;
    }
};

const Options = struct {
    website_root: []const u8,
    wasm: []const u8,
};

const Journal = struct {
    schema_version: u32 = 1,
    old_name: []const u8,
    new_name: []const u8,
    old_cache_version: u64,
    new_cache_version: u64,
};

const PublisherLock = struct {
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    path: []u8,

    fn deinit(self: *PublisherLock) void {
        _ = std.c.flock(self.fd, std.posix.LOCK.UN);
        std.Io.Threaded.closeFd(self.fd);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

const WebsiteRoot = struct {
    root: [:0]u8,
    static: [:0]u8,

    fn deinit(self: *WebsiteRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.static);
        self.* = undefined;
    }
};

const usage =
    \\Usage: zig build wasm-playground-publish -- --website-root DIR
    \\
    \\The build supplies the freshly built analyzer through --wasm FILE.
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();
    const argv = try collectArgs(allocator, init.args);
    defer freeArgs(allocator, argv);
    const options = parseArgs(argv[1..]) catch |err| {
        std.debug.print("error: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(1);
    };

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer io_backend.deinit();
    var result = publishWasm(allocator, io_backend.io(), options.website_root, options.wasm, .{}) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer result.deinit(allocator);
    std.debug.print(
        "{s} {s} ({d} bytes raw)\n",
        .{ if (result.changed) "Published" else "Already current", result.wasm_name, result.byte_count },
    );
}

fn parseArgs(args: []const []const u8) !Options {
    var root: ?[]const u8 = null;
    var wasm: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        i += 1;
        if (i >= args.len) return error.InvalidArgument;
        if (std.mem.eql(u8, flag, "--website-root")) {
            root = args[i];
        } else if (std.mem.eql(u8, flag, "--wasm")) {
            wasm = args[i];
        } else {
            return error.InvalidArgument;
        }
    }
    return .{
        .website_root = root orelse return error.InvalidArgument,
        .wasm = wasm orelse return error.InvalidArgument,
    };
}

fn collectArgs(allocator: std.mem.Allocator, vector: std.process.Args) ![]const []const u8 {
    var iterator = std.process.Args.Iterator.init(vector);
    defer iterator.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    errdefer freeArgs(allocator, args.items);
    while (iterator.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn noOpHook(_: ?*anyopaque, _: Phase) !void {}

fn publishWasm(
    allocator: std.mem.Allocator,
    io: std.Io,
    website_root: []const u8,
    wasm_source: []const u8,
    hooks: Hooks,
) !Result {
    const root = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, website_root, allocator);
    defer allocator.free(root);
    var publisher_lock = try acquirePublisherLock(allocator, root);
    defer publisher_lock.deinit();
    try recoverInterruptedPublication(allocator, io, root);

    var destination = try validateDestination(allocator, io, website_root);
    defer destination.deinit(allocator);

    const source_real = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, wasm_source, allocator);
    defer allocator.free(source_real);
    const source_content = try readFile(allocator, io, source_real, max_wasm_bytes);
    defer allocator.free(source_content);
    if (source_content.len < 4 or !std.mem.eql(u8, source_content[0..4], "\x00asm")) {
        return error.InvalidWasmHeader;
    }

    const new_name = try allocWasmName(allocator, source_content);
    errdefer allocator.free(new_name);
    if (std.mem.eql(u8, new_name, destination.wasm_name)) {
        if (!std.mem.eql(u8, source_content, destination.wasm_content)) return error.HashPrefixCollision;
        return .{ .changed = false, .wasm_name = new_name, .byte_count = source_content.len };
    }

    const new_path = try std.fs.path.join(allocator, &.{ destination.static, new_name });
    defer allocator.free(new_path);
    const patched_playground = try replaceWasmReference(
        allocator,
        destination.playground,
        destination.wasm_name,
        new_name,
    );
    defer allocator.free(patched_playground);
    const next_cache_version = std.math.add(u64, destination.cache_version, 1) catch return error.CacheVersionOverflow;
    const patched_index = try replaceCacheVersion(
        allocator,
        destination.index,
        destination.cache_version,
        next_cache_version,
    );
    defer allocator.free(patched_index);
    const journal: Journal = .{
        .old_name = destination.wasm_name,
        .new_name = new_name,
        .old_cache_version = destination.cache_version,
        .new_cache_version = next_cache_version,
    };
    const journal_path = try publicationJournalPath(allocator, destination.root);
    defer allocator.free(journal_path);
    const journal_bytes = try renderJournal(allocator, journal);
    defer allocator.free(journal_bytes);

    var mutations: MutationState = .{};
    publishMutations(
        allocator,
        io,
        &destination,
        new_path,
        source_content,
        patched_playground,
        patched_index,
        journal_path,
        journal_bytes,
        hooks,
        &mutations,
    ) catch |publish_error| {
        rollback(io, &destination, new_path, journal_path, mutations) catch return error.RollbackFailed;
        return publish_error;
    };

    return .{ .changed = true, .wasm_name = new_name, .byte_count = source_content.len };
}

const MutationState = struct {
    journal_created: bool = false,
    new_created: bool = false,
    playground_changed: bool = false,
    index_changed: bool = false,
    old_deleted: bool = false,
};

fn publishMutations(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination: *Destination,
    new_path: []const u8,
    source_content: []const u8,
    patched_playground: []const u8,
    patched_index: []const u8,
    journal_path: []const u8,
    journal_bytes: []const u8,
    hooks: Hooks,
    mutations: *MutationState,
) !void {
    try atomicWrite(io, journal_path, journal_bytes, false);
    mutations.journal_created = true;
    try syncDirectory(io, destination.root);
    try hooks.after(hooks.context, .journal_written);

    mutations.new_created = try ensureArtifact(allocator, io, new_path, source_content);
    if (mutations.new_created) try syncDirectory(io, destination.static);
    try hooks.after(hooks.context, .new_wasm_created);

    try atomicWrite(io, destination.playground_path, patched_playground, true);
    mutations.playground_changed = true;
    try syncDirectory(io, destination.static);
    try hooks.after(hooks.context, .playground_written);

    try atomicWrite(io, destination.index_path, patched_index, true);
    mutations.index_changed = true;
    try syncDirectory(io, destination.static);
    try hooks.after(hooks.context, .index_written);

    try std.Io.Dir.cwd().deleteFile(io, destination.wasm_path);
    mutations.old_deleted = true;
    try syncDirectory(io, destination.static);
    try hooks.after(hooks.context, .old_wasm_deleted);

    var final = try validateDestination(allocator, io, destination.root);
    defer final.deinit(allocator);
    if (!std.mem.eql(u8, final.wasm_name, std.fs.path.basename(new_path))) {
        return error.FinalValidationFailed;
    }
    if (final.cache_version != destination.cache_version + 1) return error.FinalValidationFailed;
    try hooks.after(hooks.context, .final_validation);
    try std.Io.Dir.cwd().deleteFile(io, journal_path);
    mutations.journal_created = false;
    try syncDirectory(io, destination.root);
}

fn rollback(
    io: std.Io,
    destination: *const Destination,
    new_path: []const u8,
    journal_path: []const u8,
    mutations: MutationState,
) !void {
    if (mutations.index_changed) try atomicWrite(io, destination.index_path, destination.index, true);
    if (mutations.playground_changed) try atomicWrite(io, destination.playground_path, destination.playground, true);
    if (mutations.old_deleted) try atomicWrite(io, destination.wasm_path, destination.wasm_content, false);
    if (mutations.new_created) try std.Io.Dir.cwd().deleteFile(io, new_path);
    if (mutations.journal_created) try std.Io.Dir.cwd().deleteFile(io, journal_path);
    try syncDirectory(io, destination.static);
    try syncDirectory(io, destination.root);
}

fn atomicWrite(io: std.Io, path: []const u8, content: []const u8, replace: bool) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
        .replace = replace,
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, content);
    try atomic_file.file.sync(io);
    if (replace) {
        try atomic_file.replace(io);
    } else {
        try atomic_file.link(io);
    }
}

fn ensureArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
) !bool {
    const existing = readFile(allocator, io, path, max_wasm_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try atomicWrite(io, path, content, false);
            return true;
        },
        else => return err,
    };
    defer allocator.free(existing);
    if (!std.mem.eql(u8, existing, content)) return error.HashPrefixCollision;
    return false;
}

fn acquirePublisherLock(allocator: std.mem.Allocator, root: []const u8) !PublisherLock {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/zttp-wasm-publish-{s}.lock",
        .{hex},
    );
    errdefer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o600,
    );
    errdefer std.Io.Threaded.closeFd(fd);
    while (true) switch (std.posix.errno(std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => break,
        .INTR => continue,
        .AGAIN => return error.PublisherAlreadyActive,
        else => return error.PublisherLockFailed,
    };
    return .{ .allocator = allocator, .fd = fd, .path = path };
}

fn syncDirectory(io: std.Io, path: []const u8) !void {
    var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer directory.close(io);
    if (std.c.fsync(directory.handle) != 0) return error.DirectorySyncFailed;
}

fn publicationJournalPath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, ".zttp-wasm-publish.json" });
}

fn renderJournal(allocator: std.mem.Allocator, journal: Journal) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var json: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(journal);
    try aw.writer.writeByte('\n');
    return allocator.dupe(u8, aw.writer.buffered());
}

fn recoverInterruptedPublication(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const journal_path = try publicationJournalPath(allocator, root);
    defer allocator.free(journal_path);
    const journal_bytes = readFile(allocator, io, journal_path, max_text_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(journal_bytes);
    var parsed = std.json.parseFromSlice(Journal, allocator, journal_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidPublicationJournal;
    defer parsed.deinit();
    const journal = parsed.value;
    const expected_cache_version = std.math.add(u64, journal.old_cache_version, 1) catch return error.InvalidPublicationJournal;
    if (journal.schema_version != 1 or
        !validWasmName(journal.old_name) or
        !validWasmName(journal.new_name) or
        std.mem.eql(u8, journal.old_name, journal.new_name) or
        journal.new_cache_version != expected_cache_version)
    {
        return error.InvalidPublicationJournal;
    }

    var website = try resolveWebsiteRoot(allocator, io, root);
    defer website.deinit(allocator);
    const old_path = try std.fs.path.join(allocator, &.{ website.static, journal.old_name });
    defer allocator.free(old_path);
    const old_exists = try artifactMatches(allocator, io, old_path, journal.old_name);
    const new_path = try std.fs.path.join(allocator, &.{ website.static, journal.new_name });
    defer allocator.free(new_path);
    const new_exists = try artifactMatches(allocator, io, new_path, journal.new_name);
    if (!old_exists and !new_exists) return error.InvalidPublicationJournal;
    const target_name = if (new_exists) journal.new_name else journal.old_name;
    const target_cache = if (new_exists) journal.new_cache_version else journal.old_cache_version;

    const playground_path = try std.fs.path.join(allocator, &.{ website.static, "playground.js" });
    defer allocator.free(playground_path);
    const playground = try readFile(allocator, io, playground_path, max_text_bytes);
    defer allocator.free(playground);
    const current_name = try parseWasmReference(playground);
    if (!std.mem.eql(u8, current_name, journal.old_name) and !std.mem.eql(u8, current_name, journal.new_name)) {
        return error.InvalidPublicationJournal;
    }
    if (!std.mem.eql(u8, current_name, target_name)) {
        const patched = try replaceWasmReference(allocator, playground, current_name, target_name);
        defer allocator.free(patched);
        try atomicWrite(io, playground_path, patched, true);
        try syncDirectory(io, website.static);
    }

    const index_path = try std.fs.path.join(allocator, &.{ website.static, "index.html" });
    defer allocator.free(index_path);
    const index = try readFile(allocator, io, index_path, max_text_bytes);
    defer allocator.free(index);
    const current_cache = try parseCacheVersion(index);
    if (current_cache != journal.old_cache_version and current_cache != journal.new_cache_version) {
        return error.InvalidPublicationJournal;
    }
    if (current_cache != target_cache) {
        const patched = try replaceCacheVersion(allocator, index, current_cache, target_cache);
        defer allocator.free(patched);
        try atomicWrite(io, index_path, patched, true);
        try syncDirectory(io, website.static);
    }

    if (new_exists and old_exists) {
        try std.Io.Dir.cwd().deleteFile(io, old_path);
        try syncDirectory(io, website.static);
    }

    var recovered = try validateDestination(allocator, io, root);
    defer recovered.deinit(allocator);
    if (!std.mem.eql(u8, recovered.wasm_name, target_name) or recovered.cache_version != target_cache) {
        return error.InvalidPublicationJournal;
    }
    try std.Io.Dir.cwd().deleteFile(io, journal_path);
    try syncDirectory(io, root);
}

fn artifactMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    expected_name: []const u8,
) !bool {
    const content = readFile(allocator, io, path, max_wasm_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(content);
    const actual_name = try allocWasmName(allocator, content);
    defer allocator.free(actual_name);
    if (!std.mem.eql(u8, actual_name, expected_name)) return error.InvalidPublicationJournal;
    return true;
}

fn resolveWebsiteRoot(allocator: std.mem.Allocator, io: std.Io, website_root: []const u8) !WebsiteRoot {
    const root = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, website_root, allocator);
    errdefer allocator.free(root);
    const deno_path = try std.fs.path.join(allocator, &.{ root, "deno.json" });
    defer allocator.free(deno_path);
    const deno_bytes = try readFile(allocator, io, deno_path, max_text_bytes);
    defer allocator.free(deno_bytes);
    var metadata = std.json.parseFromSlice(std.json.Value, allocator, deno_bytes, .{}) catch return error.InvalidWebsiteMetadata;
    defer metadata.deinit();
    if (metadata.value != .object) return error.InvalidWebsiteMetadata;
    const name = metadata.value.object.get("name") orelse return error.InvalidWebsiteDestination;
    if (name != .string or !std.mem.eql(u8, name.string, "@srdjan/zttp-website")) {
        return error.InvalidWebsiteDestination;
    }
    const static_path = try std.fs.path.join(allocator, &.{ root, "static" });
    defer allocator.free(static_path);
    const static = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, static_path, allocator);
    errdefer allocator.free(static);
    if (!std.mem.eql(u8, std.fs.path.dirname(static) orelse "", root)) {
        return error.StaticOutsideWebsiteRoot;
    }
    return .{ .root = root, .static = static };
}

fn validateDestination(allocator: std.mem.Allocator, io: std.Io, website_root: []const u8) !Destination {
    var website = try resolveWebsiteRoot(allocator, io, website_root);
    errdefer website.deinit(allocator);

    const playground_path = try std.fs.path.join(allocator, &.{ website.static, "playground.js" });
    errdefer allocator.free(playground_path);
    const playground = try readFile(allocator, io, playground_path, max_text_bytes);
    errdefer allocator.free(playground);
    const index_path = try std.fs.path.join(allocator, &.{ website.static, "index.html" });
    errdefer allocator.free(index_path);
    const index = try readFile(allocator, io, index_path, max_text_bytes);
    errdefer allocator.free(index);
    const referenced_name = try parseWasmReference(playground);

    var static_dir = try std.Io.Dir.openDirAbsolute(io, website.static, .{ .iterate = true });
    defer static_dir.close(io);
    var iterator = static_dir.iterate();
    var wasm_count: usize = 0;
    var wasm_name: ?[]u8 = null;
    errdefer if (wasm_name) |name_value| allocator.free(name_value);
    var wasm_path: ?[]u8 = null;
    errdefer if (wasm_path) |path_value| allocator.free(path_value);
    var wasm_content: ?[]u8 = null;
    errdefer if (wasm_content) |content_value| allocator.free(content_value);
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, wasm_suffix)) continue;
        wasm_count += 1;
        if (wasm_count > 1) return error.MultipleWasmArtifacts;
        if (entry.kind != .file) return error.InvalidWasmArtifact;
        if (!validWasmName(entry.name)) return error.InvalidWasmName;
        const artifact_path = try std.fs.path.join(allocator, &.{ website.static, entry.name });
        var artifact_owned = true;
        defer if (artifact_owned) allocator.free(artifact_path);
        const artifact_content = try readFile(allocator, io, artifact_path, max_wasm_bytes);
        var content_owned = true;
        defer if (content_owned) allocator.free(artifact_content);
        const expected_name = try allocWasmName(allocator, artifact_content);
        defer allocator.free(expected_name);
        if (!std.mem.eql(u8, expected_name, entry.name)) return error.WasmHashMismatch;
        if (std.mem.eql(u8, entry.name, referenced_name)) {
            if (wasm_name != null) return error.DuplicateReferencedArtifact;
            wasm_name = try allocator.dupe(u8, entry.name);
            wasm_path = artifact_path;
            artifact_owned = false;
            wasm_content = artifact_content;
            content_owned = false;
        }
    }
    const owned_wasm_name = wasm_name orelse return error.WasmReferenceMissing;
    const cache_version = try parseCacheVersion(index);

    return .{
        .root = website.root,
        .static = website.static,
        .playground_path = playground_path,
        .playground = playground,
        .index_path = index_path,
        .index = index,
        .cache_version = cache_version,
        .wasm_path = wasm_path.?,
        .wasm_name = owned_wasm_name,
        .wasm_content = wasm_content.?,
    };
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_bytes),
    );
}

fn validWasmName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, wasm_prefix) or !std.mem.endsWith(u8, name, wasm_suffix)) return false;
    const hash = name[wasm_prefix.len .. name.len - wasm_suffix.len];
    if (hash.len != 12) return false;
    for (hash) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn allocWasmName(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ wasm_prefix, hex[0..12], wasm_suffix });
}

fn parseWasmReference(playground: []const u8) ![]const u8 {
    if (std.mem.count(u8, playground, wasm_url_prefix) != 1) return error.InvalidWasmReferenceCount;
    const prefix_start = std.mem.indexOf(u8, playground, wasm_url_prefix).?;
    const value_start = prefix_start + wasm_url_prefix.len;
    const suffix_start = std.mem.indexOfPos(u8, playground, value_start, "\";") orelse return error.InvalidWasmReference;
    const url = playground[value_start..suffix_start];
    if (url.len < 2 or url[0] != '/') return error.InvalidWasmReference;
    const name = url[1..];
    if (!validWasmName(name)) return error.InvalidWasmReference;
    return name;
}

fn parseCacheVersion(index: []const u8) !u64 {
    if (std.mem.count(u8, index, cache_prefix) != 1) return error.InvalidCacheTargetCount;
    const prefix_start = std.mem.indexOf(u8, index, cache_prefix).?;
    const value_start = prefix_start + cache_prefix.len;
    const suffix_start = std.mem.indexOfScalarPos(u8, index, value_start, '"') orelse return error.InvalidCacheTarget;
    if (suffix_start == value_start) return error.InvalidCacheTarget;
    return std.fmt.parseInt(u64, index[value_start..suffix_start], 10) catch error.InvalidCacheTarget;
}

fn replaceWasmReference(
    allocator: std.mem.Allocator,
    playground: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) ![]u8 {
    const old = try std.fmt.allocPrint(allocator, "{s}/{s}\";", .{ wasm_url_prefix, old_name });
    defer allocator.free(old);
    const new = try std.fmt.allocPrint(allocator, "{s}/{s}\";", .{ wasm_url_prefix, new_name });
    defer allocator.free(new);
    return replaceExactlyOne(allocator, playground, old, new);
}

fn replaceCacheVersion(
    allocator: std.mem.Allocator,
    index: []const u8,
    old_version: u64,
    new_version: u64,
) ![]u8 {
    const old = try std.fmt.allocPrint(allocator, "{s}{d}\"", .{ cache_prefix, old_version });
    defer allocator.free(old);
    const new = try std.fmt.allocPrint(allocator, "{s}{d}\"", .{ cache_prefix, new_version });
    defer allocator.free(new);
    return replaceExactlyOne(allocator, index, old, new);
}

fn replaceExactlyOne(
    allocator: std.mem.Allocator,
    input: []const u8,
    old: []const u8,
    new: []const u8,
) ![]u8 {
    if (std.mem.count(u8, input, old) != 1) return error.InvalidReplacementCount;
    const start = std.mem.indexOf(u8, input, old).?;
    const output_len = input.len - old.len + new.len;
    const output = try allocator.alloc(u8, output_len);
    @memcpy(output[0..start], input[0..start]);
    @memcpy(output[start..][0..new.len], new);
    @memcpy(output[start + new.len ..], input[start + old.len ..]);
    return output;
}

fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn writeWebsite(allocator: std.mem.Allocator, root: []const u8, content: []const u8) ![]u8 {
    const static = try std.fs.path.join(allocator, &.{ root, "static" });
    defer allocator.free(static);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, static);
    const deno_path = try std.fs.path.join(allocator, &.{ root, "deno.json" });
    defer allocator.free(deno_path);
    try atomicWrite(std.testing.io, deno_path, "{\"name\":\"@srdjan/zttp-website\"}\n", false);
    const name = try allocWasmName(allocator, content);
    errdefer allocator.free(name);
    const wasm_path = try std.fs.path.join(allocator, &.{ static, name });
    defer allocator.free(wasm_path);
    try atomicWrite(std.testing.io, wasm_path, content, false);
    const playground_path = try std.fs.path.join(allocator, &.{ static, "playground.js" });
    defer allocator.free(playground_path);
    const playground = try std.fmt.allocPrint(allocator, "const WASM_URL = \"/{s}\";\n", .{name});
    defer allocator.free(playground);
    try atomicWrite(std.testing.io, playground_path, playground, false);
    const index_path = try std.fs.path.join(allocator, &.{ static, "index.html" });
    defer allocator.free(index_path);
    try atomicWrite(std.testing.io, index_path, "<script src=\"/playground.js?v=16\" defer></script>\n", false);
    return name;
}

fn expectOriginalTree(
    allocator: std.mem.Allocator,
    root: []const u8,
    old_name: []const u8,
    old_content: []const u8,
    new_name: []const u8,
) !void {
    var destination = try validateDestination(allocator, std.testing.io, root);
    defer destination.deinit(allocator);
    try std.testing.expectEqualStrings(old_name, destination.wasm_name);
    try std.testing.expectEqualStrings(old_content, destination.wasm_content);
    try std.testing.expectEqual(@as(u64, 16), destination.cache_version);
    const new_path = try std.fs.path.join(allocator, &.{ destination.static, new_name });
    defer allocator.free(new_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, new_path, .{}));
}

test "publication updates both references and removes the superseded artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);
    const old_name = try writeWebsite(allocator, root, "\x00asm old wasm");
    defer allocator.free(old_name);
    const source_path = try std.fs.path.join(allocator, &.{ root, "new.wasm" });
    defer allocator.free(source_path);
    const new_content = "\x00asm new wasm";
    try atomicWrite(std.testing.io, source_path, new_content, false);
    const new_name = try allocWasmName(allocator, new_content);
    defer allocator.free(new_name);

    var result = try publishWasm(allocator, std.testing.io, root, source_path, .{});
    defer result.deinit(allocator);
    try std.testing.expect(result.changed);
    try std.testing.expectEqualStrings(new_name, result.wasm_name);
    var destination = try validateDestination(allocator, std.testing.io, root);
    defer destination.deinit(allocator);
    try std.testing.expectEqualStrings(new_name, destination.wasm_name);
    try std.testing.expectEqual(@as(u64, 17), destination.cache_version);
    const old_path = try std.fs.path.join(allocator, &.{ destination.static, old_name });
    defer allocator.free(old_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, old_path, .{}));
}

test "unchanged publication is idempotent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);
    const content = "\x00asm same wasm";
    const old_name = try writeWebsite(allocator, root, content);
    defer allocator.free(old_name);
    const source_path = try std.fs.path.join(allocator, &.{ root, "source.wasm" });
    defer allocator.free(source_path);
    try atomicWrite(std.testing.io, source_path, content, false);

    var result = try publishWasm(allocator, std.testing.io, root, source_path, .{});
    defer result.deinit(allocator);
    try std.testing.expect(!result.changed);
    try expectOriginalTree(allocator, root, old_name, content, "zts-analyzer.000000000000.wasm");
}

const FailingHook = struct {
    phase: Phase,

    fn after(context: ?*anyopaque, phase: Phase) !void {
        const self: *FailingHook = @ptrCast(@alignCast(context.?));
        if (phase == self.phase) return error.InjectedFailure;
    }
};

test "every publication mutation boundary rolls back to the original tree" {
    const allocator = std.testing.allocator;
    for (std.enums.values(Phase)) |phase| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmpPath(allocator, &tmp);
        defer allocator.free(root);
        const old_content = "\x00asm old wasm";
        const old_name = try writeWebsite(allocator, root, old_content);
        defer allocator.free(old_name);
        const source_path = try std.fs.path.join(allocator, &.{ root, "new.wasm" });
        defer allocator.free(source_path);
        const new_content = "\x00asm new wasm";
        try atomicWrite(std.testing.io, source_path, new_content, false);
        const new_name = try allocWasmName(allocator, new_content);
        defer allocator.free(new_name);
        var failing: FailingHook = .{ .phase = phase };

        try std.testing.expectError(error.InjectedFailure, publishWasm(
            allocator,
            std.testing.io,
            root,
            source_path,
            .{ .context = &failing, .after = FailingHook.after },
        ));
        try expectOriginalTree(allocator, root, old_name, old_content, new_name);
    }
}

test "destination validation rejects duplicate artifacts and references" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);
    const old_name = try writeWebsite(allocator, root, "\x00asm old wasm");
    defer allocator.free(old_name);
    const static = try std.fs.path.join(allocator, &.{ root, "static" });
    defer allocator.free(static);
    const duplicate_content = "\x00asm duplicate";
    const duplicate_name = try allocWasmName(allocator, duplicate_content);
    defer allocator.free(duplicate_name);
    const duplicate = try std.fs.path.join(allocator, &.{ static, duplicate_name });
    defer allocator.free(duplicate);
    try atomicWrite(std.testing.io, duplicate, duplicate_content, false);
    try std.testing.expectError(error.MultipleWasmArtifacts, validateDestination(allocator, std.testing.io, root));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, duplicate);

    const playground_path = try std.fs.path.join(allocator, &.{ static, "playground.js" });
    defer allocator.free(playground_path);
    const duplicate_reference = try std.fmt.allocPrint(
        allocator,
        "const WASM_URL = \"/{s}\";\nconst WASM_URL = \"/{s}\";\n",
        .{ old_name, old_name },
    );
    defer allocator.free(duplicate_reference);
    try atomicWrite(std.testing.io, playground_path, duplicate_reference, true);
    try std.testing.expectError(error.InvalidWasmReferenceCount, validateDestination(allocator, std.testing.io, root));
}

test "destination validation rejects malformed content hash and cache target" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);
    const old_name = try writeWebsite(allocator, root, "\x00asm old wasm");
    defer allocator.free(old_name);
    const static = try std.fs.path.join(allocator, &.{ root, "static" });
    defer allocator.free(static);
    const old_path = try std.fs.path.join(allocator, &.{ static, old_name });
    defer allocator.free(old_path);
    try atomicWrite(std.testing.io, old_path, "\x00asm altered", true);
    try std.testing.expectError(error.WasmHashMismatch, validateDestination(allocator, std.testing.io, root));
}

test "interrupted publication journal recovers every durable phase" {
    const allocator = std.testing.allocator;
    for (std.enums.values(Phase)) |phase| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmpPath(allocator, &tmp);
        defer allocator.free(root);
        const old_name = try writeWebsite(allocator, root, "\x00asm old wasm");
        defer allocator.free(old_name);
        const new_content = "\x00asm new wasm";
        const new_name = try allocWasmName(allocator, new_content);
        defer allocator.free(new_name);
        const journal: Journal = .{
            .old_name = old_name,
            .new_name = new_name,
            .old_cache_version = 16,
            .new_cache_version = 17,
        };
        const journal_path = try publicationJournalPath(allocator, root);
        defer allocator.free(journal_path);
        const journal_bytes = try renderJournal(allocator, journal);
        defer allocator.free(journal_bytes);
        try atomicWrite(std.testing.io, journal_path, journal_bytes, false);

        const static = try std.fs.path.join(allocator, &.{ root, "static" });
        defer allocator.free(static);
        if (@intFromEnum(phase) >= @intFromEnum(Phase.new_wasm_created)) {
            const new_path = try std.fs.path.join(allocator, &.{ static, new_name });
            defer allocator.free(new_path);
            try atomicWrite(std.testing.io, new_path, new_content, false);
        }
        if (@intFromEnum(phase) >= @intFromEnum(Phase.playground_written)) {
            const playground_path = try std.fs.path.join(allocator, &.{ static, "playground.js" });
            defer allocator.free(playground_path);
            const playground = try readFile(allocator, std.testing.io, playground_path, max_text_bytes);
            defer allocator.free(playground);
            const patched = try replaceWasmReference(allocator, playground, old_name, new_name);
            defer allocator.free(patched);
            try atomicWrite(std.testing.io, playground_path, patched, true);
        }
        if (@intFromEnum(phase) >= @intFromEnum(Phase.index_written)) {
            const index_path = try std.fs.path.join(allocator, &.{ static, "index.html" });
            defer allocator.free(index_path);
            const index = try readFile(allocator, std.testing.io, index_path, max_text_bytes);
            defer allocator.free(index);
            const patched = try replaceCacheVersion(allocator, index, 16, 17);
            defer allocator.free(patched);
            try atomicWrite(std.testing.io, index_path, patched, true);
        }
        if (@intFromEnum(phase) >= @intFromEnum(Phase.old_wasm_deleted)) {
            const old_path = try std.fs.path.join(allocator, &.{ static, old_name });
            defer allocator.free(old_path);
            try std.Io.Dir.cwd().deleteFile(std.testing.io, old_path);
        }

        try recoverInterruptedPublication(allocator, std.testing.io, root);
        var destination = try validateDestination(allocator, std.testing.io, root);
        defer destination.deinit(allocator);
        const rolls_forward = phase != .journal_written;
        try std.testing.expectEqualStrings(if (rolls_forward) new_name else old_name, destination.wasm_name);
        try std.testing.expectEqual(if (rolls_forward) @as(u64, 17) else @as(u64, 16), destination.cache_version);
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().statFile(std.testing.io, journal_path, .{}),
        );
    }
}

test "publisher lock refuses a concurrent owner" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);
    var first = try acquirePublisherLock(allocator, root);
    defer first.deinit();
    try std.testing.expectError(error.PublisherAlreadyActive, acquirePublisherLock(allocator, root));
}
