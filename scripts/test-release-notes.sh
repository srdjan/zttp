#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

grep -Fq "sh scripts/render-release-notes.sh \"\$GITHUB_REF_NAME\" release-notes.md" \
    "$root/.github/workflows/release.yml"
grep -Fq 'body_path: release-notes.md' "$root/.github/workflows/release.yml"

mkdir -p "$work/scripts"
cp "$root/scripts/render-release-notes.sh" "$work/scripts/"

cat > "$work/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-09-29

### Highlights

The release keeps curated text in the changelog.

### Breaking changes

- **Old artifacts are refused.** Rebuild them.

### Fixed

- Kept in the rendered release entry.

## [1.2.2] - 2026-09-28
EOF

(
    cd "$work"
    sh scripts/render-release-notes.sh v1.2.3 body.md
)

awk '
/^### Breaking changes$/ { breaking = 1; next }
/^### Fixed$/ { breaking = 0 }
breaking { print }
' "$work/body.md" > "$work/rendered-breaking"

awk '
/^### Breaking changes$/ { breaking = 1; next }
/^### Fixed$/ { breaking = 0 }
breaking { print }
' "$work/CHANGELOG.md" > "$work/changelog-breaking"

cmp "$work/changelog-breaking" "$work/rendered-breaking"
grep -Fq '### Fixed' "$work/body.md"
grep -Fq 'https://github.com/srdjan/zttp/blob/v1.2.3/docs/user-guide.md' "$work/body.md"

cat > "$work/CHANGELOG.md" <<'EOF'
# Changelog

## [1.2.3] - 2026-09-29

### Highlights

This entry has no breaking-change section.
EOF

if (
    cd "$work"
    sh scripts/render-release-notes.sh v1.2.3 body.md
) > "$work/missing-breaking.out" 2>&1; then
    echo "release notes test: missing Breaking changes section passed" >&2
    exit 1
fi

grep -Fq 'must contain exactly one ### Breaking changes section' "$work/missing-breaking.out"

cat > "$work/CHANGELOG.md" <<'EOF'
# Changelog

## [1.2.3] - 2026-09-29

### Highlights

This entry has an empty breaking-change section.

### Breaking changes

### Added

- A feature must not count as breaking-change content.
EOF

if (
    cd "$work"
    sh scripts/render-release-notes.sh v1.2.3 body.md
) > "$work/empty-breaking.out" 2>&1; then
    echo "release notes test: empty Breaking changes section passed" >&2
    exit 1
fi

grep -Fq '### Breaking changes is empty' "$work/empty-breaking.out"

printf 'release notes renderer OK\n'
