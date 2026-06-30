# krispharper.com

A single `docker compose` stack on the home server that runs a WordPress
multisite network, its MySQL database, and a set of self-hosted home services
(media server, request/stats tools, network-wide DNS, backups, and a
VPN-routed media indexing/download group). Everything is reached from the
internet through a Cloudflare Tunnel, so the home network exposes **no inbound
ports** and there are no TLS certificates to manage locally.

```
internet -> Cloudflare edge -> (outbound tunnel) -> cloudflared -> services
                                                    (home server, one stack)
```

## Hosts

* `192.168.1.102` — home server; runs this entire `docker compose` stack.
* `192.168.1.101` — NAS; runs its own DSM admin UI (the `nas.krispharper.com` target). Not part of the compose stack.

## Services

**Web**

* `wordpress` + `db` — WordPress multisite + MySQL.
* `cloudflared` — the Cloudflare Tunnel daemon (locally-managed).

**VPN group** — `vpn` (Private Internet Access, `nl-amsterdam`) plus the
services that share its network namespace via `network_mode: "service:vpn"`, so
all of their outbound traffic exits through the VPN:

* `transmission` — download client.
* `sonarr` / `radarr` — media library managers.
* `jackett` — indexer proxy.
* `agregarr` — indexer aggregator companion.
* `flaresolverr` — solves anti-bot challenges on behalf of `jackett`.

**Standalone** (on the `internal` Docker network):

* `plex` — media server.
* `tautulli` — Plex statistics.
* `overseerr` — media request portal.
* `plex-meta-manager` — batch metadata tool (connects to `plex:32400`).
* `crashplan` — backup agent.
* `pihole` — network-wide DNS (LAN ports `53` and `8080`).

## Domains

WordPress multisite serves several sites, including `krispharper.com`.

Service subdomains under `krispharper.com`: `nas`, `plex`, `overseerr`,
`tautulli`, `sonarr`, `radarr`, `transmission`, `jackett`, `agregarr`,
`crashplan`, `pi-hole`.

## Setup

**1. Create the tunnel** (the image runs as UID 65532, so pre-own the dir):

```bash
mkdir -p cloudflared
sudo chown -R 65532:65532 cloudflared
docker run -it --rm -v "$PWD/cloudflared:/home/nonroot/.cloudflared" \
  cloudflare/cloudflared:latest tunnel login
docker run --rm -v "$PWD/cloudflared:/home/nonroot/.cloudflared" \
  cloudflare/cloudflared:latest tunnel create krispharper.com
```

Then `cp cloudflared/config.yml.example cloudflared/config.yml` and paste the
tunnel UUID into the `tunnel:` and `credentials-file:` lines.

**2. Configure secrets:** `cp .env.example .env` and fill it in.

**3. Ensure host mounts exist:** `/media/Poseidon` and `/data` must be mounted
on the host before the stack starts (if `/media/Poseidon` is a network mount,
add a `systemd` mount dependency).

**4. Start:**

```bash
docker compose up -d
docker compose logs -f cloudflared    # expect "Registered tunnel connection"
```

## Operations

* Backups: `scripts/backup.sh` dumps the WordPress DB + webroot (schedule via
  cron). Service configs under `/data` and `/media/Poseidon/Data` and media
  under `/media/Poseidon` are covered separately by CrashPlan.
* Logs: `docker compose logs -f <service>`.
* Reach a VPN-group service for debugging (from a sibling in the namespace):
  `docker compose exec sonarr wget -qO- http://localhost:9117/`.

## Files

* `docker-compose.yml` — the full stack (16 services).
* `cloudflared/config.yml.example` — tunnel identity + per-hostname ingress map.
* `config/uploads.ini` — PHP upload limits.
* `scripts/backup.sh` — WordPress DB + webroot backup.
* `CLAUDE.md` — architecture invariants, gotchas, and conventions for AI assistants.
* `.gitignore` — keeps secrets, credentials, backups, and the webroot out of git.
