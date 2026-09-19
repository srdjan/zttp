//! `zttp invariant` - read the closed invariant catalog and draft a candidate.
//!
//! `list` prints every kind the acceptance kernel knows, straight from its
//! metadata table. `author` turns an explicit selection plus a ledger and
//! currency declaration into a reviewable candidate.
//!
//! The authoring logic itself is pure and lives in
//! `packages/tools/src/invariant_author.zig`. This file is the host half: it
//! owns stdout, stderr, the environment, and the one `std.http` call the
//! optional advisory classifier needs. Builds, acceptance checks, and request
//! serving never reach any of it.

const std = @import("std");
const project_config = @import("project_config");
const author = project_config.invariant_author;
const FetchDeadline = @import("fetch_deadline.zig").FetchDeadline;

/// Where an advisory classification is sent, and the variable that authorizes
/// it. Absent the key, no request is made at all.
const classifier_url = "https://api.typesafe.ai/v1/systemone";
const api_key_env = "TYPESAFE_API_KEY";
/// Bound on the request/response exchange, carried over from the 30 second
/// timeout the tool this replaced passed to urllib. It is enforced by the
/// watchdog in `fetch_deadline.zig`, because `ConnectTcpOptions.timeout` is
/// declared but never read by `std.http.Client`: passing it bounds nothing.
const exchange_timeout_ms: u32 = 30_000;
const max_response_bytes: usize = 64 * 1024;

pub const Subcommand = enum { list, author };

pub const DispatchError = error{UnknownSubcommand};

/// `null` means "print help": no subcommand, or an explicit help request.
pub fn parseSubcommand(args: []const []const u8) DispatchError!?Subcommand {
    if (args.len == 0) return null;
    const name = args[0];
    if (std.mem.eql(u8, name, "--help") or
        std.mem.eql(u8, name, "-h") or
        std.mem.eql(u8, name, "help")) return null;
    return std.meta.stringToEnum(Subcommand, name) orelse error.UnknownSubcommand;
}

/// True for the failures a user caused and has already been told about, so the
/// dispatcher exits 1 instead of printing a Zig stack trace.
pub fn isExpectedUserError(err: anyerror) bool {
    return switch (err) {
        error.UnknownSubcommand,
        error.MissingKind,
        error.UnknownKind,
        error.DuplicateKind,
        error.TooManyKinds,
        error.MissingRequiredKind,
        error.MissingLedger,
        error.InvalidLedger,
        error.MissingCurrency,
        error.InvalidCurrency,
        error.DuplicateCurrency,
        error.TooManyCurrencies,
        error.MissingAccount,
        error.InvalidAccount,
        error.DuplicateAccount,
        error.TooManyAccounts,
        error.AccountsNeedDeclaredKind,
        error.MissingArgument,
        error.UnknownArgument,
        error.AdviceNeedsStatement,
        => true,
        else => false,
    };
}

const help_text =
    \\zttp invariant - the closed application-invariant catalog
    \\
    \\Usage:
    \\  zttp invariant list
    \\  zttp invariant author --kind <name> [--kind <name> ...] --ledger <id>
    \\                        --currency CODE:SCALE [--currency CODE:SCALE ...]
    \\                        [--account-exact <account>] [--account-prefix <prefix>]
    \\                        [--statement <sentence>] [--advise] [--model <id>]
    \\
    \\Commands:
    \\  list      Print every supported kind, its confirmed description, its
    \\            predicate version, and whether acceptance requires it.
    \\  author    Print a reviewable candidate for the selected kinds.
    \\
    \\Options:
    \\  --kind <name>            Required, repeatable. The catalog kinds being
    \\                           declared; run `zttp invariant list` for the
    \\                           supported names. The selection must name the
    \\                           kind acceptance requires of every
    \\                           specification.
    \\  --ledger <id>            Required. The ledger the invariant holds over.
    \\  --currency CODE:SCALE    Required at least once, for example USD:2.
    \\  --account-exact <acct>   Repeatable. Admit exactly this account. Needs
    \\                           --kind declared_accounts_v1.
    \\  --account-prefix <pfx>   Repeatable. Admit every account whose bytes
    \\                           begin with this non-empty prefix, the prefix
    \\                           itself included. Matching is case-sensitive
    \\                           over bytes, with no wildcard and no normalizing.
    \\  --statement <sentence>   Plain-language annotation for the review output.
    \\  --advise                 Ask an advisory classifier whether the sentence
    \\                           matches the selected kind. Needs --statement and
    \\                           TYPESAFE_API_KEY. Only the sentence and the
    \\                           catalog's published descriptions are sent.
    \\  --model <id>             Classifier model for --advise.
    \\
    \\The sentence is annotation and never the specification: the kind, the
    \\ledger, and the currencies are what zttp accepts. Save only the `candidate`
    \\object as the configured invariant JSON. zttp validates it independently;
    \\this output is not evidence, and a classifier answer is not proof.
    \\
;

pub fn printHelp() void {
    writeStdout(help_text);
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const selected = parseSubcommand(args) catch |err| {
        writeStderrFmt("zttp invariant: unknown subcommand `{s}`\n\n", .{args[0]});
        printHelp();
        return err;
    } orelse {
        printHelp();
        return;
    };
    return switch (selected) {
        .list => listCommand(allocator),
        .author => authorCommand(allocator, args[1..]),
    };
}

fn listCommand(allocator: std.mem.Allocator) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try author.renderList(&aw.writer);
    writeStdout(aw.written());
}

fn authorCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
    }

    const request = author.parseAuthorArgs(args) catch |err| {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        aw.writer.writeAll("zttp invariant author: ") catch {};
        author.writeArgErrorMessage(&aw.writer, err) catch {};
        writeStderr(aw.written());
        return err;
    };

    var advisory: author.Advisory = .{ .status = .not_requested };
    if (request.advise) {
        // `parseAuthorArgs` refuses `--advise` without a statement, so this is
        // the sentence the developer typed and nothing else.
        advisory = adviseOrUnavailable(allocator, &request, request.statement orelse "");
    }

    const out = try author.renderReview(allocator, &request, advisory);
    defer allocator.free(out);
    writeStdout(out);
}

fn adviseOrUnavailable(
    allocator: std.mem.Allocator,
    request: *const author.Request,
    statement: []const u8,
) author.Advisory {
    const api_key = envSlice(api_key_env) orelse return .{
        .status = .unavailable,
        .reason = api_key_env ++ " is not set",
    };
    // Say where the sentence is going before it goes.
    writeStderrFmt(
        "zttp invariant author: sending the statement, and nothing else, to {s}\n",
        .{classifier_url},
    );

    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();
    var host: HostTransport = .{ .io = io_backend.io(), .api_key = api_key };
    return author.requestAdvice(
        allocator,
        .{ .context = &host, .post = HostTransport.post },
        statement,
        request.model,
        request.kinds(),
    );
}

/// The real transport. It is reached only from `authorCommand`, so no build,
/// acceptance, or serving path can call it.
const HostTransport = struct {
    io: std.Io,
    api_key: []const u8,

    fn post(context: *anyopaque, allocator: std.mem.Allocator, body: []const u8) anyerror![]u8 {
        const self: *HostTransport = @ptrCast(@alignCast(context));
        const uri = try std.Uri.parse(classifier_url);

        var client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer client.deinit();

        // Connect explicitly so the exchange has a stream to arm the watchdog
        // on. That also performs the TLS handshake before `request()` runs, so
        // the trust store and clock are stamped here rather than left to it.
        const now = std.Io.Clock.real.now(self.io);
        try client.ca_bundle.rescan(allocator, self.io, now);
        client.now = now;

        const protocol = std.http.Client.Protocol.fromUri(uri) orelse
            return error.UnsupportedProtocol;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const connection = try client.connectTcpOptions(.{
            .host = try uri.getHost(&host_buf),
            .port = uri.port orelse switch (protocol) {
                .plain => 80,
                .tls => 443,
            },
            .protocol = protocol,
        });

        var authorization_buf: [512]u8 = undefined;
        const authorization = try std.fmt.bufPrint(
            &authorization_buf,
            "Bearer {s}",
            .{self.api_key},
        );
        const extra_headers = [_]std.http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "content-type", .value = "application/json" },
        };

        var req = try client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .connection = connection,
            .extra_headers = &extra_headers,
        });
        defer req.deinit();

        // Declared after req's deinit defer so LIFO runs `disarm` first: the
        // watchdog must be joined before the connection is released, or it
        // could shut down an fd that has since been recycled.
        var deadline: FetchDeadline = .{
            .stream = connection.stream_reader.stream,
            .timeout_ms = exchange_timeout_ms,
            .io = self.io,
        };
        deadline.arm();
        defer deadline.disarm();

        return exchange(allocator, &req, body) catch |err| {
            // After a shutdown the blocked call surfaces EndOfStream or
            // SocketUnconnected; report why it really ended.
            if (deadline.expired()) return error.TimedOut;
            return err;
        };
    }

    /// One request/response, with no knowledge of the deadline watching it.
    fn exchange(
        allocator: std.mem.Allocator,
        req: *std.http.Client.Request,
        body: []const u8,
    ) ![]u8 {
        req.transfer_encoding = .{ .content_length = body.len };
        var req_body = try req.sendBodyUnflushed(&.{});
        try req_body.writer.writeAll(body);
        try req_body.end();
        const connection = req.connection orelse return error.ConnectionMissing;
        try connection.flush();

        var response = try req.receiveHead(&.{});
        var read_buf: [4096]u8 = undefined;
        var reader = response.reader(&read_buf);
        const received = try reader.allocRemaining(allocator, .limited(max_response_bytes));
        errdefer allocator.free(received);
        // The body is the classifier's, not ours to quote: a non-OK answer is
        // simply no answer. `errdefer` owns the free, so this path must not
        // also free it by hand.
        if (response.head.status != .ok) return error.HttpNotOk;
        return received;
    }
};

fn envSlice(name: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

fn writeStdout(text: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, text.ptr, text.len);
}

fn writeStderr(text: []const u8) void {
    _ = std.c.write(std.c.STDERR_FILENO, text.ptr, text.len);
}

fn writeStderrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStderr(text);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "invariant dispatch routes the two subcommands and refuses anything else" {
    try testing.expectEqual(@as(?Subcommand, null), try parseSubcommand(&.{}));
    try testing.expectEqual(@as(?Subcommand, null), try parseSubcommand(&.{"--help"}));
    try testing.expectEqual(@as(?Subcommand, null), try parseSubcommand(&.{"help"}));
    try testing.expectEqual(@as(?Subcommand, .list), try parseSubcommand(&.{"list"}));
    try testing.expectEqual(@as(?Subcommand, .author), try parseSubcommand(&.{ "author", "--kind", "x" }));
    try testing.expectError(error.UnknownSubcommand, parseSubcommand(&.{"frobnicate"}));
    // A kind name is not a verb: `zttp invariant balance_conservation_v1` must
    // not quietly become an authoring run.
    try testing.expectError(error.UnknownSubcommand, parseSubcommand(&.{"balance_conservation_v1"}));
}

test "invariant help names both subcommands, the required flags, and the advisory limit" {
    inline for (.{
        "zttp invariant list",
        "zttp invariant author",
        "--kind <name>",
        "--ledger <id>",
        "--currency CODE:SCALE",
        "--statement <sentence>",
        "--advise",
        "TYPESAFE_API_KEY",
        "The sentence is annotation and never the specification",
        "a classifier answer is not proof",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, help_text, needle) != null);
    }
}

test "every authoring refusal is classified as an expected user error" {
    // An unmapped member would escape the dispatcher as a stack trace instead
    // of the one-line diagnostic the user was just shown.
    inline for (@typeInfo(author.AuthorError).error_set.?) |member| {
        try testing.expect(isExpectedUserError(@field(anyerror, member.name)));
    }
    try testing.expect(isExpectedUserError(error.UnknownSubcommand));
    try testing.expect(!isExpectedUserError(error.OutOfMemory));
}
