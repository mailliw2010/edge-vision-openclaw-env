# Middleware Layout

This directory keeps the middleware stack together:

- `middleware/.env`: Compose interpolation and service defaults for middleware
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

If the shared network does not exist yet, create it once:

```bash
docker network create openclaw-shared
```

Start it from this directory so the relative bind mounts resolve correctly:

```bash
cd /home/xcd/ai-agent/openclaw-deploy/middleware

docker compose \
  -f compose.openclaw.middleware.yml \
  up -d
```
