FROM python:3.12-slim

# Install system dependencies: nginx, gettext (envsubst), tini, apache2-utils (htpasswd)
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    gettext-base \
    tini \
    apache2-utils \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install hermes-agent directly from the official NousResearch GitHub source
# (not published to PyPI — must install from git)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "git+https://github.com/NousResearch/hermes-agent.git[all]"

# Copy runtime files
COPY start.sh /start.sh
COPY nginx.conf.template /etc/nginx/nginx.conf.template

RUN chmod +x /start.sh

# Hermes data directory (mapped to Railway volume)
ENV HERMES_HOME=/data
ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/start.sh"]
