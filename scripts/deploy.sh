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

# Build and restart the read-only cockpit dashboard from source. Runs only when
# dashboard/ changed and only after the agent is confirmed healthy, and is
# non-fatal: a cockpit failure must never take down the agent. `</dev/null` on
# the node tooling for the same reason mix needs it (script is piped on stdin).
deploy_cockpit() {
  cd "$SYMPHONY_DIR/dashboard" || return 1
  # corepack ships a pnpm that crashes on this box's node 22
  # (ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING), so use a plain global pnpm.
  corepack disable >/dev/null 2>&1 || true
  pnpm --version >/dev/null 2>&1 || npm install -g pnpm >/dev/null 2>&1 || return 1
  # --ignore-scripts: the only build scripts are sharp/unrs/msw, none needed
  # for the server build (images are unoptimized), and pnpm 11 otherwise exits
  # non-zero on un-approved build scripts.
  pnpm install --frozen-lockfile --ignore-scripts </dev/null >/dev/null 2>&1 || return 1
  NEXT_PUBLIC_DATA_SOURCE=http pnpm build </dev/null >/dev/null 2>&1 || return 1
  cp -r .next/static .next/standalone/.next/static || return 1
  cp -r public .next/standalone/public || return 1
  rm -rf "$SYMPHONY_DIR/cockpit"
  mkdir -p "$SYMPHONY_DIR/cockpit"
  cp -r .next/standalone/. "$SYMPHONY_DIR/cockpit/" || return 1
  sudo chown -R ubuntu:ubuntu "$SYMPHONY_DIR/cockpit"
  sudo systemctl restart cockpit || return 1
}

trap 'rm -f "$DRAIN_FLAG"' EXIT

# Capture the deployed SHA *before* drain. WorkflowStore (running inside the
# Symphony Elixir process) does its own periodic `git pull --ff-only` of this
# directory, so during the 10-minute drain HEAD can be silently fast-forwarded
# to the new commit. If we read HEAD post-drain, old_sha == new_sha → the diff
# below is empty → image rebuild is skipped even when docker/ changed.
# Reproduced live with PR #101 (qa_publish.py shipped but image stayed stale).
log "capture pre-drain HEAD"
cd "$SYMPHONY_DIR"
old_sha=$(git rev-parse HEAD)
log "old_sha=$old_sha"

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

log "stop symphony before git update"
sudo systemctl stop symphony

log "git pull"
cd "$SYMPHONY_DIR"
git fetch --quiet origin main
git reset --hard origin/main
new_sha=$(git rev-parse HEAD)
log "new_sha=$new_sha"

log "install logrotate config"
sudo cp "$SYMPHONY_DIR/scripts/symphony-logrotate" /etc/logrotate.d/symphony
sudo chmod 644 /etc/logrotate.d/symphony

log "build escript"
export PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin
cd "$SYMPHONY_DIR/elixir"
# Nuke _build/prod before rebuilding. Schema changes (e.g. SYM-22 adding
# :soft_cap_enabled to Config.Schema.Agent) silently reuse stale compiled
# BEAMs because mix incremental rebuild does not detect every struct
# layout shift. The stale BEAM ships an old struct, then a runtime
# Map.fetch! against the new field raises KeyError and crashes the
# orchestrator in a restart loop. Verified live 2026-05-24: SYM-22
# shipped 2026-05-22, deploy reused stale BEAM, Symphony crashed every
# turn_completed for 16h until manual rebuild on the VPS.
# 5s extra per deploy buys correctness — keep this.
rm -rf _build/prod
# `</dev/null` is load-bearing: the deploy workflow runs this script via
# `ssh 'bash -s' < scripts/deploy.sh`, so the script itself is on stdin.
# `mix` (the BEAM it spawns) reads stdin and would consume the rest of the
# piped script — every line below, including `systemctl restart symphony`,
# is then silently dropped and bash exits 0 at the premature EOF. Feeding
# mix an empty stdin keeps the remainder of the script intact for bash.
# Verified live on the VPS. Any new stdin-reading command added below this
# point needs the same redirect.
mix deps.get </dev/null >/dev/null
mix escript.build </dev/null >/dev/null

# Rebuild schoolsout-base Docker image when its source changed. The shim
# image bakes /opt/qa from docker/schoolsout-base/qa, so a stale image
# silently runs old QA harness code in newly dispatched agent containers
# (SODEV-879 reproduced this: PR shipped, deploy succeeded, image stale,
# agent kept running `npm run dev`).
#
# Also rebuild on agent_shim changes: the Dockerfile bakes the shim via
# `COPY elixir/priv/agent_shim` + `pip install`, so a shim-only change never
# reaches the agent without an image rebuild (cost three deploys to learn this
# while wiring Langfuse tracing — host-side shim deploys are inert in Docker
# mode, the agent only ever runs the image's baked shim).
if git -C "$SYMPHONY_DIR" diff --name-only "$old_sha" "$new_sha" \
  | grep -qE '^(docker/schoolsout-base/|elixir/priv/agent_shim/)'; then
  log "rebuild schoolsout-base image (source changed)"
  cd "$SYMPHONY_DIR"
  docker build --quiet -t schoolsout-base:latest -f docker/schoolsout-base/Dockerfile . >/dev/null
  # Build cache grows ~1GB per rebuild and is never reused on the next build
  # (image tag is overwritten). Left alone it filled /var/lib/docker to 10.93GB
  # within a month and starved sshd preauth on 2026-05-17, requiring NMI reboot.
  log "prune build cache"
  docker builder prune -af --filter 'until=1h' >/dev/null
else
  log "schoolsout-base image unchanged; skip rebuild"
fi

log "restart symphony"
sudo systemctl restart symphony

# Untagged image layers from the rebuild above plus orphans from killed agent
# containers accumulate as dangling. Prune is no-op when nothing to reclaim.
log "prune dangling images"
docker image prune -f >/dev/null

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

# Cockpit dashboard. Agent is healthy by here; this is best-effort and never
# fails the deploy. Gate on a marker of the sha the cockpit was last built from,
# NOT old_sha/new_sha: WorkflowStore git-pulls this dir on its own timer, so HEAD
# is often already the new commit before this script runs, making an
# old_sha..new_sha diff empty and silently skipping a needed rebuild (hit live on
# PR #235 and #238 — cockpit served a stale bundle until a manual rebuild). The
# marker reflects what is actually built, so it is immune to that race and the
# rebuild retries on failure (marker only advances on success). The
# schoolsout-base image gate above has the same latent race; left as-is for now
# to avoid forcing a heavier image rebuild on this code path.
COCKPIT_SHA_FILE="$STATE_DIR/cockpit-deployed-sha"
cockpit_sha=$(cat "$COCKPIT_SHA_FILE" 2>/dev/null || true)
if [ -z "$cockpit_sha" ] \
  || ! git -C "$SYMPHONY_DIR" cat-file -e "${cockpit_sha}^{commit}" 2>/dev/null \
  || git -C "$SYMPHONY_DIR" diff --name-only "$cockpit_sha" "$new_sha" | grep -qE '^dashboard/'; then
  log "dashboard changed since last cockpit build — rebuild cockpit"
  if deploy_cockpit; then
    echo "$new_sha" > "$COCKPIT_SHA_FILE"
    log "cockpit deployed (marker -> $new_sha)"
  else
    log "cockpit deploy FAILED (non-fatal; agent unaffected; will retry next deploy)"
  fi
else
  log "dashboard unchanged since last cockpit build; skip cockpit rebuild"
fi

log "done"
