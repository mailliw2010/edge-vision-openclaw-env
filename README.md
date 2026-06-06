# OpenClaw Docker Deployment

This directory contains the Docker image and Compose files for running OpenClaw as a reusable development container.

The container is designed to be disposable. Persistent state is mounted from the host:

- OpenClaw state: `${OPENCLAW_CONFIG_DIR}`
- Workspace: `${OPENCLAW_WORKSPACE_DIR}`
- OpenClaw auth profile secrets: `${OPENCLAW_AUTH_PROFILE_SECRET_DIR}`
- SSH keys/config: `${OPENCLAW_SSH_DIR:-/home/xcd/.openclaw-docker/ssh}`

The gateway container starts as root only long enough to launch `sshd` and prepare mounted device/SSH permissions. The OpenClaw process then runs as `node:xcd`.

## Files

- `Dockerfile.openclaw-npm` builds the OpenClaw/Codex image.
- `compose.openclaw.yml` starts the normal OpenClaw gateway and CLI sidecar.
- `compose.openclaw.gpu.yml` adds NVIDIA CUDA/NVDEC passthrough.
- `compose.openclaw.dri.yml` adds `/dev/dri` passthrough for VAAPI/DRI hardware decode.
- `docker-entrypoint.sh` starts `sshd`, prepares SSH permissions, persists SSH host keys, and drops to `node:xcd`.

## Prepare SSH Persistence

Run this once on the host:

```bash
mkdir -p /home/xcd/.openclaw-docker/ssh
chmod 700 /home/xcd/.openclaw-docker/ssh

cp /home/xcd/.ssh/id_ed25519 /home/xcd/.openclaw-docker/ssh/
cp /home/xcd/.ssh/id_ed25519.pub /home/xcd/.openclaw-docker/ssh/
cp /home/xcd/.ssh/id_ed25519.pub /home/xcd/.openclaw-docker/ssh/authorized_keys
cp /home/xcd/.ssh/known_hosts /home/xcd/.openclaw-docker/ssh/ 2>/dev/null || true

chmod 600 /home/xcd/.openclaw-docker/ssh/id_ed25519
chmod 644 /home/xcd/.openclaw-docker/ssh/id_ed25519.pub
chmod 600 /home/xcd/.openclaw-docker/ssh/authorized_keys
chmod 644 /home/xcd/.openclaw-docker/ssh/known_hosts 2>/dev/null || true
```

The private key is required for `git pull` over SSH. The `authorized_keys` file is required for SSH login into the container.

## Build The Image

Build the image only when `Dockerfile.openclaw-npm` or `docker-entrypoint.sh` changes.

```bash
cd /home/xcd/ai-agent/openclaw-deploy

docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  build openclaw-gateway
```

After rebuilding and recreating the containers, remove old dangling images:

```bash
docker image prune -f
```

## Start Normal Container

Use this when you do not need GPU or hardware video decode passthrough.

```bash
cd /home/xcd/ai-agent/openclaw-deploy

docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  up -d --no-build --force-recreate
```

SSH into the container:

```bash
ssh -p 2222 node@127.0.0.1
```

Check OpenClaw:

```bash
docker exec openclaw-openclaw-gateway-1 openclaw channels list
```

## Start With Hardware Decode

Use this for VAAPI/DRI hardware decode through `/dev/dri`.

Host prerequisite:

```bash
ls -l /dev/dri
```

Start:

```bash
cd /home/xcd/ai-agent/openclaw-deploy

docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  -f compose.openclaw.dri.yml \
  up -d --no-build --force-recreate
```

Verify inside the container:

```bash
docker exec openclaw-openclaw-gateway-1 ls -l /dev/dri
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
cd /home/xcd/ai-agent/openclaw-deploy

docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  -f compose.openclaw.gpu.yml \
  up -d --no-build --force-recreate
```

Verify inside the container:

```bash
docker exec openclaw-openclaw-gateway-1 nvidia-smi
```

If `nvidia-smi` fails on the host, it will also fail in Docker. Fix the host NVIDIA driver/runtime first.

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
cd /home/xcd/ai-agent/openclaw-deploy

docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  -f compose.openclaw.gpu.yml \
  -f compose.openclaw.dri.yml \
  up -d --no-build --force-recreate
```

Verify:

```bash
docker exec openclaw-openclaw-gateway-1 nvidia-smi
docker exec openclaw-openclaw-gateway-1 ls -l /dev/dri
```

## Stop

Use the same compose file set you used to start the container.

Normal:

```bash
docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  down
```

CUDA and DRI:

```bash
docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  -f compose.openclaw.gpu.yml \
  -f compose.openclaw.dri.yml \
  down
```

## Notes

- `OPENCLAW_SSH_PORT` defaults to `127.0.0.1:2222`.
- `OPENCLAW_SSH_DIR` defaults to `/home/xcd/.openclaw-docker/ssh`.
- `OPENCLAW_GPUS` defaults to `all`.
- `NVIDIA_DRIVER_CAPABILITIES` defaults to `compute,utility,video`.
- `OPENCLAW_DRI_DEVICE` defaults to `/dev/dri`.
- Do not mount `/var/run/docker.sock` unless the container explicitly needs to control Docker.
- Codex runs with its inner sandbox disabled because Docker is the outer isolation boundary.
