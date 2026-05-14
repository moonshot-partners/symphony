#!/usr/bin/env bash
set -euo pipefail

SYMPHONY_DIR="${SYMPHONY_DIR:-/opt/symphony}"
STATE_DIR="${STATE_DIR:-/opt/symphony/state}"
DRAIN_FLAG="$STATE_DIR/drain.flag"
STATUS_FILE="$STATE_DIR/status.json"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-600}"
DRAIN_POLL_SECONDS="${DRAIN_POLL_SECONDS:-5}"

log() {
  printf '[deploy] %s\n' "$*"
}

trap 'rm -f "$DRAIN_FLAG"' EXIT

log "begin drain"
mkdir -p "$STATE_DIR"
touch "$DRAIN_FLAG"

deadline=$(( SECONDS + DRAIN_TIMEOUT_SECONDS ))
while (( SECONDS < deadline )); do
  if [[ ! -f "$STATUS_FILE" ]]; then
    log "status file missing yet — waiting"
    sleep "$DRAIN_POLL_SECONDS"
    continue
  fi

  running_count=$(jq '.running | length' "$STATUS_FILE")
  drain_observed=$(jq -r '.drain' "$STATUS_FILE")
  log "status: drain=$drain_observed running=$running_count"

  if [[ "$drain_observed" == "true" && "$running_count" == "0" ]]; then
    log "drain complete"
    break
  fi

  sleep "$DRAIN_POLL_SECONDS"
done

if (( SECONDS >= deadline )); then
  log "drain timeout reached — proceeding anyway; systemd TimeoutStopSec is the safety net"
fi

log "git pull"
cd "$SYMPHONY_DIR"
old_sha=$(git rev-parse HEAD)
git fetch --quiet origin main
git reset --hard origin/main
new_sha=$(git rev-parse HEAD)

log "build escript"
export PATH=/home/ubuntu/.local/share/mise/installs/erlang/28.5/bin:/home/ubuntu/.local/share/mise/installs/elixir/1.19.5-otp-28/bin:$PATH
cd "$SYMPHONY_DIR/elixir"
mix deps.get >/dev/null
mix escript.build >/dev/null

# Rebuild schoolsout-base Docker image when its source changed. The shim
# image bakes /opt/qa from docker/schoolsout-base/qa, so a stale image
# silently runs old QA harness code in newly dispatched agent containers
# (SODEV-879 reproduced this: PR shipped, deploy succeeded, image stale,
# agent kept running `npm run dev`).
if git -C "$SYMPHONY_DIR" diff --name-only "$old_sha" "$new_sha" | grep -q '^docker/schoolsout-base/'; then
  log "rebuild schoolsout-base image (source changed)"
  cd "$SYMPHONY_DIR"
  docker build --quiet -t schoolsout-base:latest -f docker/schoolsout-base/Dockerfile . >/dev/null
else
  log "schoolsout-base image unchanged; skip rebuild"
fi

log "restart symphony"
sudo systemctl restart symphony

rm -f "$DRAIN_FLAG"

log "wait for healthy"
for _ in $(seq 1 12); do
  if sudo systemctl is-active --quiet symphony; then
    log "symphony active"
    break
  fi
  sleep 5
done

sudo systemctl is-active --quiet symphony || {
  log "symphony failed to come up"
  sudo journalctl -u symphony -n 30 --no-pager
  exit 1
}

log "done"
