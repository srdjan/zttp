//! The reference-tools check (M4 T7, check C7).
//!
//! Drives `examples/tools` through the path a deployer takes, with no replay:
//! `zttp build` emits a self-contained artifact, the artifact starts from an
//! empty directory with the key and credential variables set, and real HTTP
//! requests reach it over loopback. A loopback upstream on the port the
//! example names (39460) records every request, so the check sees what the
//! runtime sent, credential header included.
//!
//! The positive path is one accepted `convert` call and one `order_status`
//! call. Each applicable B8 case then runs at its own boundary:
//!
//! - B8.1 incorrect subject, request: a token for another tenant gets 403.
//! - B8.2 forged nominal value, build: a copy that passes a plain string
//!   where an `OrderId` is required is refused.
//! - B8.3 oversized upstream response, request: the tool answers 502 with
//!   `ResponseTooLarge`.
//! - B8.4 malformed result, request: an upstream status outside the output
//!   enum is refused by the gate with 500.
//! - B8.7 widened capability, build: a copy that reaches `zttp:crypto`, which
//!   the declaration excludes, is refused.
//! - B8.8 changed policy and B8.9 tampered artifact, start: one byte of the
//!   declaration or of the catalog changed, with the payload CRC recomputed as
//!   a deliberate attacker would, and the artifact refuses to serve.
//!
//! Every case must run and pass. A mutation that does not change the source
//! fails the check instead of passing it, and the check fails when it ran
//! fewer cases than it declares.
//!
//! Usage: reference-tools-check <zttp> <zttp-runtime> <examples/tools>

const std = @import("std");
const self_extract = @import("self_extract.zig");
const compat = @import("zts").compat;

const Io = std.Io;

/// The port `examples/tools/zttp.json` and `tools.ts` name for the upstream.
const upstream_port: u16 = 39460;
const jwt_key = "reference-tools-check-key-0123456789";
const credential_value = "reference-tools-credential-7d3f1a";
const example_files = [_][]const u8{ "zttp.json", "tools.ts", "declaration.json", "policy.json" };
const expected_cases: usize = 9;
const order_body = "{\"tenant_id\":\"acme\",\"order_id\":\"o-17\"}";

const Check = struct {
    gpa: std.mem.Allocator,
    io: Io,
    zttp: []const u8,
    example: []const u8,
    work: []const u8,
    environ: *const std.process.Environ.Map,
    passed: usize = 0,
    failed: usize = 0,

    fn pass(self: *Check, name: []const u8) void {
        self.passed += 1;
        std.debug.print("  PASS  {s}\n", .{name});
    }

    fn fail(self: *Check, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.failed += 1;
        std.debug.print("  FAIL  {s}: " ++ fmt ++ "\n", .{name} ++ args);
    }

    fn path(self: *Check, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, parts);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const zttp_built = args.next() orelse return usage();
    const runtime_built = args.next() orelse return usage();
    const example = args.next() orelse return usage();

    const tmp_root = init.environ_map.get("TMPDIR") orelse "/tmp";
    var name_buf: [64]u8 = undefined;
    const now: u64 = @intCast(Io.Clock.real.now(io).toNanoseconds());
    const work_name = try std.fmt.bufPrint(&name_buf, "zttp-reference-tools-{x}", .{now});
    const work = try std.fs.path.join(gpa, &.{ tmp_root, work_name });
    defer gpa.free(work);
    try Io.Dir.cwd().createDirPath(io, work);
    defer Io.Dir.cwd().deleteTree(io, work) catch {};

    // `zttp build` wraps the `zttp-runtime` it finds beside its own binary, as
    // an installed pair has it. The build graph emits the two to separate
    // cache directories, so install them side by side here.
    const bin = try std.fs.path.join(gpa, &.{ work, "bin" });
    defer gpa.free(bin);
    try Io.Dir.cwd().createDirPath(io, bin);
    const zttp = try installBinary(gpa, io, zttp_built, bin, "zttp");
    defer gpa.free(zttp);
    const runtime = try installBinary(gpa, io, runtime_built, bin, "zttp-runtime");
    gpa.free(runtime);

    var check = Check{ .gpa = gpa, .io = io, .zttp = zttp, .example = example, .work = work, .environ = init.environ_map };
    std.debug.print("reference tools: {s}\n", .{example});
    run(&check) catch |err| check.fail("harness", "{s}", .{@errorName(err)});

    const ran = check.passed + check.failed;
    std.debug.print("reference tools: {d} of {d} cases passed\n", .{ check.passed, ran });
    // Floor on the check's own input: a harness that ran fewer cases than it
    // declares checked less than its name says.
    if (ran < expected_cases) {
        std.debug.print("error: ran {d} cases, fewer than the {d} this check declares\n", .{ ran, expected_cases });
        std.process.exit(1);
    }
    if (check.failed > 0) std.process.exit(1);
}

fn usage() void {
    std.debug.print("usage: reference-tools-check <zttp> <zttp-runtime> <examples/tools>\n", .{});
    std.process.exit(2);
}

fn installBinary(gpa: std.mem.Allocator, io: Io, src: []const u8, dir: []const u8, name: []const u8) ![]u8 {
    const dest = try std.fs.path.join(gpa, &.{ dir, name });
    errdefer gpa.free(dest);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, src, gpa, .unlimited);
    defer gpa.free(bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes, .flags = .{ .permissions = .executable_file } });
    return dest;
}

fn run(check: *Check) !void {
    const project = try check.path(&.{ check.work, "project" });
    defer check.gpa.free(project);
    try copyExample(check, project, &.{});
    const artifact = try check.path(&.{ check.work, "tools-bin" });
    defer check.gpa.free(artifact);

    const build = try runZttpBuild(check, project, artifact);
    defer check.gpa.free(build.output);
    if (!build.ok) {
        check.fail("build", "zttp build failed:\n{s}", .{build.output});
        return;
    }

    const upstream = try Upstream.start();
    defer upstream.stop();

    try requestCases(check, artifact, upstream);
    try buildRefusalCases(check);
    try tamperCases(check, artifact);
}

// ---------------------------------------------------------------------------
// Request cases: positive, B8.1, B8.3, B8.4
// ---------------------------------------------------------------------------

fn requestCases(check: *Check, artifact: []const u8, upstream: *Upstream) !void {
    const port = try freePort(check.io);
    var server = try Server.start(check, artifact, port);
    defer server.stop(check.io);
    if (!try server.waitReady(check.io)) {
        check.fail("start", "the artifact did not start listening on {d}", .{port});
        return;
    }

    const acme = try token(check.gpa, "{\"sub\":\"user-1\",\"tenant\":\"acme\",\"exp\":4102444800}");
    defer check.gpa.free(acme);
    const globex = try token(check.gpa, "{\"sub\":\"user-2\",\"tenant\":\"globex\",\"exp\":4102444800}");
    defer check.gpa.free(globex);

    {
        const res = try post(check, port, "/tools/convert", acme, "{\"value\":100,\"from\":\"C\",\"to\":\"F\"}");
        defer res.deinit(check.gpa);
        if (res.status == 200 and contains(res.body, "\"value\":212") and contains(res.body, "\"unit\":\"F\"")) {
            check.pass("convert: an accepted, bounded, pure call");
        } else check.fail("convert", "status {d}, body {s}", .{ res.status, res.body });
    }

    {
        upstream.setReply(.ok);
        const before = upstream.requestCount();
        const res = try post(check, port, "/tools/order_status", acme, order_body);
        defer res.deinit(check.gpa);
        const seen = upstream.last();
        const header_ok = std.mem.eql(u8, seen.authorization(), "Bearer " ++ credential_value);
        const path_ok = std.mem.eql(u8, seen.target(), "/v1/orders?tenant=acme&order=o-17");
        if (res.status == 200 and contains(res.body, "\"status\":\"shipped\"") and upstream.requestCount() == before + 1 and
            header_ok and path_ok and !contains(res.body, credential_value))
        {
            check.pass("order_status: a scoped call the upstream receives with the injected credential");
        } else check.fail("order_status", "status {d}, body {s}, upstream saw {d} request(s), target {s}, credential {s}", .{
            res.status, res.body, upstream.requestCount() - before, seen.target(), if (header_ok) "injected" else "missing",
        });
    }

    {
        const before = upstream.requestCount();
        const res = try post(check, port, "/tools/order_status", globex, order_body);
        defer res.deinit(check.gpa);
        if (res.status == 403 and contains(res.body, "tenant") and upstream.requestCount() == before) {
            check.pass("B8.1 incorrect subject: another tenant's token is refused before the handler runs");
        } else check.fail("B8.1", "status {d}, body {s}, upstream saw {d} request(s)", .{ res.status, res.body, upstream.requestCount() - before });
    }

    {
        upstream.setReply(.oversized);
        const res = try post(check, port, "/tools/order_status", acme, order_body);
        defer res.deinit(check.gpa);
        if (res.status == 502 and contains(res.body, "ResponseTooLarge")) {
            check.pass("B8.3 oversized upstream response: the bound refuses it and the tool answers 502");
        } else check.fail("B8.3", "status {d}, body {s}", .{ res.status, res.body });
    }

    {
        upstream.setReply(.malformed);
        const res = try post(check, port, "/tools/order_status", acme, order_body);
        defer res.deinit(check.gpa);
        if (res.status == 500 and contains(res.body, "tool output refused")) {
            check.pass("B8.4 malformed result: the output gate refuses a status outside the schema");
        } else check.fail("B8.4", "status {d}, body {s}", .{ res.status, res.body });
    }
    upstream.setReply(.ok);
}

// ---------------------------------------------------------------------------
// Build cases: B8.2, B8.7
// ---------------------------------------------------------------------------

const Mutation = struct {
    find: []const u8,
    replace: []const u8,
};

fn buildRefusalCases(check: *Check) !void {
    try expectBuildRefused(check, "B8.2 forged nominal value: a plain string where an OrderId is required", "b8-2", &.{.{
        .find = "return lookupOrder(input.tenant_id, id);",
        .replace = "return lookupOrder(input.tenant_id, input.order_id);",
    }}, "expected OrderId, got string");
    try expectBuildRefused(check, "B8.7 widened capability: a helper reaches zttp:crypto, which the declaration excludes", "b8-7", &.{
        .{ .find = "import { fetch } from \"zttp:fetch\";", .replace = "import { fetch } from \"zttp:fetch\";\nimport { sha256 } from \"zttp:crypto\";" },
        .{ .find = "  const celsius = toCelsius(input.value, input.from);", .replace = "  const tag = sha256(input.from);\n  const celsius = toCelsius(input.value, input.from);" },
    }, "module_excluded_by_declaration zttp:crypto");
}

fn expectBuildRefused(check: *Check, name: []const u8, dir_name: []const u8, mutations: []const Mutation, needle: []const u8) !void {
    const project = try check.path(&.{ check.work, dir_name });
    defer check.gpa.free(project);
    copyExample(check, project, mutations) catch |err| switch (err) {
        error.MutationDidNotApply => {
            check.fail(name, "the mutation found nothing to change in tools.ts", .{});
            return;
        },
        else => return err,
    };
    const artifact = try check.path(&.{ project, "bin" });
    defer check.gpa.free(artifact);
    const build = try runZttpBuild(check, project, artifact);
    defer check.gpa.free(build.output);
    if (build.ok) {
        check.fail(name, "zttp build accepted the mutated handler", .{});
    } else if (contains(build.output, needle)) {
        check.pass(name);
    } else check.fail(name, "zttp build failed without \"{s}\":\n{s}", .{ needle, build.output });
}

// ---------------------------------------------------------------------------
// Start cases: B8.8, B8.9
// ---------------------------------------------------------------------------

fn tamperCases(check: *Check, artifact: []const u8) !void {
    // One byte inside a string each section carries, so the section still
    // decodes and only the bound digest can catch the change.
    try expectTamperRefused(check, "B8.8 changed policy: one declaration byte changed, CRC recomputed", artifact, "ZTDCL1", "zttp:crypto");
    try expectTamperRefused(check, "B8.9 tampered artifact: one catalog byte changed, CRC recomputed", artifact, "ZTCAT1", "Convert a temperature");
}

fn expectTamperRefused(check: *Check, name: []const u8, artifact: []const u8, magic: []const u8, needle: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(check.io, artifact, check.gpa, .unlimited);
    defer check.gpa.free(bytes);
    if (bytes.len < self_extract.TRAILER_SIZE) return check.fail(name, "the artifact has no trailer", .{});
    const trailer = self_extract.readTrailer(bytes.len, bytes[bytes.len - self_extract.TRAILER_SIZE ..][0..self_extract.TRAILER_SIZE]) catch {
        return check.fail(name, "the artifact trailer does not parse", .{});
    };
    const payload_start: usize = @intCast(trailer.payload_offset);
    const payload_end = payload_start + @as(usize, @intCast(trailer.payload_size));
    const payload = bytes[payload_start..payload_end];
    const at = std.mem.lastIndexOf(u8, payload, magic) orelse return check.fail(name, "the payload holds no {s} section", .{magic});
    const found = std.mem.indexOfPos(u8, payload, at, needle) orelse return check.fail(name, "the {s} section holds no \"{s}\"", .{ magic, needle });
    payload[found + needle.len - 1] ^= 0x01;
    const crc = std.hash.crc.Crc32.hash(payload);
    std.mem.writeInt(u32, bytes[bytes.len - self_extract.TRAILER_SIZE + 20 ..][0..4], crc, .little);

    const tampered = try std.fmt.allocPrint(check.gpa, "{s}-{s}", .{ artifact, magic });
    defer check.gpa.free(tampered);
    try Io.Dir.cwd().writeFile(check.io, .{ .sub_path = tampered, .data = bytes, .flags = .{ .permissions = .executable_file } });

    const port = try freePort(check.io);
    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var env = try serverEnviron(check);
    defer env.deinit();
    const empty = try check.path(&.{ check.work, "empty" });
    defer check.gpa.free(empty);
    try Io.Dir.cwd().createDirPath(check.io, empty);
    const result = std.process.run(check.gpa, check.io, .{
        .argv = &.{ tampered, "-p", port_text, "-q" },
        .cwd = .{ .path = empty },
        .environ_map = &env,
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(20), .clock = .awake } },
    }) catch |err| return check.fail(name, "the tampered artifact did not exit: {s}", .{@errorName(err)});
    defer check.gpa.free(result.stdout);
    defer check.gpa.free(result.stderr);
    const exited_nonzero = switch (result.term) {
        .exited => |code| code != 0,
        else => false,
    };
    if (exited_nonzero and contains(result.stderr, "refusing to serve")) {
        check.pass(name);
    } else check.fail(name, "term {any}, stderr:\n{s}", .{ result.term, result.stderr });
}

// ---------------------------------------------------------------------------
// Project copy and build
// ---------------------------------------------------------------------------

fn copyExample(check: *Check, dest: []const u8, mutations: []const Mutation) !void {
    try Io.Dir.cwd().createDirPath(check.io, dest);
    for (example_files) |file| {
        const src = try check.path(&.{ check.example, file });
        defer check.gpa.free(src);
        var text = try Io.Dir.cwd().readFileAlloc(check.io, src, check.gpa, .limited(1 << 20));
        defer check.gpa.free(text);
        if (std.mem.eql(u8, file, "tools.ts")) {
            for (mutations) |m| {
                if (std.mem.indexOf(u8, text, m.find) == null) return error.MutationDidNotApply;
                const next = try std.mem.replaceOwned(u8, check.gpa, text, m.find, m.replace);
                check.gpa.free(text);
                text = next;
            }
        }
        const dst = try check.path(&.{ dest, file });
        defer check.gpa.free(dst);
        try Io.Dir.cwd().writeFile(check.io, .{ .sub_path = dst, .data = text });
    }
}

const BuildResult = struct { ok: bool, output: []u8 };

fn runZttpBuild(check: *Check, project: []const u8, artifact: []const u8) !BuildResult {
    const result = try std.process.run(check.gpa, check.io, .{
        .argv = &.{ check.zttp, "build", "-o", artifact, "--no-attest" },
        .cwd = .{ .path = project },
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(120), .clock = .awake } },
    });
    defer check.gpa.free(result.stdout);
    defer check.gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const output = try std.mem.concat(check.gpa, u8, &.{ result.stdout, result.stderr });
    return .{ .ok = ok, .output = output };
}

fn serverEnviron(check: *Check) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(check.gpa);
    errdefer env.deinit();
    if (check.environ.get("PATH")) |p| try env.put("PATH", p);
    if (check.environ.get("HOME")) |h| try env.put("HOME", h);
    try env.put("TOOLS_JWT_KEY", jwt_key);
    try env.put("ORDERS_API_KEY", credential_value);
    return env;
}

// ---------------------------------------------------------------------------
// The artifact as a running server
// ---------------------------------------------------------------------------

const Server = struct {
    child: std.process.Child,
    port: u16,

    fn start(check: *Check, artifact: []const u8, port: u16) !Server {
        var port_buf: [8]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
        var env = try serverEnviron(check);
        defer env.deinit();
        const empty = try check.path(&.{ check.work, "serve" });
        defer check.gpa.free(empty);
        try Io.Dir.cwd().createDirPath(check.io, empty);
        // A deployed artifact makes no outbound request unless the operator
        // allows it; this one names only the loopback upstream.
        const child = try std.process.spawn(check.io, .{
            .argv = &.{ artifact, "-p", port_text, "-q", "--outbound-host", "127.0.0.1" },
            .cwd = .{ .path = empty },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        return .{ .child = child, .port = port };
    }

    fn waitReady(self: *Server, io: Io) !bool {
        var attempt: usize = 0;
        while (attempt < 200) : (attempt += 1) {
            if (connect(io, self.port)) |stream| {
                stream.close(io);
                return true;
            } else |_| {}
            try io.sleep(.fromMilliseconds(50), .awake);
        }
        return false;
    }

    fn stop(self: *Server, io: Io) void {
        self.child.kill(io);
    }
};

fn connect(io: Io, port: u16) !Io.net.Stream {
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    return address.connect(io, .{ .mode = .stream });
}

fn freePort(io: Io) !u16 {
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

// ---------------------------------------------------------------------------
// HTTP over loopback
// ---------------------------------------------------------------------------

const Response = struct {
    status: u16,
    body: []u8,

    fn deinit(self: Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

fn post(check: *Check, port: u16, target: []const u8, bearer: []const u8, body: []const u8) !Response {
    var stream = try connect(check.io, port);
    defer stream.close(check.io);
    var out_buf: [2048]u8 = undefined;
    var writer = stream.writer(check.io, &out_buf);
    try writer.interface.print("POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ target, bearer, body.len, body });
    try writer.interface.flush();

    const raw = try readAll(check.gpa, check.io, stream);
    defer check.gpa.free(raw);
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MalformedResponse;
    if (raw.len < 12 or !std.mem.startsWith(u8, raw, "HTTP/1.1 ")) return error.MalformedResponse;
    const status = try std.fmt.parseInt(u16, raw[9..12], 10);
    return .{ .status = status, .body = try check.gpa.dupe(u8, raw[head_end + 4 ..]) };
}

fn readAll(gpa: std.mem.Allocator, io: Io, stream: Io.net.Stream) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        var chunk: [4096]u8 = undefined;
        var vecs: [1][]u8 = .{chunk[0..]};
        const n = io.vtable.netRead(io.userdata, stream.socket.handle, &vecs) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
        if (out.items.len > 1 << 20) return error.ResponseTooLarge;
    }
    return out.toOwnedSlice(gpa);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// A compact HS256 JWS over `payload_json` with the check's key.
fn token(gpa: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const h = try gpa.alloc(u8, enc.calcSize(header.len));
    defer gpa.free(h);
    _ = enc.encode(h, header);
    const p = try gpa.alloc(u8, enc.calcSize(payload_json.len));
    defer gpa.free(p);
    _ = enc.encode(p, payload_json);
    const signing_input = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ h, p });
    defer gpa.free(signing_input);
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signing_input, jwt_key);
    var sig: [64]u8 = undefined;
    const s = enc.encode(&sig, &mac);
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ signing_input, s });
}

// ---------------------------------------------------------------------------
// The loopback upstream
// ---------------------------------------------------------------------------

const Upstream = struct {
    io_backend: Io.Threaded,
    listener: Io.net.Server,
    thread: std.Thread,
    reply: std.atomic.Value(Reply) = .init(.ok),
    count: std.atomic.Value(usize) = .init(0),
    mutex: compat.Mutex = .{},
    last_seen: Seen = .{},

    const Reply = enum(u8) { ok, oversized, malformed };

    const Seen = struct {
        target_buf: [256]u8 = undefined,
        target_len: usize = 0,
        authorization_buf: [256]u8 = undefined,
        authorization_len: usize = 0,

        fn target(self: *const Seen) []const u8 {
            return self.target_buf[0..self.target_len];
        }

        fn authorization(self: *const Seen) []const u8 {
            return self.authorization_buf[0..self.authorization_len];
        }
    };

    fn start() !*Upstream {
        const self = try std.heap.page_allocator.create(Upstream);
        self.* = .{ .io_backend = Io.Threaded.init(std.heap.page_allocator, .{ .environ = .empty }), .listener = undefined, .thread = undefined };
        const address = try Io.net.IpAddress.parseIp4("127.0.0.1", upstream_port);
        self.listener = address.listen(self.io_backend.io(), .{ .reuse_address = true }) catch |err| {
            std.debug.print("error: cannot listen on 127.0.0.1:{d}, the port examples/tools names: {s}\n", .{ upstream_port, @errorName(err) });
            return err;
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *Upstream) void {
        const io = self.io_backend.io();
        if (connect(io, upstream_port)) |stream| {
            var buf: [64]u8 = undefined;
            var writer = stream.writer(io, &buf);
            writer.interface.writeAll("GET /__stop HTTP/1.1\r\n\r\n") catch {};
            writer.interface.flush() catch {};
            stream.close(io);
        } else |_| {}
        self.thread.join();
        self.listener.deinit(io);
        self.io_backend.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn setReply(self: *Upstream, reply: Reply) void {
        self.reply.store(reply, .release);
    }

    fn requestCount(self: *Upstream) usize {
        return self.count.load(.acquire);
    }

    fn last(self: *Upstream) Seen {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_seen;
    }

    fn serve(self: *Upstream) void {
        const io = self.io_backend.io();
        while (true) {
            var stream = self.listener.accept(io) catch return;
            defer stream.close(io);
            var head: [4096]u8 = undefined;
            var len: usize = 0;
            while (std.mem.indexOf(u8, head[0..len], "\r\n\r\n") == null and len < head.len) {
                var vecs: [1][]u8 = .{head[len..]};
                const n = io.vtable.netRead(io.userdata, stream.socket.handle, &vecs) catch break;
                if (n == 0) break;
                len += n;
            }
            const text = head[0..len];
            if (std.mem.startsWith(u8, text, "GET /__stop ")) return;
            self.record(text);
            self.answer(io, &stream) catch {};
        }
    }

    fn record(self: *Upstream, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_seen = .{};
        var lines = std.mem.splitSequence(u8, text, "\r\n");
        if (lines.next()) |request_line| {
            var parts = std.mem.splitScalar(u8, request_line, ' ');
            _ = parts.next();
            if (parts.next()) |t| {
                const n = @min(t.len, self.last_seen.target_buf.len);
                @memcpy(self.last_seen.target_buf[0..n], t[0..n]);
                self.last_seen.target_len = n;
            }
        }
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "authorization")) continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            const n = @min(value.len, self.last_seen.authorization_buf.len);
            @memcpy(self.last_seen.authorization_buf[0..n], value[0..n]);
            self.last_seen.authorization_len = n;
        }
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    fn answer(self: *Upstream, io: Io, stream: *Io.net.Stream) !void {
        var oversized_buf: [5000]u8 = undefined;
        const body: []const u8 = switch (self.reply.load(.acquire)) {
            .ok => "{\"status\":\"shipped\"}",
            .malformed => "{\"status\":\"lost-in-transit\"}",
            .oversized => blk: {
                @memset(&oversized_buf, 'x');
                break :blk &oversized_buf;
            },
        };
        var out_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &out_buf);
        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try writer.interface.writeAll(body);
        try writer.interface.flush();
    }
};
