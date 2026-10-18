# Linux toolchain image for scripts/release.sh.
#
# The release gate runs `bash scripts/verify.sh --release` inside this image
# (amd64, under Rosetta). The image holds the tools that script needs: git, jq,
# curl, and ripgrep. Ripgrep is a search backend for the expert workspace tools,
# and the recorded codegen corpus holds the bytes rg produces. procps provides
# `free`, which the gate prints so a resource kill is diagnosable.
#
# Build (release.sh does this when the image is missing):
#   container build --arch amd64 -f scripts/release-linux.Containerfile \
#     -t zttp-release-linux:0.16.0-amd64 scripts/

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ripgrep jq curl xz-utils ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# Zig 0.16.0, pinned by checksum. Keep it equal to minimum_zig_version in
# build.zig.zon.
RUN curl -fsSL -o /tmp/zig.tar.xz \
        https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
    && echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"
