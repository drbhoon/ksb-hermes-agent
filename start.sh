#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"
HERMES_HOME="${HERMES_HOME:-/data}"
HERMES_PASSWORD="${HERMES_PASSWORD:?HERMES_PASSWORD env var is required}"

# Resolve the installed web_dist path so hermes can find the built frontend.
# Vite outputs to hermes_cli/web_dist/ which pip packages into site-packages.
export HERMES_WEB_DIST
HERMES_WEB_DIST=$(python3 -c "import hermes_cli, os; print(os.path.join(os.path.dirname(hermes_cli.__file__), 'web_dist'))")
echo "HERMES_WEB_DIST=${HERMES_WEB_DIST}"

# Ensure data directory exists and is writable
mkdir -p "${HERMES_HOME}"

# Generate htpasswd file for nginx basic auth
HTPASSWD_FILE="/etc/nginx/.htpasswd"
htpasswd -bc "${HTPASSWD_FILE}" hermes "${HERMES_PASSWORD}"
echo "Auth credentials written to ${HTPASSWD_FILE}"

# Substitute PORT into nginx config
export PORT
envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Remove default nginx site if present
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Start hermes gateway in the background
echo "Starting hermes gateway..."
hermes gateway run &
GATEWAY_PID=$!

# Wait for gateway to be ready (it binds a local socket/port)
sleep 3

# Start hermes dashboard on localhost:9119 in the background
# Binding to 127.0.0.1 means --insecure is NOT needed
echo "Starting hermes dashboard on localhost:9119..."
hermes dashboard --host 127.0.0.1 --no-open &
DASHBOARD_PID=$!

# Give the dashboard time to initialise before nginx starts accepting traffic
sleep 5

# Trap signals to clean up child processes on container stop
cleanup() {
    echo "Shutting down..."
    kill "${DASHBOARD_PID}" "${GATEWAY_PID}" 2>/dev/null || true
    nginx -s quit 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT

# Start nginx in the foreground — this keeps the container alive
echo "Starting nginx on 0.0.0.0:${PORT}..."
nginx -g "daemon off;"
