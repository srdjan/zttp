#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import NamedTuple


WASM_NAME_PATTERN = re.compile(r"^zts-analyzer\.([0-9a-f]{12})\.wasm$")
WASM_URL_PATTERN = re.compile(
    r'^const WASM_URL = "(/zts-analyzer\.[0-9a-f]{12}\.wasm)";$', re.MULTILINE
)
CACHE_TARGET_PATTERN = re.compile(r'src="/playground\.js\?v=([0-9]+)"')


class PublishError(Exception):
    pass


class ValidatedDestination(NamedTuple):
    static: Path
    playground_path: Path
    playground: str
    index_path: Path
    index: str
    cache_version: int
    wasm_path: Path
    wasm_content: bytes


def sha256_prefix(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()[:12]


def atomic_write(path: Path, content: bytes, mode: int = 0o644) -> None:
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def atomic_create(path: Path, content: bytes, mode: int = 0o644) -> None:
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, mode)
        try:
            os.link(temporary_path, path)
        except FileExistsError as error:
            raise PublishError(f"new website WASM already exists unexpectedly: {path.name}") from error
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def validate_destination(website_root: Path) -> ValidatedDestination:
    try:
        root = website_root.resolve(strict=True)
    except FileNotFoundError as error:
        raise PublishError(f"website root not found: {website_root}") from error

    deno_json = root / "deno.json"
    try:
        metadata = json.loads(deno_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublishError(f"invalid website metadata: {deno_json}") from error
    if metadata.get("name") != "@srdjan/zttp-website":
        raise PublishError(f"destination is not @srdjan/zttp-website: {root}")

    try:
        static = (root / "static").resolve(strict=True)
    except FileNotFoundError as error:
        raise PublishError(f"website static directory not found: {root / 'static'}") from error
    if static.parent != root:
        raise PublishError("website static directory resolves outside the website root")

    playground_path = static / "playground.js"
    index_path = static / "index.html"
    try:
        playground = playground_path.read_text(encoding="utf-8")
        index = index_path.read_text(encoding="utf-8")
    except OSError as error:
        raise PublishError("website playground.js or index.html is missing") from error

    wasm_paths = sorted(path for path in static.glob("*.wasm") if path.is_file())
    if len(wasm_paths) != 1:
        raise PublishError(f"destination must contain exactly one existing WASM, found {len(wasm_paths)}")
    wasm_path = wasm_paths[0]
    name_match = WASM_NAME_PATTERN.fullmatch(wasm_path.name)
    if name_match is None:
        raise PublishError(f"unexpected website WASM filename: {wasm_path.name}")
    wasm_content = wasm_path.read_bytes()
    if name_match.group(1) != sha256_prefix(wasm_content):
        raise PublishError(f"website WASM hash does not match its filename: {wasm_path.name}")

    wasm_urls = WASM_URL_PATTERN.findall(playground)
    if len(wasm_urls) != 1:
        raise PublishError(f"playground.js must contain exactly one WASM_URL, found {len(wasm_urls)}")
    if wasm_urls[0] != f"/{wasm_path.name}":
        raise PublishError("playground.js does not reference the existing website WASM")

    cache_targets = CACHE_TARGET_PATTERN.findall(index)
    if len(cache_targets) != 1:
        raise PublishError(f"index.html must contain exactly one playground cache target, found {len(cache_targets)}")

    return ValidatedDestination(
        static=static,
        playground_path=playground_path,
        playground=playground,
        index_path=index_path,
        index=index,
        cache_version=int(cache_targets[0]),
        wasm_path=wasm_path,
        wasm_content=wasm_content,
    )


def publish_wasm(website_root: Path, wasm_source: Path) -> dict[str, object]:
    destination = validate_destination(website_root)
    try:
        source = wasm_source.resolve(strict=True)
        source_content = source.read_bytes()
    except OSError as error:
        raise PublishError(f"WASM source not found: {wasm_source}") from error
    if not source_content.startswith(b"\x00asm"):
        raise PublishError(f"WASM source has an invalid header: {source}")

    new_name = f"zts-analyzer.{sha256_prefix(source_content)}.wasm"
    old_path = destination.wasm_path
    old_content = destination.wasm_content
    if new_name == old_path.name:
        if source_content != old_content:
            raise PublishError("WASM hash-prefix collision detected")
        return {"changed": False, "wasm_name": new_name, "bytes": len(source_content)}

    static = destination.static
    playground_path = destination.playground_path
    index_path = destination.index_path
    playground = destination.playground
    index = destination.index
    cache_version = destination.cache_version

    patched_playground, wasm_url_count = WASM_URL_PATTERN.subn(
        f'const WASM_URL = "/{new_name}";', playground
    )
    patched_index, cache_target_count = CACHE_TARGET_PATTERN.subn(
        f'src="/playground.js?v={cache_version + 1}"', index
    )
    if wasm_url_count != 1:
        raise PublishError("failed to patch exactly one WASM_URL")
    if cache_target_count != 1:
        raise PublishError("failed to patch exactly one playground cache target")

    new_path = static / new_name
    new_created = False
    playground_changed = False
    index_changed = False
    old_removed = False
    try:
        atomic_create(new_path, source_content)
        new_created = True
        atomic_write(playground_path, patched_playground.encode("utf-8"))
        playground_changed = True
        atomic_write(index_path, patched_index.encode("utf-8"))
        index_changed = True
        old_path.unlink()
        old_removed = True
        final = validate_destination(website_root)
        if final.wasm_path.name != new_name:
            raise PublishError("published website WASM failed final validation")
    except Exception as error:
        if old_removed:
            atomic_write(old_path, old_content)
        if index_changed:
            atomic_write(index_path, index.encode("utf-8"))
        if playground_changed:
            atomic_write(playground_path, playground.encode("utf-8"))
        if new_created:
            new_path.unlink(missing_ok=True)
        if isinstance(error, PublishError):
            raise
        raise PublishError(f"WASM publication failed and was rolled back: {error}") from error

    return {"changed": True, "wasm_name": new_name, "bytes": len(source_content)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Publish the zttp analyzer WASM to its website")
    parser.add_argument("--website-root", required=True, type=Path)
    parser.add_argument("--wasm", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = publish_wasm(args.website_root, args.wasm)
    except PublishError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    state = "Published" if result["changed"] else "Already current"
    print(f"{state} {result['wasm_name']} ({result['bytes']} bytes raw)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
