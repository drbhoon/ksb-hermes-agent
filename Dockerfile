FROM python:3.12-slim

# Install Node.js 20, nginx, and system tools in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends \
    nodejs nginx gettext-base tini apache2-utils git \
    && rm -rf /var/lib/apt/lists/*

# Clone the official NousResearch source
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /opt/hermes-src

WORKDIR /opt/hermes-src

# Build the React/Vite frontend
# vite.config.ts sets outDir: "../hermes_cli/web_dist" so assets land at
# /opt/hermes-src/hermes_cli/web_dist/ — the same dir HERMES_WEB_DIST will point to.
ENV npm_config_install_links=false
RUN npm install --prefer-offline --no-audit
RUN cd web && npm install --prefer-offline --no-audit && npm run build

# Fail the build immediately if the frontend assets are missing
RUN test -f /opt/hermes-src/hermes_cli/web_dist/index.html \
    || (echo "ERROR: hermes_cli/web_dist/index.html not found — Vite build did not produce output" && exit 1)

# Build the terminal TUI (required for embedded in-browser chat sessions)
RUN cd ui-tui && npm install --prefer-offline --no-audit && npm run build
RUN test -f /opt/hermes-src/ui-tui/dist/entry.js \
    || (echo "ERROR: ui-tui/dist/entry.js not found — TUI build failed" && exit 1)

# Install Python package from local source
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir ".[all]"

COPY start.sh /start.sh
COPY nginx.conf.template /etc/nginx/nginx.conf.template

RUN chmod +x /start.sh

ENV HERMES_HOME=/data
ENV PORT=8080
# Point hermes at the Vite-built frontend (matches official image pattern)
ENV HERMES_WEB_DIST=/opt/hermes-src/hermes_cli/web_dist
# Point hermes at the built TUI entry point (pip installs to site-packages, not source dir)
ENV HERMES_TUI_DIR=/opt/hermes-src/ui-tui

WORKDIR /

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/start.sh"]
