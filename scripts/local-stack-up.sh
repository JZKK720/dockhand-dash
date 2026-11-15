#!/usr/bin/env bash
# Bring up the local Dockhand stack (app + Postgres with pgvector).
#
# Usage: scripts/local-stack-up.sh [--pull]
#
# --pull first refreshes the upstream image (fnsys/dockhand:latest) so a plain
# invocation is fast and offline-friendly, while --pull picks up new releases.

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.local.yaml"

if [ "${1:-}" = "--pull" ]; then
	echo "==> Pulling the latest upstream image"
	docker compose -f "$COMPOSE_FILE" pull
fi

echo "==> Starting Postgres (pgvector) and Dockhand"
docker compose -f "$COMPOSE_FILE" up -d

echo "==> Waiting for Postgres to accept connections"
for _ in $(seq 1 60); do
	if docker exec dockhand-postgres pg_isready -U dockhand -d dockhand >/dev/null 2>&1; then
		echo "==> Postgres is ready"
		break
	fi
	sleep 2
done

echo "==> Waiting for the app to answer its health check"
for _ in $(seq 1 60); do
	if curl -fs http://localhost:4131/api/health/database >/dev/null 2>&1; then
		echo "==> Dockhand is up: http://localhost:4131"
		echo "==> Database health: http://localhost:4131/api/health/database"
		exit 0
	fi
	sleep 2
done

echo "!! The app did not become healthy. Recent logs:" >&2
docker compose -f "$COMPOSE_FILE" logs --tail 50 >&2
exit 1