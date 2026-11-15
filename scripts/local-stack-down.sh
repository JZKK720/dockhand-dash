#!/usr/bin/env bash
# Stop the local Dockhand stack.
#
# Usage: scripts/local-stack-down.sh [--volumes]
#
# --volumes also deletes the Postgres and app data volumes.

set -euo pipefail

cd "$(dirname "$0")/.."

ARGS=""
if [ "${1:-}" = "--volumes" ]; then
	ARGS="--volumes"
fi

docker compose -f docker-compose.local.yaml down $ARGS