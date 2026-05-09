# ── Stage 1: build the React/Vite frontend ───────────────────────────────────
FROM node:20-slim AS frontend-builder

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone the official source at latest main
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git .

# Install web deps and build (outputs to web/dist/)
RUN npm --prefix web ci --prefer-offline --no-audit \
    && cd web && npm run build

# Place built assets where setuptools package-data expects them
RUN cp -r web/dist hermes_cli/web_dist


# ── Stage 2: Python runtime ───────────────────────────────────────────────────
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    gettext-base \
    tini \
    apache2-utils \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy source tree (with built frontend) from stage 1
COPY --from=frontend-builder /build /opt/hermes-src

# Install Python package from local source so web_dist is included
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir /opt/hermes-src \
    && rm -rf /opt/hermes-src

COPY start.sh /start.sh
COPY nginx.conf.template /etc/nginx/nginx.conf.template

RUN chmod +x /start.sh

ENV HERMES_HOME=/data
ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/start.sh"]
