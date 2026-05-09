# ── Stage 1: build the React/Vite frontend ───────────────────────────────────
FROM node:20-slim AS frontend-builder

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git .

# Replicate the official npm install sequence (root first, then web/)
# npm_config_install_links=false matches the official Dockerfile flag
ENV npm_config_install_links=false
RUN npm install --prefer-offline --no-audit
RUN cd web && npm install --prefer-offline --no-audit

# Build — vite.config.ts sets outDir: "../hermes_cli/web_dist"
# so the compiled assets land at /build/hermes_cli/web_dist/ directly.
# No cp step needed.
RUN cd web && npm run build


# ── Stage 2: Python runtime ───────────────────────────────────────────────────
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    gettext-base \
    tini \
    apache2-utils \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy source tree with built web assets from stage 1
COPY --from=frontend-builder /build /opt/hermes-src

# Install Python package from local source.
# Keep the source tree — HERMES_WEB_DIST points into it directly,
# matching the official Docker image's editable-install pattern.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir /opt/hermes-src

COPY start.sh /start.sh
COPY nginx.conf.template /etc/nginx/nginx.conf.template

RUN chmod +x /start.sh

ENV HERMES_HOME=/data
ENV PORT=8080
# Point hermes at the built frontend assets (Vite outDir → hermes_cli/web_dist)
ENV HERMES_WEB_DIST=/opt/hermes-src/hermes_cli/web_dist

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/start.sh"]
