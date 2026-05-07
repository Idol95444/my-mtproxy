# my-mtproxy

One-command deploy for MTProto proxy with FakeTLS (Caddy + alexbers).

## Quick deploy

```bash
# On a fresh VPS (Ubuntu 22.04+ / Debian 12, root):
git clone git@github.com:YOUR_USERNAME/my-mtproxy.git
cd my-mtproxy
bash deploy.sh
```

The script will ask for:
- **DOMAIN** — your domain with an A-record pointing to this VPS
- **BASE_SECRET** — 32 hex chars (`head -c 16 /dev/urandom | xxd -ps`)
- **AD_TAG** — optional, from @MTProxybot `/newproxy`

## What it does

1. Installs Docker if missing
2. Clones [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy) (stable)
3. Generates `Caddyfile` and `config.py` from templates
4. Starts Caddy (ports 80/443, gets LE certificate)
5. Starts alexbers (port 853, FakeTLS)
6. Prints the ready-to-share FakeTLS link

## Architecture

```
Internet -> :80  -> Caddy (LE cert auto-renewal, HTTP redirect)
         -> :443 -> Caddy (TLS, decoy "OK" page, looks like nginx)
         -> :853 -> alexbers (FakeTLS, grabs cert from Caddy at startup)
```

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | Interactive installer |
| `Caddyfile.template` | Caddy config with `__DOMAIN__` placeholder |
| `config.py.template` | alexbers config with placeholders |
| `docker-compose.yml` | Both services |
| `docs/V4.md` | Full setup guide with troubleshooting |

## Security

**Never commit**: `config.py`, `.env`, `caddy_data/`, `src/` — all in `.gitignore`.

## Full guide

See [docs/V4.md](docs/V4.md) for the complete setup guide with troubleshooting.
