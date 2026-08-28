---
title: Linux Debug Runtime Exceeded the Self-Extract Copy Limit
date: 2026-08-28
category: runtime-errors
module: runtime self-extract artifact creation
problem_type: runtime_error
component: cli
severity: high
applies_when:
  - "A zttp build or deploy fails only when the adjacent zttp-runtime binary is large"
  - "Artifact creation reports error.FileTooBig before writing the output binary"
  - "A smoke gate reports only that build or deploy exited non-zero"
tags: [runtime, self-extract, streaming, linux, ci, file-size, diagnostics]
---

# Linux Debug Runtime Exceeded the Self-Extract Copy Limit

## Problem

`zttp build` creates a standalone artifact by copying the adjacent
`zttp-runtime` executable, appending the compiled handler payload, and writing a
32-byte trailer. Artifact creation read the complete runtime through
`file_io.readFile` with a 100 MiB limit before it wrote anything.

That limit was copied from the untrusted appended-payload parser. It was not a
valid limit for the trusted runtime template. The Linux Debug runtime grew past
100 MiB, so Ubuntu CI failed the normal generated-project build while macOS and
release builds stayed below the threshold.

The smoke script redirected the normal build and deploy output to `/dev/null`.
CI therefore showed only `FAIL: build exited non-zero`, hiding the underlying
`Failed to create output binary: error.FileTooBig` diagnostic.

## Causal Chain

1. `zig build smoke-v1` builds Debug `zttp` and `zttp-runtime` binaries.
2. The generated smoke project runs `zttp build`.
3. Artifact creation asks `readFile` to load `zttp-runtime` with a 100 MiB cap.
4. The Linux Debug runtime exceeds the cap, so `readFile` returns
   `error.FileTooBig` before the artifact writer runs.
5. `zttp build` exits non-zero and emits no partial artifact.
6. `scripts/smoke-v1.sh` suppresses the command output and reports only the
   outer failure.

The other `failed command` lines in the aggregate unit-test log are expected
negative-path diagnostics. The aggregate test process exits successfully. The
first failing CI gate is the later smoke build.

## Solution

Artifact creation now opens the runtime template once and keeps that file
descriptor open through the atomic write. It obtains the file size, reads only
the final trailer with `pread`, and uses the same overflow-safe trailer parser
as the in-memory helper to decide whether an older appended payload must be
stripped.

The clean runtime prefix is copied through a fixed 64 KiB stack buffer. Runtime
size no longer determines heap use, and the writer capability still observes
every output chunk. Payload bytes and the new trailer are then appended exactly
as before.

The existing sibling-temp, `fsync`, mode, umask, failure cleanup, and final
atomic rename behavior remains unchanged. A failed copy still preserves the
previous artifact.

The smoke script now captures normal build and deploy output. Successful steps
remain quiet. On failure, it prints the captured command diagnostic before its
one-line smoke failure.

## Trust Boundary

The adjacent base runtime is a build input selected by the local CLI. It is not
parsed into memory and has no fixed size ceiling.

The appended payload is still attacker-modifiable data when an artifact starts.
Its existing 100 MiB sanity limit, checksum validation, version check, and
overflow checks remain in place. Removing the runtime copy limit does not widen
that parser boundary or change the artifact format.

## Regression Coverage

The CLI test root now covers two integration cases in
`packages/runtime/src/self_extract.zig`:

- A sparse runtime of 100 MiB plus one byte must reach an injected writer error
  instead of returning `error.FileTooBig`. The writer records that no base copy
  chunk exceeds 64 KiB. The same fixture then completes with the production
  writer and verifies the final size, trailer offsets, exact payload bytes, and
  parsed bytecode.
- Using an already self-extracting artifact as the next base must strip its old
  payload and leave only the new payload after the clean runtime prefix.

The smoke gate also probes its capture helper. Successful commands must stay
quiet on stdout and stderr. Failed commands must retain both the inner command
diagnostic and the outer smoke context.

The `test-cli` build option filter does not collect this imported runtime test,
so the authoritative focused regression command is the full CLI root:

```bash
zig build test-cli
```

The end-user gate is:

```bash
zig build smoke-v1
```

The complete CI-equivalent verification remains:

```bash
bash scripts/verify.sh
```

## Assumptions

- The base runtime is a regular seekable file next to the CLI.
- The artifact trailer layout and payload section encoding remain version 1.
- Linux CI is the final acceptance environment for the size regression.
- Build and deploy success output remains intentionally quiet in the smoke log.
