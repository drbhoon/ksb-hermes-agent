#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
HERMES_HOME="${HERMES_HOME:-/data}"
HERMES_PASSWORD="${HERMES_PASSWORD:?HERMES_PASSWORD env var is required}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY env var is required}"
INSTALL_DIR="/opt/hermes-src"

# ── Bootstrap HERMES_HOME ─────────────────────────────────────────────────────
mkdir -p "${HERMES_HOME}"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

# Copy default config template on first boot
if [ ! -f "${HERMES_HOME}/config.yaml" ]; then
    [ -f "${INSTALL_DIR}/cli-config.yaml.example" ] \
        && cp "${INSTALL_DIR}/cli-config.yaml.example" "${HERMES_HOME}/config.yaml" \
        || echo "{}" > "${HERMES_HOME}/config.yaml"
fi

if [ ! -f "${HERMES_HOME}/.env" ]; then
    [ -f "${INSTALL_DIR}/.env.example" ] \
        && cp "${INSTALL_DIR}/.env.example" "${HERMES_HOME}/.env" \
        || touch "${HERMES_HOME}/.env"
fi

# Inject ANTHROPIC_API_KEY into ~/.hermes/.env on every boot so it is
# always in sync with the Railway environment variable.
if grep -q "^ANTHROPIC_API_KEY=" "${HERMES_HOME}/.env" 2>/dev/null; then
    sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}|" "${HERMES_HOME}/.env"
else
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" >> "${HERMES_HOME}/.env"
fi

# ── Pre-configure Anthropic API key + model (skips the setup wizard) ──────────
echo "Pre-configuring hermes with Anthropic provider..."
python3 - <<PYEOF
import yaml, os, sys

config_path = os.path.join(os.environ['HERMES_HOME'], 'config.yaml')
try:
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    cfg = {}

if 'model' not in cfg or not isinstance(cfg.get('model'), dict):
    cfg['model'] = {}

cfg['model']['api_key']  = os.environ['ANTHROPIC_API_KEY']
cfg['model']['default']  = os.environ.get('HERMES_MODEL', 'claude-haiku-4-5-20251001')
cfg['model']['provider'] = os.environ.get('HERMES_INFERENCE_PROVIDER', 'anthropic')

with open(config_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

print(f"Config written: provider={cfg['model']['provider']} model={cfg['model']['default']}")
PYEOF

# ── nginx basic auth + config ─────────────────────────────────────────────────
HTPASSWD_FILE="/etc/nginx/.htpasswd"
htpasswd -bc "${HTPASSWD_FILE}" hermes "${HERMES_PASSWORD}"

export PORT
envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# ── Write gateway allow-all into .env ────────────────────────────────────────
# Without this the gateway denies every user ("No user allowlists configured")
if grep -q "^GATEWAY_ALLOW_ALL_USERS=" "${HERMES_HOME}/.env" 2>/dev/null; then
    sed -i "s|^GATEWAY_ALLOW_ALL_USERS=.*|GATEWAY_ALLOW_ALL_USERS=true|" "${HERMES_HOME}/.env"
else
    echo "GATEWAY_ALLOW_ALL_USERS=true" >> "${HERMES_HOME}/.env"
fi

# ── Start hermes gateway (required for conversations) ────────────────────────
echo "Starting hermes gateway..."
hermes gateway run 2>&1 &
GATEWAY_PID=$!
sleep 3

# ── Start hermes dashboard ────────────────────────────────────────────────────
# --insecure disables hermes' own session-token auth layer so users only
# see the nginx basic-auth prompt (HERMES_PASSWORD). nginx still protects
# all external traffic — --insecure only affects the internal 127.0.0.1 binding.
echo "Starting hermes dashboard on 127.0.0.1:9119..."
hermes dashboard --host 127.0.0.1 --no-open --insecure 2>&1 &
DASHBOARD_PID=$!

# Wait up to 60 s for port 9119 to open
echo "Waiting for dashboard..."
for i in $(seq 1 30); do
    if (echo > /dev/tcp/127.0.0.1/9119) 2>/dev/null; then
        echo "Dashboard ready (${i}x2s)"
        break
    fi
    if ! kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
        echo "ERROR: hermes dashboard exited unexpectedly" >&2
        exit 1
    fi
    sleep 2
done

# ── nginx foreground ──────────────────────────────────────────────────────────
cleanup() {
    kill "${DASHBOARD_PID}" "${GATEWAY_PID}" 2>/dev/null || true
    nginx -s quit 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

echo "Starting nginx on 0.0.0.0:${PORT}..."
nginx -g "daemon off;"
