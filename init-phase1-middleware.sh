#!/usr/bin/env bash
set -euo pipefail
# set -x

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${OPENCLAW_ENV_FILE:-${ROOT_DIR}/.env}"
RESET_RESOURCES=false

usage() {
  cat <<'EOF'
Usage:
  init-phase1-middleware.sh [--reset-resources]

Initializes the phase-1 middleware baseline:
  - PostgreSQL database and role
  - MinIO bucket
  - RabbitMQ vhost, user, and permissions

This is an environment bootstrap step, not an application startup step.
Run it on first setup and again only after middleware is recreated or its
bootstrap credentials/names change.

It also repairs bind-mounted PostgreSQL and RabbitMQ data permissions before
performing the database and bucket bootstrap steps.

By default, existing databases, buckets, vhosts, users, and permissions are
left untouched. Pass --reset-resources to explicitly delete and recreate these
middleware resources.

All settings can be provided via environment variables. The script uses sane
defaults for local dev, but you should override endpoints/credentials to match
your deployment.

The PostgreSQL step runs through the running `postgres` container and the MinIO
step runs inside a temporary `minio/mc` container on the shared Docker
network, so the host does not need local `psql` or `mc` installations.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset-resources)
        RESET_RESOURCES=true
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
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

ensure_middleware_permissions() {
  local postgres_data_dir="${ROOT_DIR}/middleware/postgres/data"
  local rabbitmq_data_dir="${ROOT_DIR}/middleware/rabbitmq/data"
  local shared_group="${OPENCLAW_SHARED_GROUP:-evp}"
  local shared_gid="${OPENCLAW_SHARED_GID:-}"

  if [[ -z "$shared_gid" && -n "$shared_group" ]]; then
    shared_gid="$(getent group "$shared_group" | cut -d: -f3 || true)"
  fi

  if [[ -z "$shared_gid" ]]; then
    echo "unable to resolve shared group GID for middleware data directories" >&2
    exit 1
  fi

  if [[ -d "$postgres_data_dir" ]]; then
    docker run --rm \
      --entrypoint sh \
      -u 0:0 \
      -v "${postgres_data_dir}:/var/lib/postgresql/data" \
      postgres:16-alpine \
      -lc "
        set -eu
        chown -R 70:${shared_gid} /var/lib/postgresql/data
        chmod -R g+rwX /var/lib/postgresql/data
        find /var/lib/postgresql/data -type d -exec chmod g+s '{}' +
      "
  fi

  if [[ -d "$rabbitmq_data_dir" && -e "$rabbitmq_data_dir/.erlang.cookie" ]]; then
    docker run --rm \
      --entrypoint sh \
      -u 0:0 \
      -v "${rabbitmq_data_dir}:/var/lib/rabbitmq" \
      rabbitmq:4-management \
      -lc '
        set -eu
        chown -R 999:999 /var/lib/rabbitmq
        chmod 700 /var/lib/rabbitmq
        chmod 600 /var/lib/rabbitmq/.erlang.cookie
      '
  fi
}

parse_args "$@"
load_env_file
prepare_tenant_env
ensure_middleware_permissions

postgres_host="${OPENCLAW_POSTGRES_HOST:-127.0.0.1}"
postgres_port="${OPENCLAW_POSTGRES_PORT:-127.0.0.1:5432}"
postgres_port="${postgres_port##*:}"
postgres_bootstrap_db="${OPENCLAW_POSTGRES_BOOTSTRAP_DB:-openclaw}"
postgres_db="$OPENCLAW_POSTGRES_DB"
postgres_user="$OPENCLAW_POSTGRES_USER"
postgres_password="$OPENCLAW_POSTGRES_PASSWORD"
postgres_admin_dsn="${OPENCLAW_POSTGRES_ADMIN_DSN:-postgres://${postgres_user}:${postgres_password}@${postgres_host}:${postgres_port}/${postgres_bootstrap_db}?sslmode=disable}"

minio_endpoint="$(trim_trailing_slash "${OPENCLAW_MINIO_ENDPOINT:-http://minio:9000}")"
minio_access_key="${OPENCLAW_MINIO_ROOT_USER:-${MINIO_ROOT_USER:-openclaw}}"
minio_secret_key="${OPENCLAW_MINIO_ROOT_PASSWORD:-${MINIO_ROOT_PASSWORD:-openclaw-minio}}"
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

require_cmd curl
require_cmd docker

require_running_service postgres
require_running_service minio
require_running_service rabbitmq
wait_for_service_health postgres
wait_for_service_health minio
wait_for_service_health rabbitmq

echo "[1/3] initialize PostgreSQL"
if [[ "$RESET_RESOURCES" == "true" ]]; then
  echo "reset requested, dropping PostgreSQL database if it exists: $postgres_db"
  docker exec -i \
    -e PGPASSWORD="$postgres_password" \
    "$(resolve_middleware_container postgres)" psql \
    -h 127.0.0.1 \
    -U "$postgres_user" \
    -d "$postgres_bootstrap_db" \
    -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${postgres_db}'
  AND pid <> pg_backend_pid();

SELECT format('DROP DATABASE %I', '${postgres_db}')
WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname = '${postgres_db}') \gexec
SQL
fi

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
  ELSIF '${RESET_RESOURCES}' = 'true' THEN
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${postgres_user}', '${postgres_password}');
  ELSE
    RAISE NOTICE 'role % already exists, skipping creation', '${postgres_user}';
  END IF;
END
\$\$;

SELECT format('CREATE DATABASE %I OWNER %I', '${postgres_db}', '${postgres_user}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${postgres_db}') \gexec

DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_database WHERE datname = '${postgres_db}') THEN
    RAISE NOTICE 'database % is present', '${postgres_db}';
  END IF;
END
\$\$;
SQL

echo "[2/3] initialize MinIO"
if [[ "$RESET_RESOURCES" == "true" ]]; then
  echo "reset requested, deleting MinIO bucket if it exists: $minio_bucket"
  docker run --rm \
    --network "${OPENCLAW_DOCKER_NETWORK:-openclaw-shared}" \
    -e "MC_HOST_ev=${minio_endpoint/http:\/\//http://${minio_access_key}:${minio_secret_key}@}" \
    minio/mc \
    rb --force "ev/$minio_bucket" >/dev/null 2>/dev/null || true
fi

if docker run --rm \
  --network "${OPENCLAW_DOCKER_NETWORK:-openclaw-shared}" \
  -e "MC_HOST_ev=${minio_endpoint/http:\/\//http://${minio_access_key}:${minio_secret_key}@}" \
  minio/mc \
  stat "ev/$minio_bucket" >/dev/null 2>&1
then
  echo "bucket already exists, skipping creation: $minio_bucket"
else
  docker run --rm \
    --network "${OPENCLAW_DOCKER_NETWORK:-openclaw-shared}" \
    -e "MC_HOST_ev=${minio_endpoint/http:\/\//http://${minio_access_key}:${minio_secret_key}@}" \
    minio/mc \
    mb "ev/$minio_bucket" >/dev/null
fi

echo "[3/3] initialize RabbitMQ"
docker exec -i "$(resolve_middleware_container rabbitmq)" rabbitmqctl set_user_tags "$rabbitmq_admin_user" administrator >/dev/null 2>/dev/null || true

api_auth="${rabbitmq_admin_user}:${rabbitmq_admin_password}"
json_headers=(-H 'content-type: application/json')

rabbitmq_api_get_status() {
  local path="$1"
  curl -sS -o /dev/null -u "$api_auth" "${json_headers[@]}" \
    -w '%{http_code}' \
    "$rabbitmq_api_url$path"
}

rabbitmq_api_put() {
  local path="$1"
  local payload="$2"
  curl -fsS -u "$api_auth" "${json_headers[@]}" -X PUT \
    "$rabbitmq_api_url$path" \
    -d "$payload" >/dev/null 2>/dev/null
}

if [[ "$RESET_RESOURCES" == "true" ]]; then
  echo "reset requested, deleting RabbitMQ vhost and user if they exist: $rabbitmq_vhost / $rabbitmq_user"
  docker exec -i "$(resolve_middleware_container rabbitmq)" rabbitmqctl delete_vhost "$rabbitmq_vhost" >/dev/null 2>/dev/null || true
  docker exec -i "$(resolve_middleware_container rabbitmq)" rabbitmqctl delete_user "$rabbitmq_user" >/dev/null 2>/dev/null || true
  docker exec -i "$(resolve_middleware_container rabbitmq)" rabbitmqctl add_user "$rabbitmq_user" "$rabbitmq_password" >/dev/null
  docker exec -i "$(resolve_middleware_container rabbitmq)" rabbitmqctl set_user_tags "$rabbitmq_user" administrator >/dev/null
fi

vhost_status="$(rabbitmq_api_get_status "/api/vhosts/$rabbitmq_vhost_path" || true)"
if [[ "$vhost_status" == "404" ]]; then
  rabbitmq_api_put "/api/vhosts/$rabbitmq_vhost_path" '{}'
  echo "created RabbitMQ vhost: $rabbitmq_vhost"
elif [[ "$vhost_status" != "200" ]]; then
  echo "[warn] RabbitMQ vhost check failed ($vhost_status); skipping vhost bootstrap"
else
  echo "RabbitMQ vhost already exists, skipping: $rabbitmq_vhost"
fi

user_status="$(rabbitmq_api_get_status "/api/users/$rabbitmq_user" || true)"
if [[ "$user_status" == "404" ]]; then
  rabbitmq_api_put "/api/users/$rabbitmq_user" "{\"password\":\"$rabbitmq_password\",\"tags\":\"\"}"
  echo "created RabbitMQ user: $rabbitmq_user"
elif [[ "$user_status" != "200" ]]; then
  echo "[warn] RabbitMQ user check failed ($user_status); skipping user bootstrap"
else
  echo "RabbitMQ user already exists, skipping: $rabbitmq_user"
fi

perm_status="$(rabbitmq_api_get_status "/api/permissions/$rabbitmq_vhost_path/$rabbitmq_user" || true)"
if [[ "$perm_status" == "404" ]]; then
  rabbitmq_api_put "/api/permissions/$rabbitmq_vhost_path/$rabbitmq_user" '{"configure":".*","write":".*","read":".*"}'
  echo "created RabbitMQ permissions for user: $rabbitmq_user"
elif [[ "$perm_status" != "200" ]]; then
  echo "[warn] RabbitMQ permission check failed ($perm_status); skipping permission bootstrap"
else
  echo "RabbitMQ permissions already exist, skipping: $rabbitmq_user on $rabbitmq_vhost"
fi

echo "middleware initialization complete"
