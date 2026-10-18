# Local release pipeline: no CI build or test

Status: planned 2026-10-18, revised after a Fable critique and a Codex fact
check. Owner decisions: D9 A, D10 A, D11 A, D12 B.

## Decisions this plan carries out

- D9 A: drop the Intel macOS (`x86_64-macos-none`) binary from releases.
  `install.sh` on an Intel Mac exits with a clear message.
- D10 A: one local script, `scripts/release.sh vX.Y.Z`, verifies, builds,
  smoke-tests, and publishes the GitHub release. Linux runs in Apple's
  `container` CLI (1.5.0). `.github/workflows/release.yml` is deleted.
- D11 A: the unpublished `v0.22.3` tag moves to the final commit.
- D12 B: `.github/workflows/ci.yml` is deleted entirely.

Not decided here: `.github/workflows/proof-gate.yml` runs `zig build
-Doptimize=ReleaseFast` on pull requests. `docs/proofs-and-receipts.md:456`
documents it as a template users copy. It stays until the owner decides.

## Why

GitHub's macOS runner hit the 30-minute job limit in the v0.22.3 release run:
the verifier step ran 29m45s before cancellation. The owner runs verification
locally instead.

## Work items

### W1 `scripts/release.sh` and `scripts/release-linux.Containerfile`

Usage:

- `bash scripts/release.sh vX.Y.Z --no-publish`: run every gate, build, package,
  smoke-test, render notes, and write a manifest. No network writes.
- `bash scripts/release.sh vX.Y.Z --publish`: no gates. Re-check preconditions,
  require the manifest to match, re-hash the dist files against it, publish.

Bash, `set -euo pipefail`. Each step prints a `>> ` header like
`scripts/verify.sh`. No `python3`. Write `command rm`, `command cp`,
`command mv` (the owner's shell aliases add `-i`).

Work directory: `${XDG_CACHE_HOME:-$HOME/.cache}/zttp-release/$tag/` (not
`$TMPDIR`; a full system volume is a known failure here). Subdirectories:
`host/` (clone), `cache/` (one `ZIG_LOCAL_CACHE_DIR` for the whole run),
`out/<target>/` (prefix builds), `dist/` (assets), `release-notes.md`,
`manifest`.

Environment: at the start, unset the provider family so every replay stays
offline: `DEEPSEEK_API_KEY`, every `DEEPSEEK_*`, every `ZTTP_CODEGEN_*`
(including `ZTTP_CODEGEN_RECORD` and `ZTTP_CODEGEN_PROVIDER`), and
`ZTTP_MLX_BASE_URL`. Export `COPYFILE_DISABLE=1`.

Cleanup: one `trap ... EXIT INT TERM` that stops every container the script
named (`--name zttp-release-<role>-$$`, always with `--rm`) and kills any
`zttp serve` PID it started.

Steps for `--no-publish`, in order:

1. Preconditions, each with its own message: argument is `v<VERSION>`; the
   working tree is clean (`git status --porcelain --untracked-files=normal`
   empty); `HEAD` equals `git rev-parse "$tag^{commit}"`; the three
   `build.zig.zon` `.version` fields and `packages/zts/src/root.zig`
   `pub const string` equal the tag version (port the awk block from the old
   release.yml "Verify release tag matches version" step, `git show
   ec3f98bd:.github/workflows/release.yml`); `rg jq gh container zig git shasum
   tar` on PATH; `zig version` equals `build.zig.zon` `minimum_zig_version`.
2. Host gates in a fresh clone, not the working tree (ignored files must not
   leak in): `git clone -q "$repo" "$work/host"`, checkout the tag, then in
   `$work/host`:
   - `bash scripts/verify.sh --release`
   - `zig build smoke-getting-started`
   - advisory benchmark, exactly one line:
     `zig build bench-check || echo "warning: advisory bench-check missed; see RELEASE_CHECKLIST.md"`
   - `zig build release-check -- --json`
   - when `PROOF_LEDGER_PATH` is set: `test -f "$PROOF_LEDGER_PATH"`, then
     `./zig-out/bin/zttp ledger replay --input "$PROOF_LEDGER_PATH" --onto "${PROOF_LEDGER_ONTO:-HEAD}"`.
3. Linux image. `container system start` (registers and health-checks the
   service; safe to repeat). Build the image only when `container image
   inspect zttp-release-linux:0.16.0-amd64` fails:
   `container build --arch amd64 -f scripts/release-linux.Containerfile -t zttp-release-linux:0.16.0-amd64 scripts/`.
   The Containerfile: `FROM ubuntu:24.04`; `apt-get install -y git ripgrep jq
   curl xz-utils ca-certificates`; download
   `https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz`; check
   sha256 `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`
   with `sha256sum -c`; extract to `/opt/zig`; put it on `PATH`.
4. Linux gate: `container run --rm --name zttp-release-verify-$$ --arch amd64
   --rosetta --cpus 10 --memory 12G -v "$repo":/src:ro
   zttp-release-linux:0.16.0-amd64 bash -c '...'`. Inside: `git clone -q /src
   /work && cd /work && git checkout -q "$tag" && bash scripts/verify.sh
   --release`, with the default relative `.zig-cache` (the configuration that
   exposed the relative-path bug). Before that, print `nproc`, `free -m`, and
   `zig version` so a resource kill is diagnosable. The container exit status
   is the gate result. Rosetta is used because Zig's Debug x86_64 backend is
   self-hosted, which is where the 0.22.2 crash showed.
5. Build and package. Targets, exactly, as one bash array:
   `x86_64-linux-gnu:linux:x86_64`, `aarch64-linux-gnu:linux:aarch64`,
   `aarch64-macos-none:macos:aarch64`. For each, in `$work/host`:
   `zig build -Doptimize=ReleaseFast -Dtarget=<t> -Dstrip --prefix "$work/out/<t>"`.
   Package in `$work/dist` (`cd` there first, so tarball and `.sha256` paths
   are relative, as `install.sh` verifies them): directory
   `zttp-<tag>-<os>-<arch>` with `zttp`, `zttp-runtime`, `zts`, `LICENSE`,
   `README.md`, `CHANGELOG.md`, and `VERSION` (four `key=value` lines:
   `version`, `target`, `os`, `arch`); `tar czf`; assert `tar tzf` lists
   exactly 8 entries (the directory plus 7 files) and each expected name;
   `shasum -a 256 <name>.tar.gz > <name>.tar.gz.sha256`; remove the staging
   directory. Then `cat *.sha256 > checksums-sha256.txt`.
6. Smoke tests, one shell function shared by all three: extract the tarball,
   check `zttp version` contains the version, `zttp --help` exits 0, start
   `zttp serve -e 'function handler(req) { return Response.json({ ok: true }); }' -p <port>`,
   retry `curl -sf` up to 50 times at 0.2 s, then require the body to match
   `"ok"[[:space:]]*:[[:space:]]*true`. Pick a free port first.
   - `linux-x86_64` in `zttp-release-linux:0.16.0-amd64` (`--arch amd64 --rosetta`);
   - `linux-aarch64` in `ubuntu:24.04` with `--arch arm64` (install `curl` first);
   - `macos-aarch64` on the host with `/usr/bin/curl ... < /dev/null`.
7. `sh scripts/render-release-notes.sh "$tag" "$work/release-notes.md"`.
8. Write `$work/manifest`: `tag=`, `commit=` (HEAD sha), and one
   `sha256 <file>` line per dist file (7 files). Print the dist directory and
   the next command.

Steps for `--publish`:

1. Preconditions from step 1 above, plus: `gh auth status` succeeds;
   `git ls-remote origin "refs/tags/$tag^{}"` equals HEAD (the tag is pushed);
   `git merge-base --is-ancestor HEAD origin/main` after `git fetch origin`
   (main is pushed); `$work/manifest` exists with matching `tag` and `commit`;
   every dist file's sha256 matches the manifest.
2. Existing release: query `gh api "repos/{owner}/{repo}/releases/tags/$tag"`.
   HTTP 404 means none. A draft: `gh release delete "$tag" --yes` (keep the
   tag), then continue. A published release: abort. Any other failure: abort
   with the error.
3. `gh release create "$tag" --draft --verify-tag --title "$tag" --notes-file
   "$work/release-notes.md" --generate-notes dist/*.tar.gz dist/*.tar.gz.sha256
   dist/checksums-sha256.txt`.
4. Assert `gh release view "$tag" --json assets` lists exactly the 7 dist file
   names, then `gh release edit "$tag" --draft=false`. Print the release URL.

### W2 Delete `.github/workflows/ci.yml` and `.github/workflows/release.yml`

### W3 `tooling/repo_gate.zig`: `release-workflow` mode checks the script

Keep the subcommand name and the build step `test-release-workflow`. Replace
the YAML checks and the six YAML errors with checks over `scripts/release.sh`.
Normalize first: join backslash-continued lines into logical lines, and drop
logical lines whose first non-space character is `#`. Then, one named error
per rule:

- `MissingHostVerify`: a logical line starting (after whitespace) with
  `bash scripts/verify.sh --release`.
- `MissingContainerVerify`: a logical line containing `container run`,
  `--arch amd64`, and `scripts/verify.sh --release`.
- `InvalidBenchmarkStepCount`: exactly one logical line contains
  `zig build bench-check`.
- `BenchmarkMustBeAdvisory`: that line contains `||`.
- `MissingSmokeGettingStarted`: a line with `zig build smoke-getting-started`.
- `MissingReleaseCheck`: a line with `zig build release-check`.
- `MissingReleaseTarget`: each of `x86_64-linux-gnu`, `aarch64-linux-gnu`,
  `aarch64-macos-none` appears.
- `IntelMacosTarget`: `x86_64-macos-none` appears on no logical line.
- `ReleaseNotDraft`: a line with `gh release create` that contains `--draft`.

Update `releaseMessage`. Rewrite the positive fixture and unit tests as script
text. Build each negative fixture as the positive fixture plus one edit, and
cover every error above, including a case where the only container-verify
line is a comment. `scripts/test-release-workflow.sh` passes
`scripts/release.sh`.

### W4 `tooling/release_check.zig`

`addReleaseGateCheck` reads `scripts/release.sh` instead of the workflows.
New signature `releaseGateRequirementsPresent(build_zig, release_sh,
verify_sh)` requires `build_gate_markers` in build sources,
`release_verify_commands` in the script, `release_only_verify_marker` in the
script, `gh release create` in the script (replaces
`release_permission_marker`), and `verify_script_markers` in verify.sh.
Delete `ci_gate_markers`. Passport text: "release script, local verifier,
browser analyzer, installer, semantics, docs, smoke, and doctor gates are
wired". Update the unit tests and `writeReleaseDoctorFixture` (it creates
`.github/workflows` and writes both YAML files) to write `scripts/release.sh`.
Keep the negative test that a script running only the per-commit verifier
fails.

### W5 `build/step_coverage.zig`

Coverage text is `scripts/verify.sh` and `scripts/release.sh` (both
`@embedFile`), plus every `.yml` in `.github/workflows` when that directory
exists. Remove the panic on a missing or empty workflow directory. Floor:
panic when either embedded script is empty or names no `zig build `. Track
steps covered only by `scripts/release.sh` and report their count in the OK
line ("..., N run only at release"). Update the doc comment, the failure
message, the `scripts/manual-steps.allow` header (line 3 and the benchmark
note near line 32), and `docs/internals/testing.md` near line 298. Fix
allowlist rows in both directions as the gate reports.

### W6 `scripts/test-release-notes.sh`

Replace the two greps on release.yml with greps on `scripts/release.sh` for
`sh scripts/render-release-notes.sh "$tag"` and `--notes-file`.

### W7 Script reachability

The new references from W3-W6 make `scripts/release.sh` reachable. Add no
`manual-scripts.allow` row. Confirm with `zig build test-script-reachability`.
The gate covers `.sh` files; the Containerfile needs no row unless it fails.

### W8 `install.sh`

Keep both asset naming schemes (current `zttp-*` and legacy `zigttp-*`). Only
when neither scheme's asset exists and the platform is Intel macOS, exit 1
with: "zttp publishes no Intel macOS build from 0.22.3 on. Build from source,
or pin ZTTP_VERSION to v0.21.0 or earlier." Before that, detect Apple Silicon
under Rosetta: on Darwin, when `sysctl -n hw.optional.arm64` prints `1`, set
`ARCH=aarch64` whatever `uname -m` says. Run
`bash scripts/test-install-archive-safety.sh`.

### W9 Documentation and spine

- `RELEASE_CHECKLIST.md`: Validation and Cross-Compile become the
  `--no-publish` run; Tag And Publish ends with push main, push tag,
  `--publish`; no Intel macOS target; no workflow trigger.
- No CI anymore, so update: `CONTRIBUTING.md` lines 22 and 33;
  `docs/internals/testing.md` lines 4, 13, 216, 290, 305, 338;
  `scripts/verify.sh` header, the three `(ci.yml: ...)` labels, line 177, and
  the completion messages near line 195. Do not change any command string in
  `release_check.zig` `verify_script_markers`.
- Stale release-process text: `.github/RELEASE_NOTES_TEMPLATE.md:3`,
  `build/artifacts.zig:117`, `build.zig:64`, `docs/internals/architecture.md:327`,
  `docs/internals/capabilities.md:118`, `docs/internals/cassette-recording.md:6`,
  `docs/convergence.md:605` (check whether a generator owns it before editing).
- Platform claims: `README.md:37` (no Intel macOS binary) and
  `docs/roadmap.md:37` (source support versus published binaries).
- `docs/decisions.md`: add `D-009 Releases are verified and built locally`
  under "Repository tooling": Status standing, Decided 2026-10-18, Binds
  `scripts/release.sh`, `tooling/repo_gate.zig`, `tooling/release_check.zig`,
  `build/step_coverage.zig`; Gate `zig build test-release-workflow`. State D9
  and D12 and the 30-minute evidence.
- `agents.json` task `test-release-workflow`: `does` "checks release script
  invariants", `requiredWhen` "after release script changes". Then
  `zig build check-spine -- --write`.
- `CHANGELOG.md` `[0.22.3]` Breaking changes: add "**No Intel macOS binary.**
  Migration: build from source, or pin v0.21.0 or earlier." Keep the existing
  sentence about the 0.22.2 and 0.22.0 entries.
- Leave historical plan and solution documents unchanged.

## Verification (Opus runs these after review)

1. `zig fmt --check build.zig build/ packages/ tooling/`
2. `zig build test-native-gates test-release-workflow test-release-check test-script-reachability test-step-coverage check-spine test-spine test-doc-links test-docs-drift`, each exit status read directly.
3. `bash scripts/test-release-notes.sh`, `bash scripts/test-install-archive-safety.sh`
4. Probe every W3 error: copy `scripts/release.sh`, apply one edit, run the
   built repo-gate binary on the copy, require a non-zero exit and the
   expected message.
5. Container smoke at small scale: build the image, then `container run
   --arch amd64 --rosetta zttp-release-linux:0.16.0-amd64 bash -c 'nproc;
   free -m; zig version'`.
6. `bash scripts/verify.sh` on the host.

## Release sequence after implementation

1. Commit W1-W9, one commit per isolated unit.
2. `bash scripts/verify.sh` on the host and fix failures (any fix after step 3
   makes the evidence stale again and repeats step 3).
3. Republish convergence, then coverage (offline), each committed.
4. `release-provenance` and `release-check` pass.
5. Move the local tag: `git tag -f -a v0.22.3 -m "zttp v0.22.3" HEAD`.
6. `bash scripts/release.sh v0.22.3 --no-publish`. Record the Linux gate
   duration. If it is too long, the fallback is the full suite on `--arch
   arm64` plus only Debug `zig build test` under Rosetta.
7. Owner: `git push origin main`, `git push origin :refs/tags/v0.22.3`,
   `git push origin v0.22.3`.
8. `bash scripts/release.sh v0.22.3 --publish`.
