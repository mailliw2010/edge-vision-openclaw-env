#!/usr/bin/env bash
set -euo pipefail

NPM_PREFIX="${NPM_PREFIX:-/home/node/.npm-global}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.5.28}"
CODEX_CLI_VERSION="${CODEX_CLI_VERSION:-0.135.0}"
PNPM_VERSION="${PNPM_VERSION:-10.14.0}"

export PATH="${NPM_PREFIX}/bin:${PATH}"

run_install() {
  npm config set prefix "${NPM_PREFIX}"
  npm config set registry "${NPM_REGISTRY}"
  npm install -g \
    "openclaw@${OPENCLAW_VERSION}" \
    "@openai/codex@${CODEX_CLI_VERSION}" \
    "pnpm@${PNPM_VERSION}"
}

if [ "$(id -u)" = "0" ] && command -v gosu >/dev/null 2>&1 && id node >/dev/null 2>&1; then
  exec gosu node:node env \
    PATH="${PATH}" \
    NPM_PREFIX="${NPM_PREFIX}" \
    NPM_REGISTRY="${NPM_REGISTRY}" \
    OPENCLAW_VERSION="${OPENCLAW_VERSION}" \
    CODEX_CLI_VERSION="${CODEX_CLI_VERSION}" \
    PNPM_VERSION="${PNPM_VERSION}" \
    bash -lc '
      set -euo pipefail
      npm config set prefix "$NPM_PREFIX"
      npm config set registry "$NPM_REGISTRY"
      npm install -g \
        "openclaw@${OPENCLAW_VERSION}" \
        "@openai/codex@${CODEX_CLI_VERSION}" \
        "pnpm@${PNPM_VERSION}"
    '
else
  run_install
fi
