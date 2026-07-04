# OpenClaw Docker Deployment

This directory contains the Docker image and Compose files for running OpenClaw as a reusable development container.

The container is designed to be disposable. Persistent state is mounted from the host:

- OpenClaw state: `${OPENCLAW_CONFIG_DIR}`
- Workspace: `${OPENCLAW_WORKSPACE_DIR}`
- OpenClaw auth profile secrets: `${OPENCLAW_AUTH_PROFILE_SECRET_DIR}`
- SSH keys/config: `${OPENCLAW_SSH_DIR:-${HOME}/.openclaw-docker/ssh}`
- Git credentials store: `${OPENCLAW_GIT_CREDENTIALS_FILE_HOST:-${HOME}/.openclaw-docker/git-credentials}`
- Codex config and profiles: `${OPENCLAW_VSCODE_CODEX_DIR:-${HOME}/.openclaw-docker/vscode-codex}`

The gateway container starts as root only long enough to launch `sshd`, align the container `node` UID/GID with the host, add configured supplemental groups such as the shared `evp` Git group, and prepare mounted device/SSH permissions. The OpenClaw process then runs as `node` inside `/home/node`.

## Files

- `Dockerfile.openclaw-npm` builds the OpenClaw/Codex image.
- `Dockerfile.openclaw-evr-dev` builds a combined OpenClaw + edge-vision-runtime dev image.
- `compose.openclaw.yml` starts the normal OpenClaw gateway.
- `middleware/compose.openclaw.middleware.yml` starts PostgreSQL, MinIO, RabbitMQ, Redis, and ZLMediaKit on the same `openclaw` network.
- `compose.openclaw.gpu.yml` adds NVIDIA CUDA/NVDEC passthrough.
- `compose.openclaw.dri.yml` adds `/dev/dri` passthrough for VAAPI/DRI hardware decode.
- `docker-entrypoint.sh` starts `sshd`, prepares SSH permissions, persists SSH host keys, adds shared/device supplemental groups, and drops to `node` inside `/home/node`.
- `bootstrap-startup.sh` is the host-side orchestration entrypoint.
- `init-phase1-middleware.sh` bootstraps control-plane data after middleware is up.

## Prepare SSH Persistence

Run this once on the host:

```bash
mkdir -p "${HOME}/.openclaw-docker/ssh"
chmod 700 "${HOME}/.openclaw-docker/ssh"

cp "${HOME}/.ssh/id_ed25519" "${HOME}/.openclaw-docker/ssh/"
cp "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.openclaw-docker/ssh/"
cp "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.openclaw-docker/ssh/authorized_keys"
cp "${HOME}/.ssh/known_hosts" "${HOME}/.openclaw-docker/ssh/" 2>/dev/null || true

chmod 600 "${HOME}/.openclaw-docker/ssh/id_ed25519"
chmod 644 "${HOME}/.openclaw-docker/ssh/id_ed25519.pub"
chmod 600 "${HOME}/.openclaw-docker/ssh/authorized_keys"
chmod 644 "${HOME}/.openclaw-docker/ssh/known_hosts" 2>/dev/null || true
```

The private key is required for `git pull` over SSH. The `authorized_keys` file is required for SSH login into the container.

If you use `git config --global credential.helper store`, the container now persists
`~/.git-credentials` to `${HOME}/.openclaw-docker/git-credentials` on the host by default.

## Shared Git Permissions

When multiple host users, for example `xcd` and `zwx`, need to push their own
branches into the same bind-mounted local repository, do not switch ownership
back and forth with `chown -R <user>:<user>`. Use a shared group instead.

The default shared group name is `evp`. Create it once on the host and add each
collaborating user:

```bash
sudo groupadd -f evp
sudo usermod -aG evp xcd
sudo usermod -aG evp zwx
```

Each user must log in again, or restart the relevant shell/container session,
before the new group membership is visible:

```bash
id xcd
id zwx
```

Set the shared repository tree to group `evp` and make directories inherit that
group:

```bash
sudo chgrp -R evp /home/xcd/ai-agent/openclaw-deploy/volume
sudo chmod -R g+rwX /home/xcd/ai-agent/openclaw-deploy/volume
sudo find /home/xcd/ai-agent/openclaw-deploy/volume -type d -exec chmod g+s {} +
```

If ACLs are available, add default ACLs so tools that create files with a
restrictive umask still keep group write access:

```bash
sudo setfacl -R -m g:evp:rwx /home/xcd/ai-agent/openclaw-deploy/volume
sudo setfacl -R -d -m g:evp:rwx /home/xcd/ai-agent/openclaw-deploy/volume
```

Configure shared Git repository behavior:

```bash
find /home/xcd/ai-agent/openclaw-deploy/volume -mindepth 2 -maxdepth 2 -name .git -type d -print0 \
  | while IFS= read -r -d '' gitdir; do
      repo="${gitdir%/.git}"
      git --git-dir="$gitdir" config core.sharedRepository group
    done
```

Git also requires each user to explicitly trust a repository owned by another
UID. Add `safe.directory` in each user's own Git global config. Configure the
repository root, not the `.git` subdirectory:

```bash
sudo -u xcd git config --global --add safe.directory /home/xcd/ai-agent/openclaw-deploy/volume/edge-vision-control-plane
sudo -u zwx git config --global --add safe.directory /home/xcd/ai-agent/openclaw-deploy/volume/edge-vision-control-plane
```

Inside containers, use the container path:

```bash
git config --global --add safe.directory /home/node/public/shared/git/edge-vision-control-plane
```

`bootstrap-startup.sh` resolves `OPENCLAW_SHARED_GROUP` to
`OPENCLAW_SHARED_GID` on the host. The default group is `evp`. On container
startup, `docker-entrypoint.sh` creates or reuses that GID inside the container
and adds `node` as a supplemental member. The primary `node` UID/GID still
follows the host user that launched the stack.

Override the shared group only when needed:

```bash
OPENCLAW_SHARED_GROUP=evp ./bootstrap-startup.sh recreate
```

If `docker-entrypoint.sh` changed, use `rebuild` instead of `recreate` so the
new entrypoint is copied into the image:

```bash
./bootstrap-startup.sh rebuild
```

## Fast Model Switch

Use the mounted `CODEX_HOME` directory to keep one Codex profile per provider.
The CLI loads `config.toml` as the default and `--profile <name>` layers
`$CODEX_HOME/<name>.config.toml` on top of it, so switching is a profile change.

Create these files under `${OPENCLAW_CODEX_HOME_DIR:-${HOME}/.openclaw-docker/codex-home}`:

- `config.toml`: default provider, now `aixhan`
- `aixhan.config.toml`: explicit `--profile aixhan` override
- `openai.config.toml`: explicit `--profile openai` override
- `openrouter.config.toml`: explicit `--profile openrouter` override
- `auth.json`: shared auth store for the active `CODEX_HOME`
- `openai.auth.json` and `openrouter.auth.json`: provider-specific auth templates

This repository includes the same layout under [`codex-home/`](./codex-home); copy or
mount that directory into your active `CODEX_HOME` if you want `codex` to pick up
the templates directly.

Example `openai.config.toml`:

```toml
model_provider = "OpenAI"
model = "gpt-5.4-mini"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
env_key = "OPENAI_API_KEY"
requires_openai_auth = true
```

Example `aixhan.config.toml`:

```toml
model_provider = "Aixhan"
model = "gpt-5.4-mini"

[model_providers.Aixhan]
name = "Aixhan"
base_url = "https://api.aixhan.com/v1"
env_key = "AIXHAN_API_KEY"
wire_api = "responses"
requires_openai_auth = true
```

Example `openrouter.config.toml`:

```toml
model_provider = "OpenRouter"
model = "gpt-5.4-mini"

[model_providers.OpenRouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
requires_openai_auth = true
```

Switch at runtime with:

```bash
codex
codex --profile openai
codex --profile aixhan
codex --profile openrouter
```

For OpenClaw-backed sessions, restart the container after changing the active
profile or default `config.toml` so the gateway picks up the new provider.

## Build The Image

Build the image only when `Dockerfile.openclaw-npm`, `Dockerfile.openclaw-evr-dev`, or
`docker-entrypoint.sh` changes.
The development image grants passwordless `sudo` to the `node` user so repo bootstrap scripts can restore apt-level dependencies after container rebuilds.
If you start or build with raw `docker compose` commands, export
`OPENCLAW_NODE_UID="$(id -u)"`, `OPENCLAW_NODE_GID="$(id -g)"`,
`OPENCLAW_SHARED_GROUP`, and `OPENCLAW_SHARED_GID` first.
`bootstrap-startup.sh` now fills these automatically.

When `docker-entrypoint.sh` changes, prefer the host-side wrapper so the image is
rebuilt and the service is recreated in one step:

```bash
./bootstrap-startup.sh rebuild
```

```bash
cd "${HOME}/ai-agent/openclaw-deploy"

OPENCLAW_NODE_UID="$(id -u)" \
OPENCLAW_NODE_GID="$(id -g)" \
OPENCLAW_SHARED_GROUP="${OPENCLAW_SHARED_GROUP:-evp}" \
OPENCLAW_SHARED_GID="$(getent group "${OPENCLAW_SHARED_GROUP:-evp}" | cut -d: -f3)" \
docker compose \
  -f compose.openclaw.yml \
  build openclaw-gateway
```

for quick debug:
```
docker compose build --no-cache --progress=plain openclaw-gateway 2>&1 | tee /tmp/openclaw-build.log
```

By default, `compose.openclaw.yml` now builds `Dockerfile.openclaw-evr-dev` as
`openclaw-evr-dev:2026.5.28`. To build it directly without Compose:

`Dockerfile.openclaw-evr-dev` defaults to
`nvcr.io/nvidia/tensorrt:25.09-py3`, which matches hosts such as
`Driver Version: 580.82.09` / `CUDA Version: 13.0`. Override
`TENSORRT_BASE_IMAGE` only when the host driver is compatible with the selected
CUDA/TensorRT container.

```bash
cd "${HOME}/ai-agent/openclaw-deploy"

docker build \
  -f Dockerfile.openclaw-evr-dev \
  -t openclaw-evr-dev:2026.5.28 \
  --build-arg NODE_UID="$(id -u)" \
  --build-arg NODE_GID="$(id -g)" \
  .
```

Direct `docker build` only sets the image's default `node` UID/GID. The shared
group is a runtime setting passed through Compose as `OPENCLAW_SHARED_GROUP` and
`OPENCLAW_SHARED_GID`; `docker-entrypoint.sh` adds `node` to that supplemental
group when the container starts.

After the build, inspect the incremental layer sizes with:

```bash
docker history --no-trunc openclaw-evr-dev:2026.5.28
docker image inspect openclaw-evr-dev:2026.5.28 --format '{{.Size}}'
```

To build the smaller OpenClaw-only image instead:

```bash
OPENCLAW_IMAGE=openclaw-npm:2026.5.28 \
OPENCLAW_DOCKERFILE=Dockerfile.openclaw-npm \
docker compose \
  -f compose.openclaw.yml \
  build openclaw-gateway
```

After rebuilding and recreating the containers, remove old dangling images:

```bash
docker image prune -f
```

## Production Image Strategy

The current `Dockerfile.openclaw-evr-dev` is a development image. It is based on
the TensorRT/CUDA container and includes build tools, headers, SSH, sudo, and
debug-friendly dependencies. Do not use it directly as the long-term production
runtime image.

For production, prefer a stable runtime base image plus a thin business artifact
layer:

```text
Dockerfile.openclaw-evr-runtime
Dockerfile.openclaw-evr-prod
compose.openclaw.prod.yml
```

The runtime base should change rarely. Keep only the CUDA/TensorRT runtime,
OpenClaw runtime dependencies, media/runtime libraries, certificates, timezone
data, and the unprivileged runtime user. Exclude compilers, `cmake`, `ninja`,
`git`, `openssh-server`, `sudo`, samples, docs, test data, and `*-dev` packages
unless a production process truly needs them.

The production image should then inherit from that runtime base and add only
business artifacts:

```dockerfile
FROM openclaw-evr-runtime:25.09

WORKDIR /app
COPY dist/ /app/
COPY package.json pnpm-lock.yaml /app/
RUN pnpm install --prod --frozen-lockfile

USER node
CMD ["node", "/app/server.js"]
```

If the business service has compiled Go/C++/Node native artifacts, build them in
a separate builder image and copy the final binaries, shared libraries, and
static assets into `Dockerfile.openclaw-evr-prod`. Keep model files, weights,
large media, and generated caches outside the image; mount them as volumes or
fetch them from object storage during deployment.

Production compose files should map only required service ports and should not
enable SSH, broad debug ports, passwordless sudo, or development-only bind
mounts. Keep the dev compose files optimized for debugging and the prod compose
files optimized for repeatable rollout, smaller image size, and tighter runtime
surface.

## Start Normal Container

Use this when you do not need GPU or hardware video decode passthrough.

```bash
cd "${HOME}/ai-agent/openclaw-deploy"

docker compose \
  -f compose.openclaw.yml \
  up -d --no-build --force-recreate
```

SSH into the container:

```bash
ssh -p 2222 node@127.0.0.1
```

Check OpenClaw:

```bash
docker compose -f compose.openclaw.yml exec openclaw-gateway openclaw channels list
```

## Start Middleware

Use this when you want the control-plane storage and media services on the same
Docker network as the OpenClaw services. Business services and middleware now
use different Compose project names, but both attach to the shared
`openclaw-shared` network automatically.

If the shared network does not exist yet, create it once:

```bash
docker network create openclaw-shared
```

```bash
cd "${HOME}/ai-agent/openclaw-deploy/middleware"

docker compose -f compose.openclaw.middleware.yml up -d
```

For a single host-side entrypoint, run `./bootstrap-startup.sh` from the
repository root. It loads the root `.env`, creates the configured host mount
directories, starts middleware, starts the business stack, and then runs
`init-phase1-middleware.sh`.

Supported commands:

```bash
./bootstrap-startup.sh start      # start services without rebuilding, then run phase-1 init
./bootstrap-startup.sh status     # show compose service status
./bootstrap-startup.sh stop       # stop compose services
./bootstrap-startup.sh restart    # restart compose services
./bootstrap-startup.sh recreate   # recreate services without rebuilding, then run phase-1 init
./bootstrap-startup.sh rebuild    # rebuild images, recreate services, then run phase-1 init
```

Use `rebuild` after changing files copied into the image, such as
`docker-entrypoint.sh`. Use `recreate` for Compose/environment changes that do
not require rebuilding the image.

The file exposes these services:

- PostgreSQL on `127.0.0.1:5432`
- MinIO API on `127.0.0.1:9000` and console on `127.0.0.1:9001`
- RabbitMQ AMQP on `127.0.0.1:5672` and management UI on `127.0.0.1:15672`
- Redis on the internal Compose network as `redis:6379`
- ZLMediaKit RTMP on `127.0.0.1:1935`, HTTP on `127.0.0.1:8082`, and RTSP on `127.0.0.1:8555`

Each middleware service keeps its bind-mounted state inside `middleware/<service>/...`.
Key files are:

- `.env`
- `middleware/postgres/postgresql.conf`
- `middleware/postgres/pg_hba.conf`
- `middleware/minio/minio.env`
- `middleware/rabbitmq/conf.d/10-defaults.conf`
- `middleware/rabbitmq/enabled_plugins`
- `middleware/redis/redis.conf`
- `middleware/zlmediakit/config.ini`

## Start With Hardware Decode

Use this for VAAPI/DRI hardware decode through `/dev/dri`.

Host prerequisite:

```bash
ls -l /dev/dri
```

Start:

```bash
cd "${HOME}/ai-agent/openclaw-deploy"

docker compose \
  -f compose.openclaw.yml \
  -f compose.openclaw.dri.yml \
  up -d --no-build --force-recreate
```

Verify inside the container:

```bash
docker compose -f compose.openclaw.yml exec openclaw-gateway ls -l /dev/dri
```

If your app uses FFmpeg or VAAPI tools, install those in the image or your app environment and verify with the relevant command, for example `ffmpeg -hwaccels` or `vainfo`.

## Start With CUDA/NVIDIA

Use this for CUDA, NVIDIA utility access, and NVIDIA video decode/encode capabilities.

Host prerequisites:

```bash
nvidia-smi
docker info | grep -i nvidia
```

Start:

```bash
cd "${HOME}/ai-agent/openclaw-deploy"

docker compose \
  -f compose.openclaw.yml \
  -f compose.openclaw.gpu.yml \
  up -d --no-build --force-recreate
```

Verify inside the container:

```bash
docker compose -f compose.openclaw.yml exec openclaw-gateway nvidia-smi
docker compose -f compose.openclaw.yml exec openclaw-gateway ffmpeg -hide_banner -decoders
docker compose -f compose.openclaw.yml exec openclaw-gateway ffmpeg -hide_banner -encoders
docker compose -f compose.openclaw.yml exec openclaw-gateway gst-inspect-1.0 nvh264dec
```

If `nvidia-smi` fails on the host, it will also fail in Docker. Fix the host NVIDIA driver/runtime first.
On x86 NVIDIA servers, prefer checking `nvh264dec` / `nvh265dec` and FFmpeg `cuvid` / `nvenc`.
Jetson-specific `nvv4l2decoder` / `nvvidconv` are not expected on a normal RTX server image.

## Start With CUDA And Hardware Decode

Use both override files when the app needs NVIDIA CUDA/NVDEC plus `/dev/dri` VAAPI/DRI access.

Host prerequisites:

```bash
nvidia-smi
docker info | grep -i nvidia
ls -l /dev/dri
```

Start:

```bash
cd "${HOME}/ai-agent/openclaw-deploy"

docker compose \
  -f compose.openclaw.yml \
  -f compose.openclaw.gpu.yml \
  -f compose.openclaw.dri.yml \
  up -d --no-build --force-recreate
```

Verify:

```bash
docker compose -f compose.openclaw.yml exec openclaw-gateway nvidia-smi
docker compose -f compose.openclaw.yml exec openclaw-gateway ls -l /dev/dri
docker compose -f compose.openclaw.yml exec openclaw-gateway ffmpeg -hide_banner -hwaccels
docker compose -f compose.openclaw.yml exec openclaw-gateway gst-inspect-1.0 nvh264dec
```

## Stop

Use the same compose file set you used to start the container.

Normal:

```bash
docker compose \
  -f compose.openclaw.yml \
  down
```

CUDA and DRI:

```bash
docker compose \
  -f compose.openclaw.yml \
  -f compose.openclaw.gpu.yml \
  -f compose.openclaw.dri.yml \
  down
```

## Notes

- Root `.env` is the single source of truth for host mounts, business ports, middleware ports, and standard runtime variables.
- `OPENCLAW_TENANT` is normalized to lowercase kebab-case and directly drives the default PostgreSQL database, MinIO bucket, RabbitMQ vhost, and Redis key prefix/DB.
- Standard runtime variables are grouped at the top of `.env`: `LANG`, `TZ`, and proxy variables like `HTTP_PROXY` / `http_proxy`.
- Business variables are grouped in the middle of `.env`: gateway image, bind ports, workspace mounts, and Codex-related paths.
- Middleware variables are grouped at the bottom of `.env`: PostgreSQL, MinIO, RabbitMQ, and ZLMediaKit settings.
- `OPENCLAW_GATEWAY_PORT` defaults to `127.0.0.1:18789`.
- `OPENCLAW_BRIDGE_PORT` defaults to `127.0.0.1:18790`.
- `OPENCLAW_MSTEAMS_PORT` defaults to `127.0.0.1:3978`.
- `OPENCLAW_SSH_PORT` defaults to `127.0.0.1:2222`.
- `OPENCLAW_SSH_DIR_HOST` defaults to `${HOME}/.openclaw-docker/ssh`.
- `OPENCLAW_GIT_CREDENTIALS_FILE_HOST` defaults to `${HOME}/.openclaw-docker/git-credentials`.
- `OPENCLAW_VSCODE_CODEX_DIR_HOST` defaults to `${HOME}/.openclaw-docker/vscode-codex`.
- `OPENCLAW_CODEX_HOME_DIR` defaults to `${HOME}/.openclaw-docker/codex-home`.
- `OPENCLAW_SHARED_GROUP` defaults to `evp`; `bootstrap-startup.sh` resolves it to `OPENCLAW_SHARED_GID`.
- `OPENCLAW_SHARED_GID` can be set explicitly when the shared group cannot be resolved by name on the host.
- `OPENCLAW_REDIS_URL` defaults to `redis://redis:6379/0`.
- `OPENCLAW_REDIS_HOST` defaults to `redis`.
- `OPENCLAW_REDIS_PORT` defaults to `6379`.
- `OPENCLAW_REDIS_DB` defaults to `0`.
- `OPENCLAW_REDIS_PASSWORD` defaults to empty.
- `OPENCLAW_GPUS` defaults to `all`.
- `NVIDIA_DRIVER_CAPABILITIES` defaults to `compute,utility,video`.
- `OPENCLAW_DRI_DEVICE` defaults to `/dev/dri`.
- Do not mount `/var/run/docker.sock` unless the container explicitly needs to control Docker.
- Codex runs with its inner sandbox disabled because Docker is the outer isolation boundary.
