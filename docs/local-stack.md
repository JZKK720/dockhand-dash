# Running Dockhand locally (Docker + pgvector)

Run Dockhand on this machine as containers, backed by a pgvector-capable
Postgres. The app is the **official upstream image** — there is no local build,
so a Windows checkout can never corrupt the container entrypoint, and updates
are a plain `docker pull`.

## What it runs

| Service | Image | Source | Host port |
| --- | --- | --- | --- |
| dockhand (app) | `fnsys/dockhand:latest` | Docker Hub (upstream publish) | `4131` → container `3000` |
| database | `pgvector/pgvector:pg16` | Docker Hub (pgvector official) | `5432` |

Both images are pulled from public registries. Nothing is built locally.

## Prerequisites

- Docker Desktop (or any Docker Engine) running.
- The compose file mounts `/var/run/docker.sock` so Dockhand can manage the
  Docker engine. On Docker Desktop (Windows/macOS) this works out of the box.

## Commands

```bash
# Start (uses the cached image; fast, offline-friendly)
bash scripts/local-stack-up.sh

# Start and first refresh to the newest upstream release
bash scripts/local-stack-up.sh --pull

# Stop (keeps data volumes)
bash scripts/local-stack-down.sh

# Stop and delete the Postgres + app data volumes
bash scripts/local-stack-down.sh --volumes
```

Or drive compose directly:

```bash
docker compose -f docker-compose.local.yaml up -d
docker compose -f docker-compose.local.yaml pull   # future updates
docker compose -f docker-compose.local.yaml down
```

Once up:

- UI: <http://localhost:4131>
- DB health: <http://localhost:4131/api/health/database>

## Updating

```bash
docker compose -f docker-compose.local.yaml pull
docker compose -f docker-compose.local.yaml up -d
```

To pin a specific release instead of tracking `latest`, change the image tag in
`docker-compose.local.yaml`, e.g. `fnsys/dockhand:v1.0.57`.

## About pgvector

`pgvector/pgvector:pg16` is plain `postgres:16` with the `vector` extension
compiled in, so the database is **vector-ready**. The stock upstream app does
not create or query a vector column on its own, so swapping in this image does
not by itself enable semantic search — it just future-proofs the data layer.

## Security

The app binds to `0.0.0.0:4131` with authentication disabled (it logs a warning
about this). For a single-machine setup that is usually fine behind the OS
firewall. To tighten it:

- Bind to localhost only — change the app port mapping to
  `"127.0.0.1:4131:3000"` (and `"127.0.0.1:5432:5432"` for Postgres) in
  `docker-compose.local.yaml`, then re-run the up script.
- Or enable authentication in the app (Settings → Authentication).

Also change `POSTGRES_PASSWORD` / `DATABASE_URL` from the default `changeme`
before exposing this beyond your machine.
