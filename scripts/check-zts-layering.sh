#!/usr/bin/env bash
#
# Layering gate for the zts package.
#
# `scripts/zts-tiers.allow` assigns every tracked Zig file in `packages/zts` to
# one of five tiers, ordered lowest first. Each is its own build module,
# declared in `packages/zts/build.zig`:
#
#   zts-base       utilities every tier names and that name nothing themselves
#   zts-contracts  contract and receipt data with its serialization
#   zts            the engine: values, GC, objects, bytecode, interpreter,
#                  parser, builtins, virtual modules (module `zts-engine`)
#   zts-compiler   everything that decides whether a program is proven
#   zts-umbrella   src/root.zig alone: the `zts` module consumers import,
#                  which re-exports the four tiers and holds no code
#
# Every tier is split, so the rule is absolute: no relative import may cross a
# tier line in either direction. A relative path resolves inside the importing
# module, so it compiles a second copy of the file there, and a type from one
# copy is not the type from the other. Reach another tier by module name -
# `@import("zts-base").json_utils`, `@import("zts-engine").context`. zig also
# rejects this, with `file exists in modules 'zts-base' and 'root'`; this gate
# reports it earlier and names both ends. It fails in both directions:
#
#   - a relative import across a tier line fails, and so does an import from a
#     lower tier to a higher one even by name, because that is the cycle a DAG
#     of modules cannot express;
#   - a file with no row, and a row naming no file, both fail, so the manifest
#     cannot drift out of step with the tree.
#
# The third rule is reachability. Before the split, one root named every file,
# so a file that nothing imported could not exist. Five roots can each leave a
# file behind, and a file no root reaches still compiles, still passes
# `zig fmt`, and still gets a manifest row - but the test binary never contains
# it, so its `test` blocks never run and `zig build test-zts` reports a pass for
# code it never executed. Every file must therefore be reachable from its own
# tier's root through the relative-import graph.
#
# The manifest and reachability halves are the input floor. A manifest that lost
# its rows, or a scan whose path prefix moved, would otherwise report zero
# violations while checking nothing. See
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
TIERS = ["zts-base", "zts-contracts", "zts", "zts-compiler", "zts-umbrella"]
RANK = {name: i for i, name in enumerate(TIERS)}

# Tiers already extracted into their own build module in
# `packages/zts/build.zig`. For these the rule is stricter than direction: no
# relative import may cross the line at all, in either direction. A relative
# path resolves inside the importing module, so it compiles a second copy of the
# file there, and a type from one copy is not the type from the other. Reach a
# split tier by module name - `@import("zts-base").json_utils`.
SPLIT = ["zts-base", "zts-contracts", "zts", "zts-compiler", "zts-umbrella"]

# The build-module name each tier is declared under, and the root source file
# that module compiles, both read out of `build.zig` rather than copied here.
# A hand-copy goes stale silently: rename a module in build.zig and every
# by-name import stops matching, so the direction rule below would report a pass
# having examined nothing. `zts_roots` is the ordered table build.zig itself
# uses to build the five test binaries, and its order is tier order, so the
# tiers zip onto it positionally. The engine tier is named `zts` in the manifest
# but declared as `zts-engine`; the module actually named `zts` is the umbrella.
BUILD_ZIG = "build.zig"
ROOTS_TABLE = re.compile(
    r'\.\{\s*\.name\s*=\s*"([^"]+)"\s*,\s*\.src\s*=\s*"src/([^"]+)"\s*\}'
)

with open(BUILD_ZIG, encoding="utf-8") as handle:
    build_source = handle.read()
declared = ROOTS_TABLE.findall(
    build_source[build_source.index("zts_roots") :]
    if "zts_roots" in build_source
    else ""
)[: len(TIERS)]
if len(declared) != len(TIERS):
    sys.exit(
        f"zts layering: {BUILD_ZIG} declares {len(declared)} zts roots, expected "
        f"{len(TIERS)}. The zts_roots table moved or changed shape, so the "
        f"module-name and root-file maps cannot be derived."
    )

TIER_OF_MODULE = {module: tier for tier, (module, _) in zip(TIERS, declared)}
ROOT_OF = {tier: root for tier, (_, root) in zip(TIERS, declared)}

MIN_FILES = 100
# Floor for the by-name direction rule. Without it a map that stops matching -
# a renamed module, a moved table - filters every by-name import out and the
# rule reports a pass over an empty input. Currently 97.
MIN_NAMED_EDGES = 50

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
named_violations = defaultdict(list)
file_edges = {}
edge_count = 0
cross_count = 0
named_count = 0
for path in files:
    with open(path, encoding="utf-8") as handle:
        source = strip_comments(handle.read())
    directory = os.path.dirname(path)
    # Unique targets, not import occurrences: a file that names the same module
    # on three lines is one edge, and matches what scripts/zts-import-graph.sh
    # reports.
    targets = set()
    named = set()
    for match in IMPORT.finditer(source):
        spec = match.group(1)
        if not spec.endswith(".zig"):
            if spec in TIER_OF_MODULE:
                named.add(spec)
            continue
        target = os.path.normpath(os.path.join(directory, spec))
        if target in fileset:
            targets.add(target)
    file_edges[path] = targets
    src_tier = tier_of[path]
    for target in sorted(targets):
        edge_count += 1
        dst_tier = tier_of[target]
        if src_tier == dst_tier:
            continue
        cross_count += 1
        if RANK[src_tier] < RANK[dst_tier] or src_tier in SPLIT or dst_tier in SPLIT:
            violations[(src_tier, dst_tier)].append((short(path), short(target)))
    # The by-name direction. `@import("zts-compiler")` from a `zts-base` file
    # compiles only because `packages/zts/build.zig` happens not to declare that
    # import; nothing else refuses it, and the refusal is what the header claims.
    for module in sorted(named):
        named_count += 1
        dst_tier = TIER_OF_MODULE[module]
        if RANK[src_tier] < RANK[dst_tier]:
            named_violations[(src_tier, dst_tier)].append((short(path), module))

def fail_buckets(buckets, headline, render_pairs, footer):
    """Report tier-direction violations grouped by (source tier, target tier),
    heaviest bucket first, then exit. Both direction rules report the same
    shape and differ only in how a single edge is rendered."""
    total = sum(len(pairs) for pairs in buckets.values())
    print(headline.format(total=total), file=sys.stderr)
    for (src_tier, dst_tier), pairs in sorted(
        buckets.items(), key=lambda item: -len(item[1])
    ):
        print(f"\n  {src_tier} -> {dst_tier}  ({len(pairs)} edges)", file=sys.stderr)
        render_pairs(pairs)
    print(footer, file=sys.stderr)
    sys.exit(1)


def render_named(pairs):
    for source_file, module in sorted(pairs):
        print(f'    {source_file}  ->  @import("{module}")', file=sys.stderr)


def render_relative(pairs):
    by_source = defaultdict(list)
    for source_file, target_file in pairs:
        by_source[source_file].append(target_file)
    for source_file in sorted(by_source):
        targets = ", ".join(sorted(by_source[source_file]))
        print(f"    {source_file}  ->  {targets}", file=sys.stderr)


if named_violations:
    fail_buckets(
        named_violations,
        "zts layering: {total} module-name imports point from a lower tier to a "
        "higher one:",
        render_named,
        f"\nA tier may name its own module's tier and any tier below it, never one "
        f"above.\nThat direction is the cycle a DAG of build modules cannot "
        f"express. Move the file,\nmove what it reaches for, or change its row in "
        f"{MANIFEST}.",
    )

if violations:
    fail_buckets(
        violations,
        "zts layering: {total} relative imports cross a module line illegally:",
        render_relative,
        f"\nA lower tier must never name a higher one, and an already-split tier "
        f"({', '.join(SPLIT)})\nmust be reached by module name rather than by "
        f"relative path. Move the file, move what it\nreaches for, or change its "
        f"row in {MANIFEST}.",
    )

members_of = defaultdict(set)
for path, tier in tier_of.items():
    members_of[tier].add(path)

unreachable = []
reached_count = 0
for tier in TIERS:
    root = PREFIX + ROOT_OF[tier]
    if root not in fileset:
        sys.exit(f"zts layering: tier {tier} names a missing root: {ROOT_OF[tier]}")
    if tier_of.get(root) != tier:
        sys.exit(
            f"zts layering: {ROOT_OF[tier]} is the root of tier {tier} but its "
            f"manifest row says {tier_of.get(root)!r}"
        )
    members = members_of[tier]
    seen = {root}
    stack = [root]
    while stack:
        current = stack.pop()
        for target in file_edges[current]:
            if target in members and target not in seen:
                seen.add(target)
                stack.append(target)
    # `seen` starts at `root`, which the guard above proved is a member, and
    # only grows through the `target in members` test - so it is a subset of
    # `members` and needs no intersection.
    reached_count += len(seen)
    for path in sorted(members - seen):
        unreachable.append((tier, short(path)))

if unreachable:
    print(
        f"zts layering: {len(unreachable)} files are not reachable from their "
        f"tier's root:",
        file=sys.stderr,
    )
    for tier, path in unreachable:
        print(f"    {path}  (tier {tier}, root {ROOT_OF[tier]})", file=sys.stderr)
    print(
        "\nA file no root reaches is not compiled into that tier's test binary, so "
        "its\n`test` blocks never run and `zig build test-zts` reports a pass for "
        "code it never\nexecuted. Name it from the tier root, or from a file the "
        "root already reaches.",
        file=sys.stderr,
    )
    sys.exit(1)

if named_count < MIN_NAMED_EDGES:
    sys.exit(
        f"zts layering: only {named_count} by-name imports were examined; expected "
        f"at least {MIN_NAMED_EDGES}. The module names derived from {BUILD_ZIG} no "
        f"longer match what the tree imports, so the direction rule above checked "
        f"almost nothing."
    )

sizes = defaultdict(int)
for tier in tier_of.values():
    sizes[tier] += 1
summary = ", ".join(f"{tier} {sizes[tier]}" for tier in TIERS)
print(
    f"zts layering: OK ({len(files)} files, {edge_count} edges, "
    f"{cross_count} cross-tier, {named_count} by-name, "
    f"{reached_count} reachable; {summary})"
)
PY
