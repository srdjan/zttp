#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: scripts/render-release-notes.sh <tag> <output>" >&2
    exit 2
fi

tag=$1
output=$2

case "$tag" in
    v?*) ;;
    *)
        echo "release notes: tag must start with v: $tag" >&2
        exit 2
        ;;
esac

case "$tag" in
    *[!A-Za-z0-9._-]*)
        echo "release notes: tag contains unsupported characters: $tag" >&2
        exit 2
        ;;
esac

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
changelog="$root/CHANGELOG.md"
version=${tag#v}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

awk -v version="$version" '
BEGIN {
    heading = "## [" version "]"
}
index($0, heading) == 1 {
    suffix = substr($0, length(heading) + 1)
    if (suffix == "" || substr(suffix, 1, 1) == " ") {
        if (found) {
            print "release notes: duplicate version heading for " version > "/dev/stderr"
            exit 1
        }
        found = 1
        active = 1
        next
    }
}
active && /^## / {
    active = 0
}
active {
    print
}
END {
    if (!found) {
        print "release notes: CHANGELOG.md has no exact heading for " version > "/dev/stderr"
        exit 1
    }
}
' "$changelog" > "$work/section"

awk '
function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
}
function content(value) {
    value = trim(value)
    if (value == "" || value == "-" || value == "- ..." || value == "TODO" || value == "TBD") {
        return 0
    }
    if (value ~ /^<!--/) {
        comment = 1
    }
    if (comment) {
        if (value ~ /-->$/) {
            comment = 0
        }
        return 0
    }
    return 1
}
/^### / {
    current = substr($0, 5)
    if (current == "Highlights") {
        highlights++
    } else if (current == "Breaking changes") {
        breaking++
    }
    next
}
current == "Highlights" && content($0) {
    highlight_content = 1
}
current == "Breaking changes" && content($0) {
    breaking_content = 1
}
END {
    if (highlights != 1) {
        print "release notes: release entry must contain exactly one ### Highlights section" > "/dev/stderr"
        failed = 1
    } else if (!highlight_content) {
        print "release notes: ### Highlights is empty or still contains a placeholder" > "/dev/stderr"
        failed = 1
    }
    if (breaking != 1) {
        print "release notes: release entry must contain exactly one ### Breaking changes section" > "/dev/stderr"
        failed = 1
    } else if (!breaking_content) {
        print "release notes: ### Breaking changes is empty" > "/dev/stderr"
        failed = 1
    }
    exit failed
}
' "$work/section"

{
    printf '# zttp %s\n' "$tag"
    cat "$work/section"
    cat <<EOF

## Install

\`\`\`
curl -fsSL https://raw.githubusercontent.com/srdjan/zigttp/main/install.sh | sh
\`\`\`

Or download a tarball below and extract it manually.

## Documentation

- [User Guide](https://github.com/srdjan/zttp/blob/$tag/docs/user-guide.md)
- [CLI Reference](https://github.com/srdjan/zttp/blob/$tag/docs/cli.md)
- [Examples](https://github.com/srdjan/zttp/blob/$tag/examples/README.md)
EOF
} > "$work/body"

mv "$work/body" "$output"
