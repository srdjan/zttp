//! `zttp verify <url>` - slice 1 of proof receipts. Third-party verifier
//! that anyone (CI, security scanner, partner integration, MCP host) can run
//! against any deployed zttp endpoint to confirm the contract claims it
//! returns are signed by whoever holds the build's private key.
//!
//! The `Zttp-Attest` response header holds only `sha256=<hex>`, the SHA-256 of
//! the compact JWS. The verifier fetches the JWS from `/.well-known/zttp-attest`
//! and checks that it matches the digest.
//!
//! Trust posture for slice 1: the JWS protected header carries the full
//! Ed25519 public key. The verifier validates the signature against that
//! embedded key, prints the key fingerprint, and (with `--trust-key <hex>`)
//! can pin against a known fingerprint. Identity binding lands in slice 2
//! (well-known endpoint plus transparency log).

const std = @import("std");
const writeAllFd = @import("posix_util.zig").writeAllFd;
const envelope = @import("attest/envelope.zig");
const attest_header_strings = @import("attest/header_strings.zig");

pub const exit_ok: u8 = 0;
pub const exit_arg_error: u8 = 1;
pub const exit_not_attested: u8 = 2;
pub const exit_signature_invalid: u8 = 3;
pub const exit_key_mismatch: u8 = 4;
pub const exit_http_error: u8 = 5;

pub const Options = struct {
    url: []const u8,
    trust_key_fingerprint_hex: ?[]const u8 = null,
    json_output: bool = false,
};

pub fn parseArgs(argv: []const []const u8) !Options {
    var url: ?[]const u8 = null;
    var trust_key: ?[]const u8 = null;
    var json_output = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--trust-key")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            trust_key = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--trust-key=")) {
            // Accept the `--trust-key=<hex>` form for parity with expert/deploy.
            trust_key = arg["--trust-key=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (url != null) return error.TooManyArguments;
            url = arg;
        } else {
            return error.UnknownArgument;
        }
    }

    if (url == null) return error.MissingArgument;
    if (trust_key) |k| {
        if (k.len != 64) return error.InvalidTrustKey;
        for (k) |c| {
            if (!std.ascii.isHex(c)) return error.InvalidTrustKey;
        }
    }
    return .{
        .url = url.?,
        .trust_key_fingerprint_hex = trust_key,
        .json_output = json_output,
    };
}

pub fn printHelp() !void {
    const help =
        \\zttp verify <url> [--trust-key <hex>] [--json]
        \\
        \\Fetches the URL and reads the Zttp-Attest response header, a SHA-256
        \\digest. Fetches the signed receipt from /.well-known/zttp-attest on the
        \\same origin and checks that it matches the digest. Validates its Ed25519
        \\signature against the embedded public key. Prints the signed
        \\contract claims on success. Without --trust-key the endpoint supplies the
        \\key, so the signer is not authenticated and the output says so.
        \\
        \\Options:
        \\  --trust-key <hex>  64-char SHA-256 fingerprint of the expected public
        \\                     key. Fails (exit 4) on mismatch.
        \\  --json             Emit the claims as a single JSON object on stdout.
        \\
        \\Exit codes:
        \\  0  signature valid (key pinned only when --trust-key matched)
        \\  1  argument error
        \\  2  endpoint did not return Zttp-Attest header
        \\  3  signature does not validate, receipt does not match the header digest,
        \\     or receipt format is not supported
        \\  4  key fingerprint does not match --trust-key
        \\  5  HTTP-level error (DNS, connect, status >= 400, including the receipt fetch)
        \\
    ;
    try writeAllFd(std.c.STDOUT_FILENO, help);
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !u8 {
    var io_backend = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer io_backend.deinit();

    const uri = parseHttpUri(opts.url) catch |err| return reportFetchError(err);

    const header_value = fetchAttestHeader(allocator, io_backend.io(), uri) catch |err| return reportFetchError(err);
    defer allocator.free(header_value);
    // The old header form holds a JWS; refuse it before the document fetch.
    if (!std.mem.startsWith(u8, header_value, attest_header_strings.attest_digest_prefix)) {
        writeStderr(verificationFailureMessage(error.UnsupportedAttestationVersion) orelse "verify: attestation format is not supported\n");
        return exit_signature_invalid;
    }
    const document_body = fetchAttestDocument(allocator, io_backend.io(), uri) catch |err| return reportFetchError(err);
    defer allocator.free(document_body);

    const attest_jws = attestationFromDocument(allocator, header_value, document_body) catch |err| {
        if (verificationFailureMessage(err)) |message| writeStderr(message) else writeStderrFmt("verify: {t}\n", .{err});
        return exit_signature_invalid;
    };
    defer allocator.free(attest_jws);

    var result = envelope.verify(allocator, attest_jws) catch |err| {
        if (verificationFailureMessage(err)) |message|
            writeStderr(message)
        else
            writeStderrFmt("verify: signature verification failed: {t}\n", .{err});
        return exit_signature_invalid;
    };
    defer result.deinit();

    // Reaching the output with a pin means the fingerprint matched.
    const pinned = opts.trust_key_fingerprint_hex != null;
    if (opts.trust_key_fingerprint_hex) |expected| {
        // Hex is case-insensitive, so compare case-insensitively: an uppercase
        // or mixed-case --trust-key copy of the (lowercase) fingerprint must
        // still match. A genuinely different key still fails closed.
        if (!std.ascii.eqlIgnoreCase(expected, &result.fingerprint_hex)) {
            writeStderrFmt(
                "verify: key fingerprint does not match --trust-key\n  expected: {s}\n  actual:   {s}\n",
                .{ expected, result.fingerprint_hex },
            );
            return exit_key_mismatch;
        }
    }

    if (opts.json_output) {
        try writeClaimsJson(allocator, opts.url, &result, pinned);
    } else {
        try writeClaimsHuman(allocator, opts.url, &result, pinned);
    }
    return exit_ok;
}

fn verificationFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.AttestationDigestMismatch => "verify: the attestation document does not match the response header\n",
        error.MalformedAttestationDocument => "verify: the attestation document is malformed\n",
        error.UnsupportedRuntimeAuthority => "verify: attestation claims retired runtime authority\n",
        error.UnsupportedAttestationVersion => "verify: attestation format is not supported; rebuild the artifact with this zttp version\n",
        else => null,
    };
}

fn reportFetchError(err: anyerror) u8 {
    switch (err) {
        error.UnsupportedScheme => writeStderr("verify: only http and https URLs are supported\n"),
        error.NotAttested => writeStderr("verify: endpoint did not return Zttp-Attest header\n"),
        error.HttpStatus => writeStderr("verify: HTTP request returned non-2xx status\n"),
        else => writeStderrFmt("verify: request failed: {t}\n", .{err}),
    }
    return switch (err) {
        error.UnsupportedScheme => exit_arg_error,
        error.NotAttested => exit_not_attested,
        else => exit_http_error,
    };
}

fn parseHttpUri(url: []const u8) error{UnsupportedScheme}!std.Uri {
    const uri = std.Uri.parse(url) catch return error.UnsupportedScheme;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return error.UnsupportedScheme;
    }
    return uri;
}

/// Fetch the URL, extract the Zttp-Attest header value (`sha256=<hex>`), return
/// an owned copy. The response body is discarded.
fn fetchAttestHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: std.Uri,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});

    const status = @backingInt(response.head.status);
    if (status < 200 or status >= 300) return error.HttpStatus;

    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, attest_header_strings.header_name_attest)) {
            const owned = try allocator.dupe(u8, header.value);
            // Drain body so the connection is left clean; we ignore the bytes.
            const reader = response.reader(&.{});
            _ = reader.discardRemaining() catch {};
            return owned;
        }
    }
    return error.NotAttested;
}

/// Longest `/.well-known/zttp-attest` body the verifier reads.
const max_document_bytes: usize = 8 * 1024 * 1024;

/// Fetch `/.well-known/zttp-attest` from the scheme, host, and port of `uri`,
/// without redirects. Return the owned body.
fn fetchAttestDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: std.Uri,
) ![]u8 {
    var document_uri = uri;
    document_uri.path = .{ .raw = "/.well-known/zttp-attest" };
    document_uri.query = null;
    document_uri.fragment = null;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, document_uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});

    const status = @backingInt(response.head.status);
    if (status < 200 or status >= 300) return error.HttpStatus;

    var body_transfer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var reader = response.readerDecompressing(&body_transfer, &decompress, &decompress_buf);
    return reader.allocRemaining(allocator, .limited(max_document_bytes));
}

/// Check the well-known document against the `Zttp-Attest` digest and return an
/// owned copy of its JWS. The header must be `sha256=<hex>`. Any other form
/// (the old JWS header) and any document `v` other than `envelope.version_tag`
/// is an unsupported version. The document JWS must hash to the header digest.
pub fn attestationFromDocument(
    allocator: std.mem.Allocator,
    header_value: []const u8,
    document_body: []const u8,
) (std.mem.Allocator.Error || error{ UnsupportedAttestationVersion, AttestationDigestMismatch, MalformedAttestationDocument })![]u8 {
    if (!std.mem.startsWith(u8, header_value, attest_header_strings.attest_digest_prefix)) return error.UnsupportedAttestationVersion;

    const Document = struct { v: []const u8, attest: []const u8 };
    var parsed = std.json.parseFromSlice(Document, allocator, document_body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedAttestationDocument,
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.v, envelope.version_tag)) return error.UnsupportedAttestationVersion;

    const expected = try attest_header_strings.attestDigest(allocator, parsed.value.attest);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, header_value)) return error.AttestationDigestMismatch;
    return allocator.dupe(u8, parsed.value.attest);
}

// TODO(slice 2): add a fixture-based integration test for `run()` that spins
// up a fake HTTP server emitting the digest header and the well-known document
// (with chips, empty chips, signature-tampered, key-mismatched,
// digest-mismatched) and asserts on the exit codes. Slice 1
// relies on the `parseArgs` unit tests, the `envelope.verify` unit tests, and
// manual end-to-end runs documented in the slice-1 spec.

fn renderClaimsHuman(
    allocator: std.mem.Allocator,
    url: []const u8,
    result: *const envelope.VerifyResult,
    pinned: bool,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{s}: {s}
        \\{s}  signed_at is the signer's own claim; no host is bound to this claim.
        \\  This checks provenance, not proof. The endpoint returns a signed
        \\  claim about an artifact; it does not return the artifact. Nothing
        \\  here reconstructed an obligation or checked a derivation, so no
        \\  proof or policy acceptance is reported. For that, check the
        \\  artifact itself: `zttp proofs verify <bundle-dir> --require-proof`.
        \\
        \\  key fingerprint:  {s}
        \\  compiler version: {s}
        \\  signed at:        {d} (unix)
        \\  contract sha256:  {s}
        \\  bytecode sha256:  {s}
        \\  executable root:  {s}
        \\  policy sha256:    {s}
        \\  capability hash:  {s}
        \\  routes count:     {d}
        \\  claimed chips:    {s}
        \\  guarded categories: {s}
        \\  durable workflow: proof={s}, retrySafe={s}, idempotent={s}, faultCovered={s}
        \\
    ,
        .{
            if (pinned) "Signature verified" else "Signature valid against the key the endpoint supplied (key not pinned)",
            url,
            if (pinned) "" else "  pin it with --trust-key <fingerprint>\n",
            &result.fingerprint_hex,
            result.claims.compiler_version,
            result.claims.signed_at_unix,
            result.claims.contract_sha256,
            result.claims.bytecode_sha256,
            result.claims.executable_root_sha256,
            result.claims.policy_sha256,
            result.claims.capability_hash,
            result.claims.routes_count,
            if (result.claims.property_summary.len > 0) result.claims.property_summary else "(none)",
            if (result.claims.guarded_categories.len > 0) result.claims.guarded_categories else "(none)",
            "none",
            "false",
            "false",
            "false",
        },
    );
}

fn writeClaimsHuman(allocator: std.mem.Allocator, url: []const u8, result: *const envelope.VerifyResult, pinned: bool) !void {
    const out = try renderClaimsHuman(allocator, url, result, pinned);
    defer allocator.free(out);
    try writeAllFd(std.c.STDOUT_FILENO, out);
}

fn renderClaimsJson(allocator: std.mem.Allocator, url: []const u8, result: *const envelope.VerifyResult, pinned: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var json: std.json.Stringify = .{ .writer = &aw.writer };

    try json.beginObject();
    try json.objectField("url");
    try json.write(url);
    try json.objectField("keyFingerprint");
    try json.write(&result.fingerprint_hex);
    try json.objectField("compilerVersion");
    try json.write(result.claims.compiler_version);
    try json.objectField("signedAt");
    try json.write(result.claims.signed_at_unix);
    try json.objectField("contractSha256");
    try json.write(result.claims.contract_sha256);
    try json.objectField("bytecodeSha256");
    try json.write(result.claims.bytecode_sha256);
    try json.objectField("executableRootSha256");
    try json.write(result.claims.executable_root_sha256);
    // What this command established, named so a consumer of the JSON cannot
    // read a signature check as an acceptance. The endpoint returns a claim,
    // not the bytes, so the semantic states stay out of reach here.
    try json.objectField("assurance");
    try json.write("provenance_only");
    // False means the signer was not authenticated: the key came from the endpoint.
    try json.objectField("keyPinned");
    try json.write(pinned);
    try json.objectField("policySha256");
    try json.write(result.claims.policy_sha256);
    try json.objectField("capabilityHash");
    try json.write(result.claims.capability_hash);
    try json.objectField("coreProfileId");
    try json.write(result.claims.core_profile_id);
    try json.objectField("coreGrammarSha256");
    try json.write(result.claims.core_grammar_sha256);
    try json.objectField("semanticsSha256");
    try json.write(result.claims.semantics_sha256);
    try json.objectField("frontendProfileId");
    try json.write(@as(?[]const u8, null));
    try json.objectField("frontendGrammarSha256");
    try json.write(@as(?[]const u8, null));
    try json.objectField("routesCount");
    try json.write(result.claims.routes_count);
    try json.objectField("propertySummary");
    try json.write(result.claims.property_summary);
    try json.objectField("guardedCategories");
    try json.write(result.claims.guarded_categories);
    try json.objectField("durableWorkflowProofLevel");
    try json.write("none");
    try json.objectField("durableWorkflowRetrySafe");
    try json.write(false);
    try json.objectField("durableWorkflowIdempotent");
    try json.write(false);
    try json.objectField("durableWorkflowFaultCovered");
    try json.write(false);
    try json.endObject();
    try aw.writer.writeByte('\n');

    return try allocator.dupe(u8, aw.writer.buffered());
}

fn writeClaimsJson(allocator: std.mem.Allocator, url: []const u8, result: *const envelope.VerifyResult, pinned: bool) !void {
    const out = try renderClaimsJson(allocator, url, result, pinned);
    defer allocator.free(out);
    try writeAllFd(std.c.STDOUT_FILENO, out);
}

fn writeStderr(msg: []const u8) void {
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
}

fn writeStderrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDERR_FILENO, line.ptr, line.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseArgs: url only" {
    const opts = try parseArgs(&.{"http://example.com/"});
    try std.testing.expectEqualStrings("http://example.com/", opts.url);
    try std.testing.expect(opts.trust_key_fingerprint_hex == null);
    try std.testing.expect(!opts.json_output);
}

test "parseArgs: url with --json and --trust-key" {
    const opts = try parseArgs(&.{
        "https://example.com/api",
        "--json",
        "--trust-key",
        &@as([64:0]u8, @splat('a')),
    });
    try std.testing.expectEqualStrings("https://example.com/api", opts.url);
    try std.testing.expect(opts.json_output);
    try std.testing.expectEqualStrings(&@as([64:0]u8, @splat('a')), opts.trust_key_fingerprint_hex.?);
}

test "parseArgs: missing url errors" {
    try std.testing.expectError(error.MissingArgument, parseArgs(&.{}));
    try std.testing.expectError(error.MissingArgument, parseArgs(&.{"--json"}));
}

test "parseArgs: trust-key must be 64 hex chars" {
    try std.testing.expectError(error.InvalidTrustKey, parseArgs(&.{ "http://x", "--trust-key", "tooShort" }));
    try std.testing.expectError(error.InvalidTrustKey, parseArgs(&.{ "http://x", "--trust-key", &@as([64:0]u8, @splat('z')) }));
}

test "parseArgs: --help signals via error" {
    try std.testing.expectError(error.HelpRequested, parseArgs(&.{"--help"}));
}

test "parseArgs: rejects multiple positional args" {
    try std.testing.expectError(error.TooManyArguments, parseArgs(&.{ "http://a", "http://b" }));
}

test "the predecessor attestation error tells the caller to rebuild" {
    const message = verificationFailureMessage(error.UnsupportedAttestationVersion) orelse
        return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, message, "rebuild") != null);
}

test "retired attestation claims have an exact verification message" {
    const message = verificationFailureMessage(error.UnsupportedRuntimeAuthority) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(
        "verify: attestation claims retired runtime authority\n",
        message,
    );
}

test "renderClaimsJson uses JSON string escaping" {
    const testing = std.testing;

    var result = envelope.VerifyResult{
        .claims = .{
            .contract_sha256 = &@as([64:0]u8, @splat('a')),
            .bytecode_sha256 = &@as([64:0]u8, @splat('b')),
            .policy_sha256 = &@as([64:0]u8, @splat('c')),
            .capability_hash = &@as([64:0]u8, @splat('d')),
            .core_profile_id = "zts-model-1",
            .core_grammar_sha256 = &@as([64:0]u8, @splat('1')),
            .semantics_sha256 = &@as([64:0]u8, @splat('2')),
            .compiler_version = "zttp\"dev\\test",
            .signed_at_unix = 1_700_000_000,
            .property_summary = "quote\" slash\\ newline\n",
            .guarded_categories = "env,cache",
            .routes_count = 2,
        },
        .public_key = @as([std.crypto.sign.Ed25519.PublicKey.encoded_length]u8, @splat(0)),
        .fingerprint_hex = @splat('f'),
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer result.deinit();

    const out = try renderClaimsJson(testing.allocator, "https://example.test/a?x=\"y\"", &result, false);
    defer testing.allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqualStrings("https://example.test/a?x=\"y\"", root.get("url").?.string);
    try testing.expectEqualStrings("zttp\"dev\\test", root.get("compilerVersion").?.string);
    try testing.expectEqualStrings("zts-model-1", root.get("coreProfileId").?.string);
    try testing.expect(root.get("frontendProfileId").? == .null);
    try testing.expect(root.get("frontendGrammarSha256").? == .null);
    try testing.expectEqualStrings("quote\" slash\\ newline\n", root.get("propertySummary").?.string);
    try testing.expectEqualStrings("env,cache", root.get("guardedCategories").?.string);
    try testing.expectEqualStrings("provenance_only", root.get("assurance").?.string);
    try testing.expect(!root.get("keyPinned").?.bool);
    try testing.expect(root.get("propertySummary").? == .string);
    try testing.expectEqualStrings("none", root.get("durableWorkflowProofLevel").?.string);
    try testing.expect(!root.get("durableWorkflowRetrySafe").?.bool);
    try testing.expect(!root.get("durableWorkflowIdempotent").?.bool);
    try testing.expect(!root.get("durableWorkflowFaultCovered").?.bool);
    try testing.expectEqual(@as(i64, 1_700_000_000), root.get("signedAt").?.integer);
    try testing.expectEqual(@as(i64, 2), root.get("routesCount").?.integer);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "renderClaimsHuman keeps static guarded categories separate from claimed chips" {
    const testing = std.testing;
    var result = envelope.VerifyResult{
        .claims = .{
            .contract_sha256 = &@as([64:0]u8, @splat('a')),
            .bytecode_sha256 = &@as([64:0]u8, @splat('b')),
            .policy_sha256 = &@as([64:0]u8, @splat('c')),
            .capability_hash = &@as([64:0]u8, @splat('d')),
            .core_profile_id = "zts-model-1",
            .core_grammar_sha256 = &@as([64:0]u8, @splat('1')),
            .semantics_sha256 = &@as([64:0]u8, @splat('2')),
            .compiler_version = "test",
            .signed_at_unix = 7,
            .property_summary = "pure",
            .guarded_categories = "",
            .routes_count = 1,
        },
        .public_key = @as([std.crypto.sign.Ed25519.PublicKey.encoded_length]u8, @splat(0)),
        .fingerprint_hex = @splat('f'),
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer result.deinit();

    const out = try renderClaimsHuman(testing.allocator, "https://example.test", &result, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "Signature valid against the key the endpoint supplied (key not pinned): https://example.test\n" ++
            "  pin it with --trust-key <fingerprint>\n" ++
            "  signed_at is the signer's own claim; no host is bound to this claim.\n" ++
            "  This checks provenance, not proof. The endpoint returns a signed\n" ++
            "  claim about an artifact; it does not return the artifact. Nothing\n" ++
            "  here reconstructed an obligation or checked a derivation, so no\n" ++
            "  proof or policy acceptance is reported. For that, check the\n" ++
            "  artifact itself: `zttp proofs verify <bundle-dir> --require-proof`.\n" ++
            "\n" ++
            "  key fingerprint:  " ++ &@as([64:0]u8, @splat('f')) ++ "\n" ++
            "  compiler version: test\n" ++
            "  signed at:        7 (unix)\n" ++
            "  contract sha256:  " ++ &@as([64:0]u8, @splat('a')) ++ "\n" ++
            "  bytecode sha256:  " ++ &@as([64:0]u8, @splat('b')) ++ "\n" ++
            "  executable root:  " ++ &@as([64:0]u8, @splat('0')) ++ "\n" ++
            "  policy sha256:    " ++ &@as([64:0]u8, @splat('c')) ++ "\n" ++
            "  capability hash:  " ++ &@as([64:0]u8, @splat('d')) ++ "\n" ++
            "  routes count:     1\n" ++
            "  claimed chips:    pure\n" ++
            "  guarded categories: (none)\n" ++
            "  durable workflow: proof=none, retrySafe=false, idempotent=false, faultCovered=false\n",
        out,
    );

    result.claims.guarded_categories = "env,egress,cache,sql";
    const guarded = try renderClaimsHuman(testing.allocator, "https://example.test", &result, false);
    defer testing.allocator.free(guarded);
    try testing.expectEqualStrings(
        "Signature valid against the key the endpoint supplied (key not pinned): https://example.test\n" ++
            "  pin it with --trust-key <fingerprint>\n" ++
            "  signed_at is the signer's own claim; no host is bound to this claim.\n" ++
            "  This checks provenance, not proof. The endpoint returns a signed\n" ++
            "  claim about an artifact; it does not return the artifact. Nothing\n" ++
            "  here reconstructed an obligation or checked a derivation, so no\n" ++
            "  proof or policy acceptance is reported. For that, check the\n" ++
            "  artifact itself: `zttp proofs verify <bundle-dir> --require-proof`.\n" ++
            "\n" ++
            "  key fingerprint:  " ++ &@as([64:0]u8, @splat('f')) ++ "\n" ++
            "  compiler version: test\n" ++
            "  signed at:        7 (unix)\n" ++
            "  contract sha256:  " ++ &@as([64:0]u8, @splat('a')) ++ "\n" ++
            "  bytecode sha256:  " ++ &@as([64:0]u8, @splat('b')) ++ "\n" ++
            "  executable root:  " ++ &@as([64:0]u8, @splat('0')) ++ "\n" ++
            "  policy sha256:    " ++ &@as([64:0]u8, @splat('c')) ++ "\n" ++
            "  capability hash:  " ++ &@as([64:0]u8, @splat('d')) ++ "\n" ++
            "  routes count:     1\n" ++
            "  claimed chips:    pure\n" ++
            "  guarded categories: env,egress,cache,sql\n" ++
            "  durable workflow: proof=none, retrySafe=false, idempotent=false, faultCovered=false\n",
        guarded,
    );
}

test "renderClaimsHuman renders in full past 4096 bytes" {
    const testing = std.testing;
    const long = try testing.allocator.alloc(u8, 5000);
    defer testing.allocator.free(long);
    @memset(long, 'x');
    var result = envelope.VerifyResult{
        .claims = .{
            .contract_sha256 = &@as([64:0]u8, @splat('a')),
            .bytecode_sha256 = &@as([64:0]u8, @splat('b')),
            .policy_sha256 = &@as([64:0]u8, @splat('c')),
            .capability_hash = &@as([64:0]u8, @splat('d')),
            .core_profile_id = "zts-model-1",
            .core_grammar_sha256 = &@as([64:0]u8, @splat('1')),
            .semantics_sha256 = &@as([64:0]u8, @splat('2')),
            .compiler_version = "test",
            .signed_at_unix = 7,
            .property_summary = long,
            .guarded_categories = "",
            .routes_count = 1,
        },
        .public_key = @as([std.crypto.sign.Ed25519.PublicKey.encoded_length]u8, @splat(0)),
        .fingerprint_hex = @splat('f'),
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer result.deinit();

    const out = try renderClaimsHuman(testing.allocator, "https://example.test", &result, false);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 4096);
    try testing.expect(std.mem.indexOf(u8, out, long) != null);
    try testing.expect(std.mem.endsWith(u8, out, "faultCovered=false\n"));
}

test "a pinned key is reported as pinned in human and JSON output" {
    const testing = std.testing;
    var result = envelope.VerifyResult{
        .claims = .{
            .contract_sha256 = &@as([64:0]u8, @splat('a')),
            .bytecode_sha256 = &@as([64:0]u8, @splat('b')),
            .policy_sha256 = &@as([64:0]u8, @splat('c')),
            .capability_hash = &@as([64:0]u8, @splat('d')),
            .core_profile_id = "zts-model-1",
            .core_grammar_sha256 = &@as([64:0]u8, @splat('1')),
            .semantics_sha256 = &@as([64:0]u8, @splat('2')),
            .compiler_version = "test",
            .signed_at_unix = 7,
            .property_summary = "pure",
            .guarded_categories = "",
            .routes_count = 1,
        },
        .public_key = @as([std.crypto.sign.Ed25519.PublicKey.encoded_length]u8, @splat(0)),
        .fingerprint_hex = @splat('f'),
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer result.deinit();

    const human = try renderClaimsHuman(testing.allocator, "https://example.test", &result, true);
    defer testing.allocator.free(human);
    try testing.expect(std.mem.startsWith(
        u8,
        human,
        "Signature verified: https://example.test\n" ++
            "  signed_at is the signer's own claim; no host is bound to this claim.\n",
    ));
    try testing.expect(std.mem.indexOf(u8, human, "not pinned") == null);

    const json = try renderClaimsJson(testing.allocator, "https://example.test", &result, true);
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("keyPinned").?.bool);
}

const test_digest_header = "sha256=300a2664bcbaa90b9eaceffbb7e40f019a2cc9b050b7bc8d148d4cd7c28df5d9";

test "attestationFromDocument returns the JWS when the digest matches" {
    const jws = try attestationFromDocument(
        std.testing.allocator,
        test_digest_header,
        "{\"v\":\"zttp-attest-v5\",\"attest\":\"h.p.s\",\"contract\":{}}",
    );
    defer std.testing.allocator.free(jws);
    try std.testing.expectEqualStrings("h.p.s", jws);
}

test "attestationFromDocument refuses a digest that does not match the document" {
    try std.testing.expectError(error.AttestationDigestMismatch, attestationFromDocument(
        std.testing.allocator,
        test_digest_header,
        "{\"v\":\"zttp-attest-v5\",\"attest\":\"h.p.x\",\"contract\":{}}",
    ));
}

test "attestationFromDocument refuses a header that holds a JWS" {
    try std.testing.expectError(error.UnsupportedAttestationVersion, attestationFromDocument(
        std.testing.allocator,
        "h.p.s",
        "{\"v\":\"zttp-attest-v5\",\"attest\":\"h.p.s\",\"contract\":{}}",
    ));
}

test "attestationFromDocument refuses a document with another version" {
    try std.testing.expectError(error.UnsupportedAttestationVersion, attestationFromDocument(
        std.testing.allocator,
        test_digest_header,
        "{\"v\":\"zttp-attest-v4\",\"attest\":\"h.p.s\",\"contract\":{}}",
    ));
}

test "attestationFromDocument refuses a document that is not an attestation document" {
    try std.testing.expectError(error.MalformedAttestationDocument, attestationFromDocument(
        std.testing.allocator,
        test_digest_header,
        "{\"v\":\"zttp-attest-v5\"}",
    ));
}

test "the digest mismatch message names the response header" {
    try std.testing.expectEqualStrings(
        "verify: the attestation document does not match the response header\n",
        verificationFailureMessage(error.AttestationDigestMismatch) orelse return error.TestExpectedEqual,
    );
}
