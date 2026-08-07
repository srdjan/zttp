#!/usr/bin/env bash
#
# Layering gate for the zts package.
#
# `scripts/zts-tiers.allow` assigns every tracked Zig file in `packages/zts` to
# one of four tiers, ordered lowest first:
#
#   zts-base       utilities every tier names and that name nothing themselves
#   zts-contracts  contract and receipt data with its serialization
#   zts            the engine: values, GC, objects, bytecode, interpreter,
#                  parser, builtins, virtual modules
#   zts-compiler   everything that decides whether a program is proven
#
# A Zig module graph is a DAG: `zts-compiler` may import `zts`, and `zts` may
# not import `zts-compiler`. This gate checks that direction across the tier
# lines while the package is still one module, so the split is known to compile
# before `packages/zts/build.zig` is touched. It fails in both directions:
#
#   - an import from a lower tier to a higher one fails, because that is the
#     cycle that makes Zig analyze the engine twice and turn one type into two
#     incompatible ones across the module boundary;
#   - a file with no row, and a row naming no file, both fail, so the manifest
#     cannot drift out of step with the tree.
#
# The second half is the input floor. A manifest that lost its rows, or a scan
# whose path prefix moved, would otherwise report zero violations while checking
# nothing. See
# docs/solutions/conventions/a-gate-that-counts-nothing-still-reports-a-pass.md.
#
# Same-tier imports are unconstrained: this gate pins the direction between
# tiers, not the size of any one tier's surface. That is what
# `scripts/check-module-boundary.sh` does, for consumer packages.
#
# Run `bash scripts/zts-import-graph.sh` for the underlying graph, and see
# docs/plans/2026-08-07-021-zts-three-module-split-plan.md for the plan this
# enforces.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys
from collections import defaultdict

PREFIX = "packages/zts/src/"
MANIFEST = "scripts/zts-tiers.allow"

# Lowest first. A file may import its own tier and any tier below it.
TIERS = ["zts-base", "zts-contracts", "zts", "zts-compiler"]
RANK = {name: i for i, name in enumerate(TIERS)}

# Tiers already extracted into their own build module in
# `packages/zts/build.zig`. For these the rule is stricter than direction: no
# relative import may cross the line at all, in either direction. A relative
# path resolves inside the importing module, so it compiles a second copy of the
# file there, and a type from one copy is not the type from the other. Reach a
# split tier by module name - `@import("zts-base").json_utils`.
SPLIT = ["zts-base"]

MIN_FILES = 100

listing = subprocess.run(
    ["git", "ls-files", "-z", "--", "packages/zts"],
    capture_output=True,
    text=True,
    check=True,
).stdout
files = sorted(
    p for p in listing.split("\0") if p.endswith(".zig") and p.startswith(PREFIX)
)
fileset = set(files)

if len(files) < MIN_FILES:
    sys.exit(
        f"zts layering: only {len(files)} files under {PREFIX}; expected at least "
        f"{MIN_FILES}. The file list or the path prefix changed."
    )

if not os.path.exists(MANIFEST):
    sys.exit(f"zts layering: missing {MANIFEST}")

tier_of = {}
errors = []
with open(MANIFEST, encoding="utf-8") as handle:
    for lineno, raw in enumerate(handle, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            errors.append(f"{MANIFEST}:{lineno}: expected '<tier> <path>', got {line!r}")
            continue
        tier, rel = parts
        if tier not in RANK:
            errors.append(f"{MANIFEST}:{lineno}: unknown tier {tier!r}; expected one of {', '.join(TIERS)}")
            continue
        path = PREFIX + rel
        if path not in fileset:
            errors.append(f"{MANIFEST}:{lineno}: names no tracked file: {rel}")
            continue
        if path in tier_of:
            errors.append(f"{MANIFEST}:{lineno}: {rel} already assigned to {tier_of[path]}")
            continue
        tier_of[path] = tier

for path in files:
    if path not in tier_of:
        errors.append(f"{MANIFEST}: no row for {path[len(PREFIX):]}")

if errors:
    print("zts layering: the manifest does not match the tree:", file=sys.stderr)
    for message in errors:
        print(f"  {message}", file=sys.stderr)
    print(
        "Every tracked file needs exactly one row, and every row needs a file.",
        file=sys.stderr,
    )
    sys.exit(1)

IMPORT = re.compile(r'@import\("([^"]+)"\)')


def strip_comments(source):
    """Drop `//` line comments so a documented or commented-out import is not
    counted as an edge. A `//` inside a string literal is left alone by counting
    the quotes before it; that is enough for import lines."""
    out = []
    for line in source.split("\n"):
        cut = -1
        quotes = 0
        index = 0
        while index < len(line) - 1:
            char = line[index]
            if char == "\\":
                index += 2
                continue
            if char == '"':
                quotes += 1
            elif char == "/" and line[index + 1] == "/" and quotes % 2 == 0:
                cut = index
                break
            index += 1
        out.append(line if cut < 0 else line[:cut])
    return "\n".join(out)


short = lambda p: p[len(PREFIX):]

violations = defaultdict(list)
edge_count = 0
cross_count = 0
for path in files:
    with open(path, encoding="utf-8") as handle:
        source = strip_comments(handle.read())
    directory = os.path.dirname(path)
    # Unique targets, not import occurrences: a file that names the same module
    # on three lines is one edge, and matches what scripts/zts-import-graph.sh
    # reports.
    targets = set()
    for match in IMPORT.finditer(source):
        spec = match.group(1)
        if not spec.endswith(".zig"):
            continue
        target = os.path.normpath(os.path.join(directory, spec))
        if target in fileset:
            targets.add(target)
    for target in sorted(targets):
        edge_count += 1
        src_tier, dst_tier = tier_of[path], tier_of[target]
        if src_tier == dst_tier:
            continue
        cross_count += 1
        if RANK[src_tier] < RANK[dst_tier] or src_tier in SPLIT or dst_tier in SPLIT:
            violations[(src_tier, dst_tier)].append((short(path), short(target)))

if violations:
    total = sum(len(v) for v in violations.values())
    print(
        f"zts layering: {total} relative imports cross a module line illegally:",
        file=sys.stderr,
    )
    for (src_tier, dst_tier), pairs in sorted(
        violations.items(), key=lambda item: -len(item[1])
    ):
        print(f"\n  {src_tier} -> {dst_tier}  ({len(pairs)} edges)", file=sys.stderr)
        by_source = defaultdict(list)
        for source_file, target_file in pairs:
            by_source[source_file].append(target_file)
        for source_file in sorted(by_source):
            targets = ", ".join(sorted(by_source[source_file]))
            print(f"    {source_file}  ->  {targets}", file=sys.stderr)
    print(
        f"\nA lower tier must never name a higher one, and an already-split tier "
        f"({', '.join(SPLIT)})\nmust be reached by module name rather than by "
        f"relative path. Move the file, move what it\nreaches for, or change its "
        f"row in {MANIFEST}.",
        file=sys.stderr,
    )
    sys.exit(1)

sizes = defaultdict(int)
for tier in tier_of.values():
    sizes[tier] += 1
summary = ", ".join(f"{tier} {sizes[tier]}" for tier in TIERS)
print(
    f"zts layering: OK ({len(files)} files, {edge_count} edges, "
    f"{cross_count} cross-tier; {summary})"
)
PY
