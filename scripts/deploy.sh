#!/usr/bin/env bash
#
# Symphony deploy (SchoolsOut, upstream openai/symphony).
#
# Run on the VPS as a sudo-capable user, e.g. from CI:
#   ssh "$SSH_USER@$SSH_HOST" 'bash -s' < scripts/deploy.sh
#
# Run it FOREGROUND and watch it: it stops the orchestrator briefly, so a
# dropped connection mid-deploy must not be silent. The slow escript rebuild
# happens BEFORE the stop, so a build failure (or a disconnect during the build)
# leaves the running orchestrator untouched; only a fast stop+start swaps code.
#
# Source of truth is git: /opt/symphony is a checkout of $DEPLOY_BRANCH, so
# `git -C /opt/symphony rev-parse HEAD` (and /opt/symphony/DEPLOYED_SHA) always
# tell you exactly what is running. Gitignored runtime state (elixir/_build,
# elixir/deps, state/, dashboard build) survives the deploy untouched.

set -euo pipefail

SYMPHONY_DIR="${SYMPHONY_DIR:-/opt/symphony}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-schoolsout-prod}"
APP_USER="${APP_USER:-ubuntu}"
APP_HOME="${APP_HOME:-/home/$APP_USER}"
ENV_FILE="${ENV_FILE:-/etc/symphony/symphony.env}"
STATE_DIR="${STATE_DIR:-$SYMPHONY_DIR/state}"
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

ensure_env_line() {
  local key="$1"
  local value="$2"
  local current

  sudo mkdir -p "$(dirname "$ENV_FILE")"
  sudo touch "$ENV_FILE"
  if sudo grep -q "^${key}=" "$ENV_FILE"; then
    current=$(sudo sed -n "s|^${key}=||p" "$ENV_FILE" | tail -n 1)
    if [[ "$current" != "$value" ]]; then
      sudo sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
      log "updated $key in $ENV_FILE"
    fi
  else
    printf '%s=%s\n' "$key" "$value" | sudo tee -a "$ENV_FILE" >/dev/null
    log "configured $key in $ENV_FILE"
  fi
}

# 1. Record the pre-deploy HEAD up front. Capturing old_sha BEFORE the drain
#    means a HEAD move mid-drain can never turn the dashboard-change check into a
#    false negative that silently ships a stale cockpit.
cd "$SYMPHONY_DIR"
old_sha=$(asapp git rev-parse HEAD 2>/dev/null || echo none)

sudo mkdir -p "$STATE_DIR"
sudo chown "$APP_USER:$APP_USER" "$STATE_DIR"
ensure_env_line "SYMPHONY_STATE_DIR" "$STATE_DIR"
ensure_env_line "SYMPHONY_RUN_LEDGER_PATH" "$STATE_DIR/symphony_run_ledger.jsonl"

# 2. Best-effort drain: wait for in-flight agents to finish so a deploy never
#    kills a running turn. An unreachable orchestrator means it is already down,
#    so there is nothing to drain — proceed immediately instead of spinning the
#    full timeout. systemd TimeoutStopSec is the hard safety net.
log "waiting for agents to drain (timeout ${DRAIN_TIMEOUT_SECONDS}s)"
deadline=$(( SECONDS + DRAIN_TIMEOUT_SECONDS ))
while (( SECONDS < deadline )); do
  if ! state=$(curl -fsS "$HEALTH_URL" 2>/dev/null); then
    log "orchestrator unreachable (already down), proceeding"
    break
  fi
  running=$(printf '%s' "$state" | jq -r '.counts.running // 0' 2>/dev/null || echo unknown)
  if [[ "$running" == "0" ]]; then log "idle, proceeding"; break; fi
  log "running=$running, waiting ${DRAIN_POLL_SECONDS}s"
  sleep "$DRAIN_POLL_SECONDS"
done
(( SECONDS >= deadline )) && log "drain timeout reached, proceeding anyway"

# 3. Update code from git (the canonical deploy branch). The orchestrator keeps
#    running on the old code through this and the rebuild below.
asapp git fetch --quiet origin "$DEPLOY_BRANCH"
asapp git reset --hard "origin/$DEPLOY_BRANCH"
new_sha=$(asapp git rev-parse HEAD)
log "old_sha=$old_sha new_sha=$new_sha"
dashboard_changes="fresh checkout"
if [[ "$old_sha" != "none" ]]; then
  if ! dashboard_changes=$(asapp git diff --name-only "$old_sha" "$new_sha" -- dashboard/); then
    log "cockpit: could not diff $old_sha..$new_sha — forcing rebuild"
    dashboard_changes="fresh checkout"
  fi
fi

# 4. Rebuild the escript BEFORE stopping anything. The running orchestrator does
#    not read _build/prod or bin/symphony at runtime, so a rebuild (or a failure
#    here) cannot disturb it — prod stays up if the build breaks. _build/prod is
#    nuked because schema/struct changes can otherwise reuse stale compiled BEAMs.
log "rebuild escript (orchestrator still serving)"
cd "$SYMPHONY_DIR/elixir"
asapp env PATH="$ELIXIR_PATH" sh -c 'rm -rf _build/prod'
asapp env PATH="$ELIXIR_PATH" MIX_ENV=prod mix deps.get </dev/null >/dev/null
asapp env PATH="$ELIXIR_PATH" MIX_ENV=prod mix escript.build </dev/null

# 5. Swap code: stop, then start. This is the only window the orchestrator is
#    down, and it is just a restart (seconds), not a build.
log "restart symphony"
sudo systemctl stop symphony
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

# 6. Cockpit. Rebuild only when the dashboard tree actually changed; log the
#    decision loudly either way so a green deploy never silently ships a stale
#    cockpit. Next.js standalone keeps serving the old build until the restart,
#    so the only blip is the restart itself.
if [[ -z "$dashboard_changes" ]]; then
  log "cockpit: dashboard/ unchanged ($old_sha..$new_sha) — skip rebuild"
else
  log "cockpit: dashboard/ changed (or fresh checkout) — rebuilding"
  printf '%s\n' "$dashboard_changes" | sed 's/^/[deploy] cockpit changed: /'
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

# 7. Record what is deployed (only after every stage is green).
printf '%s\n' "$new_sha" | sudo tee "$SYMPHONY_DIR/DEPLOYED_SHA" >/dev/null
log "deployed $new_sha — orchestrator + cockpit reconciled"
