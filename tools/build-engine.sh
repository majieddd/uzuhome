#!/bin/bash
# Builds the uzu engine that uzu Home ships in its release (engine/uzu, engine/VERSION): Mirai's uzu CLI at the tag in
# engine/UZU_VERSION (or the one given), plus backend/patches. See backend/bin/uzu-build-engine.
#   tools/build-engine.sh [TAG]
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${1:-$(tr -d ' \n' <engine/UZU_VERSION)}
UZU_BUILD_SRC=${UZU_BUILD_SRC:-$HOME/Library/Caches/uzuhome-engine-build/uzu} UZU_PATCHES="$PWD/backend/patches" \
  UZU_HOME_ROOT="$PWD/engine" /bin/bash backend/bin/uzu-build-engine "$TAG" "$PWD/engine"
ls -la engine/uzu
