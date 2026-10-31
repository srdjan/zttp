#!/bin/sh
# Regression tests for install.sh archive validation and release compatibility.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

ZTTP_INSTALLER_SOURCE_ONLY=1
export ZTTP_INSTALLER_SOURCE_ONLY
. "$ROOT_DIR/install.sh"

EXPECTED_ROOT="zttp-v0.1.1-beta-macos-aarch64"

fail() {
    printf "FAIL: %s\n" "$*" >&2
    exit 1
}

expect_valid_entry() {
    validate_archive_entry "$EXPECTED_ROOT" "$1" || fail "expected valid archive entry: $1"
}

expect_invalid_entry() {
    if validate_archive_entry "$EXPECTED_ROOT" "$1"; then
        fail "expected invalid archive entry: $1"
    fi
}

expect_valid_entry "$EXPECTED_ROOT"
expect_valid_entry "$EXPECTED_ROOT/"
expect_valid_entry "$EXPECTED_ROOT/zttp"
expect_valid_entry "$EXPECTED_ROOT/docs/README.md"

expect_invalid_entry ""
expect_invalid_entry "/$EXPECTED_ROOT/zttp"
expect_invalid_entry "../$EXPECTED_ROOT/zttp"
expect_invalid_entry "$EXPECTED_ROOT/../zttp"
expect_invalid_entry "$EXPECTED_ROOT/bin/../zttp"
expect_invalid_entry "other-root/zttp"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/$EXPECTED_ROOT"
touch "$TMPDIR/$EXPECTED_ROOT/zttp"
tar czf "$TMPDIR/safe.tar.gz" -C "$TMPDIR" "$EXPECTED_ROOT"
validate_archive_paths "$TMPDIR/safe.tar.gz" "$EXPECTED_ROOT" || fail "safe archive rejected"

mkdir -p "$TMPDIR/other-root"
touch "$TMPDIR/other-root/zttp"
tar czf "$TMPDIR/outside-root.tar.gz" -C "$TMPDIR" "other-root"
if validate_archive_paths "$TMPDIR/outside-root.tar.gz" "$EXPECTED_ROOT" 2>/dev/null; then
    fail "outside-root archive accepted"
fi

# A symlink member whose name is under the expected root passes the path
# check but must be rejected by member-type validation (symlink-traversal class).
ln -s /etc/passwd "$TMPDIR/$EXPECTED_ROOT/evil-link"
tar czf "$TMPDIR/symlink.tar.gz" -C "$TMPDIR" "$EXPECTED_ROOT"
if validate_archive_paths "$TMPDIR/symlink.tar.gz" "$EXPECTED_ROOT" 2>/dev/null; then
    fail "archive with symlink member accepted"
fi

# A release that holds only the old zigttp-* assets is not installable.
OLD_NAME_VERSION="v0.18.0"
OLD_NAME_ROOT="zigttp-${OLD_NAME_VERSION}-macos-aarch64"
OLD_NAME_METADATA="${TMPDIR}/old-name-release.json"
OLD_NAME_ERROR="${TMPDIR}/old-name-install.err"

printf '%s\n' \
    '{' \
    '  "tag_name": "v0.18.0",' \
    '  "assets": [' \
    '    {' \
    "      \"name\": \"${OLD_NAME_ROOT}.tar.gz\"" \
    '    },' \
    '    {' \
    "      \"name\": \"${OLD_NAME_ROOT}.tar.gz.sha256\"" \
    '    }' \
    '  ]' \
    '}' > "$OLD_NAME_METADATA"

if (
        ZTTP_VERSION="$OLD_NAME_VERSION"
        INSTALL_DIR="${TMPDIR}/old-name-install"
        BIN_DIR="${INSTALL_DIR}/bin"
        export ZTTP_VERSION

        detect_platform() {
            OS="macos"
            ARCH="aarch64"
        }

        download_stdout() {
            command cat "$OLD_NAME_METADATA"
        }

        download() {
            fail "old-name release triggered an asset request: $1"
        }

        main
) > /dev/null 2> "$OLD_NAME_ERROR"; then
    fail "release with only zigttp-* assets was installed"
fi

grep -Fqx "Error: release v0.18.0 has no complete archive/checksum pair for macos/aarch64" "$OLD_NAME_ERROR" ||
    fail "old-name release did not report the missing archive pair"
grep -Fqx "Expected zttp-v0.18.0-macos-aarch64.tar.gz and its exact .sha256 asset" "$OLD_NAME_ERROR" ||
    fail "old-name release did not name the expected asset"

# An existing install at the requested version needs no download.
EXISTING_VERSION="v0.26.0"
EXISTING_DIR="${TMPDIR}/existing-install"
EXISTING_OUTPUT="${TMPDIR}/existing-install.out"

mkdir -p "${EXISTING_DIR}/bin"
printf '#!/bin/sh\necho "zttp 0.26.0"\n' > "${EXISTING_DIR}/bin/zttp"
printf '#!/bin/sh\necho "zts 0.26.0"\n' > "${EXISTING_DIR}/bin/zts"
printf '#!/bin/sh\necho "zttp 0.26.0"\n' > "${EXISTING_DIR}/bin/zttp-runtime"
chmod +x "${EXISTING_DIR}/bin/zttp" "${EXISTING_DIR}/bin/zts" "${EXISTING_DIR}/bin/zttp-runtime"

(
    VERSION="$EXISTING_VERSION"
    BIN_DIR="${EXISTING_DIR}/bin"

    download_stdout() {
        fail "existing install triggered a metadata request: $1"
    }

    download() {
        fail "existing install triggered an asset request: $1"
    }

    check_existing
    fail "existing install did not stop the installer"
) > "$EXISTING_OUTPUT" || fail "existing install check failed"

grep -Fqx "zttp v0.26.0 is already installed at ${EXISTING_DIR}/bin" "$EXISTING_OUTPUT" ||
    fail "existing install did not report the installed version"

# A binary with the old name in its version output is not the requested release.
printf '#!/bin/sh\necho "zigttp 0.26.0"\n' > "${EXISTING_DIR}/bin/zttp"
if (
        VERSION="$EXISTING_VERSION"
        BIN_DIR="${EXISTING_DIR}/bin"
        binary_has_expected_version zttp zttp
); then
    fail "old-name version output counted as an existing install"
fi

printf "install archive safety OK\n"
