# CHANGELOG.md release entry

Before tagging, add the release entry to `CHANGELOG.md`. The release workflow
copies the complete entry into the GitHub Release, then adds the stable Install
and Documentation sections. GitHub adds the generated commit list after this
curated body.

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Highlights

<!-- Write two or three user-facing sentences that summarize the release. -->

### Breaking changes

<!-- List every breaking change with its migration action. Write `None.` when
the release has no breaking changes. -->

### Added

<!-- List user-facing additions, or omit this section. -->

### Changed

<!-- List user-facing changes, or omit this section. -->

### Fixed

<!-- List user-facing fixes, or omit this section. -->
```

`Highlights` and `Breaking changes` are required. Keep their headings exact.
Run `sh scripts/render-release-notes.sh vX.Y.Z release-notes.md` and review the
complete output before tagging.
