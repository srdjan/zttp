#!/usr/bin/env bash
# scripts/release.sh
#
# Local release pipeline. Releases are verified, built, smoke-tested, and
# published from the maintainer's Apple Silicon Mac. Linux runs inside Apple's
# `container` CLI. No GitHub Actions workflow builds or tests a release.
#
# Usage (from anywhere; the script cd's to the repo root):
#   bash scripts/release.sh vX.Y.Z --no-publish   # every gate, build, package, smoke test
#   bash scripts/release.sh vX.Y.Z --publish      # no gates; re-check, then publish
#
# --no-publish writes no data to the network except what the gates fetch. It
# leaves the assets, the rendered notes, and a manifest in the work directory.
# --publish refuses to run unless the manifest matches HEAD and the assets on
# disk. It creates a draft GitHub release, checks its assets, then publishes it.
#
# The work directory is ${XDG_CACHE_HOME:-$HOME/.cache}/zttp-release/<tag>/. It
# is not $TMPDIR: a full system volume is a known failure here.
#
# Compatible with the bash 3.2 that macOS ships.

set -euo pipefail

# --- Arguments ---------------------------------------------------------------

usage() {
  echo "usage: bash scripts/release.sh vX.Y.Z --no-publish|--publish" >&2
  exit 2
}

fail() {
  printf 'release: error: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 2 ] || usage
tag=$1
mode=$2
case "$mode" in
  --no-publish | --publish) ;;
  *) usage ;;
esac

tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
[[ "$tag" =~ $tag_pattern ]] || fail "argument must look like v<VERSION>, for example v1.2.3: $tag"
version=${tag#v}

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

step() {
  printf '\n========================================\n'
  printf '>> %s\n' "$1"
  printf '========================================\n'
}

# --- Environment -------------------------------------------------------------

# Keep every replay offline: no provider key or provider setting may reach a gate.
while IFS= read -r name; do
  case "$name" in
    DEEPSEEK_* | ZTTP_CODEGEN_* | ZTTP_MLX_BASE_URL) unset "$name" ;;
  esac
done < <(compgen -e)
# macOS tar adds ._ files for extended attributes unless this is set.
export COPYFILE_DISABLE=1

work="${XDG_CACHE_HOME:-$HOME/.cache}/zttp-release/$tag"
dist="$work/dist"
manifest="$work/manifest"
notes="$work/release-notes.md"

linux_image="zttp-release-linux:0.17.0-arm64"
linux_cpus=10
# bash 3.2 has no associative arrays and fails on an empty array under set -u.
# Container names hold no spaces, so a plain string is a safe list.
container_names=""
SERVE_PID=""

# --- Cleanup -----------------------------------------------------------------

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
  fi
  local name
  for name in $container_names; do
    container stop --time 2 "$name" >/dev/null 2>&1 || container kill "$name" >/dev/null 2>&1 || true
  done
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Preconditions -----------------------------------------------------------

zon_version() {
  awk -F'"' '/^[[:space:]]*\.version =/ { print $2; exit }' "$1"
}

check_preconditions() {
  local missing=""
  local tool
  for tool in rg jq gh container zig git shasum tar; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] || fail "required tools are not on PATH:$missing"

  local dirty
  dirty="$(git status --porcelain --untracked-files=normal)"
  [ -z "$dirty" ] || fail "the working tree is not clean; commit or remove these first:
$dirty"

  local tag_commit head_commit
  tag_commit="$(git rev-parse --verify --quiet "$tag^{commit}")" || fail "tag $tag does not exist in this repository"
  head_commit="$(git rev-parse HEAD)"
  [ "$head_commit" = "$tag_commit" ] || fail "HEAD $head_commit is not tag $tag ($tag_commit); move the tag or check out the tagged commit"

  local package_version zts_version runtime_version binary_version
  package_version="$(zon_version build.zig.zon)"
  zts_version="$(zon_version packages/zts/build.zig.zon)"
  runtime_version="$(zon_version packages/runtime/build.zig.zon)"
  binary_version="$(awk -F'"' '/^[[:space:]]*pub const string = "/ { print $2; exit }' packages/zts/src/root.zig)"
  [ "$version" = "$package_version" ] || fail "release tag $tag does not match build.zig.zon version $package_version"
  [ "$version" = "$binary_version" ] || fail "release tag $tag does not match binary version $binary_version"
  [ "$version" = "$zts_version" ] || fail "release tag $tag does not match zts package version $zts_version"
  [ "$version" = "$runtime_version" ] || fail "release tag $tag does not match runtime package version $runtime_version"

  local zig_pin zig_have
  zig_pin="$(awk -F'"' '/^[[:space:]]*\.minimum_zig_version =/ { print $2; exit }' build.zig.zon)"
  [ -n "$zig_pin" ] || fail "build.zig.zon has no minimum_zig_version"
  zig_have="$(zig version)"
  [ "$zig_have" = "$zig_pin" ] || fail "zig $zig_have is on PATH but build.zig.zon pins $zig_pin"
}

# --- Smoke test --------------------------------------------------------------

# Extract one tarball, then check the version, the help output, and a served
# response. Runs on the host and, through `declare -f`, inside containers, so it
# uses only bash builtins and tools every target has. Each failure returns
# non-zero explicitly: callers run it in a `||` context, where `set -e` is off.
smoke_test() {
  local dist_dir=$1 name=$2 want_version=$3 curl_bin=$4
  local scratch bin version_out port body i
  scratch="$(mktemp -d)" || return 1
  tar xzf "$dist_dir/$name.tar.gz" -C "$scratch" || return 1
  bin="$scratch/$name/zttp"
  chmod +x "$bin" "$scratch/$name/zts" "$scratch/$name/zttp-runtime" || return 1

  version_out="$("$bin" version)" || { echo "smoke: $name: zttp version failed" >&2; return 1; }
  echo "smoke: $name: version: $version_out"
  case "$version_out" in
    *"$want_version"*) ;;
    *) echo "smoke: $name: version '$version_out' does not contain $want_version" >&2; return 1 ;;
  esac
  "$bin" --help >/dev/null || { echo "smoke: $name: zttp --help failed" >&2; return 1; }

  # A free port: /dev/tcp connects only when something already listens there.
  port=$((20000 + RANDOM % 20000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    port=$((20000 + RANDOM % 20000))
  done

  "$bin" serve -e 'function handler(req) { return Response.json({ ok: true }); }' -p "$port" \
    >"$scratch/serve.log" 2>&1 </dev/null &
  SERVE_PID=$!
  body=""
  i=0
  while [ "$i" -lt 50 ]; do
    if body="$("$curl_bin" -sf "http://127.0.0.1:$port/" 2>/dev/null </dev/null)"; then
      break
    fi
    body=""
    i=$((i + 1))
    sleep 0.2
  done
  kill "$SERVE_PID" 2>/dev/null || true
  wait "$SERVE_PID" 2>/dev/null || true
  SERVE_PID=""
  echo "smoke: $name: body: $body"
  if ! printf '%s' "$body" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "smoke: $name: serve did not return ok:true (got: $body)" >&2
    sed 's/^/smoke: serve.log: /' "$scratch/serve.log" >&2 || true
    return 1
  fi
  command rm -rf "$scratch"
  echo "smoke: $name: OK"
}

run_container_smoke() {
  local role=$1 arch=$2 image=$3 name=$4 prelude=$5
  shift 5
  local container_name="zttp-release-$role-$$"
  container_names="$container_names $container_name"
  local rosetta=()
  if [ "$arch" = "amd64" ]; then rosetta=(--rosetta); fi
  container run --rm --name "$container_name" --arch "$arch" ${rosetta[@]+"${rosetta[@]}"} --cpus 4 --memory 4G \
    -v "$dist":/dist:ro "$image" \
    bash -c "set -uo pipefail; $prelude$(declare -f smoke_test); smoke_test /dist $name $version curl"
}

# --- Publish -----------------------------------------------------------------

manifest_value() {
  sed -n "s/^$1=//p" "$manifest" | head -n 1
}

publish() {
  step "preconditions"
  check_preconditions
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run gh auth login"

  git fetch -q origin
  local remote_tag head_commit
  head_commit="$(git rev-parse HEAD)"
  remote_tag="$(git ls-remote origin "refs/tags/$tag^{}" | awk '{ print $1 }')"
  if [ -z "$remote_tag" ]; then
    remote_tag="$(git ls-remote origin "refs/tags/$tag" | awk '{ print $1 }')"
  fi
  [ "$remote_tag" = "$head_commit" ] || fail "tag $tag is not pushed at HEAD (remote has '${remote_tag:-nothing}'); run git push origin $tag"
  git merge-base --is-ancestor HEAD origin/main || fail "HEAD is not in origin/main; run git push origin main"

  [ -f "$manifest" ] || fail "no manifest at $manifest; run --no-publish first"
  [ "$(manifest_value tag)" = "$tag" ] || fail "manifest tag '$(manifest_value tag)' does not match $tag"
  [ "$(manifest_value commit)" = "$head_commit" ] || fail "manifest commit '$(manifest_value commit)' does not match HEAD $head_commit; run --no-publish again"
  [ -f "$notes" ] || fail "no release notes at $notes; run --no-publish first"
  [ "$(shasum -a 256 "$notes" | awk '{ print $1 }')" = "$(manifest_value notes_sha256)" ] || fail "release notes changed since the manifest was written"

  step "re-hash the assets against the manifest"
  local listed=0 kw hash file actual
  while read -r kw hash file; do
    [ "$kw" = "sha256" ] || continue
    listed=$((listed + 1))
    [ -f "$dist/$file" ] || fail "manifest names $file, which is not in $dist"
    actual="$(shasum -a 256 "$dist/$file" | awk '{ print $1 }')"
    [ "$actual" = "$hash" ] || fail "$file changed since the manifest was written"
  done <"$manifest"
  [ "$listed" -eq 7 ] || fail "manifest lists $listed assets; expected 7"
  local on_disk
  on_disk="$(find "$dist" -type f | wc -l | tr -d ' ')"
  [ "$on_disk" -eq 7 ] || fail "$dist holds $on_disk files; expected 7"

  step "existing release for $tag"
  local published_out
  if published_out="$(gh api "repos/{owner}/{repo}/releases/tags/$tag" 2>&1)"; then
    fail "a published release for $tag already exists; refusing to overwrite it"
  fi
  case "$published_out" in
    *"HTTP 404"*) ;;
    *) fail "cannot query releases for $tag: $published_out" ;;
  esac
  # The tag endpoint hides drafts, so look for one in the release list.
  local drafts
  drafts="$(gh release list --limit 1000 --json tagName,isDraft --jq ".[] | select(.tagName == \"$tag\" and .isDraft) | .tagName")" ||
    fail "cannot list releases"
  if [ -n "$drafts" ]; then
    echo "deleting the existing draft release for $tag (the tag stays)"
    gh release delete "$tag" --yes
  fi

  step "create the draft release for $tag"
  gh release create "$tag" --draft --verify-tag --title "$tag" --notes-file "$notes" --generate-notes \
    "$dist"/*.tar.gz "$dist"/*.tar.gz.sha256 "$dist/checksums-sha256.txt"

  step "check the draft assets, then publish"
  local want_assets have_assets
  want_assets="$(cd "$dist" && printf '%s\n' * | sort)"
  have_assets="$(gh release view "$tag" --json assets --jq '.assets[].name' | sort)"
  [ "$have_assets" = "$want_assets" ] || fail "draft assets differ from the dist files.
expected:
$want_assets
found:
$have_assets"
  gh release edit "$tag" --draft=false
  gh release view "$tag" --json url --jq .url
}

if [ "$mode" = "--publish" ]; then
  publish
  exit 0
fi

# --- Build, verify, package: --no-publish ------------------------------------

step "preconditions"
check_preconditions
command rm -rf "$work/host" "$work/out" "$dist" "$manifest" "$notes"
mkdir -p "$work/cache" "$work/out" "$dist"
# One Zig cache for the whole run, kept out of the clone.
export ZIG_LOCAL_CACHE_DIR="$work/cache"

step "fresh clone at $tag  (ignored files must not leak into the gates)"
git clone -q "$repo" "$work/host"
cd "$work/host"
git checkout -q "$tag"

step "host gate: release verifier"
bash scripts/verify.sh --release

step "host gate: Getting Started smoke"
bash scripts/verify.sh --release-route smoke-getting-started

step "host gate: advisory benchmark"
bash scripts/verify.sh --release-route bench-check || echo "warning: advisory bench-check missed; see RELEASE_CHECKLIST.md"

step "host gate: release passport"
bash scripts/verify.sh --release-route release-check

if [ -n "${PROOF_LEDGER_PATH:-}" ]; then
  step "host gate: proof ledger replay"
  test -f "$PROOF_LEDGER_PATH"
  ./zig-out/bin/zttp ledger replay --input "$PROOF_LEDGER_PATH" --onto "${PROOF_LEDGER_ONTO:-HEAD}"
fi

step "Linux image $linux_image"
container system start
if container image inspect "$linux_image" >/dev/null 2>&1; then
  echo "image present; not rebuilding"
else
  container build --arch arm64 -f scripts/release-linux.Containerfile -t "$linux_image" scripts/
fi

step "Linux gate: release verifier in $linux_image (native arm64)"
# The default relative .zig-cache is deliberate: it is the configuration that
# exposed the relative-path bug. The gate runs on arm64 because it cannot run
# under Rosetta: Zig builds its translate-c helper with the self-hosted x86_64
# backend, and Rosetta refuses that binary ("bss_size overflow"), so every
# compile that imports sqlite3.h fails. x86_64 Linux is covered only by the
# tarball smoke test below. The container exit status is the gate result.
verify_name="zttp-release-verify-$$"
container_names="$container_names $verify_name"
SECONDS=0
container run --rm --name "$verify_name" --arch arm64 --cpus "$linux_cpus" --memory 12G \
  -v "$repo":/src:ro "$linux_image" \
  bash -c "nproc; free -m; zig version; git clone -q /src /work && cd /work && git checkout -q $tag && bash scripts/verify.sh --release"
echo "Linux gate took ${SECONDS}s"

step "build release binaries"
targets=(
  "x86_64-linux-gnu:linux:x86_64"
  "aarch64-linux-gnu:linux:aarch64"
  "aarch64-macos-none:macos:aarch64"
)
for entry in "${targets[@]}"; do
  target="${entry%%:*}"
  zig build -Doptimize=fast "-Dtarget=$target" -Dstrip --prefix "$work/out/$target"
done

step "package tarballs"
cd "$dist"
for entry in "${targets[@]}"; do
  target="${entry%%:*}"
  rest="${entry#*:}"
  os="${rest%%:*}"
  arch="${rest#*:}"
  dir="zttp-$tag-$os-$arch"
  mkdir "$dir"
  command cp "$work/out/$target/bin/zttp" "$work/out/$target/bin/zttp-runtime" "$work/out/$target/bin/zts" "$dir/"
  command cp "$work/host/LICENSE" "$work/host/README.md" "$work/host/CHANGELOG.md" "$dir/"
  printf 'version=%s\ntarget=%s\nos=%s\narch=%s\n' "$tag" "$target" "$os" "$arch" >"$dir/VERSION"
  # --no-xattrs keeps macOS extended attributes out of the archive; GNU tar warns on them.
  tar --no-xattrs -czf "$dir.tar.gz" "$dir"
  listing="$(tar tzf "$dir.tar.gz")"
  entries="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
  [ "$entries" -eq 8 ] || fail "$dir.tar.gz lists $entries entries; expected 8"
  for member in zttp zttp-runtime zts LICENSE README.md CHANGELOG.md VERSION; do
    printf '%s\n' "$listing" | grep -qx "$dir/$member" || fail "$dir.tar.gz is missing $member"
  done
  shasum -a 256 "$dir.tar.gz" >"$dir.tar.gz.sha256"
  command rm -rf "$dir"
done
[ "$(find . -maxdepth 1 -name '*.sha256' | wc -l | tr -d ' ')" -eq 3 ] || fail "expected three .sha256 files in $dist"
cat -- *.sha256 >checksums-sha256.txt
ls -l "$dist"
cd "$work/host"

step "smoke test: linux-x86_64 in ubuntu:24.04 (amd64 under Rosetta)"
run_container_smoke smoke-x86 amd64 ubuntu:24.04 "zttp-$tag-linux-x86_64" \
  "apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null; "

step "smoke test: linux-aarch64 in ubuntu:24.04 (arm64)"
run_container_smoke smoke-arm arm64 ubuntu:24.04 "zttp-$tag-linux-aarch64" \
  "apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null; "

step "smoke test: macos-aarch64 on the host"
smoke_test "$dist" "zttp-$tag-macos-aarch64" "$version" /usr/bin/curl

step "render release notes"
sh scripts/render-release-notes.sh "$tag" "$notes"

step "write manifest"
{
  printf 'tag=%s\n' "$tag"
  printf 'commit=%s\n' "$(git rev-parse HEAD)"
  printf 'notes_sha256=%s\n' "$(shasum -a 256 "$notes" | awk '{ print $1 }')"
  (cd "$dist" && for file in *; do printf 'sha256 %s %s\n' "$(shasum -a 256 "$file" | awk '{ print $1 }')" "$file"; done)
} >"$manifest"
[ "$(grep -c '^sha256 ' "$manifest")" -eq 7 ] || fail "manifest does not list 7 assets"
cat "$manifest"

printf '\n========================================\n'
printf '>> release.sh: %s verified, built, and smoke-tested\n' "$tag"
printf '   assets:   %s\n' "$dist"
printf '   notes:    %s\n' "$notes"
printf '   next:     git push origin main && git push origin %s && bash scripts/release.sh %s --publish\n' "$tag" "$tag"
printf '========================================\n'
