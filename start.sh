#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
HERMES_HOME="${HERMES_HOME:-/data}"
HERMES_PASSWORD="${HERMES_PASSWORD:?HERMES_PASSWORD env var is required}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY env var is required}"
INSTALL_DIR="/opt/hermes-src"

# ── Safety: disable browser automation tools ─────────────────────────────────
# Prevents Hermes from launching Playwright/Chromium browser sessions
export HERMES_DISABLE_BROWSER_TOOLS=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_BROWSERS_PATH=/dev/null

# ── Enable embedded in-browser chat (PTY terminal) ────────────────────────────
# Activates the /api/pty WebSocket endpoint so the Sessions page can start chats
export HERMES_DASHBOARD_TUI=1
# Ensure hermes finds the built ui-tui entry point (pip installs to site-packages)
export HERMES_TUI_DIR="${HERMES_TUI_DIR:-/opt/hermes-src/ui-tui}"

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

# CRITICAL: cli-config.yaml.example ships with
#   base_url: "https://openrouter.ai/api/v1"
# which gets carried over when we copy the template on first boot. With
# provider=anthropic + base_url=openrouter, hermes ships Anthropic model
# names to OpenRouter, gets 404s, and dumps the HTML page into the chat.
#
# We MUST remove base_url entirely for provider=anthropic. Hermes uses
# the official `anthropic.Anthropic(...)` Python SDK, which appends its
# own `/v1/messages` path internally. The SDK's built-in default base
# is "https://api.anthropic.com" — so any value we set here either
# (a) points to the wrong host (OpenRouter), or (b) duplicates a path
# segment. Setting `https://api.anthropic.com/v1` produces the disastrous
# `https://api.anthropic.com/v1/v1/messages` → 404 not_found_error.
#
# Letting the SDK use its own default is the correct, safe path.
if cfg['model']['provider'] == 'anthropic':
    cfg['model'].pop('base_url', None)

with open(config_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

print(f"Config written: provider={cfg['model']['provider']} "
      f"model={cfg['model']['default']} "
      f"base_url={cfg['model'].get('base_url', '<default>')}")
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
# Bind to 0.0.0.0 + --insecure so hermes treats this as a "public bind". This
# disables both the Host-header DNS-rebinding guard AND the per-WebSocket
# IP allowlist check (_ws_client_is_allowed). Both checks return False
# *before* ws.accept(), and Starlette converts pre-accept WS rejections
# into HTTP 403 — which is the "403 0" we kept seeing in the access log.
#
# This is safe because the only port exposed to the outside world is the
# nginx port (PORT). Port 9119 stays inside the container; binding it to
# 0.0.0.0 only opens it on the container's loopback + container-internal
# interfaces, not on the public network. nginx in front still enforces
# HTTP Basic Auth on all non-WS routes.
echo "Starting hermes dashboard on 0.0.0.0:9119..."
hermes dashboard --host 0.0.0.0 --no-open --insecure 2>&1 &
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
