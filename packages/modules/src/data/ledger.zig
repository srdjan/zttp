//! zttp:ledger - invariant-preserving double-entry ledger.
//!
//! The runtime must install a configured LedgerStore. This module never
//! creates a default store and never accepts a database path from handler
//! code. Amounts cross the JavaScript boundary as canonical signed decimal
//! strings and are stored as SQLite INTEGER values.

const std = @import("std");
const sdk = @import("zttp-sdk");

pub const MODULE_STATE_SLOT: usize = 15; // module_slots.Slot.ledger
pub const SCHEMA_VERSION: i64 = 1;
const sqlite_busy: i32 = 5;

const schema_statements = [_][]const u8{
    "CREATE TABLE ledger_meta (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL, ledger TEXT NOT NULL, invariant_digest TEXT NOT NULL)",
    "CREATE TABLE ledger_currencies (code TEXT PRIMARY KEY, scale INTEGER NOT NULL CHECK (scale >= 0 AND scale <= 255))",
    "CREATE TABLE ledger_postings (id INTEGER PRIMARY KEY, ledger TEXT NOT NULL, currency TEXT NOT NULL REFERENCES ledger_currencies(code), idempotency_key TEXT NOT NULL, content_hash TEXT NOT NULL, UNIQUE (ledger, currency, idempotency_key))",
    "CREATE TABLE ledger_entries (posting_id INTEGER NOT NULL REFERENCES ledger_postings(id), position INTEGER NOT NULL, account TEXT NOT NULL, amount INTEGER NOT NULL, PRIMARY KEY (posting_id, position))",
    "CREATE TABLE ledger_balances (ledger TEXT NOT NULL, currency TEXT NOT NULL REFERENCES ledger_currencies(code), account TEXT NOT NULL, balance INTEGER NOT NULL, PRIMARY KEY (ledger, currency, account))",
};

pub const Currency = struct {
    code: []const u8,
    scale: u8,
};

/// The closed union of declared account rules.
///
/// Restated here rather than imported: `packages/modules` reaches `zttp-sdk`
/// and nothing else, so the acceptance kernel's own statement of the same union
/// is a separate value that meets this one only through the adapter manifest.
/// Nothing else is expressible - no wildcard, no regular expression, no locale
/// rule, and no normalization.
pub const AccountMatcherTag = enum { exact, prefix };

pub const AccountMatcher = struct {
    tag: AccountMatcherTag,
    value: []const u8,

    /// Case-sensitive over bytes. `asset:` accepts `asset:cash` and `asset:`
    /// itself, and refuses `assets:cash`.
    pub fn matches(self: AccountMatcher, account: []const u8) bool {
        return switch (self.tag) {
            .exact => std.mem.eql(u8, self.value, account),
            .prefix => std.mem.startsWith(u8, account, self.value),
        };
    }

    /// By tag, then by byte value. The configuration is required to arrive in
    /// this order for the same reason the currency header is: two declarations
    /// of one set must not be two different configurations.
    fn order(a: AccountMatcher, b: AccountMatcher) std.math.Order {
        const tags = std.math.order(@intFromEnum(a.tag), @intFromEnum(b.tag));
        if (tags != .eq) return tags;
        return std.mem.order(u8, a.value, b.value);
    }
};

/// A declared matcher is bounded here as well as at the wire boundary, so a
/// configuration built directly rather than decoded is bounded too.
pub const MAX_ACCOUNT_MATCHER_BYTES: usize = 128;

/// Trusted configuration installed by the runtime before handler code runs.
/// Currencies must be sorted by code so every consumer hashes the same header.
pub const Config = struct {
    ledger: []const u8,
    currencies: []const Currency,
    invariant_digest: [32]u8,
    /// The declared account set, or null when the specification declares no
    /// such invariant.
    ///
    /// Null and empty are deliberately different. Null is "this invariant was
    /// not declared"; an empty list would be "declared, and it admits nothing",
    /// which no specification can express and which `validateConfig` refuses.
    /// Collapsing them into one empty slice is how a declared invariant that
    /// lost its matchers on the way here would read as one that was never
    /// declared, and pass.
    accounts: ?[]const AccountMatcher = null,
};

pub const binding = sdk.ModuleBinding{
    .specifier = "zttp:ledger",
    .name = "ledger",
    .summary = "Post one balanced group to the configured protected ledger and read committed balances. Amounts are canonical signed decimal strings in declared minor units.",
    .required_capabilities = &.{ .sqlite, .crypto },
    .stateful = true,
    .sandboxable = true,
    .exports = &.{
        .{
            .name = "post",
            .module_func = postImpl,
            .arg_count = 1,
            .required_arg_count = 1,
            .effect = .write,
            .returns = .result,
            .signature = .{
                .params = &.{"{ ledger: string; currency: string; idempotencyKey: string; entries: { account: string; amount: string }[] }"},
                .returns = "{ ok: boolean; value?: { replayed: boolean }; error?: { tag: string } }",
            },
            .param_types = &.{.object},
            .param_names = &.{"group"},
            .failure_severity = .critical,
            .derives_from_args = true,
            .return_labels = .{ .internal = true },
        },
        .{
            .name = "balance",
            .module_func = balanceImpl,
            .arg_count = 3,
            .required_arg_count = 3,
            .effect = .read,
            .returns = .result,
            .signature = .{
                .params = &.{ "string", "string", "string" },
                .returns = "{ ok: boolean; value?: string; error?: { tag: string } }",
            },
            .param_types = &.{ .string, .string, .string },
            .param_names = &.{ "ledger", "currency", "account" },
            .failure_severity = .expected,
            .derives_from_args = true,
            .return_labels = .{ .secret = true, .internal = true },
        },
    },
};

// ---------------------------------------------------------------------------
// Enforced predicates, and the manifest derived from them
// ---------------------------------------------------------------------------

/// This adapter's own name for itself. The acceptance kernel states the same
/// string independently; the two are compared, never shared. Nothing in this
/// file reads a value from the kernel, which is what makes the comparison a
/// comparison rather than a constant meeting itself.
pub const adapter_identity = "zttp:ledger/native-adapter-v1";

/// The wire ordinals the closed invariant catalog gives the kinds this adapter
/// enforces. Restated here on purpose, for the same reason as the identity
/// above.
const balance_conservation_ordinal: u16 = 1;
const declared_accounts_ordinal: u16 = 2;

/// One invariant this adapter enforces, and the places it enforces it.
///
/// `group_fn` decides whether one posting group may commit. `baseline_fn`
/// decides whether an existing store may be served at all, and `account_fn`
/// decides whether one account name that store already holds is admissible.
/// All three are function pointers, so the dispatch below is a call through
/// the row rather than a hard-coded call standing beside a row that describes
/// it.
///
/// `account_fn` exists so a predicate over account names does not open a
/// second pass over the same rows. It is called from inside the single
/// exclusive walk that `baseline_fn` makes, at each of the two places that walk
/// already reads an account, which costs O(rows x matchers) CPU and no extra
/// statement.
pub const Predicate = struct {
    kind_ordinal: u16,
    predicate_version: u16,
    group_fn: *const fn (config: *const OwnedConfig, group: Group) anyerror!void,
    account_fn: ?*const fn (config: *const OwnedConfig, account: []const u8) anyerror!void = null,
    baseline_fn: ?*const fn (
        allocator: std.mem.Allocator,
        handle: *sdk.ModuleHandle,
        db: *sdk.SqliteDb,
        config: *const OwnedConfig,
    ) anyerror!void = null,
};

/// The dispatch table. `executePost`, `validateBaseline` and the stored-account
/// hook all iterate it, and nothing else decides whether a posting group may
/// commit or an existing store may be served. Rows ascend by wire ordinal,
/// which is the order the manifest encoder depends on.
const predicates = [_]Predicate{
    .{
        .kind_ordinal = balance_conservation_ordinal,
        .predicate_version = 1,
        .group_fn = validateGroup,
        .baseline_fn = validatePostingsAndBalances,
    },
    .{
        .kind_ordinal = declared_accounts_ordinal,
        .predicate_version = 1,
        .group_fn = validateDeclaredAccounts,
        .account_fn = requireDeclaredAccount,
    },
};

// Ascending, without repeats. The encoded manifest is order-sensitive, so two
// tables holding the same rows in different orders must not be expressible.
comptime {
    var previous: u16 = 0;
    for (predicates) |row| {
        if (row.kind_ordinal <= previous) {
            @compileError("the ledger predicate table must ascend by wire ordinal without repeating one");
        }
        previous = row.kind_ordinal;
    }
}

// A manifest row claims a predicate is enforced. A row with neither baseline
// hook enforces nothing over an existing store while still claiming a version,
// and a table with no `baseline_fn` at all would make no walk, so every
// `account_fn` would be called zero times and the baseline would report a pass.
comptime {
    var walkers: usize = 0;
    for (predicates) |row| {
        if (row.account_fn == null and row.baseline_fn == null) {
            @compileError("every ledger predicate row must decide something about an existing store");
        }
        if (row.baseline_fn != null) walkers += 1;
    }
    if (walkers == 0) {
        @compileError("no ledger predicate owns the store walk that feeds the account hooks");
    }
}

/// One manifest row per enforced predicate.
pub const ManifestPredicate = struct {
    kind_ordinal: u16,
    predicate_version: u16,
};

/// What this linked adapter enforces, in a shape a consumer can compare.
///
/// It carries the dispatch table, the store schema this adapter writes and
/// validates, and the export names the binding publishes. It deliberately says
/// nothing about the invariant wire schemas: this module never decodes a
/// specification, so a wire schema named here would be a value copied from the
/// consumer rather than a fact about the adapter, and comparing it would prove
/// nothing.
pub const AdapterManifest = struct {
    identity: []const u8,
    store_schema_version: i64,
    predicates: []const ManifestPredicate,
    exports: []const []const u8,
};

pub const adapter_manifest = AdapterManifest{
    .identity = adapter_identity,
    .store_schema_version = SCHEMA_VERSION,
    .predicates = &manifest_predicates,
    .exports = &manifest_exports,
};

const manifest_predicates = blk: {
    var rows: [predicates.len]ManifestPredicate = undefined;
    for (predicates, 0..) |row, index| {
        rows[index] = .{
            .kind_ordinal = row.kind_ordinal,
            .predicate_version = row.predicate_version,
        };
    }
    const frozen = rows;
    break :blk frozen;
};

const manifest_exports = blk: {
    var names: [binding.exports.len][]const u8 = undefined;
    for (binding.exports, 0..) |item, index| names[index] = item.name;
    const frozen = names;
    break :blk frozen;
};

const OwnedCurrency = struct {
    code: []u8,
    scale: u8,
};

const OwnedConfig = struct {
    ledger: []u8,
    currencies: []OwnedCurrency,
    invariant_digest: [32]u8,
    /// Null when the specification declared no account set. See `Config`.
    accounts: ?[]AccountMatcher,

    fn init(allocator: std.mem.Allocator, config: Config) !OwnedConfig {
        try validateConfig(config);

        const ledger = try allocator.dupe(u8, config.ledger);
        errdefer allocator.free(ledger);
        const currencies = try allocator.alloc(OwnedCurrency, config.currencies.len);
        errdefer allocator.free(currencies);

        var initialized: usize = 0;
        errdefer for (currencies[0..initialized]) |currency| allocator.free(currency.code);
        for (config.currencies, 0..) |currency, i| {
            currencies[i] = .{
                .code = try allocator.dupe(u8, currency.code),
                .scale = currency.scale,
            };
            initialized += 1;
        }

        var accounts: ?[]AccountMatcher = null;
        errdefer if (accounts) |owned| {
            for (owned) |matcher| allocator.free(matcher.value);
            allocator.free(owned);
        };
        if (config.accounts) |declared| {
            const rows = try allocator.alloc(AccountMatcher, declared.len);
            errdefer allocator.free(rows);
            var copied: usize = 0;
            errdefer for (rows[0..copied]) |matcher| allocator.free(matcher.value);
            for (declared, 0..) |matcher, i| {
                rows[i] = .{ .tag = matcher.tag, .value = try allocator.dupe(u8, matcher.value) };
                copied += 1;
            }
            accounts = rows;
        }

        return .{
            .ledger = ledger,
            .currencies = currencies,
            .invariant_digest = config.invariant_digest,
            .accounts = accounts,
        };
    }

    fn deinit(self: *OwnedConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.ledger);
        for (self.currencies) |currency| allocator.free(currency.code);
        allocator.free(self.currencies);
        if (self.accounts) |owned| {
            for (owned) |matcher| allocator.free(matcher.value);
            allocator.free(owned);
        }
        self.* = undefined;
    }

    fn hasCurrency(self: *const OwnedConfig, code: []const u8) bool {
        return self.currencyCode(code) != null;
    }

    /// Return store-owned memory so callers may retain the slice after a
    /// SQLite statement advances and invalidates its column-text view.
    fn currencyCode(self: *const OwnedConfig, code: []const u8) ?[]const u8 {
        for (self.currencies) |currency| {
            if (std.mem.eql(u8, currency.code, code)) return currency.code;
        }
        return null;
    }
};

pub const LedgerStore = struct {
    allocator: std.mem.Allocator,
    config: OwnedConfig,
    db: ?*sdk.SqliteDb = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) !LedgerStore {
        return .{
            .allocator = allocator,
            .config = try OwnedConfig.init(allocator, config),
        };
    }

    /// Open and validate the configured store before the runtime serves a
    /// request. The caller must enter the zttp:ledger active-module scope.
    pub fn validate(self: *LedgerStore, handle: *sdk.ModuleHandle) !void {
        _ = try self.ensureDb(handle);
    }

    fn deinitSelf(self: *LedgerStore) void {
        if (self.db) |db| sdk.sqliteClose(db);
        self.config.deinit(self.allocator);
    }

    pub fn sdkDeinit(ptr: *anyopaque) callconv(.c) void {
        const self: *LedgerStore = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        self.deinitSelf();
        allocator.destroy(self);
    }

    fn ensureDb(self: *LedgerStore, handle: *sdk.ModuleHandle) !*sdk.SqliteDb {
        if (self.db) |db| return db;
        const db = try sdk.ledgerOpen(handle);
        self.db = db;
        errdefer if (self.db == db) {
            sdk.sqliteClose(db);
            self.db = null;
        };
        try execDone(db, "PRAGMA foreign_keys = ON");
        try execDone(db, "PRAGMA synchronous = FULL");
        try self.bootstrapOrValidate(handle, db);
        return db;
    }

    fn bootstrapOrValidate(self: *LedgerStore, handle: *sdk.ModuleHandle, db: *sdk.SqliteDb) !void {
        try execDone(db, "BEGIN EXCLUSIVE");
        var committed = false;
        defer if (!committed) rollbackOrClose(self, db);

        const table_state = try inspectTables(db);
        if (table_state == .empty) {
            try self.initializeSchema(db);
        } else {
            try validateExpectedTables(db);
        }
        try self.validateBaseline(handle, db);
        try execDone(db, "COMMIT");
        committed = true;
    }

    fn initializeSchema(self: *LedgerStore, db: *sdk.SqliteDb) !void {
        for (schema_statements) |statement| try execDone(db, statement);

        const digest_hex = std.fmt.bytesToHex(self.config.invariant_digest, .lower);
        try execBound(
            db,
            "INSERT INTO ledger_meta (singleton, schema_version, ledger, invariant_digest) VALUES (1, ?1, ?2, ?3)",
            &.{ .{ .int = SCHEMA_VERSION }, .{ .text = self.config.ledger }, .{ .text = &digest_hex } },
        );
        for (self.config.currencies) |currency| {
            try execBound(
                db,
                "INSERT INTO ledger_currencies (code, scale) VALUES (?1, ?2)",
                &.{ .{ .text = currency.code }, .{ .int = currency.scale } },
            );
        }
    }

    fn validateBaseline(self: *LedgerStore, handle: *sdk.ModuleHandle, db: *sdk.SqliteDb) !void {
        try validateIntegrity(db);
        try self.validateMetadata(db);
        try self.validateCurrencies(db);
        // Every enforced predicate runs over the whole store before it is
        // served. The loop is the enforcement: a row added to the table starts
        // being checked here without this function being edited, and a row
        // removed stops being checked, which is what makes the manifest built
        // from the table describe what actually runs. A row whose predicate is
        // per-account rides inside the walk one of these makes, through
        // `checkStoredAccount` below, rather than opening a second pass.
        for (predicates) |row| if (row.baseline_fn) |run| try run(self.allocator, handle, db, &self.config);
    }

    fn validateMetadata(self: *LedgerStore, db: *sdk.SqliteDb) !void {
        const stmt = sdk.sqlitePrepare(db, "SELECT schema_version, ledger, invariant_digest FROM ledger_meta WHERE singleton = 1") orelse return error.InvalidLedgerSchema;
        defer sdk.sqliteFinalize(stmt);
        if (sdk.sqliteStep(stmt) != sdk.sqlite_row) return error.InvalidLedgerMetadata;
        if (sdk.sqliteColumnType(stmt, 0) != sdk.sqlite_integer or
            sdk.sqliteColumnType(stmt, 1) != sdk.sqlite_text or
            sdk.sqliteColumnType(stmt, 2) != sdk.sqlite_text)
        {
            return error.InvalidLedgerMetadata;
        }
        if (sdk.sqliteColumnInt64(stmt, 0) != SCHEMA_VERSION) return error.UnsupportedLedgerSchema;
        if (!std.mem.eql(u8, sdk.sqliteColumnText(stmt, 1), self.config.ledger)) return error.LedgerConfigMismatch;
        const digest_hex = std.fmt.bytesToHex(self.config.invariant_digest, .lower);
        if (!std.mem.eql(u8, sdk.sqliteColumnText(stmt, 2), &digest_hex)) return error.LedgerConfigMismatch;
        if (sdk.sqliteStep(stmt) != sdk.sqlite_done) return error.InvalidLedgerMetadata;
    }

    fn validateCurrencies(self: *LedgerStore, db: *sdk.SqliteDb) !void {
        const stmt = sdk.sqlitePrepare(db, "SELECT code, scale FROM ledger_currencies ORDER BY code") orelse return error.InvalidLedgerSchema;
        defer sdk.sqliteFinalize(stmt);
        var index: usize = 0;
        while (true) {
            const rc = sdk.sqliteStep(stmt);
            if (rc == sdk.sqlite_done) break;
            if (rc != sdk.sqlite_row or index >= self.config.currencies.len) return error.LedgerConfigMismatch;
            if (sdk.sqliteColumnType(stmt, 0) != sdk.sqlite_text or sdk.sqliteColumnType(stmt, 1) != sdk.sqlite_integer) return error.InvalidLedgerMetadata;
            const expected = self.config.currencies[index];
            if (!std.mem.eql(u8, sdk.sqliteColumnText(stmt, 0), expected.code) or
                sdk.sqliteColumnInt64(stmt, 1) != expected.scale)
            {
                return error.LedgerConfigMismatch;
            }
            index += 1;
        }
        if (index != self.config.currencies.len) return error.LedgerConfigMismatch;
    }

    fn executePost(self: *LedgerStore, handle: *sdk.ModuleHandle, group: Group) !bool {
        if (!std.mem.eql(u8, group.ledger, self.config.ledger)) return error.WrongLedger;
        if (!self.config.hasCurrency(group.currency)) return error.UnsupportedCurrency;
        // The same table, on the write path. A group that any enforced
        // predicate refuses never reaches a transaction.
        for (predicates) |row| try row.group_fn(&self.config, group);

        const db = try self.ensureDb(handle);
        var content_hash: [64]u8 = undefined;
        try contentHash(self.allocator, handle, group, &content_hash);

        try execDone(db, "BEGIN IMMEDIATE");
        var committed = false;
        defer if (!committed) rollbackOrClose(self, db);

        switch (try checkIdempotency(db, group, &content_hash)) {
            .same => {
                try execDone(db, "COMMIT");
                committed = true;
                return true;
            },
            .conflict => return error.IdempotencyConflict,
            .missing => {},
        }

        try execBound(
            db,
            "INSERT INTO ledger_postings (ledger, currency, idempotency_key, content_hash) VALUES (?1, ?2, ?3, ?4)",
            &.{ .{ .text = group.ledger }, .{ .text = group.currency }, .{ .text = group.idempotency_key }, .{ .text = &content_hash } },
        );
        const posting_id = sdk.sqliteLastInsertRowId(db);

        var deltas = std.StringHashMap(i128).init(self.allocator);
        defer deltas.deinit();
        for (group.entries, 0..) |entry, position| {
            try execBound(
                db,
                "INSERT INTO ledger_entries (posting_id, position, account, amount) VALUES (?1, ?2, ?3, ?4)",
                &.{ .{ .int = posting_id }, .{ .int = @intCast(position) }, .{ .text = entry.account }, .{ .int = entry.amount } },
            );
            const delta = try deltas.getOrPut(entry.account);
            if (!delta.found_existing) delta.value_ptr.* = 0;
            delta.value_ptr.* = try addI128(delta.value_ptr.*, entry.amount);
        }
        var accounts = deltas.iterator();
        while (accounts.next()) |account| {
            const current = try readBalanceValue(db, group.ledger, group.currency, account.key_ptr.*);
            const next = std.math.cast(i64, try addI128(current, account.value_ptr.*)) orelse return error.BalanceOverflow;
            try execBound(
                db,
                "INSERT INTO ledger_balances (ledger, currency, account, balance) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (ledger, currency, account) DO UPDATE SET balance = excluded.balance",
                &.{ .{ .text = group.ledger }, .{ .text = group.currency }, .{ .text = account.key_ptr.* }, .{ .int = next } },
            );
        }

        execDone(db, "COMMIT") catch |err| return err;
        committed = true;
        return false;
    }

    fn readBalance(self: *LedgerStore, handle: *sdk.ModuleHandle, ledger: []const u8, currency: []const u8, account: []const u8) !i64 {
        if (!std.mem.eql(u8, ledger, self.config.ledger)) return error.WrongLedger;
        if (!self.config.hasCurrency(currency)) return error.UnsupportedCurrency;
        try validateText(account);
        const db = try self.ensureDb(handle);
        return readBalanceValue(db, ledger, currency, account);
    }
};

const Entry = struct {
    account: []const u8,
    amount_text: []const u8,
    amount: i64,
};

const Group = struct {
    ledger: []const u8,
    currency: []const u8,
    idempotency_key: []const u8,
    entries: []const Entry,
};

fn postImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    if (args.len != 1 or !sdk.isObject(args[0])) return resultError(handle, "invalid_input");
    const allocator = sdk.getAllocator(handle);
    const group = decodeGroup(allocator, handle, args[0]) catch |err| return resultError(handle, errorTag(err));
    defer allocator.free(group.entries);

    const store = getInstalledStore(handle) orelse return resultError(handle, "ledger_unavailable");
    const replayed = store.executePost(handle, group) catch |err| return resultError(handle, errorTag(err));
    const payload = try sdk.createObject(handle);
    try sdk.objectSet(handle, payload, "replayed", sdk.JSValue.fromBool(replayed));
    return sdk.resultOk(handle, payload);
}

fn balanceImpl(handle: *sdk.ModuleHandle, _: sdk.JSValue, args: []const sdk.JSValue) anyerror!sdk.JSValue {
    if (args.len != 3) return resultError(handle, "invalid_input");
    const ledger = sdk.extractString(args[0]) orelse return resultError(handle, "invalid_input");
    const currency = sdk.extractString(args[1]) orelse return resultError(handle, "invalid_input");
    const account = sdk.extractString(args[2]) orelse return resultError(handle, "invalid_input");
    const store = getInstalledStore(handle) orelse return resultError(handle, "ledger_unavailable");
    const value = store.readBalance(handle, ledger, currency, account) catch |err| return resultError(handle, errorTag(err));
    var buffer: [21]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    return sdk.resultOk(handle, try sdk.createString(handle, text));
}

fn getInstalledStore(handle: *sdk.ModuleHandle) ?*LedgerStore {
    return sdk.getModuleState(handle, LedgerStore, MODULE_STATE_SLOT);
}

fn decodeGroup(allocator: std.mem.Allocator, handle: *sdk.ModuleHandle, value: sdk.JSValue) !Group {
    const ledger = sdk.extractString(sdk.objectGet(handle, value, "ledger") orelse return error.InvalidInput) orelse return error.InvalidInput;
    const currency = sdk.extractString(sdk.objectGet(handle, value, "currency") orelse return error.InvalidInput) orelse return error.InvalidInput;
    const key = sdk.extractString(sdk.objectGet(handle, value, "idempotencyKey") orelse return error.InvalidInput) orelse return error.InvalidInput;
    const entries_value = sdk.objectGet(handle, value, "entries") orelse return error.InvalidInput;
    const entries_len = sdk.arrayLength(entries_value) orelse return error.InvalidInput;
    if (entries_len == 0) return error.InvalidInput;
    try validateText(ledger);
    try validateText(currency);
    try validateText(key);

    const entries = try allocator.alloc(Entry, entries_len);
    errdefer allocator.free(entries);
    for (entries, 0..) |*entry, i| {
        const entry_value = sdk.arrayGet(handle, entries_value, @intCast(i)) orelse return error.InvalidInput;
        if (!sdk.isObject(entry_value)) return error.InvalidInput;
        const account = sdk.extractString(sdk.objectGet(handle, entry_value, "account") orelse return error.InvalidInput) orelse return error.InvalidInput;
        const amount_text = sdk.extractString(sdk.objectGet(handle, entry_value, "amount") orelse return error.InvalidInput) orelse return error.InvalidInput;
        try validateText(account);
        entry.* = .{
            .account = account,
            .amount_text = amount_text,
            .amount = try parseCanonicalAmount(amount_text),
        };
    }
    return .{
        .ledger = ledger,
        .currency = currency,
        .idempotency_key = key,
        .entries = entries,
    };
}

fn validateConfig(config: Config) !void {
    try validateText(config.ledger);
    if (config.currencies.len == 0) return error.InvalidConfig;
    var previous: ?[]const u8 = null;
    for (config.currencies) |currency| {
        try validateText(currency.code);
        if (previous) |code| {
            if (std.mem.order(u8, code, currency.code) != .lt) return error.InvalidConfig;
        }
        previous = currency.code;
    }
    if (config.accounts) |declared| {
        // Declared and empty is not expressible: an empty set admits nothing,
        // and accepting it here would install a store no posting could ever
        // reach while reading, in every summary, as a declared invariant.
        if (declared.len == 0) return error.InvalidConfig;
        var prior: ?AccountMatcher = null;
        for (declared) |matcher| {
            try validateText(matcher.value);
            if (matcher.value.len > MAX_ACCOUNT_MATCHER_BYTES) return error.InvalidConfig;
            if (prior) |before| {
                if (AccountMatcher.order(before, matcher) != .lt) return error.InvalidConfig;
            }
            prior = matcher;
        }
    }
}

fn validateText(text: []const u8) !void {
    if (text.len == 0 or std.mem.findScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidInput;
}

pub fn parseCanonicalAmount(text: []const u8) !i64 {
    if (text.len == 0) return error.InvalidAmount;
    if (std.mem.eql(u8, text, "0")) return 0;
    var start: usize = 0;
    if (text[0] == '-') {
        if (text.len == 1 or text[1] == '0') return error.InvalidAmount;
        start = 1;
    } else if (text[0] == '+' or text[0] == '0') {
        return error.InvalidAmount;
    }
    for (text[start..]) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidAmount;
    }
    return std.fmt.parseInt(i64, text, 10) catch error.AmountOverflow;
}

fn validateGroup(_: *const OwnedConfig, group: Group) anyerror!void {
    if (group.entries.len == 0) return error.InvalidInput;
    var sum: i128 = 0;
    for (group.entries) |entry| sum = addI128(sum, entry.amount) catch return error.AmountOverflow;
    if (sum != 0) return error.Unbalanced;
}

/// Whether `account` satisfies at least one declared rule.
fn matchesDeclared(declared: []const AccountMatcher, account: []const u8) bool {
    for (declared) |matcher| {
        if (matcher.matches(account)) return true;
    }
    return false;
}

/// The write-path half of `declared_accounts_v1`.
///
/// Every entry is checked, so a zero-amount entry and a pair that cancels on
/// one account are checked like any other: the invariant is over the account
/// a posting names, not over the balance it leaves behind. One failing entry
/// refuses the whole group, before `executePost` opens a transaction.
fn validateDeclaredAccounts(config: *const OwnedConfig, group: Group) anyerror!void {
    const declared = config.accounts orelse return;
    for (group.entries) |entry| {
        if (!matchesDeclared(declared, entry.account)) return error.UndeclaredAccount;
    }
}

/// The stored-account half of `declared_accounts_v1`.
///
/// A distinct error from the write path on purpose: "the group you posted
/// names an undeclared account" and "the store you configured already holds
/// one" are different facts, and a test that could not tell them apart would
/// pass on either.
fn requireDeclaredAccount(config: *const OwnedConfig, account: []const u8) anyerror!void {
    const declared = config.accounts orelse return;
    if (!matchesDeclared(declared, account)) return error.UndeclaredStoredAccount;
}

/// Every enforced predicate's rule over one account name the store holds.
///
/// Called from inside the single exclusive walk below, at each of the two
/// places that walk already reads an account. The loop is the enforcement, for
/// the same reason the two loops above are.
fn checkStoredAccount(config: *const OwnedConfig, account: []const u8) !void {
    for (predicates) |row| if (row.account_fn) |check| try check(config, account);
}

fn addI128(left: i128, right: i128) !i128 {
    const sum, const overflow = @addWithOverflow(left, right);
    if (overflow != 0) return error.ArithmeticOverflow;
    return sum;
}

const ContentHasher = struct {
    digest: sdk.Sha256Digest,

    fn init(handle: *sdk.ModuleHandle) !ContentHasher {
        var digest: sdk.Sha256Digest = undefined;
        // sdk.sha256 reaches sha256ForActiveModule through the capability-gated bridge.
        try sdk.sha256(handle, "zttp-ledger-content-v1", &digest);
        return .{ .digest = digest };
    }

    fn update(self: *ContentHasher, allocator: std.mem.Allocator, handle: *sdk.ModuleHandle, field: []const u8) !void {
        if (field.len > std.math.maxInt(usize) - 40) return error.OutOfMemory;
        const framed = try allocator.alloc(u8, 40 + field.len);
        defer allocator.free(framed);
        @memcpy(framed[0..32], &self.digest);
        std.mem.writeInt(u64, framed[32..40], @intCast(field.len), .big);
        @memcpy(framed[40..], field);
        try sdk.sha256(handle, framed, &self.digest);
    }

    fn finish(self: *const ContentHasher, out: *[64]u8) void {
        out.* = std.fmt.bytesToHex(self.digest, .lower);
    }
};

fn contentHash(allocator: std.mem.Allocator, handle: *sdk.ModuleHandle, group: Group, out: *[64]u8) !void {
    var hasher = try ContentHasher.init(handle);
    try hasher.update(allocator, handle, group.ledger);
    try hasher.update(allocator, handle, group.currency);
    for (group.entries) |entry| {
        try hasher.update(allocator, handle, entry.account);
        try hasher.update(allocator, handle, entry.amount_text);
    }
    hasher.finish(out);
}

const BoundValue = union(enum) {
    text: []const u8,
    int: i64,
};

fn bindAll(stmt: *sdk.SqliteStmt, values: []const BoundValue) !void {
    for (values, 0..) |value, i| switch (value) {
        .text => |text| try sdk.sqliteBindText(stmt, @intCast(i + 1), text),
        .int => |int| try sdk.sqliteBindInt64(stmt, @intCast(i + 1), int),
    };
}

fn execDone(db: *sdk.SqliteDb, sql: []const u8) !void {
    const stmt = sdk.sqlitePrepare(db, sql) orelse return error.SqlitePrepareFailed;
    defer sdk.sqliteFinalize(stmt);
    const rc = sdk.sqliteStep(stmt);
    if (rc == sqlite_busy) return error.SqliteBusy;
    if (rc != sdk.sqlite_done) return error.SqliteExecutionFailed;
}

fn execBound(db: *sdk.SqliteDb, sql: []const u8, values: []const BoundValue) !void {
    const stmt = sdk.sqlitePrepare(db, sql) orelse return error.SqlitePrepareFailed;
    defer sdk.sqliteFinalize(stmt);
    try bindAll(stmt, values);
    const rc = sdk.sqliteStep(stmt);
    if (rc == sqlite_busy) return error.SqliteBusy;
    if (rc != sdk.sqlite_done) return error.SqliteExecutionFailed;
}

fn rollbackOrClose(store: *LedgerStore, db: *sdk.SqliteDb) void {
    execDone(db, "ROLLBACK") catch {
        sdk.sqliteClose(db);
        if (store.db == db) store.db = null;
    };
}

const TableState = enum { empty, present };

const expected_tables = [_][]const u8{
    "ledger_balances",
    "ledger_currencies",
    "ledger_entries",
    "ledger_meta",
    "ledger_postings",
};

fn inspectTables(db: *sdk.SqliteDb) !TableState {
    const stmt = sdk.sqlitePrepare(db, "SELECT name FROM sqlite_master WHERE type IN ('table', 'index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%' LIMIT 1") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(stmt);
    return switch (sdk.sqliteStep(stmt)) {
        sdk.sqlite_done => .empty,
        sdk.sqlite_row => .present,
        else => error.SqliteExecutionFailed,
    };
}

fn validateExpectedTables(db: *sdk.SqliteDb) !void {
    const stmt = sdk.sqlitePrepare(db, "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(stmt);
    var index: usize = 0;
    while (true) {
        const rc = sdk.sqliteStep(stmt);
        if (rc == sdk.sqlite_done) break;
        if (rc != sdk.sqlite_row or index >= expected_tables.len or
            sdk.sqliteColumnType(stmt, 0) != sdk.sqlite_text or sdk.sqliteColumnType(stmt, 1) != sdk.sqlite_text)
        {
            return error.InvalidLedgerSchema;
        }
        if (!std.mem.eql(u8, sdk.sqliteColumnText(stmt, 0), expected_tables[index])) return error.InvalidLedgerSchema;
        const expected_sql = expectedSchema(expected_tables[index]) orelse return error.InvalidLedgerSchema;
        if (!std.mem.eql(u8, sdk.sqliteColumnText(stmt, 1), expected_sql)) return error.InvalidLedgerSchema;
        index += 1;
    }
    if (index != expected_tables.len) return error.InvalidLedgerSchema;

    // Autoindexes that SQLite creates for PRIMARY KEY and UNIQUE constraints
    // use reserved sqlite_* names. Every application-defined index, trigger,
    // or view is outside this adapter's schema and could change write behavior.
    const extra = sdk.sqlitePrepare(db, "SELECT name FROM sqlite_master WHERE type IN ('index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%' LIMIT 1") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(extra);
    if (sdk.sqliteStep(extra) != sdk.sqlite_done) return error.InvalidLedgerSchema;
}

fn expectedSchema(table: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, table, "ledger_meta")) return schema_statements[0];
    if (std.mem.eql(u8, table, "ledger_currencies")) return schema_statements[1];
    if (std.mem.eql(u8, table, "ledger_postings")) return schema_statements[2];
    if (std.mem.eql(u8, table, "ledger_entries")) return schema_statements[3];
    if (std.mem.eql(u8, table, "ledger_balances")) return schema_statements[4];
    return null;
}

fn validateIntegrity(db: *sdk.SqliteDb) !void {
    const stmt = sdk.sqlitePrepare(db, "PRAGMA integrity_check") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(stmt);
    if (sdk.sqliteStep(stmt) != sdk.sqlite_row or sdk.sqliteColumnType(stmt, 0) != sdk.sqlite_text or
        !std.mem.eql(u8, sdk.sqliteColumnText(stmt, 0), "ok") or sdk.sqliteStep(stmt) != sdk.sqlite_done)
    {
        return error.CorruptLedger;
    }
    const foreign_keys = sdk.sqlitePrepare(db, "PRAGMA foreign_key_check") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(foreign_keys);
    if (sdk.sqliteStep(foreign_keys) != sdk.sqlite_done) return error.CorruptLedger;
}

fn validatePostingsAndBalances(allocator: std.mem.Allocator, handle: *sdk.ModuleHandle, db: *sdk.SqliteDb, config: *const OwnedConfig) anyerror!void {
    var computed = std.StringHashMap(i128).init(allocator);
    defer {
        var iterator = computed.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        computed.deinit();
    }

    const entries = sdk.sqlitePrepare(db, "SELECT p.id, p.ledger, p.currency, e.account, e.amount FROM ledger_postings p LEFT JOIN ledger_entries e ON e.posting_id = p.id ORDER BY p.id, e.position") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(entries);
    var current_posting: ?i64 = null;
    var posting_sum: i128 = 0;
    var posting_has_entry = false;
    while (true) {
        const rc = sdk.sqliteStep(entries);
        if (rc == sdk.sqlite_done) break;
        if (rc != sdk.sqlite_row or sdk.sqliteColumnType(entries, 0) != sdk.sqlite_integer) return error.CorruptLedger;
        const posting = sdk.sqliteColumnInt64(entries, 0);
        if (current_posting == null or posting != current_posting.?) {
            if (current_posting) |previous| {
                if (!posting_has_entry or posting_sum != 0) return error.InvariantViolated;
                try validatePostingContent(allocator, handle, db, previous);
            }
            current_posting = posting;
            posting_sum = 0;
            posting_has_entry = false;
        }
        if (sdk.sqliteColumnType(entries, 4) == sdk.sqlite_null) continue;
        if (sdk.sqliteColumnType(entries, 1) != sdk.sqlite_text or
            sdk.sqliteColumnType(entries, 2) != sdk.sqlite_text or
            sdk.sqliteColumnType(entries, 3) != sdk.sqlite_text or
            sdk.sqliteColumnType(entries, 4) != sdk.sqlite_integer)
        {
            return error.CorruptLedger;
        }
        validateText(sdk.sqliteColumnText(entries, 1)) catch return error.CorruptLedger;
        validateText(sdk.sqliteColumnText(entries, 2)) catch return error.CorruptLedger;
        validateText(sdk.sqliteColumnText(entries, 3)) catch return error.CorruptLedger;
        if (!std.mem.eql(u8, sdk.sqliteColumnText(entries, 1), config.ledger) or
            !config.hasCurrency(sdk.sqliteColumnText(entries, 2)))
        {
            return error.CorruptLedger;
        }
        // The account this row already produced, handed to every per-account
        // predicate before it is accumulated. No statement is added: this is
        // the same column the balance arithmetic below reads.
        try checkStoredAccount(config, sdk.sqliteColumnText(entries, 3));
        posting_has_entry = true;
        const amount = sdk.sqliteColumnInt64(entries, 4);
        posting_sum = addI128(posting_sum, amount) catch return error.ArithmeticOverflow;
        const key = try accountKey(allocator, sdk.sqliteColumnText(entries, 1), sdk.sqliteColumnText(entries, 2), sdk.sqliteColumnText(entries, 3));
        if (computed.getPtr(key)) |balance| {
            allocator.free(key);
            balance.* = addI128(balance.*, amount) catch return error.ArithmeticOverflow;
        } else {
            computed.put(key, amount) catch |err| {
                allocator.free(key);
                return err;
            };
        }
    }
    if (current_posting) |posting| {
        if (!posting_has_entry or posting_sum != 0) return error.InvariantViolated;
        try validatePostingContent(allocator, handle, db, posting);
    }

    const balances = sdk.sqlitePrepare(db, "SELECT ledger, currency, account, balance FROM ledger_balances ORDER BY ledger, currency, account") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(balances);
    var currency: ?[]const u8 = null;
    var currency_total: i128 = 0;
    while (true) {
        const rc = sdk.sqliteStep(balances);
        if (rc == sdk.sqlite_done) break;
        if (rc != sdk.sqlite_row or sdk.sqliteColumnType(balances, 0) != sdk.sqlite_text or
            sdk.sqliteColumnType(balances, 1) != sdk.sqlite_text or
            sdk.sqliteColumnType(balances, 2) != sdk.sqlite_text or
            sdk.sqliteColumnType(balances, 3) != sdk.sqlite_integer)
        {
            return error.CorruptLedger;
        }
        validateText(sdk.sqliteColumnText(balances, 0)) catch return error.CorruptLedger;
        validateText(sdk.sqliteColumnText(balances, 1)) catch return error.CorruptLedger;
        validateText(sdk.sqliteColumnText(balances, 2)) catch return error.CorruptLedger;
        if (!std.mem.eql(u8, sdk.sqliteColumnText(balances, 0), config.ledger) or
            !config.hasCurrency(sdk.sqliteColumnText(balances, 1)))
        {
            return error.CorruptLedger;
        }
        // Every materialized balance row, including one whose balance is zero.
        // The cross-check below already pairs each historical entry account
        // with a balances row, so this walk alone covers the set; the entry
        // side above is checked as well because that pairing is a conclusion
        // of this same pass rather than a precondition of it, and because an
        // undeclared account is then reported from the row that introduced it.
        try checkStoredAccount(config, sdk.sqliteColumnText(balances, 2));
        const row_currency = sdk.sqliteColumnText(balances, 1);
        const stable_currency = config.currencyCode(row_currency) orelse return error.CorruptLedger;
        if (currency == null or !std.mem.eql(u8, currency.?, row_currency)) {
            if (currency != null and currency_total != 0) return error.InvariantViolated;
            currency = stable_currency;
            currency_total = 0;
        }
        const stored = sdk.sqliteColumnInt64(balances, 3);
        currency_total = addI128(currency_total, stored) catch return error.ArithmeticOverflow;
        const key = try accountKey(allocator, sdk.sqliteColumnText(balances, 0), row_currency, sdk.sqliteColumnText(balances, 2));
        defer allocator.free(key);
        const computed_entry = computed.fetchRemove(key) orelse return error.CorruptLedger;
        defer allocator.free(computed_entry.key);
        if (computed_entry.value < std.math.minInt(i64) or computed_entry.value > std.math.maxInt(i64) or
            stored != @as(i64, @intCast(computed_entry.value)))
        {
            return error.InvariantViolated;
        }
    }
    if (currency != null and currency_total != 0) return error.InvariantViolated;
    if (computed.count() != 0) return error.CorruptLedger;
}

fn validatePostingContent(allocator: std.mem.Allocator, handle: *sdk.ModuleHandle, db: *sdk.SqliteDb, posting_id: i64) !void {
    const posting = sdk.sqlitePrepare(db, "SELECT ledger, currency, idempotency_key, content_hash FROM ledger_postings WHERE id = ?1") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(posting);
    try sdk.sqliteBindInt64(posting, 1, posting_id);
    if (sdk.sqliteStep(posting) != sdk.sqlite_row or
        sdk.sqliteColumnType(posting, 0) != sdk.sqlite_text or
        sdk.sqliteColumnType(posting, 1) != sdk.sqlite_text or
        sdk.sqliteColumnType(posting, 2) != sdk.sqlite_text or
        sdk.sqliteColumnType(posting, 3) != sdk.sqlite_text)
    {
        return error.CorruptLedger;
    }
    const ledger = sdk.sqliteColumnText(posting, 0);
    const currency = sdk.sqliteColumnText(posting, 1);
    const key = sdk.sqliteColumnText(posting, 2);
    const stored_hash = sdk.sqliteColumnText(posting, 3);
    validateText(ledger) catch return error.CorruptLedger;
    validateText(currency) catch return error.CorruptLedger;
    validateText(key) catch return error.CorruptLedger;
    if (!isLowerHexDigest(stored_hash)) return error.CorruptLedger;

    var hasher = try ContentHasher.init(handle);
    try hasher.update(allocator, handle, ledger);
    try hasher.update(allocator, handle, currency);
    const entry = sdk.sqlitePrepare(db, "SELECT position, account, amount FROM ledger_entries WHERE posting_id = ?1 ORDER BY position") orelse return error.InvalidLedgerSchema;
    defer sdk.sqliteFinalize(entry);
    try sdk.sqliteBindInt64(entry, 1, posting_id);
    var position: i64 = 0;
    while (true) {
        const rc = sdk.sqliteStep(entry);
        if (rc == sdk.sqlite_done) break;
        if (rc != sdk.sqlite_row or sdk.sqliteColumnType(entry, 0) != sdk.sqlite_integer or
            sdk.sqliteColumnType(entry, 1) != sdk.sqlite_text or sdk.sqliteColumnType(entry, 2) != sdk.sqlite_integer or
            sdk.sqliteColumnInt64(entry, 0) != position)
        {
            return error.CorruptLedger;
        }
        const account = sdk.sqliteColumnText(entry, 1);
        validateText(account) catch return error.CorruptLedger;
        var amount_buffer: [21]u8 = undefined;
        const amount = std.fmt.bufPrint(&amount_buffer, "{d}", .{sdk.sqliteColumnInt64(entry, 2)}) catch return error.CorruptLedger;
        try hasher.update(allocator, handle, account);
        try hasher.update(allocator, handle, amount);
        position += 1;
    }
    if (position == 0) return error.InvariantViolated;
    var computed_hash: [64]u8 = undefined;
    hasher.finish(&computed_hash);
    if (!std.mem.eql(u8, stored_hash, &computed_hash)) return error.CorruptLedger;
    if (sdk.sqliteStep(posting) != sdk.sqlite_done) return error.CorruptLedger;
}

fn isLowerHexDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn accountKey(allocator: std.mem.Allocator, ledger: []const u8, currency: []const u8, account: []const u8) ![]u8 {
    const key = try allocator.alloc(u8, ledger.len + currency.len + account.len + 2);
    var index: usize = 0;
    @memcpy(key[index..][0..ledger.len], ledger);
    index += ledger.len;
    key[index] = 0;
    index += 1;
    @memcpy(key[index..][0..currency.len], currency);
    index += currency.len;
    key[index] = 0;
    index += 1;
    @memcpy(key[index..][0..account.len], account);
    return key;
}

const Idempotency = enum { missing, same, conflict };

fn checkIdempotency(db: *sdk.SqliteDb, group: Group, expected_hash: []const u8) !Idempotency {
    const stmt = sdk.sqlitePrepare(db, "SELECT content_hash FROM ledger_postings WHERE ledger = ?1 AND currency = ?2 AND idempotency_key = ?3") orelse return error.SqlitePrepareFailed;
    defer sdk.sqliteFinalize(stmt);
    try bindAll(stmt, &.{ .{ .text = group.ledger }, .{ .text = group.currency }, .{ .text = group.idempotency_key } });
    const rc = sdk.sqliteStep(stmt);
    if (rc == sdk.sqlite_done) return .missing;
    if (rc != sdk.sqlite_row or sdk.sqliteColumnType(stmt, 0) != sdk.sqlite_text) return error.CorruptLedger;
    const result: Idempotency = if (std.mem.eql(u8, sdk.sqliteColumnText(stmt, 0), expected_hash)) .same else .conflict;
    if (sdk.sqliteStep(stmt) != sdk.sqlite_done) return error.CorruptLedger;
    return result;
}

fn readBalanceValue(db: *sdk.SqliteDb, ledger: []const u8, currency: []const u8, account: []const u8) !i64 {
    const stmt = sdk.sqlitePrepare(db, "SELECT balance FROM ledger_balances WHERE ledger = ?1 AND currency = ?2 AND account = ?3") orelse return error.SqlitePrepareFailed;
    defer sdk.sqliteFinalize(stmt);
    try bindAll(stmt, &.{ .{ .text = ledger }, .{ .text = currency }, .{ .text = account } });
    const rc = sdk.sqliteStep(stmt);
    if (rc == sdk.sqlite_done) return 0;
    if (rc != sdk.sqlite_row or sdk.sqliteColumnType(stmt, 0) != sdk.sqlite_integer) return error.CorruptLedger;
    const value = sdk.sqliteColumnInt64(stmt, 0);
    if (sdk.sqliteStep(stmt) != sdk.sqlite_done) return error.CorruptLedger;
    return value;
}

fn resultError(handle: *sdk.ModuleHandle, tag: []const u8) !sdk.JSValue {
    const payload = try sdk.createObject(handle);
    try sdk.objectSet(handle, payload, "tag", try sdk.createString(handle, tag));
    return sdk.resultErrValue(handle, payload);
}

fn errorTag(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidInput, error.InvalidAmount => "invalid_input",
        error.AmountOverflow => "amount_overflow",
        error.WrongLedger => "wrong_ledger",
        error.UnsupportedCurrency => "unsupported_currency",
        error.Unbalanced => "unbalanced",
        error.UndeclaredAccount => "undeclared_account",
        error.BalanceOverflow => "balance_overflow",
        error.IdempotencyConflict => "idempotency_conflict",
        error.SqliteBusy => "storage_busy",
        error.InvalidLedgerSchema,
        error.InvalidLedgerMetadata,
        error.UnsupportedLedgerSchema,
        error.LedgerConfigMismatch,
        error.CorruptLedger,
        error.InvariantViolated,
        // A store holding an account the configured specification does not
        // declare is the same class as a store whose metadata disagrees with
        // it: the store cannot be served under this configuration. It is not
        // the caller's posting, so it does not carry the caller's tag.
        error.UndeclaredStoredAccount,
        error.ArithmeticOverflow,
        => "ledger_corrupt",
        error.MissingModuleCapability, error.LedgerNotConfigured => "ledger_unavailable",
        else => "storage_error",
    };
}

test "canonical amounts cover the full i64 range" {
    try std.testing.expectEqual(@as(i64, 0), try parseCanonicalAmount("0"));
    try std.testing.expectEqual(std.math.maxInt(i64), try parseCanonicalAmount("9223372036854775807"));
    try std.testing.expectEqual(std.math.minInt(i64), try parseCanonicalAmount("-9223372036854775808"));
    try std.testing.expectError(error.AmountOverflow, parseCanonicalAmount("9223372036854775808"));
    try std.testing.expectError(error.AmountOverflow, parseCanonicalAmount("-9223372036854775809"));
}

test "canonical amounts reject alternate decimal spellings" {
    const invalid = [_][]const u8{ "", "+1", "00", "01", "-0", "-01", " 1", "1 ", "1.0", "1e2" };
    for (invalid) |text| try std.testing.expectError(error.InvalidAmount, parseCanonicalAmount(text));
}

test "posting groups require exact zero sum using i128 accumulation" {
    const balanced = [_]Entry{
        .{ .account = "source", .amount_text = "-9223372036854775808", .amount = std.math.minInt(i64) },
        .{ .account = "target-a", .amount_text = "9223372036854775807", .amount = std.math.maxInt(i64) },
        .{ .account = "target-b", .amount_text = "1", .amount = 1 },
    };
    var config = try ownedFor(null);
    defer config.deinit(std.testing.allocator);
    try validateGroup(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &balanced });
    const unbalanced = [_]Entry{.{ .account = "source", .amount_text = "1", .amount = 1 }};
    try std.testing.expectError(error.Unbalanced, validateGroup(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &unbalanced }));
    try std.testing.expectError(error.ArithmeticOverflow, addI128(std.math.maxInt(i128), 1));
    try std.testing.expectError(error.ArithmeticOverflow, addI128(std.math.minInt(i128), -1));
}

test "content hash binds ordered accounts and canonical amounts" {
    const fake_handle: *sdk.ModuleHandle = @ptrFromInt(8);
    const first = [_]Entry{
        .{ .account = "a", .amount_text = "-5", .amount = -5 },
        .{ .account = "b", .amount_text = "5", .amount = 5 },
    };
    const reordered = [_]Entry{ first[1], first[0] };
    const group = Group{ .ledger = "main", .currency = "USD", .idempotency_key = "same-key", .entries = &first };
    var one: [64]u8 = undefined;
    var two: [64]u8 = undefined;
    var three: [64]u8 = undefined;
    try contentHash(std.testing.allocator, fake_handle, group, &one);
    try contentHash(std.testing.allocator, fake_handle, group, &two);
    try contentHash(std.testing.allocator, fake_handle, .{ .ledger = "main", .currency = "USD", .idempotency_key = "same-key", .entries = &reordered }, &three);
    try std.testing.expectEqualSlices(u8, &one, &two);
    try std.testing.expect(!std.mem.eql(u8, &one, &three));
}

test "the enforced predicate table is non-empty and canonically ordered" {
    // The manifest below is derived from this table, and the digest a consumer
    // compares is derived from that manifest. An empty or unordered table would
    // still produce a digest, so the floor is asserted here rather than left to
    // the encoder.
    try std.testing.expect(predicates.len > 0);
    var previous: ?u16 = null;
    for (predicates) |row| {
        if (previous) |prior| try std.testing.expect(row.kind_ordinal > prior);
        previous = row.kind_ordinal;
        try std.testing.expect(row.predicate_version >= 1);
    }
}

test "the adapter manifest restates the dispatch table, the store schema, and the export names" {
    try std.testing.expectEqualStrings(adapter_identity, adapter_manifest.identity);
    try std.testing.expectEqual(SCHEMA_VERSION, adapter_manifest.store_schema_version);
    try std.testing.expectEqual(predicates.len, adapter_manifest.predicates.len);
    for (predicates, adapter_manifest.predicates) |row, entry| {
        try std.testing.expectEqual(row.kind_ordinal, entry.kind_ordinal);
        try std.testing.expectEqual(row.predicate_version, entry.predicate_version);
    }
    try std.testing.expectEqual(binding.exports.len, adapter_manifest.exports.len);
    for (binding.exports, adapter_manifest.exports) |item, name| {
        try std.testing.expectEqualStrings(item.name, name);
    }
}

test "the balance conservation row names a predicate that refuses an unbalanced group" {
    // A row is evidence of enforcement only when the function it names is the
    // one that decides. This calls the row's own pointer rather than the local
    // name, so a table wired to some other function fails here.
    const unbalanced = [_]Entry{.{ .account = "a", .amount_text = "1", .amount = 1 }};
    const group = Group{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &unbalanced };
    const balanced = [_]Entry{
        .{ .account = "a", .amount_text = "-1", .amount = -1 },
        .{ .account = "b", .amount_text = "1", .amount = 1 },
    };
    var config = try ownedFor(null);
    defer config.deinit(std.testing.allocator);
    var found = false;
    for (predicates) |row| {
        if (row.kind_ordinal != balance_conservation_ordinal) continue;
        found = true;
        try std.testing.expectError(error.Unbalanced, row.group_fn(&config, group));
        try row.group_fn(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &balanced });
    }
    try std.testing.expect(found);
}

const testing_digest = [_]u8{0} ** 32;

fn declaredAccountConfig(matchers: []const AccountMatcher) Config {
    return .{
        .ledger = "main",
        .currencies = &.{.{ .code = "USD", .scale = 2 }},
        .invariant_digest = testing_digest,
        .accounts = matchers,
    };
}

fn ownedFor(matchers: ?[]const AccountMatcher) !OwnedConfig {
    return OwnedConfig.init(std.testing.allocator, .{
        .ledger = "main",
        .currencies = &.{.{ .code = "USD", .scale = 2 }},
        .invariant_digest = testing_digest,
        .accounts = matchers,
    });
}

test "an exact matcher accepts only the same bytes and a prefix accepts what starts with it" {
    const exact = AccountMatcher{ .tag = .exact, .value = "clearing:main" };
    try std.testing.expect(exact.matches("clearing:main"));
    try std.testing.expect(!exact.matches("clearing:main2"));
    try std.testing.expect(!exact.matches("clearing:mai"));
    try std.testing.expect(!exact.matches("Clearing:main"));

    const prefix = AccountMatcher{ .tag = .prefix, .value = "asset:" };
    try std.testing.expect(prefix.matches("asset:cash"));
    try std.testing.expect(prefix.matches("asset:"));
    try std.testing.expect(!prefix.matches("assets:cash"));
    try std.testing.expect(!prefix.matches("Asset:cash"));

    // Bytes, not codepoints, and no normalization anywhere.
    const unicode = AccountMatcher{ .tag = .prefix, .value = "über:" };
    try std.testing.expect(unicode.matches("über:cash"));
    try std.testing.expect(!unicode.matches("uber:cash"));
}

test "a posting group is refused whole when any entry names an undeclared account" {
    var config = try ownedFor(&.{
        .{ .tag = .exact, .value = "clearing:main" },
        .{ .tag = .prefix, .value = "asset:" },
    });
    defer config.deinit(std.testing.allocator);

    const allowed = [_]Entry{
        .{ .account = "asset:cash", .amount_text = "-5", .amount = -5 },
        .{ .account = "clearing:main", .amount_text = "5", .amount = 5 },
    };
    try validateDeclaredAccounts(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &allowed });

    // A zero-amount entry is still an entry.
    const zero_amount = [_]Entry{
        .{ .account = "asset:cash", .amount_text = "-5", .amount = -5 },
        .{ .account = "clearing:main", .amount_text = "5", .amount = 5 },
        .{ .account = "suspense:held", .amount_text = "0", .amount = 0 },
    };
    try std.testing.expectError(error.UndeclaredAccount, validateDeclaredAccounts(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &zero_amount }));

    // So is a pair that cancels on one undeclared account.
    const cancelling = [_]Entry{
        .{ .account = "suspense:held", .amount_text = "7", .amount = 7 },
        .{ .account = "suspense:held", .amount_text = "-7", .amount = -7 },
    };
    try std.testing.expectError(error.UndeclaredAccount, validateDeclaredAccounts(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &cancelling }));

    // Near misses on both matcher kinds.
    const near = [_]Entry{
        .{ .account = "assets:cash", .amount_text = "-1", .amount = -1 },
        .{ .account = "clearing:main", .amount_text = "1", .amount = 1 },
    };
    try std.testing.expectError(error.UndeclaredAccount, validateDeclaredAccounts(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &near }));
    const case_differs = [_]Entry{
        .{ .account = "Clearing:main", .amount_text = "-1", .amount = -1 },
        .{ .account = "asset:cash", .amount_text = "1", .amount = 1 },
    };
    try std.testing.expectError(error.UndeclaredAccount, validateDeclaredAccounts(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &case_differs }));
}

test "a configuration that declares no account set constrains no account" {
    var config = try ownedFor(null);
    defer config.deinit(std.testing.allocator);
    const anything = [_]Entry{
        .{ .account = "whatever:at:all", .amount_text = "-1", .amount = -1 },
        .{ .account = "and:this:too", .amount_text = "1", .amount = 1 },
    };
    try validateDeclaredAccounts(&config, .{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &anything });
    try requireDeclaredAccount(&config, "whatever:at:all");
}

test "the declared accounts row names a predicate that refuses an undeclared account" {
    // A row is evidence of enforcement only when the function it names is the
    // one that decides, on both the write path and the stored-account path.
    var config = try ownedFor(&.{.{ .tag = .prefix, .value = "asset:" }});
    defer config.deinit(std.testing.allocator);
    const refused = [_]Entry{
        .{ .account = "asset:cash", .amount_text = "-1", .amount = -1 },
        .{ .account = "equity:opening", .amount_text = "1", .amount = 1 },
    };
    const group = Group{ .ledger = "main", .currency = "USD", .idempotency_key = "k", .entries = &refused };
    var group_checked = false;
    var account_checked = false;
    for (predicates) |row| {
        if (row.kind_ordinal != declared_accounts_ordinal) continue;
        group_checked = true;
        try std.testing.expectError(error.UndeclaredAccount, row.group_fn(&config, group));
        const check = row.account_fn orelse continue;
        account_checked = true;
        try check(&config, "asset:cash");
        try std.testing.expectError(error.UndeclaredStoredAccount, check(&config, "equity:opening"));
    }
    try std.testing.expect(group_checked);
    try std.testing.expect(account_checked);
}

test "configuration refuses an empty, malformed, duplicate or unordered declared account set" {
    try std.testing.expectError(error.InvalidConfig, validateConfig(declaredAccountConfig(&.{})));
    try std.testing.expectError(error.InvalidInput, validateConfig(declaredAccountConfig(&.{
        .{ .tag = .prefix, .value = "" },
    })));
    try std.testing.expectError(error.InvalidInput, validateConfig(declaredAccountConfig(&.{
        .{ .tag = .exact, .value = &[_]u8{ 0xc3, 0x28 } },
    })));
    try std.testing.expectError(error.InvalidConfig, validateConfig(declaredAccountConfig(&.{
        .{ .tag = .exact, .value = "a" },
        .{ .tag = .exact, .value = "a" },
    })));
    try std.testing.expectError(error.InvalidConfig, validateConfig(declaredAccountConfig(&.{
        .{ .tag = .prefix, .value = "a" },
        .{ .tag = .exact, .value = "a" },
    })));
    try validateConfig(declaredAccountConfig(&.{
        .{ .tag = .exact, .value = "clearing:main" },
        .{ .tag = .prefix, .value = "asset:" },
    }));
}

test "every enforced predicate decides something at baseline, and one of them owns the walk" {
    // The account hooks run from inside the walk one `baseline_fn` makes. A
    // table with no walk would call every account hook zero times and report a
    // pass; a row with neither hook would be a manifest row enforcing nothing.
    var walkers: usize = 0;
    for (predicates) |row| {
        try std.testing.expect(row.account_fn != null or row.baseline_fn != null);
        if (row.baseline_fn != null) walkers += 1;
    }
    try std.testing.expect(walkers >= 1);
}

test "configuration requires a sorted unique currency header" {
    const digest = [_]u8{0} ** 32;
    try validateConfig(.{
        .ledger = "main",
        .currencies = &.{ .{ .code = "EUR", .scale = 2 }, .{ .code = "USD", .scale = 2 } },
        .invariant_digest = digest,
    });
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .ledger = "main",
        .currencies = &.{ .{ .code = "USD", .scale = 2 }, .{ .code = "EUR", .scale = 2 } },
        .invariant_digest = digest,
    }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .ledger = "main",
        .currencies = &.{ .{ .code = "USD", .scale = 2 }, .{ .code = "USD", .scale = 3 } },
        .invariant_digest = digest,
    }));
}
