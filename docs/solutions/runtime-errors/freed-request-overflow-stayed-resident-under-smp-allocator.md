---
title: Freed request overflow stayed resident under smp_allocator
date: 2026-11-05
category: runtime-errors
module: zts request arena (packages/zts/src/arena.zig)
problem_type: performance_issue
component: runtime
symptoms:
  - "On the t7 shape (cacheSet of a joined string), the server physical footprint grew to 418 MB by request 30 and stayed there."
  - The request arena reset freed every overflow allocation, and the memory still did not go back to the system.
  - Two RSS runs of the same binary disagreed (25 MiB in one run, 418 MB in a later run).
root_cause: memory_leak
resolution_type: code_fix
severity: medium
tags: [arena, smp-allocator, overflow, footprint, vmmap, memory-measurement, f19]
---

# Freed request overflow stayed resident under smp_allocator

## Problem

The request arena served each overflow allocation as a separate allocation from the backing allocator. In ReleaseFast the backing allocator is `std.heap.smp_allocator`. Reset freed each block, but the server footprint stayed at about 418 MB after about 30 requests on the t7 shape.

## Symptoms

- The footprint rose to a plateau and did not fall after each request.
- Each factor alone (the join, the cache write, the request count) looked flat. Only the combination grew.
- A single RSS sample per build gave contradictory results across runs.

## What Didn't Work

- An in-place grow of the last arena allocation did not stop the growth from `stringConcat`. That change was reverted.
- One RSS reading per build was misleading twice. The difference between the two t7 runs was not explained by RSS alone.

## Solution

Commit `2b45957e` makes overflow come from blocks of `ArenaConfig.overflow_block_size` (256 KiB). The arena bumps through the current block. An allocation that does not fit in a block gets its own block. `freeOverflow` frees every block on reset. Because each block is larger than 32 KiB, `smp_allocator` maps it with `PageAllocator.map` and unmaps it on free.

A separate fix (`04de59d5`) added `Context.scratchAllocator` for the slow-path buffer in `arrayJoin`. The guard row "join longer than 512 bytes in a loop" in `packages/runtime/src/runtime_pool.zig` checks that shape.

After the fix, the t7 footprint stayed at 5.7 to 7.3 MB over 100 requests.

## Why This Works

In the Zig 0.17 standard library (not this repository), `lib/std/heap/SmpAllocator.zig` sets `slab_len` to at least 64 KiB, and its largest size class is 32 KiB. A freed block of 32 KiB or less goes to a per-thread free list and stays mapped. A larger block goes to `PageAllocator.unmap` on free. Small overflow allocations therefore stayed resident after reset, and large blocks do not.

## Prevention

- Do not assume that a free to `smp_allocator` returns memory to the system. A request-scoped structure that must release memory on reset needs blocks larger than 32 KiB.
- Measure server memory with `footprint -p <pid>` and `vmmap --summary <pid>`, not one RSS sample. In `vmmap`, the "Untagged" region holds the `smp_allocator` slabs.
- Change one factor per probe, and run an A/A control beside the candidate.
- Expect a drop in the baseline at request 64. The `reuse_bounded_by_count` pool policy recycles the runtime there, so compare curves before that point.

## Related Issues

- `docs/plans/2026-11-04-f2-request-memory-plan.md` (F2 and F19 measurements).
- `docs/plans/2026-11-04-review-fixes-plan.md` (finding F19).
