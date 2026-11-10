#!/bin/bash
# Packs a built engine (DIR/uzu and DIR/VERSION, from tools/build-engine.sh or uzu-build-engine) as the release asset
# uzu-update downloads: dist/uzu-engine-<uzu tag>-macos-arm64.tar.gz. GitHub publishes its SHA-256, which uzu-update
# checks before it installs anything.
#   tools/package-engine.sh [DIR]   (default: engine)
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${1:-engine}
[[ -x $DIR/uzu && -f $DIR/VERSION ]] || { echo "no engine in $DIR (run tools/build-engine.sh)" >&2; exit 1; }
TAG=$(cut -d+ -f1 <"$DIR/VERSION")
mkdir -p dist
OUT=dist/uzu-engine-$TAG-macos-arm64.tar.gz
tar -czf "$OUT" -C "$DIR" uzu VERSION
shasum -a 256 "$OUT"
