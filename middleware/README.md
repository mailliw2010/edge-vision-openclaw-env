# Middleware Layout

This directory keeps the middleware stack together:

- `compose.openclaw.middleware.yml`: compose file for PostgreSQL, MinIO, RabbitMQ, Redis, and ZLMediaKit
- `postgres/postgresql.conf`: PostgreSQL server settings copied from the official image sample
- `postgres/pg_hba.conf`: PostgreSQL host-based auth copied from the official initdb output and adjusted for OpenClaw access
- `postgres/data`: PostgreSQL data directory
- `minio/minio.env`: MinIO runtime configuration
- `minio/data`: MinIO object data
- `minio/config`: MinIO config/state
- `rabbitmq/conf.d/10-defaults.conf`: RabbitMQ configuration
- `rabbitmq/enabled_plugins`: RabbitMQ plugin list
- `rabbitmq/data`: RabbitMQ data directory
- `redis/redis.conf`: Redis configuration
- `redis/data`: Redis append-only data
- `zlmediakit/config.ini`: ZLMediaKit config file

The middleware stack shares the `openclaw-shared` Docker network with the
business stack, but it uses its own Compose project name so `up` and `down`
stay isolated.

The root [`../.env`](../.env) is the only environment file. Compose reads it
from the host via `--env-file`, and `init-phase1-middleware.sh` also loads the
same file before bootstrapping PostgreSQL, MinIO, and RabbitMQ. The bootstrap
script uses the running `postgres` container plus a temporary `minio/mc`
container, so the host does not need local `psql` or `mc` installations.

If the shared network does not exist yet, create it once:

```bash
docker network create openclaw-shared
```

Start it from this directory so the relative bind mounts resolve correctly:

```bash
cd "${HOME}/ai-agent/openclaw-deploy/middleware"

docker compose \
  -f compose.openclaw.middleware.yml \
  up -d
```

If you want the full host-side orchestration flow, run
[`../bootstrap-startup.sh`](../bootstrap-startup.sh) from the repository root
instead of invoking middleware directly.
