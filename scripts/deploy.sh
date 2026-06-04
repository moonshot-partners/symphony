#!/usr/bin/env bash
#
# Symphony deploy (SchoolsOut, upstream openai/symphony).
#
# Run on the VPS as a sudo-capable user, e.g. from CI:
#   ssh "$SSH_USER@$SSH_HOST" 'bash -s' < scripts/deploy.sh
#
# It pulls the canonical deploy branch, rebuilds BOTH the Elixir escript
# (orchestrator) and, when the dashboard changed, the Next.js cockpit, then
# restarts the systemd services and health-checks each. Source of truth is git:
# /opt/symphony is a checkout of $DEPLOY_BRANCH, so `git -C /opt/symphony
# rev-parse HEAD` (and /opt/symphony/DEPLOYED_SHA) always tell you exactly what
# is running.
#
# Gitignored runtime state (elixir/_build, elixir/deps, state/, dashboard build)
# survives the deploy untouched.

set -euo pipefail

SYMPHONY_DIR="${SYMPHONY_DIR:-/opt/symphony}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-schoolsout-prod}"
APP_USER="${APP_USER:-ubuntu}"
APP_HOME="${APP_HOME:-/home/$APP_USER}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:4010/api/v1/state}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-600}"
DRAIN_POLL_SECONDS="${DRAIN_POLL_SECONDS:-10}"
ELIXIR_PATH="${ELIXIR_PATH:-/usr/local/elixir/bin:/usr/local/bin:/usr/bin:/bin}"
# Cockpit (separate Next.js standalone service).
COCKPIT_DIR="${COCKPIT_DIR:-$SYMPHONY_DIR/dashboard}"
COCKPIT_SERVICE="${COCKPIT_SERVICE:-cockpit}"
COCKPIT_HEALTH_URL="${COCKPIT_HEALTH_URL:-http://127.0.0.1:3000/}"
NODE_BIN_PATH="${NODE_BIN_PATH:-/usr/local/bin:/usr/bin:/bin}"

log() { printf '[deploy] %s\n' "$*"; }
asapp() { sudo -u "$APP_USER" "$@"; }

# 1. Record the pre-deploy HEAD up front. Capturing old_sha BEFORE the drain
#    means a HEAD move mid-drain can never turn the dashboard-change check into a
#    false negative that silently ships a stale cockpit.
cd "$SYMPHONY_DIR"
old_sha=$(asapp git rev-parse HEAD 2>/dev/null || echo none)

# 2. Best-effort drain: wait for in-flight agents to finish so a deploy never
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

# 3. Stop the orchestrator before swapping code.
log "stop symphony"
sudo systemctl stop symphony

# 4. Update code from git (the canonical deploy branch).
asapp git fetch --quiet origin "$DEPLOY_BRANCH"
asapp git reset --hard "origin/$DEPLOY_BRANCH"
new_sha=$(asapp git rev-parse HEAD)
log "old_sha=$old_sha new_sha=$new_sha"

# 5. Rebuild the escript. _build/prod is nuked because schema/struct changes can
#    otherwise reuse stale compiled BEAMs.
log "rebuild escript"
cd "$SYMPHONY_DIR/elixir"
asapp env PATH="$ELIXIR_PATH" sh -c 'rm -rf _build/prod'
asapp env PATH="$ELIXIR_PATH" MIX_ENV=prod mix deps.get </dev/null >/dev/null
asapp env PATH="$ELIXIR_PATH" MIX_ENV=prod mix escript.build </dev/null

# 6. Restart and health-check the orchestrator. Fail the deploy if unhealthy.
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
log "orchestrator deployed — service active, health 200"

# 7. Cockpit. Rebuild only when the dashboard tree actually changed; log the
#    decision loudly either way so a green deploy never silently ships a stale
#    cockpit. Next.js standalone keeps serving the old build until the restart,
#    so the only blip is the restart itself.
if [[ "$old_sha" != "none" ]] && asapp git diff --quiet "$old_sha" "$new_sha" -- dashboard/; then
  log "cockpit: dashboard/ unchanged ($old_sha..$new_sha) — skip rebuild"
else
  log "cockpit: dashboard/ changed (or fresh checkout) — rebuilding"
  asapp env HOME="$APP_HOME" PATH="$NODE_BIN_PATH" bash -euo pipefail -c "
    cd '$COCKPIT_DIR'
    pnpm install --frozen-lockfile
    pnpm build
    rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static
    if [ -d public ]; then rm -rf .next/standalone/public && cp -r public .next/standalone/public; fi
  " </dev/null
  log "restart cockpit"
  sudo systemctl restart "$COCKPIT_SERVICE"
  sleep 4
  if ! sudo systemctl is-active --quiet "$COCKPIT_SERVICE"; then
    log "FAIL: cockpit not active after restart"
    exit 1
  fi
  ccode=$(curl -fsS -o /dev/null -w '%{http_code}' "$COCKPIT_HEALTH_URL" 2>/dev/null || echo 000)
  if [[ "$ccode" != "200" ]]; then
    log "FAIL: cockpit health $COCKPIT_HEALTH_URL returned $ccode"
    exit 1
  fi
  log "cockpit deployed — service active, health 200"
fi

# 8. Record what is deployed (only after every stage is green).
printf '%s\n' "$new_sha" | sudo tee "$SYMPHONY_DIR/DEPLOYED_SHA" >/dev/null
log "deployed $new_sha — orchestrator + cockpit reconciled"
