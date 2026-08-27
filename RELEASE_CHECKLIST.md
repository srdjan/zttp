# Release Checklist

Reusable checklist for cutting a zttp release. Fill in the metadata, run the
gates, and keep release notes user-facing.

## Metadata

- Version: ______ (from `build.zig.zon`)
- Previous stable tag: ______ (`git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1`)
- Zig toolchain: ______ (from `build.zig.zon` `minimum_zig_version`)

## Validation

- [ ] `bash scripts/verify.sh`
- [ ] `zig build wasm` and exercise one accepted and one rejected handler
      through the exported `alloc` / `analyze` / `free` ABI.
- [ ] `zig build smoke-getting-started` (macOS beta gate)
- [ ] `zig build smoke-demo` (macOS beta gate)
- [ ] `zig build smoke-studio` (macOS beta gate; builds `-Dstudio`)
- [ ] `zig build bench-check` (rerun one miss; block the release if the rerun also misses)
- [ ] `zig build release-check -- --json`

## Cross-Compile

SQLite is vendored as a static amalgamation, so release builds should
cross-compile without Docker.

- [ ] `zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -Dstrip`
- [ ] `zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu -Dstrip`
- [ ] `zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos-none -Dstrip`
- [ ] `zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos-none -Dstrip`
- [ ] Check release binary sizes with `ls -lh zig-out/bin/`. The release workflow
      builds with `-Dstrip`; stripped `zttp` is roughly 8-9 MB (vs ~50 MB
      unstripped). A debug-sized artifact in the release means `-Dstrip` was dropped.

## Documentation

- [ ] `README.md` points to `docs/README.md`.
- [ ] `docs/user-guide.md` is the only user guide.
- [ ] `docs/roadmap.md` is the only roadmap.
- [ ] `docs/virtual-modules/README.md` matches the built-in module registry.
- [ ] `docs/performance.md` contains the current public benchmark claims.
- [ ] The official website playground uses the current ambient `Proof<T, P>`
      syntax, its checked-in WASM artifact is rebuilt from this release, and
      one accepted plus one rejected handler is exercised through the real
      browser bridge before publication.
- [ ] `zig build release-provenance` confirms that coverage and
      convergence evidence came from complete, publishable, clean-source runs
      whose source commits cover the release commit except for generated
      evidence outputs.
- [ ] Release notes link to `docs/user-guide.md`, `docs/cli.md`, and `examples/README.md`.
- [ ] No maintained docs point to release snapshots or stale transition notes.

## Tag And Publish

- [ ] Confirm `build.zig.zon` `.version` matches the intended release.
- [ ] Confirm `packages/zts/build.zig.zon` and
      `packages/runtime/build.zig.zon` match the intended release.
- [ ] Confirm `packages/zts/src/root.zig` `version.string` matches the intended release.
- [ ] Promote `CHANGELOG.md` `[Unreleased]` to `[X.Y.Z] - <date>`, open a fresh `[Unreleased]` section, and update the bottom compare-link anchors (`[Unreleased]` base + a new `[X.Y.Z]` link).
- [ ] Draft release notes from `CHANGELOG.md` and `.github/RELEASE_NOTES_TEMPLATE.md`.
- [ ] `git tag -a vX.Y.Z -m "zttp vX.Y.Z"`
- [ ] `git push origin vX.Y.Z`

Pushing a tag triggers `.github/workflows/release.yml`, which runs tests,
cross-compiles release binaries, and creates the GitHub Release with tarballs
and SHA-256 checksums. Verify the workflow and release assets before announcing.
