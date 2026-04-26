#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/ds2api"
mkdir -p /data

wait_for_local_health() {
  local attempts=0
  local max_attempts="${HFDEEP_HEALTH_WAIT_ATTEMPTS:-60}"
  local sleep_seconds="${HFDEEP_HEALTH_WAIT_INTERVAL_SECONDS:-2}"
  local url="http://127.0.0.1:${PORT}/healthz"

  while [ "${attempts}" -lt "${max_attempts}" ]; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      log "local health check passed: ${url}"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep "${sleep_seconds}"
  done

  log "local health check did not pass in time: ${url}"
  return 1
}

log() {
  printf '[hfdeep] %s\n' "$*"
}

fail() {
  printf '[hfdeep][error] %s\n' "$*" >&2
  exit 1
}

find_optional_wasm_path() {
  local candidate=""
  for candidate in \
    "${INSTALL_DIR}/sha3_wasm_bg.7b9ca65ddd.wasm" \
    "${INSTALL_DIR}/sha3_wasm_bg.wasm"
  do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  candidate="$(find "${INSTALL_DIR}" -maxdepth 2 -type f -name 'sha3_wasm_bg*.wasm' 2>/dev/null | head -n 1 || true)"
  if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

find_static_admin_dir() {
  local candidate=""
  for candidate in \
    "${INSTALL_DIR}/static/admin" \
    "${INSTALL_DIR}/admin"
  do
    if [ -f "${candidate}/index.html" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  candidate="$(find "${INSTALL_DIR}" -maxdepth 3 -type f -path '*/admin/index.html' 2>/dev/null | head -n 1 || true)"
  if [ -n "${candidate}" ]; then
    dirname "${candidate}"
    return 0
  fi

  return 1
}

write_config_from_env_if_needed() {
  mkdir -p "$(dirname "${DS2API_CONFIG_PATH}")"

  if [ -f "${DS2API_CONFIG_PATH}" ]; then
    log "using existing config file at ${DS2API_CONFIG_PATH}"
    return
  fi

  if [ -z "${DS2API_CONFIG_JSON:-}" ]; then
    log "DS2API_CONFIG_JSON not set; service will start with file path ${DS2API_CONFIG_PATH} if created later via admin"
    return
  fi

  python3 - <<'PY'
import base64
import os
import sys

target = os.environ["DS2API_CONFIG_PATH"]
raw = os.environ.get("DS2API_CONFIG_JSON", "")

if not raw:
    sys.exit(0)

try:
    data = base64.b64decode(raw, validate=True)
    text = data.decode("utf-8")
except Exception:
    text = raw

with open(target, "w", encoding="utf-8") as f:
    f.write(text)

print(f"[hfdeep] wrote config to {target}")
PY
}

main() {
  export PORT="${PORT:-7860}"
  export LOG_LEVEL="${LOG_LEVEL:-INFO}"
  export DS2API_AUTO_BUILD_WEBUI="${DS2API_AUTO_BUILD_WEBUI:-false}"
  export DS2API_CONFIG_PATH="${DS2API_CONFIG_PATH:-/data/config.json}"
  export DS2API_ENV_WRITEBACK="${DS2API_ENV_WRITEBACK:-1}"

  write_config_from_env_if_needed

  if [ -z "${DS2API_STATIC_ADMIN_DIR:-}" ]; then
    if detected_static_admin_dir="$(find_static_admin_dir)"; then
      export DS2API_STATIC_ADMIN_DIR="${detected_static_admin_dir}"
    else
      export DS2API_STATIC_ADMIN_DIR="${INSTALL_DIR}/static/admin"
    fi
  fi
  if [ -z "${DS2API_WASM_PATH:-}" ]; then
    if detected_wasm_path="$(find_optional_wasm_path)"; then
      export DS2API_WASM_PATH="${detected_wasm_path}"
    fi
  fi

  [ -x "${INSTALL_DIR}/ds2api" ] || fail "ds2api binary missing after installation"
  [ -f "${DS2API_STATIC_ADMIN_DIR}/index.html" ] || fail "admin static files missing at ${DS2API_STATIC_ADMIN_DIR}"

  if [ -n "${DS2API_WASM_PATH:-}" ]; then
    [ -f "${DS2API_WASM_PATH}" ] || fail "configured wasm asset missing at ${DS2API_WASM_PATH}"
    log "using optional wasm asset: ${DS2API_WASM_PATH}"
  else
    log "no wasm asset detected; continuing with native PoW support"
  fi
  log "using admin static dir: ${DS2API_STATIC_ADMIN_DIR}"
  log "using persistent data dir: /data"
  log "config path: ${DS2API_CONFIG_PATH}"
  log "DS2API_ENV_WRITEBACK=${DS2API_ENV_WRITEBACK}"

  log "starting DS2API on 0.0.0.0:${PORT}"
  "${INSTALL_DIR}/ds2api" &
  local ds2api_pid=$!

  wait_for_local_health || true

  wait "${ds2api_pid}"
}

main "$@"
