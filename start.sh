#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
HERMES_HOME="${HERMES_HOME:-/data}"
HERMES_PASSWORD="${HERMES_PASSWORD:?HERMES_PASSWORD env var is required}"
INSTALL_DIR="/opt/hermes-src"

# ── Bootstrap HERMES_HOME (mirrors official entrypoint) ──────────────────────
# Hermes expects this directory structure before it will start
mkdir -p "${HERMES_HOME}"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

if [ ! -f "${HERMES_HOME}/.env" ]; then
    [ -f "${INSTALL_DIR}/.env.example" ] \
        && cp "${INSTALL_DIR}/.env.example" "${HERMES_HOME}/.env" \
        || touch "${HERMES_HOME}/.env"
fi

if [ ! -f "${HERMES_HOME}/config.yaml" ]; then
    [ -f "${INSTALL_DIR}/cli-config.yaml.example" ] \
        && cp "${INSTALL_DIR}/cli-config.yaml.example" "${HERMES_HOME}/config.yaml" \
        || true
fi

# ── nginx basic auth + config ─────────────────────────────────────────────────
HTPASSWD_FILE="/etc/nginx/.htpasswd"
htpasswd -bc "${HTPASSWD_FILE}" hermes "${HERMES_PASSWORD}"
echo "Auth credentials written to ${HTPASSWD_FILE}"

export PORT
envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# ── Start hermes dashboard ────────────────────────────────────────────────────
# Gateway is for messaging platforms (Telegram/Slack/etc.) — not needed here.
# Dashboard binds to 127.0.0.1 so --insecure is never required; nginx handles
# the public-facing auth proxy.
echo "Starting hermes dashboard on 127.0.0.1:9119..."
hermes dashboard --host 127.0.0.1 --no-open 2>&1 &
DASHBOARD_PID=$!

# Wait up to 60 s for the dashboard to open port 9119
echo "Waiting for dashboard to be ready..."
for i in $(seq 1 30); do
    if (echo > /dev/tcp/127.0.0.1/9119) 2>/dev/null; then
        echo "Dashboard ready (${i}s)"
        break
    fi
    if ! kill -0 "${DASHBOARD_PID}" 2>/dev/null; then
        echo "ERROR: hermes dashboard process exited unexpectedly" >&2
        exit 1
    fi
    sleep 2
done

# ── Start nginx in the foreground ─────────────────────────────────────────────
cleanup() {
    echo "Shutting down..."
    kill "${DASHBOARD_PID}" 2>/dev/null || true
    nginx -s quit 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

echo "Starting nginx on 0.0.0.0:${PORT}..."
nginx -g "daemon off;"
