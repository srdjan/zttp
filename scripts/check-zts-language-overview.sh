#!/usr/bin/env bash
# Keep the reader-facing ZTS overview aligned with compiler-owned registries.
#
# Usage:
#   bash scripts/check-zts-language-overview.sh [path-to-zts]

set -euo pipefail

cd "$(dirname "$0")/.."

ZTS="${1:-./zig-out/bin/zts}"
OVERVIEW="docs/zts-language-overview.html"

fail() {
  printf 'ZTS language overview drift: %s\n' "$1" >&2
  exit 1
}

[[ -x "$ZTS" ]] || fail "missing executable compiler at $ZTS"
[[ -f "$OVERVIEW" ]] || fail "missing $OVERVIEW"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '%s\n' '{"schema_version":2,"operation":"meta","project_root":".","input":{}}' |
  "$ZTS" agent --stdin-json > "$work/meta.json" 2> "$work/meta.err" ||
  fail "schema-v2 meta failed: $(head -n 1 "$work/meta.err")"

"$ZTS" spec-check --json > "$work/semantics.json" 2> "$work/semantics.err" ||
  fail "spec-check failed: $(head -n 1 "$work/semantics.err")"

if ! python3 - "$OVERVIEW" "$work/meta.json" "$work/semantics.json" "$work/type-only.ts" <<'PY'
from collections import Counter, defaultdict
from html.parser import HTMLParser
import json
import sys


class OverviewParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.facts = defaultdict(list)
        self.modules = []
        self.examples = defaultdict(list)
        self.fact_stack = []
        self.module_stack = []
        self.example_stack = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        fact = attributes.get("data-zts-fact")
        if fact is not None:
            self.fact_stack.append([tag, fact, []])
        if "data-zts-module" in attributes:
            self.module_stack.append([tag, []])
        example = attributes.get("data-zts-check")
        if example is not None:
            self.example_stack.append([tag, example, []])

    def handle_data(self, data):
        for entry in self.fact_stack:
            entry[2].append(data)
        for entry in self.module_stack:
            entry[1].append(data)
        for entry in self.example_stack:
            entry[2].append(data)

    def handle_endtag(self, tag):
        if self.fact_stack and self.fact_stack[-1][0] == tag:
            _, name, parts = self.fact_stack.pop()
            self.facts[name].append("".join(parts).strip())
        if self.module_stack and self.module_stack[-1][0] == tag:
            _, parts = self.module_stack.pop()
            self.modules.append("".join(parts).strip())
        if self.example_stack and self.example_stack[-1][0] == tag:
            _, name, parts = self.example_stack.pop()
            self.examples[name].append("".join(parts))


overview_path, meta_path, semantics_path, example_path = sys.argv[1:]
parser = OverviewParser()
with open(overview_path, encoding="utf-8") as handle:
    parser.feed(handle.read())
parser.close()

with open(meta_path, encoding="utf-8") as handle:
    meta_response = json.load(handle)
with open(semantics_path, encoding="utf-8") as handle:
    semantics = json.load(handle)

if meta_response.get("success") is not True:
    raise SystemExit("schema-v2 meta did not report success")
if semantics.get("ok") is not True:
    raise SystemExit("spec-check did not report success")
meta = meta_response["payload"]

modules = meta["module_catalog"]
exports = [export for module in modules for export in module["exports"]]
effects = Counter(export["effect"] for export in exports)

# A closed effect vocabulary is part of the page's three-way legend. A new
# class must be added deliberately instead of disappearing from the totals.
if set(effects) != {"none", "read", "write"}:
    raise SystemExit("unexpected effect classes: %s" % sorted(effects))

frontends = meta["source_frontends"]
if len(frontends) != 1:
    raise SystemExit("expected exactly one source frontend, got %d" % len(frontends))

expected = {
    "profile_id": meta["profile_id"],
    "frontend_profile_id": frontends[0]["profile_id"],
    "compiler_version": meta["compiler_version"],
    "policy_version": meta["policy_version"],
    "grammar_productions": len(meta["grammar"]),
    "published_idioms": len(meta["idioms"]),
    "ambient_types": len(meta["ambient_names"]["types"]),
    "ambient_values": len(meta["ambient_names"]["values"]),
    "capability_modules": len(modules),
    "module_exports": len(exports),
    "effect_none": effects["none"],
    "effect_read": effects["read"],
    "effect_write": effects["write"],
    "agent_operations": len(meta["operations"]),
    "ir_classified": semantics["nodes"]["classified"],
    "ir_reachable": semantics["nodes"]["reachable"],
    "ir_specified": semantics["nodes"]["specified"],
    "ir_trusted": semantics["nodes"]["trusted"],
    "opcode_classified": semantics["opcodes"]["classified"],
    "opcode_reachable": semantics["opcodes"]["reachable"],
    "opcode_specified": semantics["opcodes"]["specified"],
    "opcode_translation_validated": semantics["opcodes"]["translationValidated"],
    "opcode_trusted": semantics["opcodes"]["trusted"],
}

# Floor: every expected fact must occur in the rendered document, no unknown
# fact marker may be present, and every live registry must be non-empty before
# equality has any evidentiary value.
if set(parser.facts) != set(expected):
    missing = sorted(set(expected) - set(parser.facts))
    unknown = sorted(set(parser.facts) - set(expected))
    raise SystemExit("fact marker mismatch; missing=%s unknown=%s" % (missing, unknown))
if (
    len(meta["grammar"]) < 1
    or len(meta["idioms"]) < 1
    or len(modules) < 1
    or len(exports) < 1
    or semantics["nodes"]["reachable"] < 1
    or semantics["opcodes"]["reachable"] < 1
):
    raise SystemExit("a live registry used by the overview is empty")

for name, wanted in expected.items():
    values = parser.facts[name]
    if not values:
        raise SystemExit("fact %s has no displayed value" % name)
    for value in values:
        got = int(value) if isinstance(wanted, int) else value
        if got != wanted:
            raise SystemExit("%s displays %r, compiler reports %r" % (name, got, wanted))

published_modules = [module["specifier"] for module in modules]
if not parser.modules:
    raise SystemExit("overview module list is empty")
if Counter(parser.modules) != Counter(published_modules):
    missing = sorted((Counter(published_modules) - Counter(parser.modules)).elements())
    extra = sorted((Counter(parser.modules) - Counter(published_modules)).elements())
    raise SystemExit("module list mismatch; missing=%s extra=%s" % (missing, extra))

if set(parser.examples) != {"type-only"} or len(parser.examples["type-only"]) != 1:
    raise SystemExit("expected exactly one type-only compiler example")
example = parser.examples["type-only"][0]
if len(example) < 300 or "structural Result<T, E>" not in example or "function divide" not in example:
    raise SystemExit("type-only example floor failed")
with open(example_path, "w", encoding="utf-8") as handle:
    handle.write(example)

print(
    "overview facts OK (%d productions, %d idioms, %d modules, %d exports)"
    % (len(meta["grammar"]), len(meta["idioms"]), len(modules), len(exports))
)
PY
then
  fail "displayed compiler facts do not match the live registries"
fi

# The overview snippet is a library-shaped fragment, so the default handler
# proof emits ZTS500. Every syntax, type, flow, or canonical diagnostic remains
# a failure here.
if "$ZTS" check "$work/type-only.ts" --json > "$work/type-check.json" 2> "$work/type-check.err"; then
  :
fi

if ! python3 - "$work/type-check.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)

unexpected = [
    diagnostic
    for diagnostic in result.get("diagnostics", [])
    if diagnostic.get("code") != "ZTS500"
]
if unexpected:
    first = unexpected[0]
    raise SystemExit("%s: %s" % (first.get("code", "unknown"), first.get("message", "")))
PY
then
  fail "the copied Result example has a compiler diagnostic"
fi

printf 'ZTS language overview OK (live facts, module catalog, and copied Result example)\n'
