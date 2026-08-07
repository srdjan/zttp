#!/usr/bin/env bash
#
# Measure the relative-import graph inside `packages/zts`.
#
# `docs/plans/2026-08-07-021-zts-three-module-split-plan.md` prices the
# zts-base / zts-contracts / zts / zts-compiler split from this graph. The
# header of `scripts/check-module-boundary.sh` used to carry that price as two
# written-down numbers, and both went stale: it said 84 files where the tree had
# 94 at the top level of `src/` and 154 once the subdirectories are counted.
# This script prints the live numbers instead, so the plan can be re-checked
# against the tree rather than against a comment.
#
# What it reports:
#
#   - the file and edge counts of the graph;
#   - every strongly connected component larger than one file. A Zig module
#     graph is a DAG, so any component spanning a proposed module line is a
#     blocker: no assignment of those files to separate modules compiles, and
#     rewiring their imports without breaking the cycle is what makes Zig
#     analyze the engine twice;
#   - the transitive import closure of the engine entry points, which is the
#     set of files the bottom module drags in as the tree stands;
#   - the back edges that carry the closure, ranked by how many files each one
#     frees. The point of the ranking is that the cycle is concentrated: a
#     handful of edges hold most of it.
#
# Named-module imports (std, build_options, zttp-sdk, zttp-modules) are excluded
# because they already cross a module boundary correctly. Only relative
# `@import("....zig")` edges are counted.
#
# This is a reporting tool, not a gate: it does not fail on a cycle, because
# every cycle it finds is legal today. Step 2 of the plan turns the tier
# direction into a gate. What it does fail on is its own input going missing -
# an empty graph would otherwise print a clean report while measuring nothing.

set -euo pipefail

cd "$(dirname "$0")/.."

# The file list is read inside Python rather than piped in: a heredoc claims
# stdin, so a `git ls-files | python3 - <<PY` pipeline silently delivers an
# empty list. `-z` keeps paths with spaces intact, matching the convention in
# the other scripts here.
python3 - "$@" <<'PY'
import os
import re
import subprocess
import sys
from collections import defaultdict, deque

PREFIX = "packages/zts/src/"

# The engine entry points: what a consumer reaches when it embeds the runtime or
# runs a handler. Everything reachable from these is what the bottom module
# would have to contain if the tree were split today.
ENGINE_ROOTS = [
    "context.zig",
    "interpreter.zig",
    "pool.zig",
    "builtins/root.zig",
    "parser/root.zig",
    "http.zig",
    "stripper.zig",
    "modules/root.zig",
    "comptime.zig",
    "bytecode_cache.zig",
]

# Floors on the input. A graph that lost its file list, or whose roots were
# renamed out from under it, would otherwise report a tidy zero-cycle result.
MIN_FILES = 100
MIN_EDGES = 400

listing = subprocess.run(
    ["git", "ls-files", "-z", "--", "packages/zts"],
    capture_output=True,
    text=True,
    check=True,
).stdout
paths = [p for p in listing.split("\0") if p.endswith(".zig")]
files = sorted(p for p in paths if p.startswith(PREFIX))
fileset = set(files)

if len(files) < MIN_FILES:
    sys.exit(
        f"zts import graph: only {len(files)} files under {PREFIX}; "
        f"expected at least {MIN_FILES}. The file list or the path prefix changed."
    )

IMPORT = re.compile(r'@import\("([^"]+)"\)')


def strip_comments(source):
    """Drop `//` line comments so a commented-out or documented import is not
    counted as an edge. `parser/root.zig` documents `@import("parser/root.zig")`
    in its header, which would otherwise read as a self-edge. A `//` inside a
    string literal is left alone by counting the quotes before it; that is
    enough for import lines and does not try to be a Zig lexer."""
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


edges = {f: set() for f in files}
unresolved = defaultdict(set)
for f in files:
    with open(f, encoding="utf-8") as handle:
        source = strip_comments(handle.read())
    directory = os.path.dirname(f)
    for match in IMPORT.finditer(source):
        spec = match.group(1)
        if not spec.endswith(".zig"):
            continue
        target = os.path.normpath(os.path.join(directory, spec))
        if target in fileset:
            edges[f].add(target)
        else:
            unresolved[f].add(spec)

edge_count = sum(len(v) for v in edges.values())
if edge_count < MIN_EDGES:
    sys.exit(
        f"zts import graph: only {edge_count} relative import edges; "
        f"expected at least {MIN_EDGES}. The import syntax or the scan changed."
    )

missing_roots = [r for r in ENGINE_ROOTS if PREFIX + r not in fileset]
if missing_roots:
    sys.exit(
        "zts import graph: engine roots no longer exist: "
        + ", ".join(missing_roots)
        + ". Update ENGINE_ROOTS, or the closure below measures the wrong thing."
    )

short = lambda p: p[len(PREFIX):]


def strongly_connected(graph, nodes):
    """Tarjan, iterative: recursion depth would exceed the default limit."""
    index, low, on_stack, stack, components = {}, {}, {}, [], []
    counter = 0
    for start in nodes:
        if start in index:
            continue
        index[start] = low[start] = counter
        counter += 1
        stack.append(start)
        on_stack[start] = True
        work = [(start, iter(sorted(graph[start])))]
        while work:
            node, children = work[-1]
            descended = False
            for child in children:
                if child not in index:
                    index[child] = low[child] = counter
                    counter += 1
                    stack.append(child)
                    on_stack[child] = True
                    work.append((child, iter(sorted(graph[child]))))
                    descended = True
                    break
                if on_stack.get(child):
                    low[node] = min(low[node], index[child])
            if descended:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                component = []
                while True:
                    popped = stack.pop()
                    on_stack[popped] = False
                    component.append(popped)
                    if popped == node:
                        break
                components.append(component)
    return components


def closure(graph):
    roots = [PREFIX + r for r in ENGINE_ROOTS]
    seen = set(roots)
    queue = deque(roots)
    while queue:
        node = queue.popleft()
        for child in graph.get(node, ()):
            if child not in seen:
                seen.add(child)
                queue.append(child)
    return seen


print(f"zts import graph: {len(files)} files, {edge_count} relative import edges")
top_level = sum(1 for f in files if "/" not in short(f))
print(f"  {top_level} at the top level of {PREFIX}, {len(files) - top_level} in subdirectories")

components = [c for c in strongly_connected(edges, files) if len(c) > 1]
components.sort(key=len, reverse=True)
print(f"\nstrongly connected components larger than one file: {len(components)}")
for component in components:
    members = sorted(short(m) for m in component)
    print(f"  size {len(members)}: {', '.join(members)}")

engine = closure(edges)
print(f"\nengine closure: {len(engine)} of {len(files)} files reachable from")
print(f"  {', '.join(ENGINE_ROOTS)}")

# Rank the back edges: at each step remove the single edge inside the closure
# whose removal frees the most files, and stop once no edge frees more than one.
# Below that threshold the remaining edges are ordinary tier assignment rather
# than cycle breaking, and listing them buries the ones that matter.
working = {f: set(v) for f, v in edges.items()}
print("\nback edges carrying the closure, ranked by files freed:")
ranked = 0
while True:
    current = closure(working)
    best, best_gain = None, 1
    for source in current:
        for target in list(working[source]):
            if target not in current:
                continue
            working[source].discard(target)
            gain = len(current) - len(closure(working))
            working[source].add(target)
            if gain > best_gain:
                best, best_gain = (source, target), gain
    if best is None:
        break
    working[best[0]].discard(best[1])
    ranked += 1
    print(
        f"  {short(best[0]):36s} -> {short(best[1]):30s} "
        f"frees {best_gain:3d}, closure {len(closure(working)):3d}"
    )
if ranked == 0:
    print("  none: no single edge frees more than one file")
else:
    print(f"\n{ranked} cuts take the engine closure from {len(engine)} to {len(closure(working))}")

if unresolved:
    print("\nrelative imports that resolve to no tracked file:")
    for f in sorted(unresolved):
        print(f"  {short(f)}: {', '.join(sorted(unresolved[f]))}")
PY
