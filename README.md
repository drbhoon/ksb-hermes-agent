# KSB Assistant — Hermes Agent on Railway

Self-hosted deployment of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) on [Railway](https://railway.app), built directly from the official source.

## Architecture

```
Railway ingress :$PORT
       │
   [nginx]  ← basic auth (HERMES_PASSWORD)
       │
  localhost:9119
    [hermes dashboard]  ← --host 127.0.0.1 (no --insecure flag)
       │
  [hermes gateway run]  ← background process, same container
```

All three processes run inside one container managed by `start.sh`.  
Hermes data is persisted to a Railway volume mounted at `/data`.

---

## Deploy to Railway

### 1. Fork / clone this repo

```bash
git clone https://github.com/drbhoon/ksb-hermes-agent.git
cd ksb-hermes-agent
```

### 2. Create a new Railway project

1. Go to [railway.app](https://railway.app) → **New Project**
2. Choose **Deploy from GitHub repo** → select `drbhoon/ksb-hermes-agent`
3. Railway will detect `railway.toml` and build from the Dockerfile automatically

### 3. Set environment variables

In Railway → your service → **Variables**, add:

| Variable | Value |
|---|---|
| `HERMES_PASSWORD` | A strong password for the web dashboard |
| `HERMES_HOME` | `/data` |
| `ANTHROPIC_API_KEY` | `sk-ant-...` |

`PORT` is injected automatically by Railway.

### 4. Attach a persistent volume

Railway creates the volume automatically from `railway.toml`.  
It mounts at `/data` — this is where Hermes stores all agent data and config.

### 5. Deploy

Click **Deploy** (or push a commit). Railway will:
- Build the Docker image
- Start the container via `/start.sh`
- Run a healthcheck on `/`
- Expose the service publicly once healthy

### 6. Access the dashboard

Open the Railway-provided URL (e.g. `https://ksb-assistant.up.railway.app`).  
You will be prompted for credentials:

- **Username**: `hermes`
- **Password**: the value of `HERMES_PASSWORD`

---

## Local development

```bash
cp .env.example .env
# edit .env with your values

docker build -t ksb-hermes-agent .
docker run --env-file .env -p 8080:8080 -v $(pwd)/data:/data ksb-hermes-agent
```

Open `http://localhost:8080` — username `hermes`, password from your `.env`.

---

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `HERMES_PASSWORD` | Yes | Basic auth password for the dashboard |
| `HERMES_HOME` | Yes | Path to Hermes data dir (set to `/data`) |
| `ANTHROPIC_API_KEY` | Yes | Anthropic API key for Claude models |
| `PORT` | Auto | Injected by Railway (default 8080) |

---

## Notes

- The dashboard binds to `127.0.0.1:9119` internally — the `--insecure` flag is never used
- nginx handles all public-facing traffic with basic auth enforced on every route, including WebSocket upgrades
- Hermes gateway and dashboard are co-located in the same container per Railway's single-service model
