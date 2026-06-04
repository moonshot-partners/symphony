#!/usr/bin/env bash
#
# Symphony deploy (SchoolsOut, upstream openai/symphony).
#
# Run on the VPS as a sudo-capable user, e.g. from CI:
#   ssh "$SSH_USER@$SSH_HOST" 'bash -s' < scripts/deploy.sh
#
# It pulls the canonical deploy branch, rebuilds the escript, restarts the
# systemd service, and health-checks. Source of truth is git: /opt/symphony is
# a checkout of $DEPLOY_BRANCH, so `git -C /opt/symphony rev-parse HEAD` (and
# /opt/symphony/DEPLOYED_SHA) always tell you exactly what is running.
#
# Gitignored runtime state (elixir/_build, elixir/deps, state/, dashboard build)
# survives the deploy untouched.

set -euo pipefail

SYMPHONY_DIR="${SYMPHONY_DIR:-/opt/symphony}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-schoolsout-prod}"
APP_USER="${APP_USER:-ubuntu}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:4010/api/v1/state}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-600}"
DRAIN_POLL_SECONDS="${DRAIN_POLL_SECONDS:-10}"
ELIXIR_PATH="${ELIXIR_PATH:-/usr/local/elixir/bin:/usr/local/bin:/usr/bin:/bin}"

log() { printf '[deploy] %s\n' "$*"; }
asapp() { sudo -u "$APP_USER" "$@"; }

# 1. Best-effort drain: wait for in-flight agents to finish so a deploy never
#    kills a running turn. systemd TimeoutStopSec is the hard safety net.
log "waiting for agents to drain (timeout ${DRAIN_TIMEOUT_SECONDS}s)"
deadline=$(( SECONDS + DRAIN_TIMEOUT_SECONDS ))
while (( SECONDS < deadline )); do
  running=$(curl -fsS "$HEALTH_URL" 2>/dev/null | jq -r '.counts.running // 0' 2>/dev/null || echo unknown)
  if [[ "$running" == "0" ]]; then log "idle, proceeding"; break; fi
  log "running=$running, waiting ${DRAIN_POLL_SECONDS}s"
  sleep "$DRAIN_POLL_SECONDS"
done
(( SECONDS >= deadline )) && log "drain timeout reached, proceeding anyway"

# 2. Stop the orchestrator before swapping code.
log "stop symphony"
sudo systemctl stop symphony

# 3. Update code from git (the canonical deploy branch).
cd "$SYMPHONY_DIR"
old_sha=$(asapp git rev-parse HEAD 2>/dev/null || echo none)
asapp git fetch --quiet origin "$DEPLOY_BRANCH"
asapp git reset --hard "origin/$DEPLOY_BRANCH"
new_sha=$(asapp git rev-parse HEAD)
log "old_sha=$old_sha new_sha=$new_sha"

# 4. Rebuild the escript. _build/prod is nuked because schema/struct changes can
#    otherwise reuse stale compiled BEAMs.
log "rebuild escript"
cd "$SYMPHONY_DIR/elixir"
asapp env PATH="$ELIXIR_PATH" sh -c 'rm -rf _build/prod'
asapp env PATH="$ELIXIR_PATH" MIX_ENV=prod mix deps.get </dev/null >/dev/null
asapp env PATH="$ELIXIR_PATH" MIX_ENV=prod mix escript.build </dev/null

# 5. Restart and health-check. Fail the deploy if the service or API is unhealthy.
log "restart symphony"
sudo systemctl start symphony
sleep 6
if ! sudo systemctl is-active --quiet symphony; then
  log "FAIL: symphony not active after restart"
  exit 1
fi
code=$(curl -fsS -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo 000)
if [[ "$code" != "200" ]]; then
  log "FAIL: health check $HEALTH_URL returned $code"
  exit 1
fi

# 6. Record what is deployed.
printf '%s\n' "$new_sha" | sudo tee "$SYMPHONY_DIR/DEPLOYED_SHA" >/dev/null
log "deployed $new_sha — service active, health 200"
