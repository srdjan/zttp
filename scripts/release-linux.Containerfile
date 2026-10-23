# Linux toolchain image for scripts/release.sh.
#
# The release gate runs `bash scripts/verify.sh --release` inside this image
# (native arm64). The image holds the tools that script needs: git, jq,
# curl, and ripgrep. Ripgrep is a search backend for the expert workspace tools,
# and the recorded codegen corpus holds the bytes rg produces. procps provides
# `free`, which the gate prints so a resource kill is diagnosable.
#
# Build (release.sh does this when the image is missing):
#   container build --arch arm64 -f scripts/release-linux.Containerfile \
#     -t zttp-release-linux:0.17.0-arm64 scripts/

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ripgrep jq curl xz-utils ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# Zig 0.17.0, pinned by checksum. Keep it equal to minimum_zig_version in
# build.zig.zon.
RUN curl -fsSL -o /tmp/zig.tar.xz \
        https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz \
    && echo "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"
