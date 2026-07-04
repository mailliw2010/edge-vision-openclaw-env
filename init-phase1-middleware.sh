#!/usr/bin/env bash
set -euo pipefail
# set -x

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${OPENCLAW_ENV_FILE:-${ROOT_DIR}/.env}"

usage() {
  cat <<'EOF'
Usage:
  init-phase1-middleware.sh

Initializes the phase-1 middleware baseline:
  - PostgreSQL database and role
  - MinIO bucket
  - RabbitMQ vhost, user, and permissions

This is an environment bootstrap step, not an application startup step.
Run it on first setup and again only after middleware is recreated or its
bootstrap credentials/names change.

All settings can be provided via environment variables. The script uses sane
defaults for local dev, but you should override endpoints/credentials to match
your deployment.

The PostgreSQL step runs through the running `postgres` container and the MinIO
step runs inside a temporary `minio/mc` container on the shared Docker
network, so the host does not need local `psql` or `mc` installations.
EOF
}

load_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "missing env file: $ENV_FILE" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

trim_trailing_slash() {
  local value="$1"
  printf '%s' "${value%/}"
}

normalize_tenant() {
  local value="$1"
  TENANT_VALUE="$value" python3 - <<'PY'
import os
import re

value = os.environ.get("TENANT_VALUE", "default").strip().lower()
value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
print(value or "default")
PY
}

tenant_suffix() {
  local value="$1"
  value="${value//-/_}"
  printf '%s' "$value"
}

redis_db_for_tenant() {
  local tenant_slug="$1"
  local databases="${2:-256}"
  TENANT_SLUG="$tenant_slug" REDIS_DATABASES="$databases" python3 - <<'PY'
import os
import hashlib

tenant = os.environ["TENANT_SLUG"].encode("utf-8")
databases = int(os.environ.get("REDIS_DATABASES", "256"))
if databases <= 0:
    databases = 256
digest = hashlib.sha256(tenant).digest()
value = int.from_bytes(digest[:4], "big") % databases
print(value)
PY
}

prepare_tenant_env() {
  local tenant_value
  local tenant_suffix_value

  tenant_value="$(normalize_tenant "${OPENCLAW_TENANT:-default}")"
  tenant_suffix_value="$(tenant_suffix "$tenant_value")"

  export OPENCLAW_TENANT="$tenant_value"

  : "${OPENCLAW_POSTGRES_DB:=openclaw_${tenant_suffix_value}}"
  : "${OPENCLAW_POSTGRES_USER:=openclaw}"
  : "${OPENCLAW_POSTGRES_PASSWORD:=openclaw}"
  : "${OPENCLAW_MINIO_BUCKET:=openclaw-${tenant_value}}"
  : "${OPENCLAW_RABBITMQ_VHOST:=/openclaw-${tenant_value}}"
  : "${OPENCLAW_RABBITMQ_USER:=openclaw}"
  : "${OPENCLAW_RABBITMQ_PASSWORD:=openclaw-rabbitmq}"
  : "${OPENCLAW_REDIS_DATABASES:=256}"
  : "${OPENCLAW_REDIS_DB:=$(redis_db_for_tenant "$tenant_value" "$OPENCLAW_REDIS_DATABASES")}"
  : "${OPENCLAW_REDIS_KEY_PREFIX:=${tenant_value}:}"

  export OPENCLAW_POSTGRES_DB
  export OPENCLAW_POSTGRES_USER
  export OPENCLAW_POSTGRES_PASSWORD
  export OPENCLAW_MINIO_BUCKET
  export OPENCLAW_RABBITMQ_VHOST
  export OPENCLAW_RABBITMQ_USER
  export OPENCLAW_RABBITMQ_PASSWORD
  export OPENCLAW_REDIS_DATABASES
  export OPENCLAW_REDIS_DB
  export OPENCLAW_REDIS_KEY_PREFIX
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

middleware_project_name() {
  printf '%s' "${OPENCLAW_MIDDLEWARE_PROJECT:-openclaw-middleware}"
}

resolve_middleware_container() {
  local service="$1"
  local project
  local container_id

  project="$(middleware_project_name)"
  container_id="$(
    docker ps \
      --filter "label=com.docker.compose.project=${project}" \
      --filter "label=com.docker.compose.service=${service}" \
      --format '{{.ID}}' \
      | head -n 1
  )"

  if [[ -z "$container_id" ]]; then
    echo "required middleware service is not running: ${service}" >&2
    echo "expected compose project: ${project}" >&2
    echo "start middleware first, or set OPENCLAW_MIDDLEWARE_PROJECT to the running compose project name" >&2
    exit 1
  fi

  printf '%s' "$container_id"
}

require_running_service() {
  local service="$1"
  resolve_middleware_container "$service" >/dev/null
}

wait_for_service_health() {
  local service="$1"
  local container_id
  local status

  container_id="$(resolve_middleware_container "$service")"

  until [[ "${status:-}" == "healthy" || "${status:-}" == "running" ]]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
      echo "middleware service became unavailable: $service ($status)" >&2
      exit 1
    fi
    if [[ "$status" != "healthy" && "$status" != "running" ]]; then
      echo "$service status = $status"
      sleep 1
    fi
  done
}

load_env_file
prepare_tenant_env

postgres_host="${OPENCLAW_POSTGRES_HOST:-127.0.0.1}"
postgres_port="${OPENCLAW_POSTGRES_PORT:-127.0.0.1:5432}"
postgres_port="${postgres_port##*:}"
postgres_bootstrap_db="${OPENCLAW_POSTGRES_BOOTSTRAP_DB:-openclaw}"
postgres_db="$OPENCLAW_POSTGRES_DB"
postgres_user="$OPENCLAW_POSTGRES_USER"
postgres_password="$OPENCLAW_POSTGRES_PASSWORD"
postgres_admin_dsn="${OPENCLAW_POSTGRES_ADMIN_DSN:-postgres://${postgres_user}:${postgres_password}@${postgres_host}:${postgres_port}/${postgres_bootstrap_db}?sslmode=disable}"

minio_endpoint="$(trim_trailing_slash "${OPENCLAW_MINIO_ENDPOINT:-http://minio:9000}")"
minio_access_key="${MINIO_ROOT_USER:-openclaw}"
minio_secret_key="${MINIO_ROOT_PASSWORD:-openclaw-minio}"
minio_bucket="$OPENCLAW_MINIO_BUCKET"

rabbitmq_port="${OPENCLAW_RABBITMQ_MANAGEMENT_PORT:-127.0.0.1:15672}"
rabbitmq_port="${rabbitmq_port##*:}"
rabbitmq_api_url="$(trim_trailing_slash "${OPENCLAW_RABBITMQ_API_URL:-http://${OPENCLAW_RABBITMQ_HOST:-127.0.0.1}:${rabbitmq_port}}")"
rabbitmq_vhost="$OPENCLAW_RABBITMQ_VHOST"
rabbitmq_user="$OPENCLAW_RABBITMQ_USER"
rabbitmq_password="$OPENCLAW_RABBITMQ_PASSWORD"
rabbitmq_admin_user="$rabbitmq_user"
rabbitmq_admin_password="$rabbitmq_password"
rabbitmq_vhost_path="$(
RABBITMQ_VHOST="$rabbitmq_vhost" python3 - <<'PY'
import os
import urllib.parse

print(urllib.parse.quote(os.environ["RABBITMQ_VHOST"], safe=""))
PY
)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

require_cmd curl
require_cmd docker

require_running_service postgres
require_running_service minio
require_running_service rabbitmq
wait_for_service_health postgres
wait_for_service_health minio
wait_for_service_health rabbitmq

echo "[1/3] initialize PostgreSQL"
docker exec -i \
  -e PGPASSWORD="$postgres_password" \
  "$(resolve_middleware_container postgres)" psql \
  -h 127.0.0.1 \
  -U "$postgres_user" \
  -d "$postgres_bootstrap_db" \
  -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${postgres_user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${postgres_user}', '${postgres_password}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${postgres_user}', '${postgres_password}');
  END IF;
END
\$\$;

SELECT format('CREATE DATABASE %I OWNER %I', '${postgres_db}', '${postgres_user}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${postgres_db}') \gexec
SQL

echo "[2/3] initialize MinIO"
docker run --rm \
  --network "${OPENCLAW_DOCKER_NETWORK:-openclaw-shared}" \
  -e "MC_HOST_ev=${minio_endpoint/http:\/\//http://${minio_access_key}:${minio_secret_key}@}" \
  minio/mc \
  mb --ignore-existing "ev/$minio_bucket" >/dev/null

echo "[3/3] initialize RabbitMQ"
docker exec -i "$(resolve_middleware_container rabbitmq)" rabbitmqctl set_user_tags "$rabbitmq_admin_user" administrator >/dev/null 2>/dev/null || true

api_auth="${rabbitmq_admin_user}:${rabbitmq_admin_password}"
json_headers=(-H 'content-type: application/json')

if ! curl -fsS -u "$api_auth" "${json_headers[@]}" -X PUT \
  "$rabbitmq_api_url/api/vhosts/$rabbitmq_vhost_path" >/dev/null 2>/dev/null
then
  echo "[warn] RabbitMQ management API bootstrap skipped or unauthorized; assuming compose already provisioned vhost/user"
else
  curl -fsS -u "$api_auth" "${json_headers[@]}" -X PUT \
    "$rabbitmq_api_url/api/users/$rabbitmq_user" \
    -d "{\"password\":\"$rabbitmq_password\",\"tags\":\"\"}" >/dev/null 2>/dev/null

  curl -fsS -u "$api_auth" "${json_headers[@]}" -X PUT \
    "$rabbitmq_api_url/api/permissions/$rabbitmq_vhost_path/$rabbitmq_user" \
    -d '{"configure":".*","write":".*","read":".*"}' >/dev/null 2>/dev/null
fi

echo "middleware initialization complete"
