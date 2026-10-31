//! HTTP Server with JavaScript Request Handlers
//!
//! Architecture:
//! - Threaded HTTP/1.1 using Zig's std.Io.Threaded backend
//! - Per-request JS context isolation via LockFreePool-backed handler pool
//! - Deno-compatible handler API

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine_adapter.zig");
const runtime_config_mod = @import("runtime_config.zig");
const Io = std.Io;
const net = std.Io.net;
const HandlerPool = engine.HandlerPool;
const RuntimeConfig = engine.RuntimeConfig;
const execution_spec = @import("execution_spec.zig");
const http_parser = @import("http_parser.zig");
const http_types = @import("http_types.zig");
const HttpRequestView = http_types.HttpRequestView;
const HttpResponse = http_types.HttpResponse;
const HttpHeader = http_types.HttpHeader;
const QueryParam = http_types.QueryParam;

const contract_runtime = @import("contract_runtime.zig");
const fault_explain = @import("fault_explain.zig");
const incident_log = @import("incident_log.zig");
const RuntimeContract = contract_runtime.RuntimeContract;
const ValidatedRuntimeContract = contract_runtime.ValidatedRuntimeContract;
const proof_adapter = @import("proof_adapter.zig");
const attest_header_strings = @import("attest/header_strings.zig");
const pcc = @import("zttp_proof_checker");
const activation = @import("server_activation.zig");
const attest_envelope = @import("attest/envelope.zig");
const attest_well_known = @import("attest/well_known.zig");
const self_extract = @import("self_extract.zig");
const security_logger_mod = @import("security_logger.zig");
const SecurityLogger = security_logger_mod.SecurityLogger;
const response_mod = @import("server_response.zig");
const static_mod = @import("server_static.zig");
const resolveStaticFile = static_mod.resolveStaticFile;
const io_mod = @import("posix_util.zig");
const unixMillisNow = io_mod.unixMillisNow;
const writeAllFd = io_mod.writeAllFd;
const createUnixSocketPair = io_mod.createUnixSocketPair;
const writevAllFd = io_mod.writevAllFd;
const defaultPoolSize = io_mod.defaultPoolSize;
const initIoBackend = io_mod.initIoBackend;
const etagMatchesIfNoneMatch = http_types.etagMatchesIfNoneMatch;
const findHeaderValue = http_types.findHeaderValue;
const formatHttpError = response_mod.formatHttpError;
const formatStaticNotModified = response_mod.formatStaticNotModified;
const formatStaticOkHeader = response_mod.formatStaticOkHeader;
const buildDynamicResponseHeader = response_mod.buildDynamicResponseHeader;
const formatWellKnownHeaders = response_mod.formatWellKnownHeaders;

const FastHeaderSlots = http_parser.FastHeaderSlots;
const findHeaderEnd = http_parser.findHeaderEnd;
const parseRequestLineBorrowed = http_parser.parseRequestLineBorrowed;
const parseHeadersFromLinesBorrowed = http_parser.parseHeadersFromLinesBorrowed;
const parseQueryString = http_parser.parseQueryString;
const splitHeaderLine = http_parser.splitHeaderLine;
const parseContentLength = http_parser.parseContentLength;

const readFilePosix = engine.readFile;

const server_connection_pool_mod = @import("server_connection_pool.zig");
const ConnectionPool = server_connection_pool_mod.ConnectionPool;

// ============================================================================
// Server Configuration
// ============================================================================

pub const ServerConfig = struct {
    /// Port to listen on
    port: u16 = 8080,

    /// Host to bind to
    host: []const u8 = "127.0.0.1",

    /// JS handler script path or inline code
    handler: HandlerSource,

    /// Maximum request body size (default 1MB)
    max_body_size: usize = 1024 * 1024,

    /// Maximum number of headers per request (DOS protection)
    max_headers: usize = 64,

    /// Maximum URL length in the request line. URLs exceeding this cap are
    /// rejected with HTTP 414 before any allocation proportional to the URL.
    max_url_length: usize = http_parser.DEFAULT_MAX_URL_LENGTH,

    /// Maximum query-string length (the part after '?'). Queries exceeding
    /// this cap are rejected with HTTP 414 before any allocation. Defaults
    /// match the URL cap; configure larger values only for APIs that
    /// legitimately require long query strings.
    max_query_length: usize = http_parser.DEFAULT_MAX_QUERY_LENGTH,

    /// Request timeout in milliseconds
    timeout_ms: u32 = 30_000,

    /// JS runtime configuration
    runtime_config: RuntimeConfig = .{},

    /// Number of runtime instances in pool (0 = auto)
    pool_size: usize = 0,

    /// Log requests to stdout
    log_requests: bool = true,

    /// Static file directory (null = disabled)
    static_dir: ?[]const u8 = null,

    /// Enable HTTP keep-alive connections
    keep_alive: bool = true,

    /// Keep-alive idle timeout in milliseconds (max time between requests).
    /// A connection idling between requests is closed after this long;
    /// timeout_ms still bounds receiving each request once its first byte
    /// arrives.
    keep_alive_timeout_ms: u32 = 5_000,

    /// Maximum requests per keep-alive connection (0 = unlimited)
    keep_alive_max_requests: u32 = 100,

    /// Max time to wait for a runtime from the pool (0 = fail immediately)
    pool_wait_timeout_ms: u32 = 5000, // Wait up to 5s for pool slot

    /// Embedded contract JSON (from self-extracting binary).
    /// When present, enables contract-aware runtime behavior:
    /// startup env validation, route pre-filtering, property logging.
    contract_json: ?[]const u8 = null,

    /// Compact JWS (slice 1 of proof receipts) embedded by `zttp compile
    /// --attest`. When present alongside a validated contract, the server
    /// precomputes `Zttp-Proofs` and `Zttp-Attest` response headers once
    /// and emits them on every HTTP response.
    attestation_jws: ?[]const u8 = null,

    /// SHA-256 of the exact serialized runtime-policy section read from a
    /// self-extract payload. Null for dev/live reload, which has no section 4.
    policy_section_sha256: ?[32]u8 = null,
    /// Section 4 exactly as loaded, for the acceptance kernel's own decoder.
    policy_section: ?[]const u8 = null,

    /// The proof certificate, exactly as embedded. Null for dev, live reload,
    /// and any artifact built before certificates existed. A production
    /// artifact without one does not serve.
    certificate: ?[]const u8 = null,

    /// Skip startup env validation (for testing/development)
    skip_env_check: bool = false,

    /// When set, a background thread drains the global security event
    /// stream and appends JSONL records to this file path.
    security_log_path: ?[]const u8 = null,

    /// Operator override of the contract-derived pooling policy. Null
    /// means "use the policy derived from the contract properties".
    lifecycle_override: ?contract_runtime.PoolingPolicy = null,

    /// Replay and handler tests use this projection instead of the full server
    /// configuration. This keeps the serving surface out of their import graph.
    pub fn executionSpec(self: *const ServerConfig) execution_spec.ExecutionSpec {
        return .{ .handler = self.handler, .runtime_config = self.runtime_config };
    }
};

// Declared in `execution_spec.zig`, next to the `ExecutionSpec` that carries
// them below the server edge. Re-exported here because the whole CLI surface
// spells them `server.HandlerSource`.
pub const HandlerSource = execution_spec.HandlerSource;
pub const AppendedPayload = execution_spec.AppendedPayload;

// ============================================================================
// Server Implementation
// ============================================================================

/// Ignore SIGPIPE process-wide so a client that disconnects mid-response turns
/// a write into EPIPE (surfaced as error.BrokenPipe, an expected network error)
/// instead of delivering SIGPIPE, whose default disposition kills the whole
/// server. This covers every write path uniformly (writeAllFd, writevAllFd, and
/// the evented std writer) on both macOS and Linux, where a per-socket
/// SO_NOSIGPIPE / per-call MSG_NOSIGNAL would each leave gaps. Idempotent.
fn ignoreSigpipe() void {
    if (comptime builtin.target.os.tag == .windows) return;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

/// Process-wide shutdown flag. Set by the SIGTERM/SIGINT handler; polled by
/// the accept loop. Atomic so signal-handler stores are visible to the polling
/// thread without data races; .monotonic ordering is sufficient (no
/// memory-ordering guarantee is needed between the flag and pool state).
var g_shutdown_requested: std.atomic.Value(bool) = .init(false);

/// Listen on the public address with SO_REUSEADDR and without SO_REUSEPORT.
/// std sets both when `reuse_address` is true, and SO_REUSEPORT lets a second
/// server bind the same port and take the traffic. Clearing it after `listen`
/// works on macOS but not on Linux, so this builds the socket itself.
fn listenExclusive(address: net.IpAddress) !net.Server {
    const posix = std.posix;
    const rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return error.SystemResources;
    const fd: posix.socket_t = @intCast(rc);
    errdefer _ = posix.system.close(fd);
    _ = posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC));
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
    var storage: Io.Threaded.PosixAddress = undefined;
    var len = Io.Threaded.addressToPosix(&address, &storage);
    switch (posix.errno(posix.system.bind(fd, &storage.any, len))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ACCES => return error.AccessDenied,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        else => return error.Unexpected,
    }
    switch (posix.errno(posix.system.listen(fd, 128))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.Unexpected,
    }
    if (posix.errno(posix.system.getsockname(fd, &storage.any, &len)) != .SUCCESS) return error.Unexpected;
    return .{
        .socket = .{ .handle = fd, .address = Io.Threaded.addressFromPosix(&storage) },
        .options = if (net.Server.AcceptOptions != void) .{ .mode = .stream, .protocol = null },
    };
}

fn sigShutdownHandler(_: std.c.SIG) callconv(.c) void {
    g_shutdown_requested.store(true, .monotonic);
}

fn installShutdownSignals() void {
    if (comptime builtin.target.os.tag == .windows) return;
    // SA_RESETHAND: the first signal sets the graceful-shutdown flag. The
    // accept-loop wake thread opens a loopback connection so a blocked accept
    // observes it; a second SIGINT/SIGTERM retains the usual hard-stop escape.
    var act = std.posix.Sigaction{
        .handler = .{ .handler = sigShutdownHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

pub const Server = struct {
    config: ServerConfig,
    allocator: std.mem.Allocator,
    io_backend: IoBackend,
    evented_ready: bool,
    listener: ?net.Server,
    pool: ?HandlerPool,
    handler_code: []const u8,
    handler_filename: []const u8,
    /// Owned source backing, including an initial file load. Borrowed inline
    /// and embedded inputs never enter these owners. Retire only after swap.
    source_generation: ?SourceGeneration = null,
    superseded_source: ?SourceGeneration = null,
    embedded_bytecode: ?[]const u8,
    runtime_dep_bytecodes: ?[]const []const u8,
    running: std.atomic.Value(bool),
    request_count: std.atomic.Value(u64),
    conn_pool: ?*ConnectionPool,
    contract: ?ValidatedRuntimeContract,
    proof_cache: ?proof_adapter.ProofCache,
    /// The promotion an accepted certificate earned. Null until the acceptance
    /// kernel says otherwise, and null again after any live swap: the swapped
    /// handler is not the artifact the certificate described.
    proof_checked: ?contract_runtime.ProofCheckedContract = null,
    /// Guards `contract`/`proof_cache` against the live-reload watcher thread
    /// freeing+rebuilding them (`replaceContractLocked`) while worker threads read
    /// them mid-request. Only engaged when `reload_active` is set, so the
    /// production path (no swaps) takes no lock.
    contract_lock: engine.RwLock = .{},
    /// True once live reload (`--watch`) is wired up and may call
    /// `replaceSourceGeneration` concurrently with request handling.
    reload_active: bool = false,
    /// Opt-in soundness-incident log fd, opened once at startup from
    /// `config.runtime_config.incident_log_path` and shared with pooled runtimes
    /// through their config. Server-lifetime; closed in deinit after the pool drains.
    incident_log_fd: ?std.c.fd_t = null,
    security_logger: ?*SecurityLogger,
    /// Precomputed `Zttp-Proofs` and `Zttp-Attest` header strings, built
    /// once in `start` when both a validated contract and an attestation JWS
    /// are present. Null otherwise; both response paths skip the writes.
    attestation_headers: ?attest_header_strings.HeaderStrings,
    /// Precomputed `GET /.well-known/zttp-attest` body, built alongside
    /// `attestation_headers`. Null on unattested builds; the route falls
    /// through to the normal handler path.
    well_known_doc: ?attest_well_known.Doc,
    const Self = @This();
    const IoBackend = Io.Threaded;

    const SourceGeneration = struct {
        allocator: std.mem.Allocator,
        code: []const u8,
        filename: []const u8,
        owns_filename: bool = false,

        fn deinit(self: *SourceGeneration) void {
            self.allocator.free(self.code);
            if (self.owns_filename) self.allocator.free(self.filename);
        }
    };

    /// A source candidate owns its source/name and runtime contract. Its policy
    /// BORROWS the analyzed HandlerContract/configured policy until installation
    /// returns; keep those owners alive until this candidate is retired. The
    /// pool deep-copies the policy before publishing any generation change.
    /// This is source/development evidence, never an accepted artifact proof.
    pub const SourceCandidate = struct {
        source: ?SourceGeneration,
        contract: ?ValidatedRuntimeContract,
        policy: ?engine.RuntimePolicy,
        configured_policy_checked: bool,

        pub fn deinit(self: *SourceCandidate) void {
            if (self.source) |*source| source.deinit();
            if (self.contract) |*contract| contract.deinit();
            self.source = null;
            self.contract = null;
            self.policy = null;
        }
    };

    pub fn prepareSourceGeneration(
        self: *Self,
        source_allocator: std.mem.Allocator,
        code: *?[]const u8,
        filename: []const u8,
        contract: ?*const engine.HandlerContract,
        configured: ?*const engine.HandlerPolicy,
    ) !SourceCandidate {
        try activation.requireSourceSwap(false, contract, configured != null);
        const bytes = code.* orelse return error.MissingHandlerSource;
        const owned_filename = try source_allocator.dupe(u8, filename);
        errdefer source_allocator.free(owned_filename);
        var validated: ?ValidatedRuntimeContract = null;
        if (contract) |hc| {
            const raw = try contract_runtime.fromHandlerContract(self.allocator, hc);
            validated = try contract_runtime.validate(raw, .{});
        }
        // Every fallible preparation succeeded. Ownership now leaves the caller,
        // including when a later no-pool/refusal path destroys this candidate.
        code.* = null;
        return .{
            .source = .{ .allocator = source_allocator, .code = bytes, .filename = owned_filename, .owns_filename = true },
            .contract = validated,
            .policy = if (contract) |hc| self.stageDevCapabilityPolicy(hc, configured) else null,
            .configured_policy_checked = configured != null,
        };
    }

    pub fn replaceSourceGeneration(self: *Self, candidate: *SourceCandidate) !usize {
        // Requests acquire contract then runtime-init. Use the same order, and
        // keep the metadata lock until code, policy and metadata all agree.
        self.contract_lock.lock();
        defer self.contract_lock.unlock();
        const pool = if (self.pool) |*p| p else return error.NoHandlerPool;
        const source = candidate.source orelse return error.MissingHandlerSource;
        try activation.requireSourceSwap(self.generationIsGuarded(), null, candidate.configured_policy_checked);
        const invalidated = try pool.reloadSourceGeneration(source.code, source.filename, candidate.policy, self.sourceServingSettings());
        // Pool preparation is the final fallible operation. It does not read
        // the retired source under runtime-init before any backing is freed.
        if (self.superseded_source) |*retired| retired.deinit();
        self.superseded_source = self.source_generation;
        self.source_generation = source;
        candidate.source = null;
        self.handler_code = source.code;
        self.handler_filename = source.filename;
        self.embedded_bytecode = null;
        self.runtime_dep_bytecodes = null;
        self.replaceContractLocked(candidate.contract);
        candidate.contract = null;
        return invalidated;
    }

    /// Install the initial analyzed source contract/policy as one transition.
    /// On error the caller retains `contract`; on success the server owns it.
    pub fn installSourceContract(
        self: *Self,
        contract: ValidatedRuntimeContract,
        analyzed: *const engine.HandlerContract,
        configured: ?*const engine.HandlerPolicy,
    ) !void {
        self.contract_lock.lock();
        defer self.contract_lock.unlock();
        if (self.pool) |*pool| {
            try pool.installDevPolicyGeneration(
                self.stageDevCapabilityPolicy(analyzed, configured),
                engine.contractRequiresRuntimePolicyIndex(analyzed),
                self.sourceServingSettings(),
            );
        }

        self.replaceContractLocked(contract);
    }

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Self {
        // A disconnecting client must never take down the server with SIGPIPE.
        ignoreSigpipe();

        var cfg = config;
        if (cfg.pool_size == 0) {
            cfg.pool_size = defaultPoolSize();
        }

        // Load handler code (or use embedded bytecode)
        var embedded_bytecode: ?[]const u8 = null;
        var runtime_dep_bytecodes: ?[]const []const u8 = null;
        const handler_code, const handler_filename = switch (cfg.handler) {
            .inline_code => |code| .{ code, "<inline>" },
            .prepared_eval => |source| .{ source.code, "<inline>" },
            .file_path => |path| blk: {
                const source = try readFilePosix(allocator, path, 10 * 1024 * 1024);
                break :blk .{ source, path };
            },
            .embedded_bytecode => |bytecode| blk: {
                // Embedded bytecode from build-time compilation
                embedded_bytecode = bytecode;
                // Handler code is not needed when using embedded bytecode,
                // but the tuple needs a value, so it holds an empty placeholder
                break :blk .{ "", "<embedded>" };
            },
            .appended_payload => |payload| blk: {
                // Bytecode extracted from self-extracting binary at runtime
                embedded_bytecode = payload.bytecode;
                runtime_dep_bytecodes = payload.dep_bytecodes;
                break :blk .{ "", "<appended>" };
            },
        };

        return Self{
            .config = cfg,
            .allocator = allocator,
            .io_backend = undefined,
            .evented_ready = false,
            .listener = null,
            .pool = null,
            .handler_code = handler_code,
            .handler_filename = handler_filename,
            .source_generation = if (cfg.handler == .file_path) .{
                .allocator = allocator,
                .code = handler_code,
                .filename = handler_filename,
            } else null,
            .embedded_bytecode = embedded_bytecode,
            .runtime_dep_bytecodes = runtime_dep_bytecodes,
            .running = std.atomic.Value(bool).init(false),
            .request_count = std.atomic.Value(u64).init(0),
            .conn_pool = null,
            .contract = null,
            .proof_cache = null,
            .security_logger = null,
            .attestation_headers = null,
            .well_known_doc = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Stop connection pool first (if using thread pool mode)
        if (self.conn_pool) |cp| cp.deinit();

        if (self.pool) |*p| p.deinit();
        // Pool drained: no runtime can still be writing to the incident log fd.
        if (self.incident_log_fd) |fd| std.Io.Threaded.closeFd(fd);
        if (self.proof_cache) |*pc| pc.deinit();
        self.clearProofChecked();
        if (self.contract) |*c| c.deinit();
        if (self.attestation_headers) |*ah| ah.deinit(self.allocator);
        if (self.well_known_doc) |*wkd| wkd.deinit(self.allocator);
        if (self.security_logger) |logger| logger.deinit();
        engine.deinitSecurityEvents();
        if (self.evented_ready) {
            const io = self.io_backend.io();
            if (self.listener) |*l| l.deinit(io);
            self.io_backend.deinit();
        }

        // Runtime readers drained above; each source uses its original allocator.
        if (self.source_generation) |*source| source.deinit();
        if (self.superseded_source) |*source| source.deinit();
    }

    /// Whether the installed generation depends on a runtime guard decision.
    ///
    /// Such a generation is a tuple - executable root, contract, residual plan,
    /// policy - that one acceptance run established together. A live swap
    /// replaces the executable without re-running acceptance, so it cannot
    /// produce that tuple, and the swap is refused rather than allowed to leave
    /// a new handler standing on the old policy's coverage.
    fn clearProofChecked(self: *Self) void {
        self.proof_checked = null;
    }

    pub fn generationIsGuarded(self: *const Self) bool {
        const promoted = self.proof_checked orelse return false;
        return promoted.guards.required > 0;
    }

    /// Caller holds contract_lock, or is still in single-threaded startup.
    fn replaceContractLocked(self: *Self, new_contract: ?ValidatedRuntimeContract) void {
        if (self.contract) |*contract| contract.deinit();
        self.contract = new_contract;
        // Source analysis is not acceptance. Discard all authority and cached
        // values belonging to the previous artifact, including fault facts.
        self.clearProofChecked();
        if (self.proof_cache) |*cache| cache.deinit();
        self.proof_cache = null;
        self.clearAttestation();
        _ = self.applyPoolingPolicy();
    }

    const ServingSettings = struct {
        pooling: contract_runtime.PoolingPolicy,
        handler_proof: fault_explain.Proof = .{},
        cache_properties: ?contract_runtime.Properties = null,
        policy_index_required: bool,
    };

    /// Only accepted proof facts can enable proof-driven serving behavior.
    /// A decoded/validated contract supplies no authority to this derivation.
    fn servingSettings(self: *const Self, checked: ?*const contract_runtime.ProofCheckedContract) ServingSettings {
        var settings = ServingSettings{
            .pooling = self.config.lifecycle_override orelse contract_runtime.derivePoolingPolicy(checked),
            .policy_index_required = requiresRuntimePolicyIndex(
                self.config.runtime_config.runtime_policy_index_required,
                if (checked) |proof| proof.guards.required > 0 else false,
            ),
        };
        if (checked) |proof| {
            const properties = proof.properties;
            settings.handler_proof = .{
                .optional_safe = properties.optional_safe,
                .result_safe = properties.result_safe,
            };
            if ((properties.pure or (properties.deterministic and properties.read_only)) and !proof.reads_request_state) {
                settings.cache_properties = properties;
            }
        }
        return settings;
    }

    fn sourceServingSettings(self: *const Self) @import("runtime_pool.zig").ServingSettings {
        // Source analysis carries no accepted certificate, even when replacing
        // an artifact that had one. Preserve the operator's lifecycle override.
        const settings = self.servingSettings(null);
        return .{ .handler_proof = settings.handler_proof, .pooling_policy = settings.pooling };
    }

    /// Apply the same derived facts used at pool startup after a source change.
    /// Old runtimes retain their immutable config; new runtimes get fresh fault
    /// explanation facts and pooling behavior under the generation lock.
    fn applyPoolingPolicy(self: *Self) ?contract_runtime.PoolingPolicy {
        const pool = if (self.pool) |*p| p else return null;
        const settings = self.servingSettings(if (self.proof_checked) |*proof| proof else null);
        pool.setServingSettings(.{ .handler_proof = settings.handler_proof, .pooling_policy = settings.pooling });
        return settings.pooling;
    }

    fn clearAttestation(self: *Self) void {
        if (self.attestation_headers) |*ah| {
            ah.deinit(self.allocator);
            self.attestation_headers = null;
        }
        if (self.well_known_doc) |*wkd| {
            wkd.deinit(self.allocator);
            self.well_known_doc = null;
        }
    }

    /// Derive the full capability policy from a freshly compiled
    /// HandlerContract and push it onto the runtime pool (dev/serve live path
    /// only). Fail-closed on allocation failure so a proven-restricted handler
    /// never becomes permissive after a reload.
    pub fn setDevCapabilityPolicy(
        self: *Self,
        contract: *const engine.HandlerContract,
        configured: ?*const engine.HandlerPolicy,
    ) !void {
        const pool = if (self.pool) |*p| p else return;
        try pool.setDevCapabilityPolicyIndexed(
            self.stageDevCapabilityPolicy(contract, configured),
            engine.contractRequiresRuntimePolicyIndex(contract),
        );
    }

    /// Return the borrowed contract view. The pool deep-copies it into the new
    /// refcounted generation before this contract can be retired.
    pub fn stageDevCapabilityPolicy(
        _: *Self,
        contract: *const engine.HandlerContract,
        configured: ?*const engine.HandlerPolicy,
    ) engine.RuntimePolicy {
        return engine.contractRuntimePolicy(contract, configured);
    }

    pub fn start(self: *Self) !void {
        try initIoBackend(&self.io_backend, self.allocator);
        self.evented_ready = true;

        // Process-wide security event stream. Emits to an uninitialized
        // stream are silent no-ops, so this just sizes the ring once.
        try engine.initSecurityEvents(self.allocator, 128);

        if (self.config.security_log_path) |path| {
            self.security_logger = SecurityLogger.start(self.allocator, path) catch |err| {
                std.log.err("Failed to start security logger at '{s}': {}", .{ path, err });
                return err;
            };
            std.log.info("Security events -> {s}", .{path});
        }

        try activation.activate(self);

        // Initialize runtime pool with embedded bytecode (must be set before prewarm)
        // Wire the server-level request timeout into the runtime config so the
        // interpreter's cooperative deadline check is enforced per handler call.
        var pool_rt_config = self.config.runtime_config;
        pool_rt_config.request_timeout_ms = self.config.timeout_ms;
        // Fault explanation, pooling and response-cache eligibility share one
        // derivation from accepted facts. Contract integrity alone earns none.
        const settings = self.servingSettings(if (self.proof_checked) |*proof| proof else null);
        pool_rt_config.handler_proof = settings.handler_proof;

        // Open the opt-in soundness-incident log and share the fd with every
        // pooled runtime (they write to it directly; O_APPEND keeps small lines
        // atomic). Failure is non-fatal: incidents still reach the error log.
        if (self.config.runtime_config.incident_log_path) |ilp| {
            self.incident_log_fd = incident_log.open(self.allocator, ilp) catch |err| fd_blk: {
                std.log.warn("Failed to open incident log '{s}': {}", .{ ilp, err });
                break :fd_blk null;
            };
            pool_rt_config.incident_log_fd = self.incident_log_fd;
        }

        // Either a checked source-policy contract or an accepted deployed
        // tuple can require authoritative bounded membership. Preserve the
        // source-policy bit installed before Server.init; the pool combines it
        // with the bit that `embedded_handler` carries.
        pool_rt_config.runtime_policy_index_required = settings.policy_index_required;

        var pool_timer = engine.Timer.start() catch null;
        self.pool = if (self.config.handler == .prepared_eval)
            try engine.initPreparedEvalHandlerPool(
                self.allocator,
                pool_rt_config,
                .{ .code = self.handler_code },
                self.handler_filename,
                self.config.pool_size,
                self.config.pool_wait_timeout_ms,
            )
        else
            try engine.initHandlerPool(
                self.allocator,
                pool_rt_config,
                self.handler_code,
                self.handler_filename,
                self.config.pool_size,
                self.config.pool_wait_timeout_ms,
                self.embedded_bytecode,
                self.runtime_dep_bytecodes,
            );
        if (comptime runtime_config_mod.debug_hooks_enabled) {
            if (pool_rt_config.debug_panic_path) |path| {
                self.pool.?.debug_panic_path = path;
            }
        }
        if (pool_timer) |*t| {
            const elapsed_ms = t.read() / std.time.ns_per_ms;
            const prewarm_count = @min(@as(usize, 2), self.config.pool_size);
            std.log.info("Pool ready: {d} slots, {d} prewarmed, {d}ms", .{
                self.config.pool_size, prewarm_count, elapsed_ms,
            });
        }

        if (self.contract) |*contract| {
            logContractSummary(contract);

            // Fail fast if proven env vars are missing
            if (!self.config.skip_env_check) {
                const missing = try contract_runtime.validateEnvVars(self.allocator, contract);
                defer self.allocator.free(missing);
                if (missing.len > 0) {
                    for (missing) |name| {
                        std.log.err("required env var not set: {s} (proven by contract)", .{name});
                    }
                    return error.MissingEnvVars;
                }
            }
        }

        if (settings.cache_properties) |properties| {
            self.proof_cache = proof_adapter.ProofCache.init(self.allocator, properties, .{});
            std.log.info("   Proof cache: enabled (handler proven deterministic + read_only + input-independent)", .{});
        } else if (self.proof_checked) |proof| {
            const properties = proof.properties;
            if ((properties.pure or (properties.deterministic and properties.read_only)) and proof.reads_request_state) {
                std.log.info("   Proof cache: disabled (handler reads request headers/body; method+URL key would be unsound)", .{});
            }
        }

        // Slice 1 of proof receipts: precompute the two response headers once.
        // The values are deterministic for a build, so per-request cost is one
        // memcpy per header into the response buffer.
        if (self.contract) |*contract| {
            if (self.config.attestation_jws) |jws| {
                // Fail-closed attestation: emit the Zttp-Proofs / Zttp-Attest
                // response headers and the /.well-known doc ONLY after the
                // embedded JWS is proven to bind to the artifact this server
                // actually loaded. `attest_envelope.verify` only proves the JWS
                // was signed - the binding checks below are what tie it to this
                // run. A tampered binary (swapped bytecode, or a contract.json
                // that no longer hashes to the signed claim) therefore emits no
                // attestation at all, so a third-party `zttp verify` reports it
                // unattested rather than trusting a signature over different
                // bytecode. Every failure path leaves attestation cleared.
                attest: {
                    const cj = self.config.contract_json orelse {
                        std.log.warn("attestation: JWS present but no embedded contract (attestation disabled)", .{});
                        break :attest;
                    };

                    var verify_result = attest_envelope.verify(self.allocator, jws) catch |err| {
                        std.log.warn("attestation: embedded JWS failed self-verify: {} (attestation disabled)", .{err});
                        break :attest;
                    };
                    defer verify_result.deinit();

                    // Bind to the bytecode actually loaded into the pool via the
                    // signed claim, not the contract's self-reported (tamperable)
                    // artifact field. No embedded bytecode means we cannot bind:
                    // fail closed.
                    const live_bytecode = self.embedded_bytecode orelse {
                        std.log.warn("attestation: JWS present but no embedded bytecode to bind it to (attestation disabled)", .{});
                        break :attest;
                    };
                    if (!activation.bytecodeMatchesClaim(live_bytecode, verify_result.claims.bytecode_sha256)) {
                        std.log.err("attestation: running bytecode does not match the signed claim (attestation disabled)", .{});
                        break :attest;
                    }

                    // Defense in depth: cross-check the verified claim hashes
                    // against the live loaded contract.
                    if (!activation.attestationClaimsMatchContract(verify_result.claims, contract.view())) {
                        std.log.err("attestation: signed JWS claims do not match the loaded contract hashes (attestation disabled)", .{});
                        break :attest;
                    }

                    // Fails closed if the served contract.json does not hash to
                    // the signed contractSha256 claim.
                    var doc = attest_well_known.build(
                        self.allocator,
                        cj,
                        jws,
                        verify_result.public_key,
                        verify_result.claims.contract_sha256,
                    ) catch |err| {
                        std.log.err("attestation: well-known build failed: {} (attestation disabled)", .{err});
                        break :attest;
                    };

                    // Binding proven: now emit the response headers. On failure,
                    // free the doc and emit nothing (break is not an error return,
                    // so an errdefer would not fire).
                    self.attestation_headers = attest_header_strings.build(
                        self.allocator,
                        contract.properties(),
                        jws,
                    ) catch |err| {
                        doc.deinit(self.allocator);
                        std.log.warn("attestation: failed to build response headers: {} (attestation disabled)", .{err});
                        break :attest;
                    };
                    self.well_known_doc = doc;
                    std.log.info("   Attestation: enabled (bound to running bytecode)", .{});
                }
            }
        }

        // Apply the lifecycle policy: CLI override wins, otherwise derive
        // from contract properties.
        if (self.applyPoolingPolicy()) |effective| {
            std.log.info("   Pooling policy: {s}", .{@tagName(effective)});
        }

        // Parse address and create listener
        const address = try net.IpAddress.parseIp4(self.config.host, self.config.port);

        self.listener = try listenExclusive(address);
        g_shutdown_requested.store(false, .monotonic);

        // Threaded backend: a fixed connection pool avoids per-connection
        // thread spawning while keeping the HTTP request path synchronous.
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const worker_count = cpu_count * 2;
        self.conn_pool = try ConnectionPool.init(self.allocator, self, worker_count);
        std.log.info("   Connection pool: {d} workers", .{worker_count});

        installShutdownSignals();
        self.running.store(true, .release);

        std.log.info("Server listening on http://{s}:{d}", .{ self.config.host, self.config.port });
        std.log.info("   Pool size: {d} runtimes", .{self.config.pool_size});
    }

    pub fn run(self: *Self) !void {
        try self.start();
        try self.acceptLoop();
        self.shutdown(self.config.timeout_ms);
    }

    /// Start the server, spawn work_fn on a background thread, then
    /// block on the accept loop. The background thread is joined when
    /// the accept loop exits (server.running becomes false).
    pub fn runWithBackgroundWork(
        self: *Self,
        context: anytype,
        comptime work_fn: fn (@TypeOf(context)) void,
    ) !void {
        try self.start();
        const thread = std.Thread.spawn(.{}, work_fn, .{context}) catch |err| {
            self.shutdown(self.config.timeout_ms);
            return err;
        };
        defer thread.join();
        defer self.shutdown(self.config.timeout_ms);
        return self.acceptLoop();
    }

    const AcceptWakeContext = struct {
        server: *Self,
        done: std.atomic.Value(bool) = .init(false),
    };

    fn wakeAcceptOnShutdown(context: *AcceptWakeContext) void {
        while (!context.done.load(.acquire) and !g_shutdown_requested.load(.monotonic)) {
            const ts = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        if (context.done.load(.acquire)) return;
        const host = if (std.mem.eql(u8, context.server.config.host, "0.0.0.0"))
            "127.0.0.1"
        else
            context.server.config.host;
        const address = net.IpAddress.parseIp4(host, context.server.config.port) catch return;
        const io = context.server.io_backend.io();
        var stream = address.connect(io, .{ .mode = .stream }) catch return;
        stream.close(io);
    }

    fn acceptLoop(self: *Self) !void {
        const io = self.io_backend.io();
        var listener = self.listener orelse return error.NotStarted;
        var wake_context = AcceptWakeContext{ .server = self };
        var wake_thread: ?std.Thread = null;
        if (comptime builtin.target.os.tag != .windows) {
            wake_thread = try std.Thread.spawn(.{}, wakeAcceptOnShutdown, .{&wake_context});
        }
        defer if (wake_thread) |thread| {
            wake_context.done.store(true, .release);
            thread.join();
        };

        while (self.running.load(.acquire) and !g_shutdown_requested.load(.monotonic)) {
            const stream = listener.accept(io) catch |err| switch (err) {
                // Per-connection hiccup: drop it and keep serving.
                error.ConnectionAborted => continue,
                // Resource exhaustion under load or attack (EMFILE/ENFILE/
                // ENOBUFS) is exactly when the server must stay up. Back off
                // briefly so we don't busy-spin while descriptors/buffers drain.
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.SystemResources,
                => {
                    std.log.warn("accept: transient resource exhaustion ({}); backing off", .{err});
                    std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
                    continue;
                },
                // `shutdown` surfaces as these while a concurrent accept is
                // blocked; exit the loop cleanly rather than as an error.
                error.SocketNotListening, error.Canceled => return,
                else => return err,
            };

            if (g_shutdown_requested.load(.monotonic)) {
                stream.close(io);
                return;
            }

            const fd = stream.socket.handle;
            if (self.conn_pool) |cp| {
                if (!cp.submit(fd)) std.Io.Threaded.closeFd(fd);
            } else {
                // start() initializes conn_pool before setting running=true.
                std.Io.Threaded.closeFd(fd);
                return error.NotStarted;
            }
        }
    }

    /// Cooperative graceful shutdown: stop accepting new connections, then
    /// drain in-flight JS executions. Returns once all in-flight requests
    /// complete or the grace period expires. Call from the server's control
    /// thread/signal path; this method does not make `running` or listener
    /// ownership thread-safe for arbitrary cross-thread callers.
    ///
    /// `grace_ms` does not bound the WebSocket worker join: a callback already
    /// executing when shutdown begins runs to completion, so only a non-zero
    /// `request_timeout_ms` bounds it.
    pub fn shutdown(self: *Self, grace_ms: u32) void {
        self.running.store(false, .release);
        // Close listener so a blocked accept() wakes immediately.
        if (self.evented_ready) {
            const io = self.io_backend.io();
            if (self.listener) |*l| {
                l.deinit(io);
                self.listener = null;
            }
        }
        // Drain: wait up to grace_ms for active JS executions to finish.
        // std.time.sleep/milliTimestamp do not exist in Zig 0.16; poll with
        // std.c.nanosleep is the portable wait used by this test server.
        if (self.pool) |*p| {
            var waited_ms: u32 = 0;
            while (p.getInUse() > 0 and waited_ms < grace_ms) {
                const ts = std.c.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
                waited_ms += 5;
            }
        }
    }

    /// Parse HTTP request from a pre-read buffer (synchronous path for thread pool).
    pub fn parseRequestFromBuffer(self: *Self, allocator: std.mem.Allocator, data: []const u8) !ParsedRequest {
        var headers: std.ArrayListUnmanaged(HttpHeader) = .empty;
        errdefer headers.deinit(allocator);
        try headers.ensureTotalCapacity(allocator, self.config.max_headers);

        // Find end of headers
        const header_end = findHeaderEnd(data) orelse return error.InvalidRequest;
        const header_section = data[0..header_end];
        const body_start = header_end + 4;

        // Parse request line
        var lines = std.mem.splitSequence(u8, header_section, "\r\n");
        const request_line = lines.next() orelse return error.InvalidRequest;
        const parsed_line = try parseRequestLineBorrowed(request_line, self.config.max_url_length);

        const qr = try parseQueryString(allocator, parsed_line.query_string, self.config.max_query_length);
        errdefer if (qr.storage) |s| allocator.free(s);
        errdefer if (qr.decoded_storage) |ds| allocator.free(ds);

        // Parse headers with fast slot population
        var fast_slots = FastHeaderSlots{};
        var line_iter = HeaderLineIterator{ .iter = lines };
        try parseHeadersFromLinesBorrowed(
            allocator,
            self.config.max_headers,
            &headers,
            &fast_slots,
            &line_iter,
        );

        // Extract body if present
        var body: ?[]u8 = null;
        if (fast_slots.transfer_encoding == .chunked) {
            if (fast_slots.content_length != null) return error.InvalidRequest;
            const decoded = try http_parser.decodeChunkedBody(
                allocator,
                data[body_start..],
                self.config.max_body_size,
            );
            if (decoded.len > 0) {
                body = decoded;
            } else {
                allocator.free(decoded);
            }
        } else if (fast_slots.content_length) |len| {
            if (len > 0) {
                if (len > self.config.max_body_size) return error.FileTooBig;
                if (body_start > data.len or len > data.len - body_start) {
                    return error.IncompleteBody;
                }
                body = try allocator.alloc(u8, len);
                @memcpy(body.?, data[body_start..][0..len]);
            }
        }

        return ParsedRequest{
            .method = parsed_line.method,
            .url = parsed_line.url,
            .path = parsed_line.path,
            .query_params = qr.params,
            .headers = headers,
            .body = body,
            .string_storage = &.{},
            .owns_string_storage = false,
            .query_params_storage = qr.storage,
            .query_decoded_storage = qr.decoded_storage,
            .connection = fast_slots.connection,
            .content_length = fast_slots.content_length,
            .content_type = fast_slots.content_type,
            .is_http_10 = parsed_line.is_http_10,
        };
    }
};

// ============================================================================
// HTTP Parsing Helpers
// ============================================================================

const HeaderLineIterator = struct {
    iter: std.mem.SplitIterator(u8, .sequence),

    pub fn next(self: *HeaderLineIterator) !?[]const u8 {
        return self.iter.next();
    }
};

const ParsedRequest = struct {
    method: []const u8,
    url: []const u8,
    /// URL path without query string (e.g., "/api/process" from "/api/process?items=100")
    path: []const u8 = "",
    /// Parsed query parameters (references into string_storage)
    query_params: []const QueryParam = &.{},
    headers: std.ArrayListUnmanaged(HttpHeader),
    body: ?[]u8,
    /// Batch buffer holding method, url, and header strings (single allocation)
    string_storage: []u8,
    owns_string_storage: bool = true,
    /// Backing storage for query_params array
    query_params_storage: ?[]QueryParam = null,
    /// Backing buffer for percent-decoded query param strings
    query_decoded_storage: ?[]u8 = null,
    /// OPTIMIZATION: Fast slots for commonly accessed headers (avoids O(n) lookup)
    connection: ?[]const u8 = null,
    content_length: ?usize = null,
    content_type: ?[]const u8 = null,
    /// HTTP/1.0 requests default to close; keep-alive requires an explicit header.
    is_http_10: bool = false,

    pub fn deinit(self: *ParsedRequest, allocator: std.mem.Allocator) void {
        if (self.body) |b| allocator.free(b);
        if (self.owns_string_storage) {
            // Free single batch allocation instead of individual strings.
            allocator.free(self.string_storage);
        }
        // Free query params storage if allocated
        if (self.query_params_storage) |qps| allocator.free(qps);
        if (self.query_decoded_storage) |ds| allocator.free(ds);
        // Headers list only - strings are in string_storage
        self.headers.deinit(allocator);
    }

    pub fn asView(self: *const ParsedRequest) HttpRequestView {
        return .{
            .method = self.method,
            .url = self.url,
            .path = self.path,
            .query_params = self.query_params,
            .headers = self.headers,
            .body = self.body,
        };
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn requiresRuntimePolicyIndex(configured_contract: bool, accepted_artifact: bool) bool {
    return configured_contract or accepted_artifact;
}

test "server preserves either source or artifact policy-index requirement" {
    try std.testing.expect(!requiresRuntimePolicyIndex(false, false));
    try std.testing.expect(requiresRuntimePolicyIndex(true, false));
    try std.testing.expect(requiresRuntimePolicyIndex(false, true));
    try std.testing.expect(requiresRuntimePolicyIndex(true, true));
}

fn logContractSummary(contract: *const ValidatedRuntimeContract) void {
    const inner = contract.view();
    const p = &inner.properties;
    std.log.info("Contract loaded: {d} env vars{s}, {d} routes{s}", .{
        inner.env_vars.len,
        if (inner.env_dynamic) @as([]const u8, " (+dynamic)") else "",
        inner.routes.len,
        if (inner.routes_dynamic) @as([]const u8, " (+dynamic)") else "",
    });

    // Log proven properties as a separate line for clarity
    if (p.pure or p.read_only or p.retry_safe or p.deterministic or
        p.injection_safe or p.state_isolated or p.idempotent or
        p.no_secret_leakage or p.fault_covered or p.result_safe)
    {
        std.log.info("   Proven:{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}", .{
            if (p.pure) @as([]const u8, " pure") else "",
            if (p.read_only) @as([]const u8, " read_only") else "",
            if (p.retry_safe) @as([]const u8, " retry_safe") else "",
            if (p.deterministic) @as([]const u8, " deterministic") else "",
            if (p.injection_safe) @as([]const u8, " injection_safe") else "",
            if (p.state_isolated) @as([]const u8, " state_isolated") else "",
            if (p.idempotent) @as([]const u8, " idempotent") else "",
            if (p.no_secret_leakage) @as([]const u8, " no_secret_leakage") else "",
            if (p.fault_covered) @as([]const u8, " fault_covered") else "",
            if (p.result_safe) @as([]const u8, " result_safe") else "",
        });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "splitHeaderLine accepts no-space colon" {
    const h1_opt = splitHeaderLine("X-Test:123");
    try std.testing.expect(h1_opt != null);
    const h1 = h1_opt.?;
    try std.testing.expectEqualStrings("X-Test", h1.key);
    try std.testing.expectEqualStrings("123", h1.value);

    const h2_opt = splitHeaderLine("X-Test: 123");
    try std.testing.expect(h2_opt != null);
    const h2 = h2_opt.?;
    try std.testing.expectEqualStrings("X-Test", h2.key);
    try std.testing.expectEqualStrings("123", h2.value);
}

test "threaded readRequestData handles partial headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);

    try writeAllFd(fds[1], "GET / HTTP/1.1\r\nHost: example.com\r\n");
    try writeAllFd(fds[1], "Content-Length: 5\r\n\r\nhello");
    std.Io.Threaded.closeFd(fds[1]);

    var pending: ConnectionPool.PendingRequestBytes = .{};
    defer pending.deinit(pool.allocator);

    const data = try pool.readRequestData(fds[0], allocator, &pending, null);
    var request = try server.parseRequestFromBuffer(allocator, data);
    defer request.deinit(allocator);
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings("hello", request.body.?);
    try std.testing.expectEqual(@as(usize, 0), pending.bytes.len);
}

test "threaded completeRequestLength rejects a chunked body whose encoding exceeds the wire cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const max_body_size: usize = 64;

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = max_body_size, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = allocator,
    };

    // Each one-byte decoded chunk carries a large extension. The decoded
    // payload stays within max_body_size while its encoded representation
    // exceeds the separate wire-size cap.
    var request: std.ArrayList(u8) = .empty;
    try request.appendSlice(
        allocator,
        "POST /api HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n",
    );
    const body_start = request.items.len;
    var chunk_index: usize = 0;
    while (chunk_index < max_body_size) : (chunk_index += 1) {
        try request.appendSlice(allocator, "1;");
        try request.appendNTimes(allocator, 'x', 1100);
        try request.appendSlice(allocator, "\r\na\r\n");
    }
    const incomplete_len = request.items.len;
    try request.appendSlice(allocator, "0\r\n\r\n");
    const encoded_cap = http_parser.maxChunkedEncodedBodyBytes(max_body_size);
    try std.testing.expect(incomplete_len - body_start > encoded_cap);

    // A body still in flight past the cap is refused before it completes.
    var in_flight: http_parser.ChunkedBodyParseState = .{};
    try std.testing.expectError(
        error.FileTooBig,
        pool.completeRequestLength(request.items[0..incomplete_len], &in_flight),
    );

    // A read that crosses the cap and finishes the body in one step is refused too.
    var complete: http_parser.ChunkedBodyParseState = .{};
    try std.testing.expectError(
        error.FileTooBig,
        pool.completeRequestLength(request.items, &complete),
    );
}

test "threaded readRequestData handles chunked body across reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);

    try writeAllFd(fds[1], "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel");
    try writeAllFd(fds[1], "lo\r\n6\r\n world\r\n0\r\n\r\n");
    std.Io.Threaded.closeFd(fds[1]);

    var pending: ConnectionPool.PendingRequestBytes = .{};
    defer pending.deinit(pool.allocator);

    const data = try pool.readRequestData(fds[0], allocator, &pending, null);
    var request = try server.parseRequestFromBuffer(allocator, data);
    defer request.deinit(allocator);
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings("hello world", request.body.?);
    try std.testing.expectEqual(@as(usize, 0), pending.bytes.len);
}

// Functional regression test, not a perf-timing test: readRequestData's
// read_buf caps every posix.read() at 16 KiB, so a chunked body well past
// that threshold forces several *real* socket reads, each re-entering
// completeRequestLength with the same persisted ChunkedBodyParseState. This
// proves the resumable state survives repeated genuine reads without
// corrupting the assembled body. It cannot by itself distinguish a linear
// resume from a reintroduced pos=0 rescan (both are functionally correct,
// just one is quadratically slower) — that algorithmic property is covered
// by the chunkedBodyConsumedResumable poisoned-prefix unit tests in
// http_parser.zig.
test "threaded readRequestData resumes chunked body parsing across many real socket reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 64 * 1024, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);

    // 1000 chunks of 20 bytes each ("14" is hex for 20): ~26 encoded bytes
    // per chunk, ~26 KB total, well past the 16 KB read_buf.
    const chunk_count = 1000;
    const chunk_data_len = 20;

    var request_bytes: std.ArrayList(u8) = .empty;
    defer request_bytes.deinit(std.testing.allocator);
    try request_bytes.appendSlice(std.testing.allocator, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n");

    var expected_body: std.ArrayList(u8) = .empty;
    defer expected_body.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < chunk_count) : (i += 1) {
        const byte: u8 = 'a' + @as(u8, @intCast(i % 26));
        try request_bytes.appendSlice(std.testing.allocator, "14\r\n");
        try request_bytes.appendNTimes(std.testing.allocator, byte, chunk_data_len);
        try request_bytes.appendSlice(std.testing.allocator, "\r\n");
        try expected_body.appendNTimes(std.testing.allocator, byte, chunk_data_len);
    }
    try request_bytes.appendSlice(std.testing.allocator, "0\r\n\r\n");
    try std.testing.expect(request_bytes.items.len > 16 * 1024);

    // The payload exceeds the platform's default AF_UNIX stream socket
    // buffer (8 KiB on macOS), so writing it in one shot before any reader
    // runs would deadlock: the write blocks waiting for a reader that only
    // starts once the write call returns. Write from a separate thread so
    // the socket drains concurrently with readRequestData's read loop,
    // same as a real client.
    const WriteCtx = struct {
        fd: std.posix.fd_t,
        bytes: []const u8,
    };
    const writer_thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: WriteCtx) void {
            writeAllFd(ctx.fd, ctx.bytes) catch {};
            std.Io.Threaded.closeFd(ctx.fd);
        }
    }.run, .{WriteCtx{ .fd = fds[1], .bytes = request_bytes.items }});
    defer writer_thread.join();

    var pending: ConnectionPool.PendingRequestBytes = .{};
    defer pending.deinit(pool.allocator);

    const data = try pool.readRequestData(fds[0], allocator, &pending, null);
    var request = try server.parseRequestFromBuffer(allocator, data);
    defer request.deinit(allocator);
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings(expected_body.items, request.body.?);
    try std.testing.expectEqual(@as(usize, 0), pending.bytes.len);
}

test "threaded readRequestData preserves pipelined bytes for the next request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = std.testing.allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    const first = "GET /first HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const second = "GET /second HTTP/1.1\r\nHost: example.com\r\n\r\n";
    var pending: ConnectionPool.PendingRequestBytes = .{};
    defer pending.deinit(pool.allocator);
    try pending.replace(pool.allocator, first ++ second);

    const first_data = try pool.readRequestData(fds[0], allocator, &pending, null);
    try std.testing.expectEqualStrings(first, first_data);
    try std.testing.expectEqualStrings(second, pending.bytes);
    var first_request = try server.parseRequestFromBuffer(allocator, first_data);
    try std.testing.expectEqualStrings("/first", first_request.path);
    first_request.deinit(allocator);

    _ = arena.reset(.retain_capacity);
    allocator = arena.allocator();
    const second_data = try pool.readRequestData(fds[0], allocator, &pending, null);
    try std.testing.expectEqualStrings(second, second_data);
    try std.testing.expectEqual(@as(usize, 0), pending.bytes.len);
    var second_request = try server.parseRequestFromBuffer(allocator, second_data);
    defer second_request.deinit(allocator);
    try std.testing.expectEqualStrings("/second", second_request.path);
}

test "threaded readRequestData rejects unsupported transfer-encoding before preserving body bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    try writeAllFd(
        fds[1],
        "POST /first HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\n\r\n" ++
            "GET /second HTTP/1.1\r\nHost: example.com\r\n\r\n",
    );

    var pending: ConnectionPool.PendingRequestBytes = .{};
    defer pending.deinit(pool.allocator);

    try std.testing.expectError(
        error.UnsupportedTransferEncoding,
        pool.readRequestData(fds[0], allocator, &pending, null),
    );
    try std.testing.expectEqual(@as(usize, 0), pending.bytes.len);
}

test "connection queue drain closes queued file descriptors" {
    var queue = ConnectionPool.BoundedQueue.init();
    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[1]);

    try std.testing.expect(queue.push(.{ .stream_fd = fds[0] }));
    try std.testing.expectEqual(@as(usize, 1), queue.drainAndClose());
    try std.testing.expectEqual(@as(usize, 0), queue.count.load(.acquire));

    var buf: [1]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "threaded handleSingleRequestSync returns 413 for oversized body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    // Content-Length far above the 1024-byte cap. The body itself is not sent:
    // readRequestData rejects on the header value alone.
    try writeAllFd(fds[1], "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5000\r\n\r\n");

    var pending: ConnectionPool.PendingRequestBytes = .{};
    defer pending.deinit(pool.allocator);

    const outcome = try pool.handleSingleRequestSync(fds[0], 0, allocator, &pending);
    try std.testing.expectEqual(ConnectionPool.RequestOutcome.close, outcome);

    // The oversized request gets a real 413 response, not a silent connection drop.
    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 413 Payload Too Large\r\n"));
}

test "threaded waitForNextRequest closes idle keep-alive connection early" {
    var server: Server = undefined;
    server.config = .{
        .handler = .{ .inline_code = "" },
        .timeout_ms = 30_000,
        .keep_alive_timeout_ms = 50,
    };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = std.testing.allocator,
    };

    const fds = try createUnixSocketPair();
    defer std.Io.Threaded.closeFd(fds[0]);
    defer std.Io.Threaded.closeFd(fds[1]);

    // No bytes pending: the idle wait expires at keep_alive_timeout_ms, far
    // below the 30s request timeout, which would pin the worker.
    var timer = try engine.Timer.start();
    try std.testing.expect(!pool.waitForNextRequest(fds[0]));
    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    try std.testing.expect(elapsed_ms >= 40);
    try std.testing.expect(elapsed_ms < 5_000);

    // Bytes already buffered: no idle wait at all.
    try writeAllFd(fds[1], "G");
    try std.testing.expect(pool.waitForNextRequest(fds[0]));
}

test "threaded keep-alive connection serves two sequential requests" {
    var server: Server = undefined;
    server.config = .{
        .handler = .{ .inline_code = "" },
        .timeout_ms = 2_000,
        .keep_alive_timeout_ms = 500,
    };
    server.reload_active = false;
    server.contract = null;
    server.well_known_doc = .{ .body = "{\"v\":1}", .etag_hex = @splat('0') };

    var pool = ConnectionPool{
        .workers = &[_]std.Thread{},
        .queue = ConnectionPool.BoundedQueue.init(),
        .running = std.atomic.Value(bool).init(true),
        .server = &server,
        .allocator = std.testing.allocator,
    };

    const fds = try createUnixSocketPair();
    var server_fd_owned = true;
    defer if (server_fd_owned) std.Io.Threaded.closeFd(fds[0]);

    // handleConnection owns fds[0] and closes it on exit. Defers run LIFO:
    // closing fds[1] first wakes the idle wait so the join cannot hang.
    const worker = try std.Thread.spawn(.{}, ConnectionPool.handleConnection, .{ &pool, fds[0] });
    server_fd_owned = false;
    defer worker.join();
    defer std.Io.Threaded.closeFd(fds[1]);

    const request = "GET " ++ attest_well_known.route_path ++ " HTTP/1.1\r\nHost: example.com\r\n\r\n";
    for (0..2) |_| {
        try writeAllFd(fds[1], request);
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOf(u8, buf[0..len], "{\"v\":1}") == null) {
            const n = try std.posix.read(fds[1], buf[len..]);
            try std.testing.expect(n > 0);
            len += n;
        }
        try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "HTTP/1.1 200 OK\r\n"));
    }
}

test "threaded health and readiness probes return over socket accept path" {
    const Runner = struct {
        fn expectProbe(method: []const u8, path: []const u8, headers: []const u8, status: u16) !void {
            var server: Server = undefined;
            server.config = .{
                .handler = .{ .inline_code = "" },
                .timeout_ms = 2_000,
                .keep_alive = false,
            };
            server.reload_active = false;
            server.contract = null;
            server.well_known_doc = null;
            server.pool = null;

            var pool = ConnectionPool{
                .workers = &[_]std.Thread{},
                .queue = ConnectionPool.BoundedQueue.init(),
                .running = std.atomic.Value(bool).init(true),
                .server = &server,
                .allocator = std.testing.allocator,
            };

            const fds = try createUnixSocketPair();
            var server_fd_owned = true;
            defer if (server_fd_owned) std.Io.Threaded.closeFd(fds[0]);

            const worker = try std.Thread.spawn(.{}, ConnectionPool.handleConnection, .{ &pool, fds[0] });
            server_fd_owned = false;
            defer worker.join();
            defer std.Io.Threaded.closeFd(fds[1]);

            var request_buf: [256]u8 = undefined;
            const request = try std.fmt.bufPrint(
                &request_buf,
                "{s} {s} HTTP/1.1\r\nHost: example.com\r\n{s}Connection: close\r\n\r\n",
                .{ method, path, headers },
            );
            try writeAllFd(fds[1], request);

            var response_buf: [512]u8 = undefined;
            var n: usize = 0;
            while (n < response_buf.len) {
                const received = try std.posix.read(fds[1], response_buf[n..]);
                if (received == 0) break;
                n += received;
            }
            var status_buf: [32]u8 = undefined;
            const status_prefix = try std.fmt.bufPrint(&status_buf, "HTTP/1.1 {d} ", .{status});
            try std.testing.expect(std.mem.startsWith(u8, response_buf[0..n], status_prefix));
            const body_start = (std.mem.indexOf(u8, response_buf[0..n], "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
            const body = switch (status) {
                200 => "OK",
                501 => "Not Implemented",
                413 => "Payload Too Large",
                else => return error.TestUnexpectedResult,
            };
            var length_buf: [32]u8 = undefined;
            const length = try std.fmt.bufPrint(&length_buf, "Content-Length: {d}\r\n", .{body.len});
            try std.testing.expect(std.mem.indexOf(u8, response_buf[0..body_start], length) != null);
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, method, "HEAD")) "" else body, response_buf[body_start..n]);
        }
    };

    for ([_][]const u8{ "GET", "HEAD" }) |method| {
        try Runner.expectProbe(method, "/_health", "", 200);
        try Runner.expectProbe(method, "/_readiness", "", 200);
        try Runner.expectProbe(method, "/_health", "Transfer-Encoding: gzip\r\n", 501);
        try Runner.expectProbe(method, "/_health", "Content-Length: 2147483647\r\n", 413);
    }
}

const ShutdownGraceScenario = enum {
    completes_within_grace,
    expires,
};

fn runShutdownGraceScenario(scenario: ShutdownGraceScenario) !void {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.heap.c_allocator;
    const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));
    const Wait = struct {
        fn forFlag(flag: *const std.atomic.Value(bool), expected: bool, timeout_ms: u64) !void {
            var timer = try engine.Timer.start();
            while (flag.load(.acquire) != expected) {
                if (timer.read() > timeout_ms * std.time.ns_per_ms) return error.TestTimedOut;
                const pause = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = std.c.nanosleep(&pause, null);
            }
        }

        fn forPoolOccupancy(pool: *const HandlerPool, expected: usize, timeout_ms: u64) !void {
            var timer = try engine.Timer.start();
            while (pool.getInUse() != expected) {
                if (timer.read() > timeout_ms * std.time.ns_per_ms) return error.TestTimedOut;
                const pause = std.c.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = std.c.nanosleep(&pause, null);
            }
        }

        fn forReadable(fd: std.posix.fd_t, timeout_ms: i32) !void {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            try std.testing.expect(try std.posix.poll(&fds, timeout_ms) > 0);
        }
    };
    const BlockingUpstream = struct {
        allocator: std.mem.Allocator,
        io_backend: Io.Threaded,
        listener: net.Server,
        port: u16,
        thread: ?std.Thread = null,
        request_started: std.atomic.Value(bool) = .init(false),
        release_response: std.atomic.Value(bool) = .init(false),
        thread_error: std.atomic.Value(ErrorInt) = .init(0),

        const Upstream = @This();

        fn init(upstream_allocator: std.mem.Allocator) !Upstream {
            var io_backend = Io.Threaded.init(upstream_allocator, .{ .environ = .empty });
            const io = io_backend.io();
            const address = try net.IpAddress.parseIp4("127.0.0.1", 0);
            const listener = try address.listen(io, .{ .reuse_address = true });
            return .{
                .allocator = upstream_allocator,
                .io_backend = io_backend,
                .listener = listener,
                .port = listener.socket.address.getPort(),
            };
        }

        fn start(self: *Upstream) !void {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        fn run(self: *Upstream) void {
            self.runInner() catch |err| {
                self.thread_error.store(@intFromError(err), .release);
            };
        }

        fn runInner(self: *Upstream) !void {
            const io = self.io_backend.io();
            var stream = try self.listener.accept(io);
            defer stream.close(io);

            var request: std.ArrayList(u8) = .empty;
            defer request.deinit(self.allocator);
            var chunk: [512]u8 = undefined;
            while (std.mem.indexOf(u8, request.items, "\r\n\r\n") == null) {
                const n = try std.posix.read(stream.socket.handle, &chunk);
                if (n == 0) return error.EndOfStream;
                if (request.items.len + n > 16 * 1024) return error.StreamTooLong;
                try request.appendSlice(self.allocator, chunk[0..n]);
            }
            self.request_started.store(true, .release);

            try Wait.forFlag(&self.release_response, true, 10_000);
            try writeAllFd(
                stream.socket.handle,
                "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\ndrained",
            );
        }

        fn wake(self: *Upstream) !net.Stream {
            const io = self.io_backend.io();
            const address = try net.IpAddress.parseIp4("127.0.0.1", self.port);
            var stream = try address.connect(io, .{ .mode = .stream });
            errdefer stream.close(io);
            try writeAllFd(stream.socket.handle, "GET /cleanup HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            return stream;
        }

        fn join(self: *Upstream) !void {
            const thread = self.thread orelse return;
            thread.join();
            self.thread = null;
            const err_int = self.thread_error.swap(0, .acq_rel);
            if (err_int != 0) return @errorFromInt(err_int);
        }

        fn deinit(self: *Upstream) void {
            self.release_response.store(true, .release);
            const io = self.io_backend.io();
            var wake_stream: ?net.Stream = null;
            defer if (wake_stream) |*stream| stream.close(io);
            // This branch is only reachable when the test failed before its
            // explicit join, so report cleanup trouble and keep tearing down.
            // A panic here would replace the failure being diagnosed.
            var listener_closed = false;
            if (self.thread != null) {
                wake_stream = self.wake() catch |err| blk: {
                    std.debug.print("blocking upstream cleanup wake failed: {s}\n", .{@errorName(err)});
                    self.listener.deinit(io);
                    listener_closed = true;
                    self.thread.?.join();
                    self.thread = null;
                    break :blk null;
                };
            }
            self.join() catch |err| {
                std.debug.print("blocking upstream worker failed: {s}\n", .{@errorName(err)});
            };
            if (!listener_closed) self.listener.deinit(io);
            self.io_backend.deinit();
        }
    };

    const grace_ms: u32 = switch (scenario) {
        .completes_within_grace => 2_000,
        .expires => 25,
    };
    const expiry_timeout_ms: u64 = 500;

    var previous_term: std.posix.Sigaction = undefined;
    var previous_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &previous_term);
    std.posix.sigaction(std.posix.SIG.INT, null, &previous_int);
    defer {
        std.posix.sigaction(std.posix.SIG.TERM, &previous_term, null);
        std.posix.sigaction(std.posix.SIG.INT, &previous_int, null);
        g_shutdown_requested.store(false, .monotonic);
    }

    var upstream = try BlockingUpstream.init(allocator);
    defer upstream.deinit();
    try upstream.start();

    const handler = try allocator.print(
        \\function handler(req) {{
        \\  const response = fetchSync("http://127.0.0.1:{d}/hold");
        \\  return Response.text(response.text());
        \\}}
    , .{upstream.port});
    defer allocator.free(handler);

    const io = upstream.io_backend.io();
    const loopback = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var port_reservation = try loopback.listen(io, .{ .reuse_address = true });
    const server_port = port_reservation.socket.address.getPort();
    port_reservation.deinit(io);

    var server = try Server.init(allocator, .{
        .handler = .{ .inline_code = handler },
        .port = server_port,
        .pool_size = 1,
        .timeout_ms = 5_000,
        .keep_alive = false,
        .log_requests = false,
        .runtime_config = .{
            .outbound_http_enabled = true,
            .outbound_allow_host = "127.0.0.1",
            .outbound_timeout_ms = 5_000,
            .dev_capability_policy = .{
                .egress_scopes = (engine.endpoint.ScopeSet{}).with(.loopback),
            },
        },
    });
    defer server.deinit();
    try server.start();

    const server_address = try net.IpAddress.parseIp4("127.0.0.1", server_port);

    var accept_error = std.atomic.Value(ErrorInt).init(0);
    var shutdown_started = std.atomic.Value(bool).init(false);
    var allow_shutdown = std.atomic.Value(bool).init(false);
    var shutdown_done = std.atomic.Value(bool).init(false);
    var shutdown_elapsed_ns = std.atomic.Value(u64).init(0);
    const AcceptContext = struct {
        server: *Server,
        result: *std.atomic.Value(ErrorInt),
        shutdown_started: *std.atomic.Value(bool),
        allow_shutdown: *const std.atomic.Value(bool),
        shutdown_done: *std.atomic.Value(bool),
        shutdown_elapsed_ns: *std.atomic.Value(u64),
        grace_ms: u32,

        fn run(context: @This()) void {
            context.server.acceptLoop() catch |err| {
                context.result.store(@intFromError(err), .release);
                return;
            };
            context.shutdown_started.store(true, .release);
            Wait.forFlag(context.allow_shutdown, true, 10_000) catch |err| {
                context.result.store(@intFromError(err), .release);
                return;
            };
            var shutdown_timer = engine.Timer.start() catch |err| {
                context.result.store(@intFromError(err), .release);
                context.shutdown_done.store(true, .release);
                return;
            };
            context.server.shutdown(context.grace_ms);
            context.shutdown_elapsed_ns.store(shutdown_timer.read(), .release);
            context.shutdown_done.store(true, .release);
        }
    };
    const accept_thread = try std.Thread.spawn(.{}, AcceptContext.run, .{AcceptContext{
        .server = &server,
        .result = &accept_error,
        .shutdown_started = &shutdown_started,
        .allow_shutdown = &allow_shutdown,
        .shutdown_done = &shutdown_done,
        .shutdown_elapsed_ns = &shutdown_elapsed_ns,
        .grace_ms = grace_ms,
    }});
    var accept_joined = false;
    defer if (!accept_joined) {
        g_shutdown_requested.store(true, .monotonic);
        allow_shutdown.store(true, .release);
        upstream.release_response.store(true, .release);
        var wake = server_address.connect(io, .{ .mode = .stream }) catch blk: {
            if (server.listener) |*listener| {
                listener.deinit(server.io_backend.io());
                server.listener = null;
            }
            break :blk null;
        };
        if (wake) |*stream| stream.close(io);
        accept_thread.join();
    };

    var original = try server_address.connect(io, .{ .mode = .stream });
    defer original.close(io);
    try writeAllFd(
        original.socket.handle,
        "GET /drain HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    );
    try Wait.forFlag(&upstream.request_started, true, 5_000);
    try std.testing.expectEqual(@as(usize, 1), server.pool.?.getInUse());

    try std.posix.raise(std.posix.SIG.TERM);
    // No client is opened until acceptLoop has exited. This makes the server's
    // own signal wake path the only way to reach the assertion.
    try Wait.forFlag(&shutdown_started, true, 2_000);

    // The accept loop is stopped, but shutdown is held at the test handshake
    // until this connection is queued. It must close without being served.
    var rejected = try server_address.connect(io, .{ .mode = .stream });
    defer rejected.close(io);
    allow_shutdown.store(true, .release);

    try Wait.forReadable(rejected.socket.handle, 2_000);
    var rejected_bytes: [64]u8 = undefined;
    const rejected_len = std.posix.read(rejected.socket.handle, &rejected_bytes) catch |err| switch (err) {
        error.ConnectionResetByPeer => 0,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 0), rejected_len);

    switch (scenario) {
        .completes_within_grace => {
            // Give shutdown time to reach its drain loop while the upstream
            // remains blocked. It must not return until that request is released.
            const drain_probe_pause = std.c.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&drain_probe_pause, null);
            try std.testing.expect(!shutdown_done.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), server.pool.?.getInUse());
            upstream.release_response.store(true, .release);
            try Wait.forFlag(&shutdown_done, true, 2_000);
        },
        .expires => {
            try Wait.forFlag(&shutdown_done, true, expiry_timeout_ms);
            const accept_err_int = accept_error.load(.acquire);
            if (accept_err_int != 0) return @errorFromInt(accept_err_int);
            const elapsed_ns = shutdown_elapsed_ns.load(.acquire);
            try std.testing.expect(elapsed_ns >= grace_ms * std.time.ns_per_ms);
            try std.testing.expect(elapsed_ns < expiry_timeout_ms * std.time.ns_per_ms);
            try std.testing.expect(!upstream.release_response.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), server.pool.?.getInUse());
            try std.testing.expectError(
                error.ConnectionRefused,
                server_address.connect(io, .{ .mode = .stream }),
            );
            upstream.release_response.store(true, .release);
            try Wait.forPoolOccupancy(&server.pool.?, 0, expiry_timeout_ms);
        },
    }
    accept_thread.join();
    accept_joined = true;
    const accept_err_int = accept_error.load(.acquire);
    if (accept_err_int != 0) return @errorFromInt(accept_err_int);

    try std.testing.expect(!server.running.load(.acquire));
    try std.testing.expect(server.listener == null);
    try std.testing.expectEqual(@as(usize, 0), server.pool.?.getInUse());
    try std.testing.expectError(
        error.ConnectionRefused,
        server_address.connect(io, .{ .mode = .stream }),
    );

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);
    var response_chunk: [512]u8 = undefined;
    while (std.mem.indexOf(u8, response.items, "\r\n\r\ndrained") == null) {
        try Wait.forReadable(original.socket.handle, 2_000);
        const n = try std.posix.read(original.socket.handle, &response_chunk);
        if (n == 0) break;
        if (response.items.len + n > 4 * 1024) return error.StreamTooLong;
        try response.appendSlice(allocator, response_chunk[0..n]);
    }
    try std.testing.expect(std.mem.startsWith(u8, response.items, "HTTP/1.1 200 OK\r\n"));
    const body_start = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse return error.InvalidResponse;
    try std.testing.expectEqualStrings("drained", response.items[body_start + 4 ..]);
    try Wait.forPoolOccupancy(&server.pool.?, 0, expiry_timeout_ms);
    try upstream.join();
}

test "SIGTERM graceful shutdown stops accepts and drains an in-flight request" {
    try runShutdownGraceScenario(.completes_within_grace);
}

test "SIGTERM graceful shutdown returns when grace expires" {
    try runShutdownGraceScenario(.expires);
}

test "parseRequestFromBuffer rejects duplicate content length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "Content-Length: 6\r\n" ++
        "\r\n" ++
        "hello";

    try std.testing.expectError(error.DuplicateContentLength, server.parseRequestFromBuffer(allocator, data));
}

test "parseRequestFromBuffer decodes chunked transfer encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";

    var request = try server.parseRequestFromBuffer(allocator, data);
    defer request.deinit(allocator);
    try std.testing.expect(request.body != null);
    try std.testing.expectEqualStrings("hello world", request.body.?);
}

test "parseRequestFromBuffer rejects content-length with chunked transfer encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\nhello\r\n0\r\n\r\n";

    try std.testing.expectError(error.InvalidRequest, server.parseRequestFromBuffer(allocator, data));
}

test "parseRequestFromBuffer rejects unsupported transfer-encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: gzip\r\n" ++
        "\r\n" ++
        "hello";

    try std.testing.expectError(error.UnsupportedTransferEncoding, server.parseRequestFromBuffer(allocator, data));
}

test "buildDynamicResponseHeader filters handler supplied framing headers" {
    const allocator = std.testing.allocator;
    var response = HttpResponse.init(allocator);
    defer response.deinit();

    response.status = 201;
    response.body = "created";
    try response.putHeader("X-Test", "one");
    try response.putHeader("Content-Length", "999");
    try response.putHeader("Connection", "close");
    try response.putHeader("Transfer-Encoding", "chunked");

    const attestation = attest_header_strings.HeaderStrings{
        .proofs_value = "pure",
        .attest_value = "jws",
    };

    var sync_buf: [512]u8 = undefined;
    const sync_len = try buildDynamicResponseHeader(&sync_buf, &response, true, attestation);
    const sync = sync_buf[0..sync_len];
    try std.testing.expect(std.mem.startsWith(u8, sync, "HTTP/1.1 201 Created\r\nX-Test: one\r\nZttp-Proofs: pure\r\nZttp-Attest: jws\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, sync, "Content-Length: 999") == null);
    try std.testing.expect(std.mem.indexOf(u8, sync, "Connection: close") == null);
    try std.testing.expect(std.mem.indexOf(u8, sync, "Transfer-Encoding: chunked") == null);
}

test "parseRequestFromBuffer rejects invalid content length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: nope\r\n" ++
        "\r\n";

    try std.testing.expectError(error.InvalidContentLength, server.parseRequestFromBuffer(allocator, data));
}

test "parseRequestFromBuffer accepts large header values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const long_value = try allocator.alloc(u8, 9000);
    @memset(long_value, 'a');

    const data = try allocator.print("GET / HTTP/1.1\r\nHost: example.com\r\nX-Long: {s}\r\n\r\n", .{long_value});

    var request = try server.parseRequestFromBuffer(allocator, data);
    defer request.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), request.headers.items.len);
    try std.testing.expectEqualStrings("X-Long", request.headers.items[1].key);
    try std.testing.expectEqualStrings(long_value, request.headers.items[1].value);
}

test "parseRequestFromBuffer rejects incomplete body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 1024, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hel";

    try std.testing.expectError(error.IncompleteBody, server.parseRequestFromBuffer(allocator, data));
}

test "parseRequestFromBuffer rejects oversized body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = undefined;
    server.config = .{ .handler = .{ .inline_code = "" }, .max_body_size = 4, .max_headers = 64 };

    const data =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";

    try std.testing.expectError(error.FileTooBig, server.parseRequestFromBuffer(allocator, data));
}

test "findHeaderEnd finds terminator across SIMD boundary" {
    var buf: [64]u8 = @as([64]u8, @splat('A'));
    // Place terminator so it crosses a 16-byte boundary (starts at index 15).
    buf[15] = '\r';
    buf[16] = '\n';
    buf[17] = '\r';
    buf[18] = '\n';

    const idx = findHeaderEnd(&buf);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, 15), idx.?);
}

test "findHeaderEnd returns null when terminator absent" {
    const data = "GET / HTTP/1.1\r\nHost: example.com\r\n";
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd(data));
}

test "findHeaderEnd handles short buffers" {
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd(""));
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd("\r\n\r"));
    try std.testing.expectEqual(@as(?usize, 0), findHeaderEnd("\r\n\r\n"));
}

test "attestationClaimsMatchContract rejects JWS describing different bytecode" {
    const policy_bytes = @as([32]u8, @splat(0x11));
    const artifact_bytes = @as([32]u8, @splat(0x22));
    const policy_hex = std.fmt.bytesToHex(policy_bytes, .lower);
    const artifact_hex = std.fmt.bytesToHex(artifact_bytes, .lower);
    const source_identity = engine.sourceIdentityForPath("handler.ts");
    const core_grammar_hex = std.fmt.bytesToHex(source_identity.core_grammar_hash, .lower);
    const semantics_hex = std.fmt.bytesToHex(source_identity.semantics_hash, .lower);

    var live = RuntimeContract{
        .env_vars = &.{},
        .env_dynamic = false,
        .routes = &.{},
        .routes_dynamic = false,
        .properties = .{},
        .policy_hash = policy_bytes,
        .artifact_sha256 = artifact_bytes,
        .source_identity = source_identity,
        .allocator = std.testing.allocator,
    };

    var claims = attest_envelope.Claims{
        .contract_sha256 = &@as([64:0]u8, @splat('0')),
        .bytecode_sha256 = &artifact_hex,
        .policy_sha256 = &policy_hex,
        .capability_hash = &@as([64:0]u8, @splat('0')),
        .core_profile_id = source_identity.core_profile.id(),
        .core_grammar_sha256 = &core_grammar_hex,
        .semantics_sha256 = &semantics_hex,
        .compiler_version = "test",
        .signed_at_unix = 0,
        .property_summary = "",
        .guarded_categories = "",
        .routes_count = 0,
    };

    // Matching claims pass.
    try std.testing.expect(activation.attestationClaimsMatchContract(claims, &live));

    // A validly-signed JWS that describes different bytecode is rejected.
    const wrong_artifact = std.fmt.bytesToHex(@as([32]u8, @splat(0x33)), .lower);
    claims.bytecode_sha256 = &wrong_artifact;
    try std.testing.expect(!activation.attestationClaimsMatchContract(claims, &live));

    // A different policy hash is rejected.
    claims.bytecode_sha256 = &artifact_hex;
    const wrong_policy = std.fmt.bytesToHex(@as([32]u8, @splat(0x44)), .lower);
    claims.policy_sha256 = &wrong_policy;
    try std.testing.expect(!activation.attestationClaimsMatchContract(claims, &live));

    // An unpinned (all-zero) live hash skips the field instead of rejecting,
    // mirroring contract_runtime's skip-on-zero semantics for live reload.
    live.policy_hash = @as([32]u8, @splat(0));
    try std.testing.expect(activation.attestationClaimsMatchContract(claims, &live));

    const wrong_grammar = std.fmt.bytesToHex(@as([32]u8, @splat(0x55)), .lower);
    claims.core_grammar_sha256 = &wrong_grammar;
    try std.testing.expect(!activation.attestationClaimsMatchContract(claims, &live));
}

test "bytecodeMatchesClaim binds attestation to the running bytecode (fail-closed)" {
    const bytecode = "fake-bytecode-blob";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytecode, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    // Pinned claim matching the running bytecode passes.
    try std.testing.expect(activation.bytecodeMatchesClaim(bytecode, &hex));
    // Swapped bytecode (the tamper case) fails - the signed claim no longer
    // describes what is loaded, so attestation is disabled.
    try std.testing.expect(!activation.bytecodeMatchesClaim("other-bytecode", &hex));
    // An unpinned (all-zero) claim cannot bind a running artifact: fail closed.
    try std.testing.expect(!activation.bytecodeMatchesClaim(bytecode, &@as([64:0]u8, @splat('0'))));
    // A malformed (non-64-char) claim is rejected.
    try std.testing.expect(!activation.bytecodeMatchesClaim(bytecode, "abc"));
}

fn runtimePolicyClaimsForTest(runtime_policy_sha256: []const u8) attest_envelope.Claims {
    return .{
        .contract_sha256 = &@as([64:0]u8, @splat('0')),
        .bytecode_sha256 = &@as([64:0]u8, @splat('0')),
        .policy_sha256 = &@as([64:0]u8, @splat('0')),
        .capability_hash = &@as([64:0]u8, @splat('0')),
        .runtime_policy_sha256 = runtime_policy_sha256,
        .core_profile_id = "zts-model-1",
        .core_grammar_sha256 = &@as([64:0]u8, @splat('1')),
        .semantics_sha256 = &@as([64:0]u8, @splat('2')),
        .compiler_version = "test",
        .signed_at_unix = 0,
        .property_summary = "",
        .guarded_categories = "",
        .routes_count = 0,
    };
}

fn serverForRuntimePolicyPayloadTest(
    allocator: std.mem.Allocator,
    payload: *const self_extract.Payload,
) !Server {
    return Server.init(allocator, .{
        .handler = .{ .appended_payload = .{
            .bytecode = payload.bytecode,
            .dep_bytecodes = payload.dep_bytecodes,
            .contract_json = payload.contract_json,
        } },
        .attestation_jws = payload.attestation_jws,
        .policy_section_sha256 = payload.policy_section_sha256,
        .pool_size = 1,
        .log_requests = false,
    });
}

test "a deployed artifact that cannot be checked refuses to serve before any pool exists" {
    const allocator = std.testing.allocator;
    const policy = engine.RuntimePolicy{};
    const serialized = try self_extract.serializePayload(allocator, .{
        .bytecode = "bytecode",
        .policy = &policy,
    });
    defer allocator.free(serialized);
    const payload = (try self_extract.parse(allocator, serialized)).?;
    defer payload.deinit(allocator);

    var server = try serverForRuntimePolicyPayloadTest(allocator, &payload);
    defer server.deinit();

    // No contract, so nothing can be checked. The refusal is unconditional.
    try std.testing.expectError(error.ProofContractMissing, server.start());
    // And it happened before the handler pool was built: a refused artifact
    // never gets a warm runtime, so there is no window in which it could serve.
    try std.testing.expect(server.pool == null);
    try std.testing.expect(server.proof_checked == null);
}

test "an unchecked server drives no proof-authoritative behavior" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{
        .handler = .{ .inline_code = "" },
        .pool_size = 1,
        .log_requests = false,
    });
    defer server.deinit();

    // No certificate, so no promotion, so the conservative pooling policy and
    // no proof response cache. This is the same rule as the deployed path seen
    // from the other side, not an exemption for development.
    try std.testing.expect(server.proof_checked == null);
    try std.testing.expect(server.proof_cache == null);
    try std.testing.expectEqual(
        contract_runtime.PoolingPolicy.reuse_bounded_by_count,
        contract_runtime.derivePoolingPolicy(null),
    );
}

/// A contract JSON carrying the current source identity, so `validate` has the
/// stamps it insists on. Everything else is left at its default: these tests
/// are about promotion, not about contract parsing.
fn stampedContractJsonForTest(allocator: std.mem.Allocator, properties: []const u8) ![]u8 {
    const identity = engine.sourceIdentityForPath("handler.ts");
    const grammar = std.fmt.bytesToHex(identity.core_grammar_hash, .lower);
    const semantics = std.fmt.bytesToHex(identity.semantics_hash, .lower);
    return allocator.print("{{\"version\":18,\"sourceIdentity\":{{\"coreProfileId\":\"{s}\",\"coreGrammarHash\":\"{s}\",\"semanticsHash\":\"{s}\"}}{s}}}", .{ identity.core_profile.id(), grammar, semantics, properties });
}

test "a live swap drops the promotion the replaced artifact earned" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{
        .handler = .{ .inline_code = "" },
        .pool_size = 1,
        .log_requests = false,
    });
    defer server.deinit();

    const contract_json = try stampedContractJsonForTest(
        allocator,
        ",\"properties\":{\"pure\":true,\"deterministic\":true,\"stateIsolated\":true}",
    );
    defer allocator.free(contract_json);
    const raw = try contract_runtime.parseContractJson(allocator, contract_json);
    server.contract = try contract_runtime.validate(raw, .{});

    // Stand in for what an accepted certificate earns.
    server.proof_checked = contract_runtime.promote(&server.contract.?, .{
        .outcome = .{ .accepted = .{ .grade = .translation_validated, .development_only = false } },
        .provenance = .absent,
        .work_spent = 1,
    }, @as([32]u8, @splat(0)));
    try std.testing.expect(server.proof_checked != null);

    // The certificate described the artifact that is being replaced, so the
    // swap takes the promotion with it.
    const swapped_raw = try contract_runtime.parseContractJson(allocator, contract_json);
    {
        server.contract_lock.lock();
        defer server.contract_lock.unlock();
        server.replaceContractLocked(try contract_runtime.validate(swapped_raw, .{}));
    }
    try std.testing.expect(server.contract != null);
    try std.testing.expect(server.proof_checked == null);
    try std.testing.expect(server.proof_cache == null);

    // And dropping the contract entirely leaves nothing promoted either.
    {
        server.contract_lock.lock();
        defer server.contract_lock.unlock();
        server.replaceContractLocked(null);
    }
    try std.testing.expect(server.proof_checked == null);
}

test "promotion refuses a policy rejection" {
    const allocator = std.testing.allocator;
    const contract_json = try stampedContractJsonForTest(allocator, "");
    defer allocator.free(contract_json);
    const raw = try contract_runtime.parseContractJson(allocator, contract_json);
    var validated = try contract_runtime.validate(raw, .{});
    defer validated.deinit();

    // Checked but refused by policy.
    try std.testing.expect((contract_runtime.promote(&validated, .{
        .outcome = .{ .rejected = .{
            .reached = .{ .proof_checked = .trusted },
            .rejection = .{
                .stage = .policy,
                .code = .grade_below_floor,
                .recertifiable = true,
            },
            .development_only = false,
        } },
        .provenance = .absent,
        .work_spent = 1,
    }, @as([32]u8, @splat(0)))) == null);
}

test "self-extract runtime policy binding rejects a widened policy" {
    const allocator = std.testing.allocator;
    const original_policy = engine.RuntimePolicy{
        .egress = .{ .enabled = true, .values = &[_][]const u8{"api.allowed.example"} },
    };
    const original_policy_section = try self_extract.serializePolicy(allocator, &original_policy);
    defer allocator.free(original_policy_section);
    var original_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(original_policy_section, &original_digest, .{});
    const original_hex = std.fmt.bytesToHex(original_digest, .lower);

    const key_pair = try attest_envelope.keyPairFromSeed(@as([32]u8, @splat(0x42)));
    var receipt = try attest_envelope.sign(
        allocator,
        runtimePolicyClaimsForTest(&original_hex),
        key_pair,
    );
    defer receipt.deinit(allocator);

    const widened_policy = engine.RuntimePolicy{
        .egress = .{ .enabled = true, .values = &[_][]const u8{
            "api.allowed.example",
            "evil.example",
        } },
    };
    const serialized = try self_extract.serializePayload(allocator, .{
        .bytecode = "bytecode",
        .policy = &widened_policy,
        .attestation = receipt.jws_compact,
    });
    defer allocator.free(serialized);
    const payload = (try self_extract.parse(allocator, serialized)).?;
    defer payload.deinit(allocator);
    var server = try serverForRuntimePolicyPayloadTest(allocator, &payload);
    defer server.deinit();

    try std.testing.expectError(
        error.RuntimePolicyClaimMismatch,
        server.start(),
    );
}
test "self-extract runtime policy binding rejects an unpinned receipt" {
    const allocator = std.testing.allocator;
    const policy = engine.RuntimePolicy{
        .egress = .{ .enabled = true, .values = &[_][]const u8{"api.allowed.example"} },
    };
    const key_pair = try attest_envelope.keyPairFromSeed(@as([32]u8, @splat(0x24)));
    var receipt = try attest_envelope.sign(
        allocator,
        runtimePolicyClaimsForTest(attest_envelope.unpinned_runtime_policy_sha256),
        key_pair,
    );
    defer receipt.deinit(allocator);
    const serialized = try self_extract.serializePayload(allocator, .{
        .bytecode = "bytecode",
        .policy = &policy,
        .attestation = receipt.jws_compact,
    });
    defer allocator.free(serialized);
    const payload = (try self_extract.parse(allocator, serialized)).?;
    defer payload.deinit(allocator);
    var server = try serverForRuntimePolicyPayloadTest(allocator, &payload);
    defer server.deinit();

    try std.testing.expectError(
        error.RuntimePolicyClaimUnpinned,
        server.start(),
    );
}

test "attested appended payload requires a parsed runtime policy hash" {
    const allocator = std.testing.allocator;
    const key_pair = try attest_envelope.keyPairFromSeed(@as([32]u8, @splat(0x18)));
    var receipt = try attest_envelope.sign(
        allocator,
        runtimePolicyClaimsForTest(&@as([64:0]u8, @splat('a'))),
        key_pair,
    );
    defer receipt.deinit(allocator);
    var server = try Server.init(allocator, .{
        .handler = .{ .appended_payload = .{
            .bytecode = "bytecode",
            .dep_bytecodes = &.{},
        } },
        .attestation_jws = receipt.jws_compact,
        .pool_size = 1,
        .log_requests = false,
    });
    defer server.deinit();

    try std.testing.expectError(
        error.RuntimePolicySectionHashMissing,
        server.start(),
    );
}

test "a swap that would strand a guard is refused from either side" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "handler.ts");
    var contract = emptySourceContractForTest(path);
    defer contract.deinit(allocator);

    // Nothing guarded on either side: an ordinary dev swap.
    try std.testing.expectEqual(activation.SwapRefusal.none, activation.swapRefusal(false, &contract, false));
    // The plain-swap and missing-contract branches, which carry no candidate.
    try std.testing.expectEqual(activation.SwapRefusal.none, activation.swapRefusal(false, null, false));

    // Without a checked candidate policy, the running generation's guard
    // coverage belongs to the executable being replaced. No candidate, not
    // even a static one or none at all, may take over.
    try std.testing.expectEqual(
        activation.SwapRefusal.installed_generation_is_guarded,
        activation.swapRefusal(true, &contract, false),
    );
    try std.testing.expectEqual(
        activation.SwapRefusal.installed_generation_is_guarded,
        activation.swapRefusal(true, null, false),
    );

    // A candidate that computes a capability resource has no coverage at all,
    // because a live swap runs no acceptance. Each category answers for itself.
    contract.env.dynamic = true;
    try std.testing.expectEqual(
        activation.SwapRefusal.candidate_computes_a_capability_resource,
        activation.swapRefusal(false, &contract, false),
    );
    contract.env.dynamic = false;
    contract.egress.dynamic = true;
    try std.testing.expectEqual(
        activation.SwapRefusal.candidate_computes_a_capability_resource,
        activation.swapRefusal(false, &contract, false),
    );
    contract.egress.dynamic = false;
    contract.cache.dynamic = true;
    try std.testing.expectEqual(
        activation.SwapRefusal.candidate_computes_a_capability_resource,
        activation.swapRefusal(false, &contract, false),
    );
    contract.cache.dynamic = false;
    contract.sql.dynamic = true;
    try std.testing.expectEqual(
        activation.SwapRefusal.candidate_computes_a_capability_resource,
        activation.swapRefusal(false, &contract, false),
    );

    // A candidate checked against an explicit policy may replace either a
    // static or guarded generation because the checked pair is installed as
    // one pool generation.
    try std.testing.expectEqual(activation.SwapRefusal.none, activation.swapRefusal(false, &contract, true));
    try std.testing.expectEqual(activation.SwapRefusal.none, activation.swapRefusal(true, &contract, true));
}

test "every retired module candidate leaves the serving generation active" {
    const allocator = std.testing.allocator;
    const retired = [_][]const u8{
        "zttp:durable",
        "zttp:workflow",
        "zttp:queue",
        "zttp:scope",
        "zttp:io",
        "zttp:service",
        "zttp:ledger",
        "zttp:tool",
    };
    for (retired) |module| {
        var contract = emptySourceContractForTest(try allocator.dupe(u8, "handler.ts"));
        defer contract.deinit(allocator);
        try contract.modules.append(allocator, try allocator.dupe(u8, module));
        // Preparation checks this result before the server replaces or retires
        // either retained code generation.
        try std.testing.expectEqual(
            activation.SwapRefusal.candidate_uses_retired_authority,
            activation.swapRefusal(false, &contract, true),
        );
    }
}

fn emptySourceContractForTest(path: []const u8) engine.HandlerContract {
    return .{
        .handler = .{ .path = path, .line = 1, .column = 0 },
        .routes = .empty,
        .modules = .empty,
        .functions = .empty,
        .env = .{ .literal = .empty, .dynamic = false },
        .egress = .{ .endpoints = .empty, .dynamic = false },
        .cache = .{ .namespaces = .empty, .dynamic = false },
        .sql = .{ .backend = "sqlite", .queries = .empty, .dynamic = false },
        .api = .{
            .schemas = .empty,
            .requests = .{ .schema_refs = .empty, .dynamic = false },
            .auth = .{ .bearer = false, .jwt = false },
            .routes = .empty,
            .schemas_dynamic = false,
            .routes_dynamic = false,
        },
        .verification = null,
        .aot = null,
    };
}

fn sourceContractForTest(allocator: std.mem.Allocator, route: []const u8, key: []const u8) !engine.HandlerContract {
    var contract = emptySourceContractForTest(try allocator.dupe(u8, "handler.ts"));
    errdefer contract.deinit(allocator);
    contract.source_identity = engine.sourceIdentityForPath("handler.ts");
    contract.properties = .{
        .pure = false,
        .read_only = true,
        .stateless = false,
        .retry_safe = false,
        .deterministic = true,
        .has_egress = false,
        .state_isolated = true,
        .result_safe = true,
    };
    const owned_key = try allocator.dupe(u8, key);
    contract.env.literal.append(allocator, owned_key) catch |err| {
        allocator.free(owned_key);
        return err;
    };
    const method = try allocator.dupe(u8, "GET");
    errdefer allocator.free(method);
    const path = try allocator.dupe(u8, route);
    errdefer allocator.free(path);
    try contract.api.routes.append(allocator, .{
        .method = method,
        .path = path,
        .request_schema_refs = .empty,
        .request_schema_dynamic = false,
        .requires_bearer = false,
        .requires_jwt = false,
    });
    return contract;
}

test "source replacement keeps failed state and retires successful generations together" {
    const allocator = std.testing.allocator;
    var source_heap: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(source_heap.deinit() == 0);
    const source_allocator = source_heap.allocator();
    const old_code = "function handler(req) { return Response.text('old'); }";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old.ts", .data = old_code });
    const initial_path = try tmp.dir.realPathFileAlloc(std.testing.io, "old.ts", allocator);
    defer allocator.free(initial_path);
    var server = try Server.init(allocator, .{ .handler = .{ .file_path = initial_path }, .pool_size = 2 });
    defer server.deinit();
    server.reload_active = true;
    server.pool = try HandlerPool.init(allocator, .{}, server.handler_code, initial_path, 2, 0);
    const pool = &server.pool.?;
    const initial_source = server.handler_code.ptr;
    var old_contract = try sourceContractForTest(allocator, "/old", "OLD_KEY");
    defer old_contract.deinit(allocator);
    const initial = try contract_runtime.validate(try contract_runtime.fromHandlerContract(allocator, &old_contract), .{});
    try server.installSourceContract(initial, &old_contract, null);

    var accepted: pcc.verdict.PropertyVerdicts = .{};
    inline for (.{ .read_only, .deterministic, .state_isolated, .results_checked }) |property| {
        accepted.accept(property, .translation_validated);
    }
    server.proof_checked = contract_runtime.promote(&server.contract.?, .{
        .outcome = .{ .accepted = .{ .grade = .translation_validated, .development_only = false } },
        .provenance = .absent,
        .work_spent = 1,
        .properties = accepted,
    }, @as([32]u8, @splat(0)));
    const settings = server.servingSettings(&server.proof_checked.?);
    try std.testing.expect(settings.handler_proof.result_safe);
    try std.testing.expect(settings.cache_properties != null);
    _ = server.applyPoolingPolicy();
    server.proof_cache = proof_adapter.ProofCache.init(allocator, settings.cache_properties.?, .{});
    server.attestation_headers = try attest_header_strings.build(allocator, settings.cache_properties.?, "old-signature");
    server.well_known_doc = .{ .body = try allocator.dupe(u8, "old-document"), .etag_hex = @splat('0') };
    var old_lease = try pool.acquireWorkerRuntime();
    defer old_lease.deinit();
    const old_policy = old_lease.runtime.policy_generation.?;
    const reload_before = pool.reload_generation.load(.acquire);
    const request: HttpRequestView = .{ .method = "GET", .url = "/", .headers = .empty, .body = null };

    var next_contract = try sourceContractForTest(allocator, "/new", "NEW_KEY");
    defer next_contract.deinit(allocator);
    {
        var bytes: ?[]const u8 = try source_allocator.dupe(u8, "function handler(req) { return Response.text('rejected'); }");
        defer if (bytes) |code| source_allocator.free(code);
        var candidate = try server.prepareSourceGeneration(source_allocator, &bytes, "rejected.ts", &next_contract, null);
        defer candidate.deinit();
        try std.testing.expect(bytes == null);
        candidate.policy = .{ .env = .{ .enabled = true, .values = &.{ "DUP", "DUP" } } };
        try std.testing.expectError(error.DuplicateEntry, server.replaceSourceGeneration(&candidate));
        try std.testing.expect(candidate.source != null);
        try std.testing.expect(candidate.contract != null);
        try std.testing.expectEqualStrings(old_code, server.handler_code);
        try std.testing.expectEqualStrings(old_code, pool.handler_code);
        try std.testing.expectEqualStrings(initial_path, server.source_generation.?.filename);
        try std.testing.expect(server.handler_code.ptr == initial_source);
        try std.testing.expect(pool.handler_code.ptr == initial_source);
        try std.testing.expect(server.contract.?.matchesRoute("GET", "/old"));
        try std.testing.expect(!server.contract.?.matchesRoute("GET", "/new"));
        try std.testing.expect(server.proof_checked != null);
        try std.testing.expect(server.proof_cache != null);
        try std.testing.expectEqualStrings("old-signature", server.attestation_headers.?.attest_value);
        try std.testing.expectEqualStrings("old-document", server.well_known_doc.?.body);
        try std.testing.expect(pool.policy_generation == old_policy);
        try std.testing.expectEqual(reload_before, pool.reload_generation.load(.acquire));
        try std.testing.expect(pool.config.handler_proof.result_safe);
    }
    {
        var bytes: ?[]const u8 = try source_allocator.dupe(u8, "function handler(req) { return Response.text('new'); }");
        defer if (bytes) |code| source_allocator.free(code);
        var candidate = try server.prepareSourceGeneration(source_allocator, &bytes, "new.ts", &next_contract, null);
        defer candidate.deinit();
        _ = try server.replaceSourceGeneration(&candidate);
        try std.testing.expect(candidate.source == null);
        try std.testing.expect(candidate.contract == null);
        try std.testing.expect(server.contract.?.matchesRoute("GET", "/new"));
        try std.testing.expect(!server.contract.?.matchesRoute("GET", "/old"));
        try std.testing.expect(server.proof_checked == null);
        try std.testing.expect(server.proof_cache == null);
        try std.testing.expect(server.attestation_headers == null);
        try std.testing.expect(server.well_known_doc == null);
        try std.testing.expect(!pool.config.handler_proof.result_safe);
        try std.testing.expectEqual(contract_runtime.PoolingPolicy.reuse_bounded_by_count, pool.pooling_policy);
        try std.testing.expect(pool.policy_generation.policy.allowsEnv("NEW_KEY"));
        try std.testing.expect(!pool.policy_generation.policy.allowsEnv("OLD_KEY"));
        var response = try pool.executeHandler(request);
        defer response.deinit();
        try std.testing.expectEqualStrings("new", response.body);
    }
    // A second source transition without a contract drops the old route filter.
    // The retained runtime still owns its old executable and policy reference.
    {
        var bytes: ?[]const u8 = try source_allocator.dupe(u8, "function handler(req) { return Response.text('latest'); }");
        defer if (bytes) |code| source_allocator.free(code);
        var candidate = try server.prepareSourceGeneration(source_allocator, &bytes, "latest.ts", null, null);
        defer candidate.deinit();
        _ = try server.replaceSourceGeneration(&candidate);
        try std.testing.expect(server.contract == null);
        try std.testing.expectEqualStrings("new.ts", server.superseded_source.?.filename);
        try std.testing.expectEqualStrings("latest.ts", server.handler_filename);
        var response = try pool.executeHandler(request);
        defer response.deinit();
        try std.testing.expectEqualStrings("latest", response.body);
    }
    try std.testing.expect(old_policy.policy.allowsEnv("OLD_KEY"));
    try std.testing.expect(!old_policy.policy.allowsEnv("NEW_KEY"));
    try std.testing.expect(old_lease.runtime.config.handler_proof.result_safe);
    var retained_response = try old_lease.runtime.executeHandler(request);
    defer retained_response.deinit();
    try std.testing.expectEqualStrings("old", retained_response.body);
}

test "source preparation failure no-pool and guard refusal preserve ownership" {
    const allocator = std.testing.allocator;
    var server = try Server.init(allocator, .{ .handler = .{ .inline_code = "function handler(req) { return Response.text('old'); }" }, .pool_size = 1 });
    defer server.deinit();
    var bytes: ?[]const u8 = try allocator.dupe(u8, "function handler(req) { return Response.text('new'); }");
    defer if (bytes) |code| allocator.free(code);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, server.prepareSourceGeneration(failing.allocator(), &bytes, "new.ts", null, null));
    try std.testing.expect(bytes != null);
    var candidate = try server.prepareSourceGeneration(allocator, &bytes, "new.ts", null, null);
    defer candidate.deinit();
    try std.testing.expect(bytes == null);
    try std.testing.expectError(error.NoHandlerPool, server.replaceSourceGeneration(&candidate));
    try std.testing.expect(candidate.source != null);
    try std.testing.expect(server.source_generation == null);

    server.pool = try HandlerPool.init(allocator, .{ .runtime_policy_index_required = true }, server.handler_code, "<old>", 1, 0);
    const previous_policy = server.pool.?.policy_generation;
    try std.testing.expectError(error.GuardedGenerationSwapRefused, server.replaceSourceGeneration(&candidate));
    try std.testing.expect(server.pool.?.policy_generation == previous_policy);
    try std.testing.expect(candidate.source != null);
    try std.testing.expectEqualStrings("<inline>", server.handler_filename);
    try std.testing.expectEqualStrings("function handler(req) { return Response.text('old'); }", server.pool.?.handler_code);
}
