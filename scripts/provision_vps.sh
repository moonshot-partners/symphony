#!/usr/bin/env bash
# Provision a fresh Ubuntu host to run the Symphony orchestrator.
#
# Usage (as root, on a fresh host):
#   sudo bash scripts/provision_vps.sh [--force-unit]
#
# Steps (idempotent):
#   1. apt: build-essential, git, curl, libssl, autoconf, m4
#   2. mise + pinned erlang/elixir for ${SERVICE_USER}
#   3. clone Symphony into ${SYMPHONY_DIR}
#   4. build escript (MIX_ENV=prod mix build)
#   5. write /etc/symphony/symphony.env.example (operator copies + edits)
#   6. install /etc/systemd/system/symphony.service (preserved if present;
#      pass --force-unit to overwrite)
#
# After provisioning the operator must:
#   sudo cp /etc/symphony/symphony.env.example /etc/symphony/symphony.env
#   sudo chmod 600 /etc/symphony/symphony.env
#   sudo $EDITOR /etc/symphony/symphony.env   # fill in tokens
#   sudo systemctl enable --now symphony

set -euo pipefail

SYMPHONY_REPO="${SYMPHONY_REPO:-https://github.com/moonshot-partners/symphony.git}"
SYMPHONY_BRANCH="${SYMPHONY_BRANCH:-main}"
SYMPHONY_DIR="${SYMPHONY_DIR:-/opt/symphony}"
SERVICE_USER="${SERVICE_USER:-ubuntu}"

ELIXIR_VERSION="1.19.5-otp-28"
ERLANG_VERSION="28.5"

ENV_DIR="/etc/symphony"
ENV_EXAMPLE="${ENV_DIR}/symphony.env.example"
ENV_FILE="${ENV_DIR}/symphony.env"
UNIT_FILE="/etc/systemd/system/symphony.service"

FORCE_UNIT=0
for arg in "$@"; do
  case "$arg" in
    --force-unit) FORCE_UNIT=1 ;;
    *) printf 'unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log() { printf '[provision] %s\n' "$*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "must run as root (sudo)"
    exit 1
  fi
}

require_user() {
  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    log "service user '${SERVICE_USER}' missing — create it first"
    exit 1
  fi
}

home_of() {
  getent passwd "$1" | cut -d: -f6
}

step_apt() {
  log "apt: installing toolchain prerequisites"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    build-essential \
    ca-certificates \
    curl \
    git \
    libssl-dev \
    autoconf \
    m4 \
    libncurses-dev \
    unzip
}

step_mise() {
  local home; home="$(home_of "${SERVICE_USER}")"
  local mise_bin="${home}/.local/bin/mise"

  if [ ! -x "${mise_bin}" ]; then
    log "installing mise for ${SERVICE_USER}"
    sudo -u "${SERVICE_USER}" -H bash -c 'curl -fsSL https://mise.run | sh'
  else
    log "mise already installed for ${SERVICE_USER}"
  fi

  log "pinning erlang@${ERLANG_VERSION} and elixir@${ELIXIR_VERSION}"
  sudo -u "${SERVICE_USER}" -H bash <<EOF
set -euo pipefail
export PATH="${home}/.local/bin:\$PATH"
mise use -g "erlang@${ERLANG_VERSION}"
mise use -g "elixir@${ELIXIR_VERSION}"
EOF
}

step_clone() {
  if [ -d "${SYMPHONY_DIR}/.git" ]; then
    log "${SYMPHONY_DIR} already a git repo — skipping clone"
    return 0
  fi
  log "cloning Symphony into ${SYMPHONY_DIR}"
  install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${SYMPHONY_DIR}"
  sudo -u "${SERVICE_USER}" git clone --branch "${SYMPHONY_BRANCH}" "${SYMPHONY_REPO}" "${SYMPHONY_DIR}"
}

step_build() {
  local home; home="$(home_of "${SERVICE_USER}")"
  log "building Symphony escript (MIX_ENV=prod)"
  sudo -u "${SERVICE_USER}" -H bash <<EOF
set -euo pipefail
export PATH="${home}/.local/share/mise/installs/erlang/${ERLANG_VERSION}/bin:${home}/.local/share/mise/installs/elixir/${ELIXIR_VERSION}/bin:\$PATH"
cd "${SYMPHONY_DIR}/elixir"
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
MIX_ENV=prod mix build
EOF
}

step_env() {
  install -d -m 755 "${ENV_DIR}"
  log "writing ${ENV_EXAMPLE}"
  cat > "${ENV_EXAMPLE}" <<'EOF'
# Symphony orchestrator environment.
# Copy to /etc/symphony/symphony.env, chmod 600, and fill in real values.

# --- Required secrets ---
LINEAR_API_KEY=
GH_TOKEN=
CLAUDE_CODE_OAUTH_TOKEN=

# --- Workflow ---
SYMPHONY_WORKFLOW_FILE=/opt/symphony/elixir/WORKFLOW.schools-out.md
SYMPHONY_AGENT_SHIM_PYTHON=/opt/symphony/elixir/priv/agent_shim/.venv/bin/python

# --- Locale ---
LANG=C.UTF-8
LC_ALL=C.UTF-8

# --- BEAM tuning ---
ELIXIR_ERL_OPTIONS=

# --- OpenTelemetry ---
OTEL_SERVICE_NAME=symphony
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=
OTEL_EXPORTER_OTLP_HEADERS=
OTEL_LOG_TOOL_DETAILS=true
OTEL_LOG_USER_PROMPTS=false
OTEL_TRACES_EXPORT_INTERVAL=10000
OTEL_METRIC_EXPORT_INTERVAL=10000
OTEL_LOGS_EXPORT_INTERVAL=10000
EOF
  chmod 644 "${ENV_EXAMPLE}"
}

step_unit() {
  local home; home="$(home_of "${SERVICE_USER}")"

  if [ -f "${UNIT_FILE}" ] && [ "${FORCE_UNIT}" -ne 1 ]; then
    log "${UNIT_FILE} already exists — keep it (use --force-unit to overwrite)"
    return 0
  fi

  log "writing ${UNIT_FILE}"
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=Symphony Elixir Orchestrator
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${SYMPHONY_DIR}/elixir
EnvironmentFile=${ENV_FILE}
Environment="PATH=${home}/.local/share/mise/shims:${home}/.local/bin:${home}/.local/share/mise/installs/erlang/${ERLANG_VERSION}/bin:${home}/.local/share/mise/installs/elixir/${ELIXIR_VERSION}/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${SYMPHONY_DIR}/elixir/bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ${SYMPHONY_DIR}/elixir/WORKFLOW.schools-out.md
Restart=on-failure
RestartSec=10
TimeoutStopSec=900
KillMode=mixed
StandardOutput=journal
StandardError=journal
SyslogIdentifier=symphony

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${UNIT_FILE}"
  systemctl daemon-reload
}

step_summary() {
  log "provision complete"
  log ""
  log "next:"
  log "  1. sudo cp ${ENV_EXAMPLE} ${ENV_FILE}"
  log "  2. sudo chmod 600 ${ENV_FILE}"
  log "  3. sudo \$EDITOR ${ENV_FILE}            # fill in real secrets"
  log "  4. sudo systemctl enable --now symphony"
  log "  5. sudo systemctl status symphony"
}

main() {
  require_root
  require_user
  step_apt
  step_mise
  step_clone
  step_build
  step_env
  step_unit
  step_summary
}

main "$@"
