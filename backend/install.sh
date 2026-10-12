#!/bin/bash
# Installs (or repairs) the backend uzu Home drives: the scripts, the uzu engine that ships with the app, the launchd
# agents and the uzuctl command. Keeps an existing config.env, models.conf, converted models and state.
# uzu Home runs this from Server > Set up; it can also be run by hand.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="${UZU_HOME_ROOT:-$HOME/Library/Application Support/UzuHome/backend}"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
step() { printf '\n==> %s\n' "$*"; }

[[ $(uname -m) == arm64 ]] || { echo "uzu needs an Apple-silicon Mac."; exit 1; }

step "Copying the scripts to $ROOT"
mkdir -p "$ROOT"/{bin,lib,share,patches,launchd,logs,state,engine,models}
find "$SRC/bin" -maxdepth 1 -type f ! -name '.*' -exec cp {} "$ROOT/bin/" \;
rm -rf "$ROOT/lib" "$ROOT/share" "$ROOT/patches"
cp -R "$SRC/lib" "$SRC/share" "$SRC/patches" "$ROOT/"
chmod 755 "$ROOT"/bin/uzuctl "$ROOT"/bin/uzu-engine "$ROOT"/bin/uzu-update "$ROOT"/bin/uzu-convert "$ROOT"/bin/uzu-build-engine "$ROOT"/bin/uzu-gateway.py
chmod 644 "$ROOT"/bin/uzu-common.sh
[[ -f $SRC/VERSION ]] && cp "$SRC/VERSION" "$ROOT/bin/.bundle-version"
[[ -f $ROOT/config.env ]] || cp "$SRC/config.env.default" "$ROOT/config.env"
[[ -f $ROOT/models.conf ]] || cp "$SRC/models.conf" "$ROOT/models.conf"
source "$ROOT/bin/uzu-common.sh"

step "Installing the uzu engine"
if [[ -x $SRC/engine/uzu ]]; then
  bundled=$(tr -d ' \n' <"$SRC/engine/VERSION")
  installed=$(engine_version 2>/dev/null || true)
  # replace it when the app ships a newer uzu release, or the same release built with other patches
  newer=$(/usr/bin/python3 -c 'import sys
def p(v): return [int("".join(c for c in x if c.isdigit()) or 0) for x in v.split("+")[0].split(".")]
b, i = sys.argv[1], sys.argv[2]
print(1 if not i or p(b) > p(i) or (p(b) == p(i) and b != i) else 0)' "$bundled" "$installed" 2>/dev/null || echo 1)
  if [[ ! -x $ENGINE_BIN ]] || [[ $newer == 1 ]] || ! "$ENGINE_BIN" server --help 2>/dev/null | grep -q -- --sessions; then
    if [[ -x $ENGINE_BIN ]]; then mkdir -p "$ROOT/engine/previous"; cp -p "$ENGINE_BIN" "$ROOT/engine/previous/uzu"; cp -p "$ROOT/engine/VERSION" "$ROOT/engine/previous/VERSION" 2>/dev/null || true; fi
    cp "$SRC/engine/uzu" "$ENGINE_BIN.new" && chmod 755 "$ENGINE_BIN.new" && mv "$ENGINE_BIN.new" "$ENGINE_BIN"
    printf '%s\n' "$bundled" >"$ROOT/engine/VERSION"
    xattr -dr com.apple.quarantine "$ENGINE_BIN" 2>/dev/null || true
    echo "uzu $bundled installed"
  else
    echo "keeping uzu $installed (the app ships $bundled)"
  fi
fi
"$ENGINE_BIN" --version >/dev/null || { echo "The uzu engine does not run on this Mac." >&2; exit 1; }

step "Choosing the Python that runs the endpoint"
py=""
for cand in /opt/homebrew/bin/python3 /usr/bin/python3; do
  [[ $cand == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1 && continue # the stub would ask to install tools
  [[ -x $cand ]] && "$cand" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null && { py=$cand; break; }
done
[[ -n $py ]] || { echo "Python 3.9 or newer is needed: run xcode-select --install, or brew install python." >&2; exit 1; }
set_config PYTHON "$py"
echo "$py ($("$py" --version 2>&1))"

step "Linking uzuctl into ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/uzuctl" "$HOME/.local/bin/uzuctl"

step "Writing the launchd agents"
"$ROOT/bin/uzuctl" install-agents
load_config
if [[ $ENDPOINT_AT_LOGIN == 1 ]]; then
  "$ROOT/bin/uzuctl" gateway restart >/dev/null && echo "endpoint running at http://127.0.0.1:$GATEWAY_PORT/v1"
fi

step "Done"
echo "Models from Mirai's catalog download the first time they start (about 6 GB for the 9B Medium)."
