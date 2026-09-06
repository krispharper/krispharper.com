# CLAUDE.md

Context and operating rules for AI assistants working in this repository.

## What this is

A single `docker compose` stack (`docker-compose.yml`, 16 services) on the home
server `192.168.1.102`. It runs WordPress multisite + MySQL and a set of home
services, all exposed via a locally-managed Cloudflare Tunnel. No inbound WAN
ports; TLS terminates at Cloudflare's edge. The NAS at `192.168.1.101` is a
separate box (only its DSM UI is exposed, as `nas.krispharper.com`).

## Architecture invariants — do not break these

* **VPN namespace.** `transmission`, `sonarr`, `radarr`, `jackett`, `agregarr`,
  and `flaresolverr` use `network_mode: "service:vpn"` — they share the `vpn`
  container's network stack so their outbound traffic exits through the VPN.
  Such services **cannot** declare their own `ports:` or `networks:` keys; port
  publishing (if ever needed) goes on the `vpn` service. Never give one of these
  its own network "to make it reachable" — that defeats the VPN routing.
* **Same-namespace addressing.** Services in the VPN namespace reach each other
  over **`localhost`** (e.g. `jackett` -> FlareSolverr at
  `http://localhost:8191`). Anything outside the namespace (including
  `cloudflared`) reaches them via the **`vpn`** name and the service's port
  (e.g. `http://vpn:9117` for jackett). This is why the tunnel ingress targets
  `vpn:<port>` for these and why FlareSolverr's URL in jackett's config is
  `localhost`, not `flaresolverr`.
* **Per-service UID/GID are intentionally non-uniform — do not normalize:**
    * `sonarr`, `radarr`, `jackett`, `transmission`, `overseerr`: PUID/USERID
      `1026`, PGID/GROUPID `100`.
    * `plex`: `PLEX_UID 1026`, `PLEX_GID 1000`.
    * `tautulli`: PUID `1026`, PGID `1000`.
    * `crashplan`: `USER_ID 1026`.
* **WordPress config is authoritative.** A real `wp-config.php` exists in the
  bind-mounted webroot, so the official image will not regenerate it and the
  `WORDPRESS_*` env vars are inert. Multisite constants, `DB_HOST = 'db'`, and
  the `X-Forwarded-Proto` HTTPS-trust block all live in that file. Do not pin
  `WP_HOME`/`WP_SITEURL` (it collapses multisite onto one domain).
* **Two databases, named for their engines.** `db` is WordPress's MySQL and
  `postgres` is kadm's. Do not rename either to something role-shaped: the
  kadm container's `KADM_DATABASE_URL` resolves the host `postgres` by service
  name, and WordPress's `wp-config.php` hard-codes `DB_HOST = 'db'`.
* **`kadm` must never publish a port and must always have a Cloudflare Access
  application.** It is a collection of personal apps -- finances, crosswords, and
  more over time -- sharing one Postgres database with a schema per app. It holds
  every account balance, transaction and tax return, and has no login page of its
  own -- Access is the whole of its authentication. The
  app fails closed (it refuses requests without a verified Access JWT, and
  refuses outright when `KADM_CF_ACCESS_AUD` is unset), so a missing Access app
  locks you out rather than exposing the data. A published port would be the one
  way to reach it unauthenticated.
* **`kadm` holds a read-write `/media/Poseidon` mount and runs as `1026:100`.**
  Its media app renames movie directories, writes `poster.jpg` and deletes
  rejected files, so unlike crashplan's read-only copy of the same share this
  one has to be writable. The `user:` line is not cosmetic: the image has no
  `USER` directive, the NAS squashes root, and a root-owned write there fails or
  lands as `nobody` — the same trap `scripts/backup.sh` runs as `kris` to avoid.
  1026:100 is what sonarr, radarr and transmission already write as, so renamed
  files keep the ownership the rest of the stack expects. It also mounts
  `/data/kadm-media` for contact sheets and subtitle strips, which sits outside
  `/media/Poseidon` deliberately: those regenerate from the films, and CrashPlan
  would otherwise store disposable images offsite forever. **kadm still stays on
  `internal` and still publishes no port** — it reaches Radarr and Transmission
  at `vpn:<port>` exactly as `cloudflared` does, and giving it
  `network_mode: "service:vpn"` would take away both its Access route and its
  Postgres connection.
* **`kadm` mounts the films twice, and the second mount is load-bearing.**
  `radarr` mounts them as `/media/Poseidon/Movies:/movies`, so every path its
  API reports is `/movies/...` — and kadm opens those paths verbatim. With only
  the `/media/Poseidon` mount, every analysis failed with "No such file or
  directory" on a file that was plainly there, just under a name that container
  could not see. `- /media/Poseidon/Movies:/movies` matches Radarr's namespace,
  which is the convention the whole *arr stack follows for this reason. If you
  ever change Radarr's movie mount, change kadm's to match, and extend
  `KADM_MEDIA_MAC_PATHS` so the "open in VLC" path keeps resolving.
* **Host mounts.** `/media/Poseidon` (media + several configs) and `/data`
  (configs for sonarr/radarr/overseerr/plex/agregarr) must be mounted on the
  host before the stack starts.
* **CrashPlan only sees `/media/Poseidon`.** That is its single read-only mount,
  so it covers media and the service configs that live on the NAS -- and it does
  **not** cover `/data` (both database data directories, plus sonarr/radarr/
  overseerr/plex/agregarr configs) or `/var/www/html` (the webroot). Anything
  outside `/media/Poseidon` is backed up only by `scripts/backup.sh`, which is
  why that script writes to the NAS rather than to local disk: the destination is
  what pulls the dumps into CrashPlan's set. Do not "tidy" the backup path onto
  the local disk.

## Tunnel ingress targets

**The tunnel is remotely managed: the ingress map lives in the Cloudflare
dashboard, not in this repo.** cloudflared pulls it down at startup and logs
`Updated to new configuration ... version=N`. The local `cloudflared/config.yml`
is read for the tunnel identity and credentials, and its `ingress:` block is
ignored -- so editing it changes nothing, and an unrouted hostname falls through
to the remote config's `http_status:404` catch-all, which presents as the target
service being broken.

Proof, if it is ever in doubt: the running config carries an
`originRequest.httpHostHeader` on `jackett` and a second `crashplan` entry
pointing at `https://crashplan.krispharper.com:443`. Neither appears in
`config/config.yml`, which has drifted and is kept only as a readable record of
intent.

Add or change a hostname under **Networks > Tunnels > (tunnel) > Configure >
Public Hostname**. `docker compose run --rm cloudflared ... ingress rule <url>`
validates the *local file* only and will happily confirm a rule the daemon has
never seen. Source of truth for what hostname maps to
what:

* WordPress domains -> `http://wordpress:80`
* `nas` -> `http://192.168.1.101:5000` (the NAS box; not a container)
* `plex` -> `http://plex:32400`, `overseerr` -> `:5055`, `tautulli` -> `:8181`
  (bridged compose services)
* `sonarr` -> `http://vpn:8989`, `radarr` -> `http://vpn:7878`,
  `transmission` -> `http://vpn:9091`, `jackett` -> `http://vpn:9117`,
  `agregarr` -> `http://vpn:7171` (via the VPN namespace)
* `crashplan` -> `http://crashplan:5800`, `pi-hole` -> `http://pihole:80`
* `kadm` -> `http://kadm:8000` (bridged compose service)

`cloudflared` runs with an explicit `--config /home/nonroot/.cloudflared/config.yml`
because auto-discovery is unreliable in the distroless image.

## DNS model

* Each served hostname is a **proxied CNAME -> `<UUID>.cfargotunnel.com`** in its
  Cloudflare zone. Tunnel UUID: `fd3ffcf5-3523-45f9-95a3-49fde4c20599`.

## Secrets

In `.env` (gitignored): `MYSQL_*`, `VPN_USERNAME`, `VPN_PASSWORD`, `PLEX_CLAIM`,
`PI_HOLE_PASSWORD`, `KADM_*`.

The media app adds `KADM_RADARR_API_KEY`, `KADM_TMDB_API_KEY`, and optionally
`KADM_TRANSMISSION_USERNAME` / `KADM_TRANSMISSION_PASSWORD`,
`KADM_OPENSUBTITLES_API_KEY` and `KADM_MEDIA_MAC_PATHS`.

`KADM_MEDIA_MAC_PATHS` is display text for the client, not a server path — it
maps the prefix kadm sees onto the prefix the machine you browse from uses, so
the review page can print something you can paste into VLC. It belongs in `.env`
because it describes a particular Mac rather than this host, and nothing on the
server mounts or reads those paths. Radarr mounts the films at `/movies`, so
that is the prefix to map: `KADM_MEDIA_MAC_PATHS={"/movies": "/Volumes/Movies"}`.
Leaving it unset just hides the "On the Mac" line. The first two are not optional in practice: without
the Radarr key the media app's endpoints answer 503 naming the missing setting,
and without the TMDB key no artwork appears at all, because Apple's iTunes Search
API stopped returning movie results and TMDB is now the only working source.

`KADM_SECRET_KEY` encrypts the New York Times session cookie kadm stores for the
crossword app. It must stay out of the database: `/data/postgres` is dumped nightly
to the NAS and picked up by CrashPlan, so a plaintext cookie in a table would put a
live NYT login in offsite backups. Unset, kadm refuses to store the cookie rather
than storing it unencrypted. Rotating it invalidates the stored cookie, which then
has to be pasted again—not a failure, but not silent either. Also keep `jackett`'s `ServerConfig.json` (API key + admin
hash, under `/media/Poseidon/Data`) out of version control.

## Backups

`scripts/backup.sh` dumps MySQL, Postgres and the webroot to
`/media/Poseidon/Data/backups`, nightly from `kris`'s crontab at 08:00 UTC
(03:00 Chicago; the host clock is UTC). Retention is 30 days for the databases
and 14 for the webroot. `scripts/backup.sh --status` reports the newest backup of
each component and exits non-zero if one is stale or missing.

Things in it that look incidental and are not:

* **It runs as `kris`, not root.** The NAS squashes root, so a root-owned write
  there fails or lands as `nobody`. `sudo` is used only to *read* the webroot --
  `sudo tar -czf -` with the shell doing the redirect, so tar never writes to the
  NAS as root.
* **Databases are dumped through their containers**, never copied from `/data`.
  A file-level copy of a live database is a copy of a half-written one.
* **It refuses to run when the NAS is unmounted.** `/media/Poseidon/Data` is a
  plain local directory when the share is not mounted, so writing there would put
  the backups on the same disk as the databases and still report success. The
  check asks whether NFS is *among* the mounts on that path, because autofs holds
  the mountpoint and the NFS mount is stacked on top -- `findmnt` returns both.
* **`pg_restore` cannot read a `-Fc` archive from a pipe.** Fed one on stdin it
  says "did not find magic string in file header", which reads as a corrupt dump
  and is not one. The script verifies by copying the dump back into the container.
* **The webroot is `/var/www/html`**, a host bind mount, not a directory inside
  the checkout. An earlier version of this script tarred `${STACK_DIR}/wordpress`,
  which does not exist, so every run would have failed at that step -- and since
  the script had never been scheduled, nothing surfaced it.

## Gotchas learned the hard way

* **Stale local DNS during changes.** Pi-hole is in the LAN resolution path and
  will serve old records after a DNS change. Always verify with `dig @1.1.1.1`
  (authoritative), never a plain `dig` from inside the network — a plain `dig`
  caused a long false diagnosis once.
* **`tunnel route dns` writes into the cert's zone.** If `cert.pem` is authorized
  for the wrong zone, the command silently appends that zone to the name (e.g.
  creating `krispharper.com.krispharper.us`) instead of erroring. Use a cert for
  the correct zone, or add cross-zone records manually in the dashboard.
* **`tunnel route dns` conflicts** with an existing record (it errors); delete
  the old record first. `--overwrite-dns` is unreliable, don't depend on it.
* **arr URL base.** sonarr/radarr/jackett must have their URL base set to `/`
  (root); a leftover base path breaks per-hostname routing.
* **FlareSolverr exit IP.** It must share the VPN namespace with jackett so the
  anti-bot clearance is solved and replayed from the same exit IP; otherwise
  jackett reports "cookies not valid."
* **Redirect Rule values:** watch for trailing whitespace in the hostname Value
  fields — `http.host eq "example.com "` never matches.
* **301 vs 302:** browsers cache 301 hard. Use 302 while testing redirects;
  switch to 301 only once confirmed.
* **Cloudflare 100MB** request-body cap applies to WordPress uploads;
  `config/uploads.ini` sets PHP to 64M to stay under it.

## Common commands

```bash
docker compose up -d                      # full stack
docker compose up -d db wordpress cloudflared   # web path only
docker compose logs -f <service>
scripts/backup.sh                         # both databases + webroot -> NAS
scripts/backup.sh --status                # is anything stale or missing?
# debug a VPN-group service from a sibling in the namespace:
docker compose exec sonarr wget -S --spider http://localhost:9117/ 2>&1 | head
```

## Conventions

* **Git:** two remotes — `upstream` (original) and `github` (fork). Push and open
  PRs against `github` unless told otherwise. Commit messages in past tense.
  Branches named `feature/some_feature_name`. Create PRs via the API first, then
  open with `gh pr view --web`; never run `gh pr create` more than once.
* **Markdown:** bulleted lists use `*` (not `-`); put a blank line between a
  header and its content; em dashes have no surrounding spaces—like this.
* **Compose:** preserve each service's existing UID/GID, volume paths, and
  network mode exactly; these were taken from the original service definitions
  and several are deliberately inconsistent across services.
