#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# CI uses Linux x86-64; Zig cross-compiles the printer artifact.
set -euo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]
: "${GITHUB_PATH:?GitHub Actions path file is required}"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
archive=zig-x86_64-linux-0.17.0.tar.xz
checksum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
directory="$root/.scratch/toolchain"
mkdir -p "$directory"
curl --fail --location --retry 3 --output "$directory/$archive" "https://ziglang.org/download/0.17.0/$archive"
printf '%s  %s\n' "$checksum" "$directory/$archive" | sha256sum --check
tar -xJf "$directory/$archive" -C "$directory"
compiler="$directory/zig-x86_64-linux-0.17.0"
[[ $("$compiler/zig" version) == 0.17.0 ]]
printf '%s\n' "$compiler" >> "$GITHUB_PATH"
