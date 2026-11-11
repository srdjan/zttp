# Receipt archive, schema-only database input, and header support, 2026-11-10

The fix-all-errors audit of 2026-11-10 left three owner decisions open. On
2026-11-10 the owner answered "as recomended". That answer chose option (b)
of Decisions 3, 4, and 5. This plan records the units for those choices.

## Decisions

Decision 3 (b): the workspace archives a transaction record when the session
acknowledges its receipt. Acquire also archives a receipted record that is
still in `.zttp/change-sets`. Before this change, every receipted record stayed
in `.zttp/change-sets`, and acquire read the receipt of each one. One damaged
receipted record therefore blocked every acquire.

Decision 4 (b): the proof read set holds the schema of the configured SQLite
database, not its bytes. Before this change, a server that wrote a row during
the approval wait failed the commit with `ProofReadSetChanged`. A database
larger than 32 MiB failed the capture with `FileTooBig`.

Decision 5 (b): a handler gets response headers at the next re-record of the
codegen corpus. This plan records that work and does not do it.

## Units

### D3: archive a receipted record

- Model: Opus, directly. The change is in one file.
- File: `packages/pi/src/change_transaction.zig`.
- Turn budget: 40.

`markReceipted` writes the `receipted` marker and then moves the record to
`.zttp/change-sets-archive/<id>.<n>` with `archiveReceiptedTransaction`. A
second acknowledgement of the same id succeeds when the record is gone and
`<id>.1` is in the archive. Recovery archives a record that has the
`committed` and `receipted` markers before it reads the manifest or the
receipt. Recovery still validates a pending record, and refuses it when it is
damaged.

Acceptance check: these tests fail before the change and pass after it.

1. An acknowledged record is in the archive and not in `.zttp/change-sets`. A
   second acknowledgement returns without an error.
2. Acquire succeeds when a receipted record has a damaged receipt, and the
   record moves to the archive.
3. Acquire still refuses a pending record with a damaged receipt.

Then `zig build test-expert-app` and `bash scripts/verify.sh` pass.

### D4: hash only the schema of the configured database

- Model: Sonnet, in a detached worktree from local main.
- Files: `packages/tools/src/precompile_sql.zig`, `packages/tools/src/zts_cli.zig`,
  `packages/pi/src/workspace_snapshot.zig`, `docs/user-guide.md`.
- Turn budget: 60.

The proof reads the configured database only to prepare SQL statements. A
database that the proof rebuilds from the same schema therefore gives the same
verdict. A configured path that ends in `.sql` stays a text input. For any other
configured path, the capture reads the first 16 bytes of the file. When those
bytes are the SQLite header `SQLite format 3\0`, the read set holds the schema
text. Otherwise the read set holds the file bytes, as before.

`precompile_sql.readDatabaseSchema` reads the `sql` column of `sqlite_master`.
It leaves out each row with a null `sql` and each name that starts with
`sqlite_`. It orders tables, indexes, views, and triggers in that sequence, by
`rowid` inside each type. It ends each statement with `;\n`.
`precompile_sql.execSqlite` opens or creates a database and runs SQL text.
Materialize writes a schema entry with `execSqlite`, and recheck reads the
schema again.

Acceptance check: these tests fail before the change and pass after it.

1. A configured database is recorded as its schema text. A row write keeps the
   read set, and a schema change fails recheck with `ProofReadSetChanged`.
2. A configured database larger than 32 MiB is captured.
3. The materialized baseline holds a database with the same schema.
4. A text file that replaces the database fails recheck.

Then `zig build test-precompile`, `zig build test-expert-app`, and
`bash scripts/verify.sh` pass. The corpus case `sql-users` configures
`schema.sql`, so the corpus replay does not change.

### D5: record the header support plan

- Model: Opus, directly.
- File: `docs/decisions.md`.

A new decision entry states that response headers wait for the next re-record.
That work honors `headers` in a Response init. The flow analysis treats each
header value as response content, and `flow_analyzer_version` moves to 11.
Until then, ZTS203 refuses every init member except `status`.

## Remaining gaps

The archive keeps at most 1024 records for one proof id. At that bound,
acknowledgement fails with `TooManyArchivedTransactions`.

## Status

Complete 2026-11-10. D3 is `32b8e531`. D4 is `8ad0c240` and `dcc50bce`. D5 is `1e5a2402`. `bash scripts/verify.sh` exited 0 at `dcc50bce` on macOS and in the Linux arm64 container.

D4 test 3 (materialize) and test 4 (text file replaces the database) passed before the change. Those two tests guard the new schema path, and they do not reproduce the old defect. A configured SQLite file with a `.ts`, `.js`, `.json`, or `.sql` extension is captured by the directory walk as bytes, as before.
