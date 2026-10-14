---
title: Edge Chunked Requests Bypassed the Encoded Body Cap
date: 2026-07-16
category: security-issues
module: Runtime HTTP request parsing
problem_type: security_issue
component: tooling
symptoms:
  - Chunked edge requests could consume unbounded encoded-buffer space while keeping the decoded payload within max_body_size.
  - The edge read loop reparsed the accumulated chunked body from byte zero after every socket read.
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags: [runtime, edge, http, chunked-encoding, body-limit, denial-of-service]
---

# Edge Chunked Requests Bypassed the Encoded Body Cap

## Problem

The edge request reader limited only the decoded chunk payload. A client could therefore send many tiny chunks with large chunk extensions, keeping decoded bytes under `max_body_size` while forcing the server to buffer much more encoded input. The same loop also called the non-resumable parser on the full body after every read.

## Symptoms

- Chunk metadata could grow beyond the configured decoded-body limit without producing `error.FileTooBig`.
- Repeated reads restarted chunk parsing instead of continuing from the last validated offset.

## What Didn't Work

The decoded-size check inside the chunk parser was necessary but insufficient: chunk-size lines, extensions, delimiters, and trailers are not counted as decoded payload. Reusing `chunkedBodyConsumed` also preserved correct framing but discarded parser progress on every call.

## Solution

The encoded cap is now a shared parser policy. `maxChunkedEncodedBodyBytes` permits 64 KiB of overhead for small payload limits and at most another decoded-limit-sized allowance for larger bodies, using checked addition to saturate at `usize` maximum (`packages/runtime/src/http_parser.zig`). Both the main and edge readers called that shared helper. The edge reader was removed with the edge runtime (see `pre-rebase:packages/runtime/src/edge_server.zig`), so `completeRequestLength` in `packages/runtime/src/server.zig` is now the only caller (`packages/runtime/src/server.zig`).

The edge reader created one `ChunkedBodyParseState` for the request and passed it to `chunkedBodyConsumedResumable` on every read (`pre-rebase:packages/runtime/src/edge_server.zig`). The main reader does the same: `readRequestData` creates one state per request (`packages/runtime/src/server.zig`) and `completeRequestLength` passes it on every read (`packages/runtime/src/server.zig`). It rejects both incomplete bodies whose buffered encoded length crosses the cap and complete bodies whose consumed encoded length is over the cap (`packages/runtime/src/server.zig`). The existing `error.FileTooBig` path therefore continues to map the request to HTTP 413.

## Why This Works

Decoded and encoded limits now protect different resources: the parser's decoded count bounds handler-visible payload, while the reader's encoded count bounds buffered wire representation. Caller-owned resumable state retains the current chunk phase, offset, decoded count, pending chunk size, and trailer start, so validated prefixes are not scanned again (`packages/runtime/src/http_parser.zig`).

## Prevention

- Keep wire-size and decoded-size limits separate for framed or compressed protocols.
- Keep a regression that uses one-byte chunks with large extensions; it must stay below `max_body_size` after decoding while exceeding the encoded cap. It first lived in the edge runtime (`pre-rebase:packages/runtime/src/edge_server.zig`). Since plan 005 G4 it is the `server.zig` test "threaded completeRequestLength rejects a chunked body whose encoding exceeds the wire cap", which checks both the in-flight and the completing branch.
- Preserve poisoned-prefix resume tests for splits in size lines, chunk data, chunk-data CRLF, and trailers so regressions cannot hide behind functionally correct full rescans.
- Verify this path with `zig build test-server`, `zig build test-zruntime`, and `zig build`.

## Related Issues

The single-buffer decode path remains separate: `decodeChunkedBody` validates and decodes a complete body after request framing has already determined its extent. The encoded cap belongs in incremental request readers, where buffering occurs.
