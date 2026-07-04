#!/usr/bin/env bash
set -euo pipefail

runtime_owner() {
  local runtime_group
  runtime_group="${OPENCLAW_RUNTIME_GROUP:-${OPENCLAW_RUNTIME_GID:-$(id -g node)}}"
  printf 'node:%s' "$runtime_group"
}

sync_node_identity() {
  local desired_uid desired_gid current_uid current_gid existing_user existing_group

  desired_uid="${OPENCLAW_RUNTIME_UID:-${OPENCLAW_NODE_UID:-}}"
  desired_gid="${OPENCLAW_RUNTIME_GID:-${OPENCLAW_NODE_GID:-}}"

  current_uid="$(id -u node)"
  current_gid="$(id -g node)"

  if [[ -n "$desired_gid" && "$desired_gid" != "$current_gid" ]]; then
    existing_group="$(getent group "$desired_gid" | cut -d: -f1 || true)"
    if [[ -n "$existing_group" && "$existing_group" != "node" ]]; then
      usermod -g "$existing_group" node
    else
      groupmod -g "$desired_gid" node
    fi
  fi

  if [[ -n "$desired_uid" && "$desired_uid" != "$current_uid" ]]; then
    existing_user="$(getent passwd "$desired_uid" | cut -d: -f1 || true)"
    if [[ -n "$existing_user" && "$existing_user" != "node" ]]; then
      echo "refusing to remap node to uid ${desired_uid}: already used by ${existing_user}" >&2
      exit 1
    fi
    usermod -u "$desired_uid" node
  fi
}

fix_node_home_ownership() {
  local gid
  gid="$(id -g node)"
  chown node:"$gid" /home/node
  install -d -o node -g "$gid" \
    /home/node/.cache \
    /home/node/.cache/go-build \
    /home/node/.config \
    /home/node/.config/go \
    /home/node/.local \
    /home/node/.local/bin \
    /home/node/go \
    /home/node/go/bin
}

setup_node_ssh_dir() {
  local owner
  owner="$(runtime_owner)"
  mkdir -p /home/node/.ssh
  chown "$owner" /home/node/.ssh
  chmod 700 /home/node/.ssh

  for key in /home/node/.ssh/id_*; do
    [ -e "$key" ] || continue
    case "$key" in
      *.pub) chmod 644 "$key" ;;
      *) chmod 600 "$key" ;;
    esac
    chown "$owner" "$key"
  done

  if [ -f /home/node/.ssh/authorized_keys ]; then
    chown "$owner" /home/node/.ssh/authorized_keys
    chmod 600 /home/node/.ssh/authorized_keys
  fi

  if [ -f /home/node/.ssh/known_hosts ]; then
    chown "$owner" /home/node/.ssh/known_hosts
    chmod 644 /home/node/.ssh/known_hosts
  fi

  if [ -f /home/node/.ssh/config ]; then
    chown "$owner" /home/node/.ssh/config
    chmod 600 /home/node/.ssh/config
  fi
}

setup_git_credentials() {
  local owner
  owner="$(runtime_owner)"

  if [ -f /home/node/.git-credentials ]; then
    chown "$owner" /home/node/.git-credentials
    chmod 600 /home/node/.git-credentials
  fi
}

ensure_group_for_gid() {
  local gid="$1"
  local name="$2"
  local existing
  existing="$(getent group "$gid" | cut -d: -f1 || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return
  fi
  if getent group "$name" >/dev/null; then
    name="${name}${gid}"
  fi
  groupadd -g "$gid" "$name"
  echo "$name"
}

setup_device_groups() {
  local path gid group_name
  for path in /dev/dri/renderD* /dev/dri/card*; do
    [ -e "$path" ] || continue
    gid="$(stat -c '%g' "$path")"
    group_name="$(ensure_group_for_gid "$gid" "hostdev${gid}")"
    usermod -aG "$group_name" node
  done
}

setup_shared_group() {
  local gid="${OPENCLAW_SHARED_GID:-}"
  local name="${OPENCLAW_SHARED_GROUP:-evp}"
  local group_name

  [ -n "$gid" ] || return 0
  case "$gid" in
    *[!0-9]*)
      echo "ignoring invalid OPENCLAW_SHARED_GID: $gid" >&2
      return 0
      ;;
  esac

  group_name="$(ensure_group_for_gid "$gid" "$name")"
  usermod -aG "$group_name" node
}

setup_sshd_host_keys() {
  local key_dir="${OPENCLAW_SSHD_HOST_KEYS_DIR:-/home/node/.openclaw/sshd-host-keys}"
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"

  local key_type
  for key_type in rsa ecdsa ed25519; do
    local key_path="$key_dir/ssh_host_${key_type}_key"
    if [ ! -f "$key_path" ]; then
      ssh-keygen -q -N "" -t "$key_type" -f "$key_path"
    fi
    chown root:root "$key_path" "$key_path.pub"
    chmod 600 "$key_path"
    chmod 644 "$key_path.pub"
    ln -sf "$key_path" "/etc/ssh/ssh_host_${key_type}_key"
    ln -sf "$key_path.pub" "/etc/ssh/ssh_host_${key_type}_key.pub"
  done
}

start_sshd() {
  mkdir -p /run/sshd
  setup_node_ssh_dir
  setup_sshd_host_keys
  /usr/sbin/sshd -D -e &
}

if [ "$(id -u)" = "0" ]; then
  sync_node_identity
  fix_node_home_ownership
  setup_shared_group
  setup_device_groups
  setup_git_credentials
  if [ "${OPENCLAW_ENABLE_SSHD:-1}" != "0" ]; then
    start_sshd
  fi
  exec gosu "$(runtime_owner)" "$@"
fi

exec "$@"
