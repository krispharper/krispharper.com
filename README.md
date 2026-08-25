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
* `kadm` + `postgres` — a collection of personal apps + their database. It
  started as finance tracking (accounts, balances, net worth, income, taxes,
  transactions) and now also covers crossword solve times, with more to come;
  each app owns a Postgres schema inside the one `kadm` database. The Postgres
  service is called `postgres` rather than `db`, which WordPress's MySQL already
  holds; with two databases on one stack each is named for its engine.
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
`crashplan`, `pi-hole`, `kadm`.

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

Then `cp config/config.yml cloudflared/config.yml` and paste the tunnel UUID into
the `tunnel:` and `credentials-file:` lines.

**The `ingress:` block in that file is not what routes traffic.** This tunnel is
remotely managed: the real ingress map lives in the Cloudflare dashboard and
cloudflared fetches it at startup, logging `Updated to new configuration`. The
local file supplies the tunnel identity and credentials only. `config/config.yml`
is kept as a readable record of intent and has drifted from what is actually
served, so trust the dashboard, or the log line above.

**2. Configure secrets:** `cp .env.example .env` and fill it in. As well as the
MySQL, VPN, Plex and Pi-hole values, `kadm` needs:

```
KADM_DB_PASSWORD=              # Postgres password for the kadm role
KADM_CF_ACCESS_TEAM_DOMAIN=    # e.g. yourteam.cloudflareaccess.com
KADM_CF_ACCESS_AUD=            # Access application AUD tag for kadm.krispharper.com
KADM_SECRET_KEY=               # encrypts the stored New York Times cookie
```

In the current dashboard: the **team domain** is under Zero Trust > Settings
("Team name and domain"), and the **AUD tag** under Zero Trust > Access controls
> Applications > Configure > Additional settings ("Application Audience (AUD)
Tag").

The AUD is per application, so it must come from the app whose domain is
`kadm.krispharper.com` — an AUD belonging to a different app rejects every
request. Leaving it blank does not open the app up; it makes it refuse
everything.

**3. Ensure host mounts exist:** `/media/Poseidon` and `/data` must be mounted
on the host before the stack starts (if `/media/Poseidon` is a network mount,
add a `systemd` mount dependency).

**4. Start:**

```bash
docker compose up -d
docker compose logs -f cloudflared    # expect "Registered tunnel connection"
```

## Operations

* Deploying `kadm`: `make publish` in the kadm repo, then here
  `docker compose pull kadm && docker compose up -d kadm`. After a deploy that
  changes the schema, `docker compose run --rm kadm alembic upgrade head`.
  Images are tagged with the commit as well as `latest`, so
  `image: krispharper/kadm:<sha>` pins or rolls back.
* Adding a hostname: **in the Cloudflare dashboard**, under Networks > Tunnels >
  (tunnel) > Configure > Public Hostname. The tunnel is remotely managed, so the
  `ingress:` block in `cloudflared/config.yml` is ignored -- editing it does
  nothing and the hostname stays on the catch-all `http_status:404`, which looks
  like the target service failing rather than a missing route. Confirm with
  `docker compose logs cloudflared | grep 'Updated to new configuration'`, which
  prints the ingress actually in force. The hostname also needs a proxied CNAME to
  `fd3ffcf5-3523-45f9-95a3-49fde4c20599.cfargotunnel.com`.
* The image is built for `linux/amd64`. It is produced on an Apple Silicon
  laptop, whose native output would be arm64 and would die here on every start
  with `exec format error` -- the kernel refusing a foreign binary, which looks
  like an application fault and is not one. `make publish` pins the platform and
  the service declares it, so a mismatch fails at pull instead.
* Backups: `scripts/backup.sh`, nightly by cron. See [Backups](#backups).
* Logs: `docker compose logs -f <service>`.
* Reach a VPN-group service for debugging (from a sibling in the namespace):
  `docker compose exec sonarr wget -qO- http://localhost:9117/`.

## Backups

`scripts/backup.sh` covers three things, and runs from `kris`'s crontab at 08:00
UTC (03:00 America/Chicago—the host clock is UTC):

| Component | What | Kept |
|---|---|---|
| `mysql` | WordPress's database, `mysqldump --single-transaction` | 30 days |
| `postgres` | kadm's database, `pg_dump -Fc` | 30 days |
| `webroot` | `/var/www/html`, including `wp-config.php` and `.htaccess` | 14 days |

Both databases are dumped **through their running containers**, so the data
directories under `/data` are never read while an engine has them open. A
file-level copy of a live database is not a backup, it is a copy of whatever
happened to be on disk mid-write.

```bash
scripts/backup.sh            # a full run, ~75s (the webroot tar is most of it)
scripts/backup.sh --status   # newest backup per component; non-zero if any is stale
tail -20 backup.log          # what cron has been doing
```

**Backups are written to the NAS, at `/media/Poseidon/Data/backups`, and that
location is load-bearing.** A backup on the same disk as its source is one disk
failure away from being no backup—and the NAS copy is the only thing that puts
these into CrashPlan's set. CrashPlan mounts `/media/Poseidon` read-only **and
nothing else**: `/data` and `/var/www/html` are in no backup other than this one.

The script refuses to run if the NAS is not mounted, rather than writing to the
local directory underneath the mountpoint. With the share unmounted,
`/media/Poseidon/Data` is an ordinary local directory, so an unguarded run would
quietly put every backup on the same disk as the databases and report success.

### Restoring

Both of these have been tested end to end against a scratch database—row counts
and a balance total matched the live database to the cent. Restore into a scratch
copy first and compare; never straight over a live database.

```bash
# Postgres (kadm). pg_restore cannot read a custom-format archive from a pipe,
# so the file has to go into the container.
CID=$(docker compose ps -q postgres)
docker cp /media/Poseidon/Data/backups/postgres/kadm-<stamp>.dump "$CID:/tmp/r.dump"
docker exec "$CID" createdb -U kadm kadm_restore_test
docker exec "$CID" pg_restore -U kadm -d kadm_restore_test /tmp/r.dump
docker exec "$CID" psql -U kadm -d kadm_restore_test -c 'select count(*) from finances.transaction'
# happy? then: dropdb kadm, createdb kadm, pg_restore into it, and restart kadm.

# MySQL (WordPress).
set -a; source .env; set +a
docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
    mysql -u root -e 'create database wp_restore_test'
gunzip -c /media/Poseidon/Data/backups/mysql/mysql-<stamp>.sql.gz |
    docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
    mysql -u root wp_restore_test
```

The Postgres restore relies on compose creating the `kadm` role from
`KADM_DB_PASSWORD`, since the dump carries one database and not the cluster's
globals. A restore into a fresh volume therefore needs `.env` to be right first.

## Files

* `docker-compose.yml` — the full stack (16 services).
* `config/config.yml` — tunnel identity, plus an ingress map that is **not** in
  force: routing is configured in the Cloudflare dashboard. Copy to
  `cloudflared/config.yml`, which supplies the daemon's identity and credentials.
* `config/uploads.ini` — PHP upload limits.
* `scripts/backup.sh` — nightly backup of both databases and the webroot.
* `CLAUDE.md` — architecture invariants, gotchas, and conventions for AI assistants.
* `.gitignore` — keeps secrets, credentials, backups, and the webroot out of git.
