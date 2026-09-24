---
title: A damaged artifact started as a plain runtime
date: 2026-09-24
category: security-issues
module: runtime self-extract artifact detection
problem_type: security_issue
component: tooling
symptoms:
  - "A self-contained binary with one payload byte changed and a stale CRC-32 started and served 200 from the project directory instead of refusing."
  - "The startup log had no \"Proof accepted\" line, and a DebugAllocator leak trace showed project_config.discover running, so the binary had become a plain runtime."
  - "Run from an empty directory, the same damaged binary exited with NoHandler instead of reporting a damaged payload."
  - "A tamper probe reached the proof kernel (ExecutableGraphMismatch) only after the payload CRC-32 was recomputed, so the first probe had tested the outer integrity layer and not the kernel."
  - "zttp proofs bundle wrote a damaged artifact as a hash-only bundle without a word."
root_cause: logic_error
resolution_type: code_fix
severity: critical
related_components:
  - self-extract payload
  - runtime startup validation
  - proof-checker acceptance
  - proofs bundle and verify
tags:
  - self-extract
  - artifact-integrity
  - fail-open
  - fail-closed
  - crc32
  - runtime-startup
  - tamper-probe
  - errdefer-leak
---

# A damaged artifact started as a plain runtime

## Problem

A self-contained deployment binary is a base `zttp-runtime` executable with a
handler payload appended and a 32-byte trailer at the end. When the trailer
framed a payload that was damaged, the loader reported "no payload", and the
binary started as a plain runtime that served whatever project was in the
working directory, with no proof, no attestation, and no declared capability
ceiling.

## Symptoms

The defect was found while collecting deployed-binary evidence for M4 T5b. The
probe changed one byte of the shipped `ZTDCL1` exclude entry (`zttp:sql` to
`zttp:sqm`) in a built binary and ran it from the project directory. The
expected result was a refusal at artifact binding. The actual result was a
server that started and answered 200.

Three observations showed that the binary was no longer the artifact. The log
had no "Proof accepted" line. A DebugAllocator leak trace showed
`project_config.discover` running, which only the plain runtime does. Run from
an empty directory, the same binary exited with `NoHandler`, the error of a
plain runtime that finds no project. Nothing in the output said that a payload
had been seen and discarded: a damaged artifact and a plain runtime took the
same startup path.

## What Didn't Work

The first probe tested the wrong layer. It changed a byte inside the payload
and left the trailer's CRC-32 as built, so the checksum check failed before the
proof checker saw any byte. The probe was meant to exercise the kernel's
refusal at artifact binding. It exercised the outer integrity check instead,
and the outer check's failure mode was not a refusal: it was a fallback to a
different, more permissive program.

Only after the payload CRC-32 was recomputed (a scratchpad one-off, not part of
the repository) did the tampered binary reach acceptance, where it was refused
with `attestation: the loaded executable graph does not match the signed root`
and `error.ExecutableGraphMismatch`. So the kernel was correct, and the first
probe could not have shown that. It showed something more important: the layer
in front of the kernel was fail-open.

## Solution

The fix is two commits on local main, ee4df160 and f7ac41d4 (not yet pushed).
The one rule behind both: a binary is an artifact exactly when its trailer
frames a payload, and after that decision no failure may answer "not an
artifact".

**`detect` refuses once the frame is accepted.** Before the fix, a short read
and a checksum mismatch returned `null`, and `detect` passed `parse`'s own
`null` through:

```zig
if (payload_read < 0 or @as(usize, @intCast(payload_read)) != payload_data.len) return null;
const checksum_actual = std.hash.crc.Crc32.hash(payload_data);
if (checksum_actual != checksum_expected) return null;
return parse(allocator, payload_data);
```

Now `detect` resolves its own path and delegates to `detectPath`
(`packages/runtime/src/self_extract.zig:136`, `:151`). After `readTrailer`
accepts the frame, every failure is an error. A short read, a checksum
mismatch, a `parse` error other than `OutOfMemory`, and a `parse` null are all
`error.CorruptArtifact` (`self_extract.zig:148`, `:191-208`):

```zig
if (checksum_actual != checksum_expected) {
    return corruptArtifact("the payload checksum does not match its trailer");
}
const payload = parse(allocator, payload_data) catch |err| switch (err) {
    error.OutOfMemory => return err,
    else => {
        if (!builtin.is_test) std.log.err("self-extract: the payload does not parse: {s}", .{@errorName(err)});
        return error.CorruptArtifact;
    },
};
return payload orelse corruptArtifact("the payload carries no handler bytecode or is truncated");
```

The `null` returns that remain in `detectPath` are all before the frame is
accepted: the file cannot be opened, is smaller than a trailer, gives a short
trailer read, or `readTrailer` reports `NoPayload`, which it does for a wrong
magic and for offsets that do not add up to the file size exactly
(`self_extract.zig:246-261`).

**An oversized framed payload is an error too.** `readTrailer` used to return
`NoPayload` for a correctly framed payload over 100 MiB, so it also started the
plain runtime, and a test named "an oversized payload is refused before it is
allocated" asserted that `NoPayload`. It now returns `PayloadTooLarge` after
the framing check (`self_extract.zig:262`), and `create` refuses to build a
payload over `max_payload_bytes` (`self_extract.zig:232`, `:343`), so the
builder cannot write an artifact the runtime will not read.

**`runtime_cli` refuses on every `detect` error.** Before the fix, every error
except `UnsupportedArtifactFormat` became "no payload" through `else => null`.
Now `PayloadTooLarge` and `CorruptArtifact` each exit 1 with their own line,
and every other error exits 1 with "Could not inspect this binary for a handler
payload: <error>. Refusing to start." (`packages/runtime/src/runtime_cli.zig:37-63`).
Only `null` starts the plain runtime. One behavior change follows: a failure to
resolve the binary's own path now refuses instead of starting plain. That case
was not seen on macOS or Linux.

**`zttp proofs` had the same fallback.** `payloadFromBinary`
(`packages/runtime/src/proofs/bundle.zig:672`) mapped a checksum or parse
failure to `null`, and `zttp proofs bundle` then wrote the damaged artifact as
a hash-only bundle. It now returns `CorruptArtifact`, and both `bundle` and
`verify` print one diagnostic line and exit 1. `verify` had already failed on
the `null`, with "not checked"; `bundle` had not.

**`parse` no longer leaks on a truncated section.** The new tests exposed a
leak. `parse` returned `null` when a later section header was truncated, when a
section size ran past the data, or when no bytecode section was present, and a
`null` return skipped the `errdefer` that frees the sections already read. The
three sites now return `error.InvalidPayload`, so the `errdefer` runs.

## Why This Works

Before the fix, the artifact-or-not decision was made twice. The frame said
"artifact", and then any later failure said "not an artifact", which overruled
the frame. The second decision selected the most permissive mode the binary
has: discover a project in the working directory and serve its source with no
proof.

After the fix, the decision is made once, from the frame alone. Before the
frame is accepted, the answer can be `null`. After it, the only answers are a
valid payload or an error, and every caller turns every error into a refusal.
So a damaged artifact can no longer become a different program. The order in
`readTrailer` supports this: the framing checks run first, so a base binary
that happens to end in the magic bytes is still "no payload", while a real
artifact in an old format is `UnsupportedArtifactFormat` and a real artifact
that is too large is `PayloadTooLarge`.

## Prevention

**Decide artifact-or-not from the frame alone, then never return
not-an-artifact.** Any loader that selects between a strict mode and a
permissive fallback has this shape. Put the discriminator at one point, make it
depend only on the envelope, and after that point let every failure be an
error. A `null` or "absent" return after the discriminator is a fail-open,
because absent selects the fallback. At the call site, an `else => null` over
the error set does the same thing. And search for every reader of the same
format: here three readers (`detect`, the size check in `readTrailer`, and
`payloadFromBinary`) each carried the fallback on their own, and the compiler
found the third only because the new error made its exhaustive switch fail.

**A tamper probe must also recompute every outer integrity check, or it tests
only the outer layer - and check that outer layer's failure mode.** A byte
changed under a checksum is caught by the checksum, not by the check the probe
names. So a tamper probe needs two runs. The first leaves the outer checks
stale and asserts that the outer layer refuses, with an exit status and a
message, not a fallback. The second recomputes every outer check and asserts
that the inner layer refuses. In this case the first run found the defect.
Confirm each refusal from positive evidence, such as the log line and the exit
status, because a fallback can also serve without an error.

**Test shapes.** Three tests in `self_extract.zig` pin the boundary through the
public `detectPath` entry point, using a real artifact built with `create`:

- "detectPath reads an intact artifact and reports no payload for a plain
  binary" pins both sides of the discriminator.
- "detectPath refuses a framed payload with a changed byte instead of reporting
  no payload" flips one bytecode byte and leaves the CRC stale: the outer-layer
  run.
- "detectPath refuses a framed payload whose checksum holds but whose sections
  do not parse" sets the section count to `0xFFFF` and recomputes the CRC, so
  only the parser can notice: the inner-layer run. It is the test that exposed
  the `parse` leak under the testing allocator.

"an oversized payload is refused before it is allocated, not read as no
payload" pins `PayloadTooLarge` and the exact bound, and "bundle refuses a
current-format artifact whose payload checksum fails, instead of bundling it as
hash-only" pins the `zttp proofs` path. Each changed branch was checked by
mutation: restoring the old `null` on a checksum mismatch fails the matching
test in an unfiltered `zig build test`. End to end, a freshly built artifact
with one payload byte changed and the CRC left stale exits 1 from the project
directory, `zttp proofs bundle` refuses it and writes no directory, and the
intact artifact and a plain `zttp-runtime` still serve 200.

## Related Issues

This is the repository's recurring damaged-read-as-absent class: an input that
is damaged is treated as an input that is absent, and absence selects a more
permissive mode. In
[a-check-that-never-ran-passed-every-handler](a-check-that-never-ran-passed-every-handler.md),
a type that could not be resolved answered "assignable". In
[empty-label-set-claimed-a-value-was-clean](empty-label-set-claimed-a-value-was-clean.md),
an absent label set read as "clean". In
[a-gate-that-counts-nothing-still-reports-a-pass](../conventions/a-gate-that-counts-nothing-still-reports-a-pass.md),
an empty input read as a pass. Here the permissive mode was a whole different
program.

[self-extract-runtime-policy-attestation-binding](self-extract-runtime-policy-attestation-binding.md)
covers the adversary who recomputes the checksum: CRC-32 detects corruption and
proves nothing about authenticity. This doc covers the other half: a detected
corruption must refuse, never fall back.
