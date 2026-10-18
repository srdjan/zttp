# Release Checklist

Reusable checklist for cutting a zttp release. Fill in the metadata, run the
gates, and keep release notes user-facing.

No GitHub workflow builds or tests a release. `scripts/release.sh` verifies,
builds, smoke-tests, and publishes it from an Apple Silicon Mac. Linux runs
inside Apple's `container` CLI.

## Metadata

- Version: ______ (from `VERSION`, the authority; every other copy must match it)
- Previous stable tag: ______ (`git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1`)
- Zig toolchain: ______ (from `build.zig.zon` `minimum_zig_version`)

## Documentation

- [ ] `README.md` points to `docs/README.md`.
- [ ] `docs/user-guide.md` is the only user guide.
- [ ] `docs/roadmap.md` is the only roadmap.
- [ ] `docs/virtual-modules/README.md` matches the built-in module registry.
- [ ] `docs/performance.md` contains the current public benchmark claims.
- [ ] `zig build release-provenance` confirms that coverage and
      convergence evidence came from complete, publishable, clean-source runs
      whose source commits cover the release commit except for generated
      evidence outputs.
- [ ] Release notes link to `docs/user-guide.md`, `docs/cli.md`, and `examples/README.md`.
- [ ] No maintained docs point to release snapshots or stale transition notes.

## Prepare And Tag

- [ ] Confirm `VERSION` holds the intended release. It is the authority.
- [ ] Confirm `build.zig.zon`, `packages/zts/build.zig.zon`, and
      `packages/runtime/build.zig.zon` `.version` equal `VERSION`.
- [ ] Confirm `packages/zts/src/root.zig` `version.string`, the `README.md`
      heading, and the `install.sh` "current:" comment equal `VERSION`.
      `zig build test` fails on any difference.
- [ ] In `zttp-website`, run `deno task sync-version` and commit.
- [ ] Promote `CHANGELOG.md` `[Unreleased]` to `[X.Y.Z] - <date>`, open a fresh `[Unreleased]` section, and update the bottom compare-link anchors (`[Unreleased]` base + a new `[X.Y.Z]` link).
- [ ] Add `### Highlights` and `### Breaking changes` to the versioned
      `CHANGELOG.md` entry. Use `.github/RELEASE_NOTES_TEMPLATE.md` as the
      authoring guide. List every breaking change with its migration action;
      write `None.` when there are no breaking changes.
- [ ] Run `sh scripts/render-release-notes.sh vX.Y.Z release-notes.md` and
      review the complete body. The command fails if the exact version entry,
      Highlights, or Breaking changes is missing or empty.
- [ ] Commit everything. The release script refuses a dirty working tree.
- [ ] `git tag -a vX.Y.Z -m "zttp vX.Y.Z"` at the final commit. The script
      refuses a tag that is not at `HEAD`.

## Validate And Build

Run `bash scripts/release.sh vX.Y.Z --no-publish`. It writes nothing to
GitHub. It runs these steps in order and stops at the first failure:

- [ ] Preconditions: clean tree, `HEAD` at the tag, every version copy equal
      to the tag, Zig equal to `minimum_zig_version`, and the tools on `PATH`.
- [ ] `bash scripts/verify.sh --release` on the host, in a fresh clone.
- [ ] `zig build smoke-getting-started` (macOS beta gate).
- [ ] `zig build bench-check`. It is advisory in the script: a miss prints a
      warning and does not stop the run. Rerun it once after a warning, and
      block the release if the rerun also misses.
- [ ] `zig build release-check -- --json`.
- [ ] The same `bash scripts/verify.sh --release` on Linux x86_64, inside the
      `zttp-release-linux:0.16.0-amd64` image under Rosetta. Note the duration
      the script prints.
- [ ] Cross-compile `x86_64-linux-gnu`, `aarch64-linux-gnu`, and
      `aarch64-macos-none` with `-Doptimize=ReleaseFast -Dstrip`. SQLite is
      vendored as a static amalgamation, so no container is needed to build.
      zttp publishes no Intel macOS binary.
- [ ] Package the three tarballs, their `.sha256` files, and
      `checksums-sha256.txt` in `${XDG_CACHE_HOME:-$HOME/.cache}/zttp-release/vX.Y.Z/dist`.
- [ ] Smoke-test each tarball: `zttp version`, `zttp --help`, and a served
      `ok:true` response. Linux x86_64 and aarch64 run in containers; macOS
      aarch64 runs on the host.
- [ ] Check release binary sizes with `ls -lh` on the `dist` tarballs. Stripped
      `zttp` measured 12.1-13.3 MB across the four targets at 0.21.0. A
      debug-sized artifact in the release means `-Dstrip` was dropped.
- [ ] Review the rendered `release-notes.md` and the printed `manifest`.

## Publish

- [ ] `git push origin main`
- [ ] `git push origin vX.Y.Z`
- [ ] `bash scripts/release.sh vX.Y.Z --publish`. It runs no gates. It checks
      that the tag and `main` are pushed, that the manifest matches `HEAD`, and
      that the files on disk match the manifest. It creates a draft release,
      checks the seven assets, and publishes the draft.
- [ ] Open the release page and check the assets before announcing.

If a tag moves after `--no-publish`, run `--no-publish` again. The manifest
records the commit, and `--publish` refuses a manifest from another commit.
