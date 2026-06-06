# Telegram Channel Setup

This deployment does not require `TELEGRAM_BOT_TOKEN` in Docker Compose. Use a token file under the existing OpenClaw auth mount instead.

## Paths

- Deployment directory: `/home/xcd/ai-agent/openclaw-deploy`
- Host token file: `/home/xcd/.openclaw-docker/auth/telegram-bot-token`
- Container token file: `/home/node/.config/openclaw/telegram-bot-token`

The host auth directory is already mounted into the container:

```text
/home/xcd/.openclaw-docker/auth -> /home/node/.config/openclaw
```

## 1. Create A Telegram Bot

1. Open Telegram.
2. Chat with `@BotFather`.
3. Run `/newbot`.
4. Choose a bot name and a bot username ending in `bot`.
5. Copy the bot token.

For direct messages, open a chat with the new bot and send `/start`.

## 2. Store The Token On The Host

Run this on the server as user `xcd`:

```bash
install -d -m 700 /home/xcd/.openclaw-docker/auth

read -rsp 'Telegram bot token: ' TELEGRAM_BOT_TOKEN
printf '\n'

printf '%s\n' "$TELEGRAM_BOT_TOKEN" > /home/xcd/.openclaw-docker/auth/telegram-bot-token
chmod 600 /home/xcd/.openclaw-docker/auth/telegram-bot-token
unset TELEGRAM_BOT_TOKEN
```

## 3. Add The Telegram Channel

Run:

```bash
docker exec openclaw-openclaw-gateway-1 \
  openclaw channels add \
  --channel telegram \
  --token-file /home/node/.config/openclaw/telegram-bot-token
```

Then restart the gateway:

```bash
cd /home/xcd/ai-agent/openclaw-deploy

docker compose \
  --env-file /home/xcd/.openclaw-docker/env/openclaw.env \
  -f compose.openclaw.yml \
  restart openclaw-gateway
```

## 4. Verify

```bash
docker exec openclaw-openclaw-gateway-1 \
  openclaw channels status --channel telegram --probe

docker exec openclaw-openclaw-gateway-1 \
  openclaw channels logs --channel telegram --lines 100
```

Telegram uses polling by default, so no public webhook or public server port is required.

## 5. Pair Your Telegram DM

The default Telegram DM policy is `pairing`. After sending a message to the bot, OpenClaw may create a pairing request.

List pending requests:

```bash
docker exec openclaw-openclaw-gateway-1 \
  openclaw pairing list --channel telegram
```

Approve a request:

```bash
docker exec openclaw-openclaw-gateway-1 \
  openclaw pairing approve --channel telegram <pairing-code> --notify
```

After approval, send another message to the bot.

## Troubleshooting

Check service health:

```bash
curl -fsS http://127.0.0.1:18789/healthz
```

Check configured channels:

```bash
docker exec openclaw-openclaw-gateway-1 openclaw channels list
docker exec openclaw-openclaw-gateway-1 openclaw channels status --probe
```

If the token changes, update the host token file and restart the gateway.
