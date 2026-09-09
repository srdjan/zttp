#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "wasm_playground_publish", SCRIPT_DIR / "wasm-playground-publish.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load WASM publisher")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


def hash_name(content: bytes) -> str:
    return f"zts-analyzer.{hashlib.sha256(content).hexdigest()[:12]}.wasm"


def write_website(root: Path, wasm_content: bytes = b"\x00asm old wasm") -> tuple[Path, str]:
    static = root / "static"
    static.mkdir(parents=True)
    (root / "deno.json").write_text(
        json.dumps({"name": "@srdjan/zttp-website"}), encoding="utf-8"
    )
    old_name = hash_name(wasm_content)
    (static / old_name).write_bytes(wasm_content)
    (static / "playground.js").write_text(
        f'const WASM_URL = "/{old_name}";\n', encoding="utf-8"
    )
    (static / "index.html").write_text(
        '<script src="/playground.js?v=16" defer></script>\n', encoding="utf-8"
    )
    return static, old_name


def tree_snapshot(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class WasmPlaygroundPublishTests(unittest.TestCase):
    def test_changed_publication_updates_references_before_removing_old_wasm(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            static, old_name = write_website(root)
            source = root / "new.wasm"
            source.write_bytes(b"\x00asm new wasm")
            new_name = hash_name(source.read_bytes())

            result = publisher.publish_wasm(root, source)

            self.assertTrue(result["changed"])
            self.assertEqual(result["wasm_name"], new_name)
            self.assertFalse((static / old_name).exists())
            self.assertEqual(
                [path.name for path in static.glob("zts-analyzer.*.wasm")], [new_name]
            )
            self.assertIn(f'const WASM_URL = "/{new_name}";', (static / "playground.js").read_text())
            self.assertIn('src="/playground.js?v=17"', (static / "index.html").read_text())

    def test_unchanged_publication_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            static, old_name = write_website(root)
            source = root / "source.wasm"
            source.write_bytes((static / old_name).read_bytes())
            before = tree_snapshot(root)

            result = publisher.publish_wasm(root, source)

            self.assertFalse(result["changed"])
            self.assertEqual(tree_snapshot(root), before)

    def test_duplicate_wasm_url_fails_without_modifying_destination(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            static, old_name = write_website(root)
            playground = static / "playground.js"
            playground.write_text(
                f'const WASM_URL = "/{old_name}";\nconst WASM_URL = "/{old_name}";\n',
                encoding="utf-8",
            )
            source = root / "new.wasm"
            source.write_bytes(b"\x00asm new wasm")
            before = tree_snapshot(root)

            with self.assertRaisesRegex(publisher.PublishError, "exactly one WASM_URL"):
                publisher.publish_wasm(root, source)

            self.assertEqual(tree_snapshot(root), before)

    def test_missing_cache_bust_target_fails_without_modifying_destination(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            static, _ = write_website(root)
            (static / "index.html").write_text("<main>missing script</main>\n", encoding="utf-8")
            source = root / "new.wasm"
            source.write_bytes(b"\x00asm new wasm")
            before = tree_snapshot(root)

            with self.assertRaisesRegex(publisher.PublishError, "exactly one playground cache target"):
                publisher.publish_wasm(root, source)

            self.assertEqual(tree_snapshot(root), before)

    def test_duplicate_wasm_artifacts_fail_without_modifying_destination(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            static, _ = write_website(root)
            (static / "zts-analyzer.000000000000.wasm").write_bytes(b"\x00asm duplicate")
            source = root / "new.wasm"
            source.write_bytes(b"\x00asm new wasm")
            before = tree_snapshot(root)

            with self.assertRaisesRegex(publisher.PublishError, "exactly one existing WASM"):
                publisher.publish_wasm(root, source)

            self.assertEqual(tree_snapshot(root), before)


if __name__ == "__main__":
    unittest.main()
