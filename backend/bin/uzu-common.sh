# Shared helpers for uzu Home's backend scripts (sourced, not executed).

ROOT="${UZU_HOME_ROOT:-$HOME/Library/Application Support/UzuHome/backend}"
LOGS="$ROOT/logs"
STATE="$ROOT/state"
ENGINE_BIN="$ROOT/engine/uzu"
DOMAIN="gui/$(id -u)"
ENGINE_LABEL=io.github.majieddd.uzuhome.engine
GATEWAY_LABEL=io.github.majieddd.uzuhome.gateway
UPDATER_LABEL=io.github.majieddd.uzuhome.updater
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_ENV_HINTS=1

load_config() {
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  : "${MODEL:=qwen3.5-9b-m}" "${CONTEXT:=65536}" "${SESSIONS:=1}" "${THINKING:=off}" "${IDLE_MINUTES:=30}"
  : "${GATEWAY_PORT:=8585}" "${ENGINE_PORT:=18585}" "${SERVED_NAME:=uzu}"
  : "${ENDPOINT_AT_LOGIN:=1}" "${UPDATE_HOUR:=4}" "${UPDATE_MINUTE:=45}"
  : "${SHARE_ON_NETWORK:=0}" "${REQUIRE_KEY:=0}" "${AUTO_UPDATE:=1}" "${PYTHON:=/usr/bin/python3}"
  if [[ -z ${MEMORY_MODE:-} ]]; then if ((IDLE_MINUTES > 0)); then MEMORY_MODE=idle; else MEMORY_MODE=always; fi; fi
}

# Print the models.conf line for a key (key|label|source|model), or fail.
model_line() {
  grep -v '^\s*#' "$ROOT/models.conf" | awk -F'|' -v k="$1" '$1 == k { print; found = 1 } END { exit !found }'
}

model_field() { # model_field KEY N  (1=key 2=label 3=source 4=model)
  model_line "$1" | cut -d'|' -f"$2"
}

set_config() { # set_config KEY VALUE
  local file="$ROOT/config.env"
  if grep -q "^$1=" "$file"; then
    /usr/bin/sed -i '' "s|^$1=.*|$1=$2|" "$file"
  else
    printf '%s=%s\n' "$1" "$2" >>"$file"
  fi
}

http_ok() { # http_ok URL  -> 0 when the URL answers 2xx within 2s
  /usr/bin/curl -fsS -o /dev/null --max-time 2 "$1" 2>/dev/null
}

is_loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }

engine_version() { # what the installed engine reports, e.g. 0.6.3+6d021ae.patched
  if [[ -f $ROOT/engine/VERSION ]]; then tr -d ' \n' <"$ROOT/engine/VERSION"; return; fi
  "$ENGINE_BIN" --version 2>/dev/null | awk '{print $2}'
}

notify() { # notify "message" — macOS notification, ignored when no GUI session
  /usr/bin/osascript -e "display notification \"${1//\"/\\\"}\" with title \"uzu Home\"" >/dev/null 2>&1 || true
}

trim_log() { # keep logs under ~20 MB
  [[ -f $1 ]] && (($(stat -f %z "$1") > 20000000)) && tail -c 5000000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
  return 0
}
