#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/ds2api"
mkdir -p /data

bucket_restore_data() {
  if [ -z "${HF_TOKEN:-}" ] || [ -z "${HF_BUCKET_REPO:-}" ]; then
    log "HF Bucket restore skipped: HF_TOKEN or HF_BUCKET_REPO not set"
    return
  fi

  python3 - <<'PY'
import os
import sys
from urllib.parse import urlparse
from huggingface_hub import HfFileSystem

token = os.environ.get("HF_TOKEN", "")
repo = os.environ.get("HF_BUCKET_REPO", "")
local_data = "/data"

if not token or not repo:
    print("[hfdeep] bucket restore skipped: HF_TOKEN or HF_BUCKET_REPO not set")
    sys.exit(0)

fs = HfFileSystem(token=token)
bucket_root = f"hf://buckets/{repo}"
os.makedirs(local_data, exist_ok=True)

def to_relative_path(remote_file: str) -> str:
    prefix = f"hf://buckets/{repo}/"
    if remote_file.startswith(prefix):
        return remote_file[len(prefix):]

    parsed = urlparse(remote_file)
    path = parsed.path.lstrip("/")
    repo_prefix = f"{repo}/"
    if path.startswith(repo_prefix):
        return path[len(repo_prefix):]

    buckets_prefix = f"buckets/{repo}/"
    if path.startswith(buckets_prefix):
        return path[len(buckets_prefix):]

    return path

try:
    if not fs.exists(bucket_root):
        print(f"[hfdeep] bucket restore skipped: {bucket_root} not found")
        sys.exit(0)

    files = []
    seen = set()

    for pattern in (f"{bucket_root}/*", f"{bucket_root}/**/*"):
        try:
            for path in fs.glob(pattern):
                if path not in seen:
                    files.append(path)
                    seen.add(path)
        except Exception as exc:
            print(f"[hfdeep] bucket restore glob warning for {pattern}: {exc}")

    restored = 0
    for remote_file in files:
        if fs.isfile(remote_file):
            rel_path = to_relative_path(remote_file)
            if not rel_path or rel_path in (".", ".."):
                continue
            local_file = os.path.join(local_data, rel_path)
            os.makedirs(os.path.dirname(local_file), exist_ok=True)
            fs.get(remote_file, local_file)
            print(f"[hfdeep] bucket restored: {rel_path}")
            restored += 1
    print(f"[hfdeep] bucket restore done, {restored} file(s) restored")
except Exception as exc:
    print(f"[hfdeep] bucket restore error: {exc}")
PY
}

start_bucket_sync_daemon() {
  if [ -z "${HF_TOKEN:-}" ] || [ -z "${HF_BUCKET_REPO:-}" ]; then
    log "HF Bucket sync daemon skipped: HF_TOKEN or HF_BUCKET_REPO not set"
    return
  fi

  python3 - <<'PY' &
import glob
import os
import threading
import time
from huggingface_hub import HfFileSystem
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

token = os.environ.get("HF_TOKEN", "")
repo = os.environ.get("HF_BUCKET_REPO", "")
data_dir = "/data"
bucket_root = f"hf://buckets/{repo}"
restore_grace_seconds = 30
startup_time = time.time()

def push():
    if not token or not repo:
        return
    fs = HfFileSystem(token=token)
    files = [
        f for f in glob.glob(os.path.join(data_dir, "**", "*"), recursive=True)
        if os.path.isfile(f)
    ]
    if not files:
        return
    try:
        for local_path in files:
            rel_path = os.path.relpath(local_path, data_dir)
            remote_path = f"{bucket_root}/{rel_path}"
            fs.put(local_path, remote_path)
        print(f"[hfdeep] bucket push done, {len(files)} file(s) synced", flush=True)
    except Exception as exc:
        print(f"[hfdeep] bucket push error: {exc}", flush=True)

class Handler(FileSystemEventHandler):
    def __init__(self):
        self._timer = None
        self._lock = threading.Lock()

    def _schedule(self):
        with self._lock:
            if time.time() - startup_time < restore_grace_seconds:
                return
            if self._timer:
                self._timer.cancel()
            self._timer = threading.Timer(5, push)
            self._timer.start()

    def on_modified(self, event):
        if not event.is_directory:
            self._schedule()

    def on_created(self, event):
        if not event.is_directory:
            self._schedule()

    def on_deleted(self, event):
        if not event.is_directory:
            self._schedule()

observer = Observer()
observer.schedule(Handler(), path=data_dir, recursive=True)
observer.start()
print("[hfdeep] bucket watcher started for /data", flush=True)

def periodic():
    while True:
        time.sleep(300)
        push()

threading.Thread(target=periodic, daemon=True).start()

# 启动后等待一段时间再启用 watcher，避免 restore / config 注入阶段触发抖动同步
time.sleep(30)

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    observer.stop()
observer.join()
PY
}

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

  bucket_restore_data
  write_config_from_env_if_needed

  if [ -z "${DS2API_STATIC_ADMIN_DIR:-}" ]; then
    export DS2API_STATIC_ADMIN_DIR="${INSTALL_DIR}/static/admin"
  fi
  if [ -z "${DS2API_WASM_PATH:-}" ]; then
    export DS2API_WASM_PATH="${INSTALL_DIR}/sha3_wasm_bg.7b9ca65ddd.wasm"
  fi

  [ -x "${INSTALL_DIR}/ds2api" ] || fail "ds2api binary missing after installation"
  [ -f "${DS2API_WASM_PATH}" ] || fail "wasm asset missing at ${DS2API_WASM_PATH}"

  log "starting DS2API on 0.0.0.0:${PORT}"
  "${INSTALL_DIR}/ds2api" &
  local ds2api_pid=$!

  if wait_for_local_health; then
    start_bucket_sync_daemon
  else
    log "bucket sync daemon skipped because local health check did not pass"
  fi

  wait "${ds2api_pid}"
}

main "$@"
