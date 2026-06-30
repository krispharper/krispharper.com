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
* **Host mounts.** `/media/Poseidon` (media + several configs) and `/data`
  (configs for sonarr/radarr/overseerr/plex/agregarr) must be mounted on the
  host before the stack starts.

## Tunnel ingress targets

Defined in `cloudflared/config.yml`. Source of truth for what hostname maps to
what:

* WordPress domains -> `http://wordpress:80`
* `nas` -> `http://192.168.1.101:5000` (the NAS box; not a container)
* `plex` -> `http://plex:32400`, `overseerr` -> `:5055`, `tautulli` -> `:8181`
  (bridged compose services)
* `sonarr` -> `http://vpn:8989`, `radarr` -> `http://vpn:7878`,
  `transmission` -> `http://vpn:9091`, `jackett` -> `http://vpn:9117`,
  `agregarr` -> `http://vpn:7171` (via the VPN namespace)
* `crashplan` -> `http://crashplan:5800`, `pi-hole` -> `http://pihole:80`

`cloudflared` runs with an explicit `--config /home/nonroot/.cloudflared/config.yml`
because auto-discovery is unreliable in the distroless image.

## DNS model

* Each served hostname is a **proxied CNAME -> `<UUID>.cfargotunnel.com`** in its
  Cloudflare zone. Tunnel UUID: `fd3ffcf5-3523-45f9-95a3-49fde4c20599`.

## Secrets

In `.env` (gitignored): `MYSQL_*`, `VPN_USERNAME`, `VPN_PASSWORD`, `PLEX_CLAIM`,
`PI_HOLE_PASSWORD`. Also keep `jackett`'s `ServerConfig.json` (API key + admin
hash, under `/media/Poseidon/Data`) out of version control.

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
scripts/backup.sh                         # WordPress DB + webroot
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
