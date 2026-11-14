---
title: A finite loop held the expert approval prompt for minutes
date: 2026-11-14
category: runtime-errors
module: pi expert result card test run
problem_type: runtime_error
component: tooling
severity: medium
symptoms:
  - "A candidate with `for (const i of range(4000000000))` passed `zttp check`, and the approval prompt did not appear while `zttp test` ran."
  - "`zttp test` on that handler took 210 s in one Debug run and then reported a pass."
  - "The workspace lock stays held during the run, so a second session in the same workspace ends with an error. This is from a code reading, not a probe."
root_cause: missing_validation
resolution_type: code_fix
related_components:
  - testing_framework
tags:
  - expert
  - result-card
  - timeout
  - range
  - zttp-test
---

# A finite loop held the expert approval prompt for minutes

## Problem

Before the approval prompt, `zttp expert` runs `zttp test` on the candidate. The first version of that run had no time limit. The reason was that the handler profile has no `while` loop, and `for...of` walks a finite array. That reason was wrong.

## Symptoms

- A review probe stopped `zttp test` after 20 s and reported that the prompt never appears. That claim was also wrong.
- A full run of the same handler took 210 s and passed. The measurement is one run on a Debug build.

## Root Cause

`range()` makes a finite loop of any length. The profile bounds the number of steps, not the time. `zttp test` sets no request deadline: `request_timeout_ms` in `packages/runtime/src/runtime_config.zig#RuntimeConfig` defaults to 0, and the test command does not set it.

## Solution

`packages/pi/src/tools/common.zig#runCommandWithin` gives a child process a wall-time deadline and kills it at the deadline. `packages/pi/src/suite_run.zig#run` calls it with `packages/pi/src/suite_run.zig#default_timeout_ms`, 30 000 ms. That limit is a choice, not a measurement. The suite of a `zttp init` project took 48 ms. The card then reads `Tests: could not run: zttp test did not finish in 30000 ms`.

The test "the card says the suite did not finish when the run passes the time limit" in `packages/pi/src/repl.zig` sets a limit of 1000 ms. Without the limit, the same test saw a pass only after the full run.

## Prevention

A host step that runs candidate handler code needs a wall-time limit, even when every loop in the profile is finite. Do not use "the loop is finite" as a reason to omit the limit.
