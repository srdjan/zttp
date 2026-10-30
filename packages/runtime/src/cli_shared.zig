const std = @import("std");
const writeAllFd = @import("posix_util.zig").writeAllFd;
const builtin = @import("builtin");
const project_config_mod = @import("project_config");
const zts = @import("zts");
const execution_spec = @import("execution_spec.zig");

/// True when stderr is attached to a real terminal. Used to gate ANSI escape
/// codes so piped output and CI logs stay clean.
pub fn stderrIsTty() bool {
    return switch (builtin.target.os.tag) {
        .windows => false,
        else => std.posix.system.isatty(std.posix.STDERR_FILENO) != 0,
    };
}

/// ANSI escape codes resolved at call time from a tty flag. Pass `false` for
/// non-TTY destinations and every field becomes an empty string, so the same
/// format strings produce clean output in both modes.
pub const Palette = struct {
    reset: []const u8,
    bold: []const u8,
    dim: []const u8,
    red: []const u8,
    green: []const u8,
    yellow: []const u8,
    cyan: []const u8,
};

pub fn palette(tty: bool) Palette {
    return if (tty) .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .dim = "\x1b[2m",
        .red = "\x1b[31m",
        .green = "\x1b[32m",
        .yellow = "\x1b[33m",
        .cyan = "\x1b[36m",
    } else .{
        .reset = "",
        .bold = "",
        .dim = "",
        .red = "",
        .green = "",
        .yellow = "",
        .cyan = "",
    };
}

/// Emit a phase-start line to stderr so a long-running local command shows
/// progress instead of going silent until it finishes. Dimmed on a TTY,
/// plain when piped. Stderr-only so `--json` stdout stays machine-pure;
/// mirrors the `deploy --cloud` step-line style for a consistent feel.
pub fn step(label: []const u8) void {
    const p = palette(stderrIsTty());
    std.debug.print("  {s}{s}{s}\n", .{ p.dim, label, p.reset });
}

pub fn collectArgs(allocator: std.mem.Allocator, args_vector: std.process.Args) ![]const []const u8 {
    var args_iter = std.process.Args.Iterator.init(args_vector);
    defer args_iter.deinit();

    var args = std.ArrayList([]const u8).empty;
    errdefer args.deinit(allocator);
    while (args_iter.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }
    return args.toOwnedSlice(allocator);
}

pub fn threadedIo(allocator: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{ .environ = .empty });
}

pub fn realCwd(allocator: std.mem.Allocator) ![]u8 {
    var io_backend = threadedIo(allocator);
    defer io_backend.deinit();
    const cwd_z = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io_backend.io(), ".", allocator);
    defer allocator.free(cwd_z);
    return try allocator.dupe(u8, cwd_z);
}

pub fn takeArg(i: *usize, argv: []const []const u8, missing: anyerror) ![]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return missing;
    return argv[i.*];
}

/// Prepare inline evaluation and retain the original source bytes.
/// The returned `.prepared_eval` owns its code buffer. Source that admission refuses
/// prints its admission diagnostic and returns `error.SourceRefused`. An allocation
/// failure returns `error.OutOfMemory`. The result is never `.inline_code`.
pub fn prepareInlineSource(allocator: std.mem.Allocator, source: []const u8) !execution_spec.HandlerSource {
    if (try zts.checkSourceAdmission(allocator, source)) |failure| {
        const line = try zts.formatAdmissionRefusal(allocator, source, "<eval>", failure);
        defer allocator.free(line);
        std.debug.print("{s}\n", .{line});
        return error.SourceRefused;
    }
    const code = try allocator.dupe(u8, source);
    return .{ .prepared_eval = .{ .code = code } };
}

pub fn printVersion() !void {
    const version = "zttp " ++ zts.version.string ++ "\n";
    try writeAllFd(std.c.STDOUT_FILENO, version);
}

pub fn writeStdoutLine(s: []const u8) !void {
    try writeAllFd(std.c.STDOUT_FILENO, s);
    try writeAllFd(std.c.STDOUT_FILENO, "\n");
}

pub fn writeStderrLine(s: []const u8) void {
    _ = std.c.write(std.c.STDERR_FILENO, s.ptr, s.len);
    _ = std.c.write(std.c.STDERR_FILENO, "\n", 1);
}

/// The serve flags that consume the next argument. `findPositionalPath` skips
/// these values; `runtime_cli.zig` `applyServeFlags` parses them, and its test
/// checks that each entry is a value flag there.
pub const serve_value_flags = [_][]const u8{
    "-p",
    "--port",
    "-h",
    "--host",
    "-e",
    "--eval",
    "-m",
    "--memory",
    "-n",
    "--pool",
    "--static",
    "--outbound-host",
    "--outbound-timeout-ms",
    "--outbound-max-response",
    "--max-body-size",
    "--security-log",
    "--lifecycle",
    "--sqlite",
    "--trace",
    "--incident-log",
    "--replay",
    "--test",
    "--_debug-panic-path",
};

fn isServeValueFlag(arg: []const u8) bool {
    for (serve_value_flags) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

pub fn findPositionalPath(argv: []const []const u8) ?[]const u8 {
    var skip_next = false;
    for (argv) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (isServeValueFlag(arg)) {
            skip_next = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        return arg;
    }
    return null;
}

pub fn hasFlag(argv: []const []const u8, name: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn looksLikeHandlerFile(path: []const u8) bool {
    return zts.classifySourcePath(path).isSupportedFile();
}

pub fn parseSize(str: []const u8) !usize {
    var num_end: usize = 0;
    for (str, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            num_end = i + 1;
        } else {
            break;
        }
    }

    if (num_end == 0) return error.InvalidSize;

    const num = try std.fmt.parseInt(usize, str[0..num_end], 10);
    const suffix = str[num_end..];

    const multiplier: usize = if (suffix.len == 0)
        1
    else if (std.ascii.eqlIgnoreCase(suffix, "k") or std.ascii.eqlIgnoreCase(suffix, "kb"))
        1024
    else if (std.ascii.eqlIgnoreCase(suffix, "m") or std.ascii.eqlIgnoreCase(suffix, "mb"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "g") or std.ascii.eqlIgnoreCase(suffix, "gb"))
        1024 * 1024 * 1024
    else
        return error.InvalidSizeSuffix;

    return std.math.mul(usize, num, multiplier) catch return error.InvalidSize;
}

pub const WatchSet = struct {
    paths: []const []const u8,

    pub fn deinit(self: *WatchSet, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
    }

    pub fn computeStamp(self: *const WatchSet, io: std.Io) !u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.paths) |path| {
            try foldPathIntoHash(io, &hash, path);
        }
        return hash.final();
    }
};

pub fn buildWatchSet(allocator: std.mem.Allocator, argv: []const []const u8) !WatchSet {
    var io_backend = threadedIo(allocator);
    defer io_backend.deinit();
    const io = io_backend.io();

    const explicit_path = findPositionalPath(argv);
    var project = try project_config_mod.discover(allocator, io, explicit_path);
    defer if (project) |*p| p.deinit(allocator);

    var paths = std.ArrayList([]const u8).empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    if (project) |*cfg| {
        try paths.append(allocator, try allocator.dupe(u8, cfg.manifest_path));
        try paths.append(allocator, try std.fs.path.resolve(allocator, &.{ cfg.root_dir, "src" }));
        if (try cfg.resolvedStaticDir(allocator)) |static_dir| {
            try paths.append(allocator, static_dir);
        }
        if (try cfg.resolvedPolicyPath(allocator)) |policy_path| {
            try paths.append(allocator, policy_path);
        }
    } else if (explicit_path) |path| {
        if (looksLikeHandlerFile(path)) {
            const abs = try std.fs.path.resolve(allocator, &.{path});
            const dir_name = std.fs.path.dirname(abs) orelse ".";
            defer allocator.free(abs);
            try paths.append(allocator, try allocator.dupe(u8, dir_name));
        }
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try std.fs.path.resolve(allocator, &.{"."}));
    }

    return .{ .paths = try paths.toOwnedSlice(allocator) };
}

pub fn foldPathIntoHash(io: std.Io, hash: *std.hash.Wyhash, path: []const u8) !void {
    const stat = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };

    hash.update(path);
    hash.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    hash.update(std.mem.asBytes(&stat.size));

    if (stat.kind != .directory) return;

    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(std.heap.smp_allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const entry_stat = try std.Io.Dir.statFile(entry.dir, io, entry.basename, .{});
        hash.update(entry.path);
        hash.update(std.mem.asBytes(&entry_stat.mtime.nanoseconds));
        hash.update(std.mem.asBytes(&entry_stat.size));
    }
}

test "findPositionalPath skips the value of --_debug-panic-path" {
    try std.testing.expectEqualStrings(
        "handler.ts",
        findPositionalPath(&.{ "--_debug-panic-path", "/x", "handler.ts" }).?,
    );
}

test "parse size" {
    try std.testing.expectEqual(@as(usize, 1024), try parseSize("1k"));
    try std.testing.expectEqual(@as(usize, 1024), try parseSize("1K"));
    try std.testing.expectEqual(@as(usize, 1024), try parseSize("1kb"));
    try std.testing.expectEqual(@as(usize, 256 * 1024), try parseSize("256k"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), try parseSize("1m"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), try parseSize("1mb"));
    try std.testing.expectEqual(@as(usize, 100), try parseSize("100"));
}

test "watch set includes the configured capability policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zttp.json",
        .data = "{\"entry\":\"src/handler.ts\",\"policy\":\"policy.json\"}",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/handler.ts", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "policy.json", .data = "{}" });

    const handler_path = try tmp.dir.realPathFileAlloc(std.testing.io, "src/handler.ts", allocator);
    defer allocator.free(handler_path);
    var watch_set = try buildWatchSet(allocator, &.{handler_path});
    defer watch_set.deinit(allocator);

    var found_policy = false;
    for (watch_set.paths) |path| {
        if (std.mem.eql(u8, std.fs.path.basename(path), "policy.json")) {
            found_policy = true;
            break;
        }
    }
    try std.testing.expect(found_policy);
}

test "inline preparation retains original bytes and its fixed source case" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "function handler(req: Request): Response { return Response.text(\"ok\"); }",
        "function handler(req) { return Response.text(\"ok\"); }",
    };
    for (sources) |source| {
        const prepared = try prepareInlineSource(allocator, source);
        defer allocator.free(inlineTestCode(prepared));
        try std.testing.expect(prepared == .prepared_eval);
        try std.testing.expectEqualStrings(source, prepared.prepared_eval.code);
        try std.testing.expect(prepared.prepared_eval.code.ptr != source.ptr);
    }
    try std.testing.expectError(
        error.SourceRefused,
        prepareInlineSource(allocator, "function handler(req: any): Response { return Response.text(\"ok\"); }"),
    );
}

const InlinePreparationFaultAllocator = struct {
    backing: std.mem.Allocator,
    fail_index: ?usize = null,
    allocations: usize = 0,
    induced: bool = false,

    fn allocator(self: *InlinePreparationFaultAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *InlinePreparationFaultAllocator = @ptrCast(@alignCast(context));
        const index = self.allocations;
        self.allocations += 1;
        if (self.fail_index == index) {
            self.induced = true;
            return null;
        }
        return self.backing.rawAlloc(length, alignment, address);
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
        const self: *InlinePreparationFaultAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, length, address);
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
        const self: *InlinePreparationFaultAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, length, address);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *InlinePreparationFaultAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, address);
    }
};

fn inlineTestCode(source: execution_spec.HandlerSource) []const u8 {
    return switch (source) {
        .prepared_eval => |prepared| prepared.code,
        else => unreachable,
    };
}

test "inline preparation never turns an allocation failure into a different source case" {
    const accepted = "function handler(req: Request): Response { const value: string = \"ok\"; return Response.text(value); }";
    const refused = "function handler(req: any): Response { return Response.text(\"ok\"); }";
    var baseline: InlinePreparationFaultAllocator = .{ .backing = std.testing.allocator };
    const prepared = try prepareInlineSource(baseline.allocator(), accepted);
    std.testing.allocator.free(inlineTestCode(prepared));
    try std.testing.expect(prepared == .prepared_eval);
    try std.testing.expect(baseline.allocations > 0);
    var out_of_memory: usize = 0;
    for (0..baseline.allocations) |index| {
        var fault: InlinePreparationFaultAllocator = .{ .backing = std.testing.allocator, .fail_index = index };
        const result = prepareInlineSource(fault.allocator(), accepted) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            out_of_memory += 1;
            continue;
        };
        // The parser reserves node capacity as a hint, and a refused hint is not an error.
        defer std.testing.allocator.free(inlineTestCode(result));
        try std.testing.expectEqualStrings(accepted, inlineTestCode(result));
    }
    try std.testing.expect(out_of_memory > 0);
    var refused_baseline: InlinePreparationFaultAllocator = .{ .backing = std.testing.allocator };
    try std.testing.expectError(error.SourceRefused, prepareInlineSource(refused_baseline.allocator(), refused));
    for (0..refused_baseline.allocations) |index| {
        var fault: InlinePreparationFaultAllocator = .{ .backing = std.testing.allocator, .fail_index = index };
        const result = prepareInlineSource(fault.allocator(), refused);
        if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
            error.OutOfMemory, error.SourceRefused => {},
            else => return err,
        }
    }
}

test "inline refusal line carries the eval name, position, and message" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { source: []const u8, line: []const u8 }{
        .{ .source = "function handler(req: any): Response { return Response.text(\"ok\"); }", .line = "<eval>:1:23: 'any' type is not supported; use specific types (string, number, object) or union types instead" },
        .{ .source = "function handler(req: Request): Response { return Response.text(\"ok\"); } /* open", .line = "TypeScript strip error in <eval>: error.UnterminatedComment" },
        .{ .source = "const s = \"open\nfunction handler(req: Request): Response { return Response.text(\"ok\"); }", .line = "<eval>:1:16: unterminated string literal; close the quote, or write the newline as \\n" },
    };
    for (cases) |case| {
        const failure = (try zts.checkSourceAdmission(allocator, case.source)).?;
        const line = try zts.formatAdmissionRefusal(allocator, case.source, "<eval>", failure);
        defer allocator.free(line);
        try std.testing.expectEqualStrings(case.line, line);
    }
}
