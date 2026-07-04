#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${OPENCLAW_ENV_FILE:-${ROOT_DIR}/.env}"

usage() {
  cat <<'EOF'
Usage: bootstrap-startup.sh [start|status|stop|restart|recreate|rebuild]

Commands:
  start      Start services without rebuilding, then run phase-1 middleware init.
  status     Show compose service status.
  stop       Stop compose services.
  restart    Restart compose services.
  recreate   Recreate compose services without rebuilding, then run phase-1 middleware init.
  rebuild    Rebuild images, recreate services, then run phase-1 middleware init.
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

ensure_host_dirs() {
  : "${OPENCLAW_CONFIG_DIR_HOST:=${HOME}/.openclaw-docker/state}"
  : "${OPENCLAW_WORKSPACE_DIR_HOST:=${HOME}/ai-agent}"
  : "${OPENCLAW_AUTH_PROFILE_SECRET_DIR_HOST:=${HOME}/.openclaw-docker/auth}"
  : "${OPENCLAW_SSH_DIR_HOST:=${HOME}/.openclaw-docker/ssh}"
  : "${OPENCLAW_GIT_CREDENTIALS_FILE_HOST:=${HOME}/.openclaw-docker/git-credentials}"
  : "${OPENCLAW_VSCODE_SERVER_DIR_HOST:=${HOME}/.openclaw-docker/vscode-server}"
  : "${OPENCLAW_VSCODE_CODEX_DIR_HOST:=${HOME}/.openclaw-docker/vscode-codex}"

  mkdir -p \
    "$OPENCLAW_CONFIG_DIR_HOST" \
    "$OPENCLAW_WORKSPACE_DIR_HOST" \
    "$(dirname "$OPENCLAW_GIT_CREDENTIALS_FILE_HOST")" \
    "$OPENCLAW_VSCODE_SERVER_DIR_HOST" \
    "$OPENCLAW_VSCODE_CODEX_DIR_HOST"
  install -d -m 700 \
    "$OPENCLAW_AUTH_PROFILE_SECRET_DIR_HOST" \
    "$OPENCLAW_SSH_DIR_HOST"
  if [[ ! -e "$OPENCLAW_GIT_CREDENTIALS_FILE_HOST" ]]; then
    install -m 600 /dev/null "$OPENCLAW_GIT_CREDENTIALS_FILE_HOST"
  else
    chmod 600 "$OPENCLAW_GIT_CREDENTIALS_FILE_HOST"
  fi

  export OPENCLAW_CONFIG_DIR_HOST
  export OPENCLAW_WORKSPACE_DIR_HOST
  export OPENCLAW_AUTH_PROFILE_SECRET_DIR_HOST
  export OPENCLAW_SSH_DIR_HOST
  export OPENCLAW_GIT_CREDENTIALS_FILE_HOST
  export OPENCLAW_VSCODE_SERVER_DIR_HOST
  export OPENCLAW_VSCODE_CODEX_DIR_HOST
}

ensure_middleware_rabbitmq_permissions() {
  local rabbitmq_data_dir="${ROOT_DIR}/middleware/rabbitmq/data"

  if [[ ! -d "$rabbitmq_data_dir" ]]; then
    return 0
  fi

  if [[ ! -e "$rabbitmq_data_dir/.erlang.cookie" ]]; then
    return 0
  fi

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

prepare_business_env() {
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

  : "${OPENCLAW_REDIS_URL:=redis://redis:6379/${OPENCLAW_REDIS_DB}}"

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
  export OPENCLAW_REDIS_URL
}

prepare_runtime_identity() {
  : "${OPENCLAW_NODE_UID:=$(id -u)}"
  : "${OPENCLAW_NODE_GID:=$(id -g)}"
  : "${OPENCLAW_RUNTIME_UID:=${OPENCLAW_NODE_UID}}"
  : "${OPENCLAW_RUNTIME_GID:=${OPENCLAW_NODE_GID}}"
  : "${OPENCLAW_SHARED_GROUP:=evp}"

  if [[ -z "${OPENCLAW_SHARED_GID:-}" && -n "$OPENCLAW_SHARED_GROUP" ]]; then
    OPENCLAW_SHARED_GID="$(getent group "$OPENCLAW_SHARED_GROUP" | cut -d: -f3 || true)"
  fi

  export OPENCLAW_NODE_UID
  export OPENCLAW_NODE_GID
  export OPENCLAW_RUNTIME_UID
  export OPENCLAW_RUNTIME_GID
  export OPENCLAW_SHARED_GROUP
  export OPENCLAW_SHARED_GID
}

compose_cmd() {
  docker compose \
    --env-file "$ENV_FILE" \
    -f "${ROOT_DIR}/compose.openclaw.gpu.yml" \
    -f "${ROOT_DIR}/compose.openclaw.dri.yml" \
    -f "${ROOT_DIR}/compose.openclaw.yml" \
    "$@"
}

prepare_env() {
  load_env_file
  ensure_host_dirs
  prepare_business_env
  prepare_runtime_identity
}

run_phase1_init() {
  OPENCLAW_ENV_FILE="$ENV_FILE" bash "${ROOT_DIR}/init-phase1-middleware.sh"
}

main() {
  local command="${1:-start}"

  case "$command" in
    start)
      prepare_env
      ensure_middleware_rabbitmq_permissions
      compose_cmd up -d --no-build
      run_phase1_init
      ;;
    status)
      prepare_env
      compose_cmd ps
      ;;
    stop)
      prepare_env
      compose_cmd stop
      ;;
    restart)
      prepare_env
      compose_cmd restart
      ;;
    recreate)
      prepare_env
      ensure_middleware_rabbitmq_permissions
      compose_cmd up -d --no-build --force-recreate
      run_phase1_init
      ;;
    rebuild)
      prepare_env
      ensure_middleware_rabbitmq_permissions
      compose_cmd up -d --build --force-recreate
      run_phase1_init
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "unknown command: $command" >&2
      usage >&2
      exit 2
      ;;
  esac

}

main "$@"
