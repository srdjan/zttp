# Version alignment: one release version, and the website follows it

Status: PLANNED (2026-10-17)

## Problem

The release version has seven hand-kept copies, and they disagree today:

| Source | Value |
| --- | --- |
| `VERSION` | 0.22.2 (bumped alone in `1bee7b1b` and `20caa237`) |
| `build.zig.zon`, `packages/zts/build.zig.zon`, `packages/runtime/build.zig.zon` | 0.22.0 |
| `packages/zts/src/root.zig` `version.string` | 0.22.0 |
| `packages/zts/src/root.zig` `version.major/minor/patch` | 0 / 20 / 0 |
| `README.md:6` heading, `install.sh:6` comment | v0.22.0 |
| `zts --version` | prints 0.19.0 |

`tooling/release_version.zig` already checks five of these, but only
`zig build release-check` runs it, so ordinary work never sees drift.
`zts --version` prints `expert_meta.compiler_version`, which is the analyzer
surface identity pinned at 0.19.0 on purpose (see the comment at
`packages/tools/src/expert_meta.zig:9-31`). That identity must not move; the
CLI should simply not print it as the release version.

The website (`../zttp-website`) carries its own version (`deno.json` 1.3.1) and
shows `v0.21.0` in the nav and the download button. The user wants the
website to follow the zttp version.

## Decisions

- `VERSION` is the intended release version: 0.22.2. Every other copy follows it.
- The analyzer surface identity (`analyzer_surface_version = "0.19.0"`) does
  not change. Moving it stales every cassette.
- The website's version equals the zttp version. Its nav label and download
  link show that version. This supersedes the earlier choice to wait for the
  tag: the user owns push order and must push the zttp tag before deploying
  the site.
- No changelog entries are invented for 0.22.1 or 0.22.2. Writing release notes
  stays with the user.

## Work in zttp

### Z1: align every copy to 0.22.2

Set 0.22.2 in the three `build.zig.zon` files, `root.zig` `version.string`,
the `README.md` heading, and the `install.sh` comment. In `root.zig`, derive
`major`, `minor`, and `patch` from `string` at comptime with
`std.SemanticVersion.parse`, so they cannot drift again. Update the `root.zig`
"version" test to assert the string and the derived fields. Leave
`CHANGELOG.md` and `docs/roadmap.md:198` alone: they are history.

### Z2: `zts --version` prints the release version

In `packages/tools/src/zts_cli.zig:126`, print `zts.version.string` instead of
`expert_meta.compiler_version`. Add a test or contract check that pins the
behavior if the file has a nearby test seam; otherwise rely on Z4's run.
Do not touch `expert_meta.zig`.

### Z3: version drift fails `zig build test`

Make the existing alignment check run inside the aggregate `zig build test`
against the real repository files. Extend `release_version.check` (or add a
sibling check) so it also covers the `README.md` heading and the `install.sh`
"current:" comment. Prefer adding a test to a step that the aggregate already
reaches (for example `test-release-check`) over a new build step, because a
new step needs agent-spine registration (`agents.json`, `zig build check-spine`).
Follow the gate-floor rule in `AGENTS.md`: the test must fail when it reads no
files. Probe it: change one copy in a scratch copy of the repo or by a
temporary edit, confirm the run fails with a named source, then revert.

### Z4: release checklist names the website

Add a step to `RELEASE_CHECKLIST.md` beside the version-bump steps: "In
`zttp-website`, run `deno task sync-version` and commit."

### Verification for zttp

Use a private cache: `ZIG_LOCAL_CACHE_DIR=$(mktemp -d)`. Unset
`DEEPSEEK_API_KEY` for every run.

- `zig build` then `zig-out/bin/zts --version` prints `zts 0.22.2` and
  `zig-out/bin/zttp --version` prints `zttp 0.22.2`.
- `zig build release-check`: the version row is ok.
- `zig build test-expert-app` passes offline. This measures whether the
  version bump moves any cassette identity (`protocol_identity.zig:39` and
  `aggregate_proof.zig:554` hash `zts.version.string`). If it fails, stop and
  report the stale cassettes; do not re-record.
- `zig build test` and `zig build check-spine` pass. Then `bash scripts/verify.sh`.
  Redirect each to a file and read the exit status directly.

## Work in zttp-website

### W1: version source and sync task

Add `scripts/sync_version.ts` (Deno, typed, no `any`). It reads a version from
an argument, or from `../ZTTP/VERSION` when no argument is given. It validates
SemVer and rewrites four places: `deno.json` `version`, the nav label
`<small>vX.Y.Z</small>`, the download `href` `releases/tag/vX.Y.Z`, and the
text "Download vX.Y.Z". Wire it as `deno task sync-version` with only the
read and write permissions it needs. Run it once to set 0.22.2.

### W2: contract test

In `tests/site_contract_test.ts`, add a test: the `deno.json` version, the nav
label, the download `href`, and the download text all name the same version.

### W3: guidance

In `CLAUDE.md`, state that the site version follows zttp, and that
`deno task sync-version` is the only way to change it. Make sure
`deno task verify` still checks the new script (`deno check` and lint).

### Verification for zttp-website

`deno task verify` passes. Probe the W2 test: change one of the four values
in a scratch clone and confirm the test fails.

## Commits

zttp: Z1+Z2 in one commit ("align release version to 0.22.2"), Z3 in one,
Z4 and this plan's status in one. zttp-website: W1-W3 in one commit
("follow zttp versions: 0.22.2"). Do not push.
