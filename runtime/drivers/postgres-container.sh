#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-up}"
CONTAINER_NAME="${CONTAINER_NAME:-exeris-community-postgres}"
IMAGE="${IMAGE:-postgres:17-alpine}"
HOST_PORT="${HOST_PORT:-5432}"
DB_NAME="${DB_NAME:-exeris}"
DB_USER="${DB_USER:-exeris}"
DB_PASSWORD="${DB_PASSWORD:-exeris}"
WAIT_SECONDS="${WAIT_SECONDS:-30}"

usage() {
  echo "Usage: $0 [up|down|status|logs]" >&2
  exit 2
}

case "$ACTION" in
  up)
    existing_id="$(docker ps -aq -f "name=^${CONTAINER_NAME}$")"
    if [[ -n "$existing_id" ]]; then
      running_name="$(docker ps --format '{{.Names}}' -f "name=^${CONTAINER_NAME}$")"
      if [[ -n "$running_name" ]]; then
        echo "PostgreSQL container '$CONTAINER_NAME' is already running"
      else
        docker start "$CONTAINER_NAME" >/dev/null
        echo "Started existing PostgreSQL container '$CONTAINER_NAME'"
      fi
    else
      docker run -d \
        --name "$CONTAINER_NAME" \
        -e POSTGRES_DB="$DB_NAME" \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -p "$HOST_PORT:5432" \
        "$IMAGE" >/dev/null
      echo "Created PostgreSQL container '$CONTAINER_NAME' on port $HOST_PORT"
    fi

    deadline=$((SECONDS + WAIT_SECONDS))
    while (( SECONDS < deadline )); do
      if docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        echo "jdbc:postgresql://127.0.0.1:${HOST_PORT}/${DB_NAME}"
        exit 0
      fi
      sleep 1
    done

    echo "Timed out waiting for PostgreSQL container '$CONTAINER_NAME'" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    exit 1
    ;;
  down)
    if docker ps -aq -f "name=^${CONTAINER_NAME}$" | grep -q .; then
      docker rm -f "$CONTAINER_NAME" >/dev/null
      echo "Removed PostgreSQL container '$CONTAINER_NAME'"
    else
      echo "PostgreSQL container '$CONTAINER_NAME' does not exist"
    fi
    ;;
  status)
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' -f "name=^${CONTAINER_NAME}$"
    ;;
  logs)
    docker logs "$CONTAINER_NAME"
    ;;
  *)
    usage
    ;;
esac