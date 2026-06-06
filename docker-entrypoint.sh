#!/usr/bin/env bash
set -euo pipefail

setup_node_ssh_dir() {
  mkdir -p /home/node/.ssh
  chown node:xcd /home/node/.ssh
  chmod 700 /home/node/.ssh

  for key in /home/node/.ssh/id_*; do
    [ -e "$key" ] || continue
    case "$key" in
      *.pub) chmod 644 "$key" ;;
      *) chmod 600 "$key" ;;
    esac
    chown node:xcd "$key"
  done

  if [ -f /home/node/.ssh/authorized_keys ]; then
    chown node:xcd /home/node/.ssh/authorized_keys
    chmod 600 /home/node/.ssh/authorized_keys
  fi

  if [ -f /home/node/.ssh/known_hosts ]; then
    chown node:xcd /home/node/.ssh/known_hosts
    chmod 644 /home/node/.ssh/known_hosts
  fi

  if [ -f /home/node/.ssh/config ]; then
    chown node:xcd /home/node/.ssh/config
    chmod 600 /home/node/.ssh/config
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
  setup_device_groups
  if [ "${OPENCLAW_ENABLE_SSHD:-1}" != "0" ]; then
    start_sshd
  fi
  exec gosu node:xcd "$@"
fi

exec "$@"
