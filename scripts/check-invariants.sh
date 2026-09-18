#!/usr/bin/env bash
#
# Application-invariant drift and evidence gate.
#
# This compares independent definitions. The acceptance kernel owns the closed
# operation catalog. The compiler maps imports to its row numbers. The native
# module owns the exports and effects. The bytecode observer owns the final-code
# names. The runtime binds the adapter identity. No producer summary is used as
# proof that these surfaces agree.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from __future__ import annotations

import pathlib
import re
import sys


class GateError(Exception):
    pass


paths = {
    "kernel": pathlib.Path("packages/proof-checker/src/invariant.zig"),
    "proof_system": pathlib.Path("packages/proof-checker/src/proof_system.zig"),
    "compiler": pathlib.Path("packages/tools/src/precompile.zig"),
    "compiler_ir": pathlib.Path("packages/zts/src/proof_ir.zig"),
    "native": pathlib.Path("packages/modules/src/data/ledger.zig"),
    "native_bridge": pathlib.Path("packages/zts/src/modules/data/ledger.zig"),
    "observer": pathlib.Path("packages/runtime/src/invariant_observer.zig"),
    "producer": pathlib.Path("packages/runtime/src/proof_certificate.zig"),
    "artifact_graph": pathlib.Path("packages/runtime/src/artifact_graph.zig"),
    "checker_tests": pathlib.Path("packages/proof-checker/src/checker.zig"),
    "config_tests": pathlib.Path("packages/tools/src/invariant_config.zig"),
    "docs": pathlib.Path("docs/verification.md"),
    "concepts": pathlib.Path("CONCEPTS.md"),
    "build": pathlib.Path("build.zig"),
}

for label, path in paths.items():
    if not path.is_file():
        raise GateError(f"missing {label} source: {path}")
    if not path.read_bytes():
        raise GateError(f"empty {label} source: {path}")

sources = {label: path.read_text() for label, path in paths.items()}


def one(pattern: str, source: str, label: str, flags: int = 0) -> str:
    matches = re.findall(pattern, source, flags)
    if len(matches) != 1:
        raise GateError(f"{label}: expected one match, found {len(matches)}")
    match = matches[0]
    return match if isinstance(match, str) else match[0]


def kernel_rows(source: str) -> list[tuple[int, str, str, int, str]]:
    body = one(
        r"pub const catalog\s*=\s*\[_\]CatalogEntry\s*\{(.*?)^\};",
        source,
        "kernel catalog",
        re.MULTILINE | re.DOTALL,
    )
    rows = re.findall(
        r"\.\{\s*\.operation\s*=\s*\.([a-z0-9_]+),\s*"
        r"\.sink\s*=\s*\.([a-z0-9_]+),\s*"
        r"\.impl_id\s*=\s*(0x[0-9a-fA-F_]+|[0-9_]+),\s*"
        r"\.writes\s*=\s*(true|false)\s*\},",
        body,
    )
    residue = re.sub(
        r"\.\{\s*\.operation\s*=\s*\.[a-z0-9_]+,\s*"
        r"\.sink\s*=\s*\.[a-z0-9_]+,\s*"
        r"\.impl_id\s*=\s*(?:0x[0-9a-fA-F_]+|[0-9_]+),\s*"
        r"\.writes\s*=\s*(?:true|false)\s*\},",
        "",
        body,
    )
    residue = re.sub(r"//[^\n]*", "", residue)
    if re.sub(r"\s", "", residue):
        raise GateError("kernel catalog contains an unparsed token or row")
    if not rows:
        raise GateError("kernel catalog is empty")
    result = []
    for index, (operation, sink, impl, writes) in enumerate(rows):
        result.append((index, operation, sink, int(impl.replace("_", ""), 0), writes))
    if len({row[1] for row in result}) != len(result):
        raise GateError("kernel catalog contains a duplicate operation")
    return result


def compiler_rows(source: str) -> dict[str, int]:
    body = one(
        r"fn resolveLedger\([^)]*\).*?\{(.*?)\n\s*\}",
        source,
        "compiler ledger resolver",
        re.DOTALL,
    )
    module = one(
        r'imported\.module,\s*"([^"]+)"',
        body,
        "compiler ledger module",
    )
    if module != "zttp:ledger":
        raise GateError(f"compiler resolves invariant calls from {module!r}")
    rows = re.findall(
        r'imported\.name,\s*"([a-z0-9_]+)"\)\)\s*return\s+([0-9]+);',
        body,
    )
    if not rows:
        raise GateError("compiler ledger resolver is empty")
    result = {name: int(index) for name, index in rows}
    if len(result) != len(rows):
        raise GateError("compiler ledger resolver contains duplicate names")
    return result


def native_rows(source: str) -> tuple[str, dict[str, str]]:
    specifier = one(r'\.specifier\s*=\s*"([^"]+)"', source, "native ledger specifier")
    exports = one(
        r"\.exports\s*=\s*&\.\{(.*?)\n\s*\},\n\};",
        source,
        "native ledger exports",
        re.DOTALL,
    )
    rows = re.findall(
        r'\.name\s*=\s*"([a-z0-9_]+)".*?\.effect\s*=\s*\.([a-z0-9_]+),',
        exports,
        re.DOTALL,
    )
    if not rows:
        raise GateError("native ledger export set is empty")
    result = dict(rows)
    if len(result) != len(rows):
        raise GateError("native ledger export set contains duplicate names")
    return specifier, result


def observer_rows(source: str) -> set[str]:
    rows = set(re.findall(r'"zttp:ledger#([a-z0-9_]+)"\)\)\s*return\s*\.([a-z0-9_]+);', source))
    if not rows:
        raise GateError("bytecode observer ledger set is empty")
    for encoded, operation in rows:
        if encoded != operation:
            raise GateError(f"observer maps {encoded} to {operation}")
    return {operation for _, operation in rows}


def documented_rows(source: str) -> list[str]:
    block = one(
        r"<!-- application-invariants: catalog -->(.*?)<!-- application-invariants: evidence -->",
        source,
        "documented invariant catalog",
        re.DOTALL,
    )
    rows = re.findall(r"^- `([^`]+)`$", block, re.MULTILINE)
    if not rows:
        raise GateError("documented invariant catalog is empty")
    return rows


def validate(current: dict[str, str]) -> tuple[list[str], list[str]]:
    kernel = kernel_rows(current["kernel"])
    compiler = compiler_rows(current["compiler"])
    specifier, native = native_rows(current["native"])
    observer = observer_rows(current["observer"])

    if len(kernel) < 2:
        raise GateError(f"kernel catalog has {len(kernel)} rows, expected at least 2")
    expected_index = {operation: index for index, operation, _, _, _ in kernel}
    if compiler != expected_index:
        raise GateError(f"compiler rows {compiler} do not match kernel rows {expected_index}")
    expected_effect = {
        operation: "write" if writes == "true" else "read"
        for _, operation, _, _, writes in kernel
    }
    if specifier != "zttp:ledger":
        raise GateError(f"native module specifier is {specifier!r}")
    if native != expected_effect:
        raise GateError(f"native exports {native} do not match kernel effects {expected_effect}")
    if observer != set(expected_index):
        raise GateError(f"observer operations {sorted(observer)} do not match kernel operations {sorted(expected_index)}")

    if one(r"ledger_call\s*=\s*([0-9]+)", current["proof_system"], "kernel ledger_call tag") != "8":
        raise GateError("kernel ledger_call tag is not 8")
    if one(r"ledger_call\s*=\s*([0-9]+)", current["compiler_ir"], "compiler ledger_call tag") != "8":
        raise GateError("compiler ledger_call tag is not 8")
    if '.ledger_call => .ledger_call' not in current["producer"]:
        raise GateError("producer no longer maps the compiler ledger_call tag exhaustively")
    if "const catalog = pcc.invariant.catalog[nodes[emission.node].aux];" not in current["producer"]:
        raise GateError("producer no longer derives sink and implementation identity from the kernel catalog")
    if 'pub const adapter_identity = "zttp:ledger/native-adapter-v1";' not in current["kernel"]:
        raise GateError("kernel ledger adapter identity is missing")
    if "adapter.adaptModuleBinding(ledger.binding)" not in current["native_bridge"]:
        raise GateError("native host bridge no longer adapts the protected ledger binding")
    if "pcc.invariant.adapterDigest()" not in current["artifact_graph"]:
        raise GateError("artifact graph no longer binds the kernel ledger adapter identity")

    docs = [
        f"{index}|{operation}|{sink}|0x{impl:08x}|{'write' if writes == 'true' else 'read'}"
        for index, operation, sink, impl, writes in kernel
    ]
    if documented_rows(current["docs"]) != docs:
        raise GateError("documented invariant catalog does not match the kernel catalog")
    if "certificate schema 4" not in current["docs"] or "`zttp_pcc_v3`" not in current["docs"]:
        raise GateError("verification docs do not state the current certificate schema and proof system")
    if "### Application invariant" not in current["concepts"]:
        raise GateError("CONCEPTS.md has no Application invariant entry")

    evidence = [
        ("checker_tests", 'test "a configured invariant is checked independently from property and guard verdicts"'),
        ("checker_tests", 'test "missing and extra invariant witnesses reject"'),
        ("checker_tests", 'test "a forged invariant operation cannot borrow a real call site"'),
        ("artifact_graph", 'test "the inventory covers every executable and authority-bearing member"'),
        ("native", 'test "posting groups require exact zero sum using i128 accumulation"'),
        ("config_tests", 'test "confirmed invariant JSON canonicalizes currencies and rejects weakened templates"'),
    ]
    missing_evidence = [marker for source, marker in evidence if marker not in current[source]]
    if missing_evidence:
        raise GateError("missing invariant evidence: " + ", ".join(missing_evidence))
    return docs, [marker for _, marker in evidence]


def require_invalidated(label: str, source_name: str, pattern: str, replacement: str) -> None:
    mutated = dict(sources)
    changed, count = re.subn(pattern, replacement, mutated[source_name], count=1, flags=re.DOTALL)
    if count != 1:
        raise GateError(f"{label} probe did not mutate exactly one source location")
    mutated[source_name] = changed
    try:
        validate(mutated)
    except GateError:
        return
    raise GateError(f"{label} invalidation probe passed")


try:
    catalog, evidence = validate(sources)
    require_invalidated(
        "deleted kernel row",
        "kernel",
        r"\n\s*\.\{\s*\.operation\s*=\s*\.balance,.*?\.writes\s*=\s*false\s*\},",
        "",
    )
    require_invalidated(
        "mutated compiler row",
        "compiler",
        r'(imported\.name,\s*"balance"\)\)\s*return\s+)1;',
        r"\g<1>0;",
    )
    require_invalidated(
        "deleted native export",
        "native",
        r"\n\s*\.\{\n\s*\.name\s*=\s*\"balance\".*?\n\s*\},",
        "",
    )
    require_invalidated(
        "mutated bytecode observer row",
        "observer",
        r'"zttp:ledger#balance"\)\) return \.balance;',
        '"zttp:ledger#balance_probe")) return .balance;',
    )
except GateError as error:
    print(f"application invariants: {error}", file=sys.stderr)
    sys.exit(1)

print(
    f"application invariants: {len(catalog)} catalog rows and "
    f"{len(evidence)} compiled evidence markers agree; mutation probes reject"
)
PY
