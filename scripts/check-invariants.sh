#!/usr/bin/env bash
#
# Application-invariant drift and evidence gate.
#
# The gate itself is Zig: packages/tools/src/invariant_drift_gate.zig. It
# imports the surfaces that are data - the kernel operation catalog, the kind
# table, the linked native binding, the authoring renderer - and text-scans only
# the surfaces that are code. This file is the entry point developers already
# have in their fingers, and it delegates.
#
# `zig build test-invariant-drift` also requires the compiled evidence the gate
# only sees as text. `zig build invariant-gate` builds the binary alone, which
# accepts `--mutate <input>` to run one in-memory mutation probe.

set -euo pipefail

cd "$(dirname "$0")/.."

exec zig build test-invariant-drift "$@"
