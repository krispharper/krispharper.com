#!/usr/bin/env bash
#
# Back up the home stack: both databases and the WordPress webroot.
#
#   mysql     WordPress's database, via mysqldump --single-transaction
#   postgres  kadm's database, via pg_dump -Fc
#   webroot   /var/www/html, including wp-config.php and .htaccess
#
# Each database is dumped through its running container, so the data directories
# under /data are never read while an engine has them open. A file-level copy of a
# live database is not a backup; it is a copy of whatever was on disk mid-write.
#
# **Backups go to the NAS, not to this box.** Two reasons. A backup on the same
# disk as its source is one disk failure from being no backup -- and the NAS copy
# is the only thing that puts these in CrashPlan's set, because CrashPlan mounts
# /media/Poseidon read-only and nothing else. /data and /var/www/html are not in
# any backup but this one.
#
# Schedule as kris (not root: NFS squashes root, and nothing here needs it):
#
#   0 8 * * * /home/kris/krispharper.com/scripts/backup.sh >> /home/kris/krispharper.com/backup.log 2>&1
#
# The host clock is UTC, so 08:00 is 03:00 in Chicago.
#
#   scripts/backup.sh --status
#
# prints the newest backup of each component and exits non-zero if any is older
# than STALE_HOURS. That guards the failure that has already happened here once: a
# backup script that was correct, committed, and never scheduled, so the answer to
# "are we backed up" was no for months with nothing to indicate it.

set -euo pipefail

# Overridable so the script can be exercised from outside the checkout.
STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BACKUP_ROOT="${BACKUP_ROOT:-/media/Poseidon/Data/backups}"
WEBROOT="${WEBROOT:-/var/www/html}"
DB_RETENTION_DAYS="${DB_RETENTION_DAYS:-30}"
WEBROOT_RETENTION_DAYS="${WEBROOT_RETENTION_DAYS:-14}"
STALE_HOURS="${STALE_HOURS:-48}"

COMPOSE=(docker compose -f "${STACK_DIR}/docker-compose.yml")
COMPONENTS=(mysql postgres webroot)

log()  { echo "[$(date '+%F %T %Z')] $*"; }
fail() { log "FAILED: $*"; exit 1; }

# The destination has to be the NAS mount and not the empty mountpoint underneath
# it. With the share unmounted, /media/Poseidon/Data is an ordinary local
# directory, so an unguarded run would write every backup onto the same disk as
# the databases and report success -- the exact false sense of safety this script
# exists to remove. Listing the parent first triggers the autofs mount.
require_nas() {
    local parent fstype
    parent="$(dirname "${BACKUP_ROOT}")"
    ls "${parent}" >/dev/null 2>&1 || true
    # Several lines come back: autofs holds the mountpoint and the NFS mount is
    # stacked on top of it, so this asks whether NFS is among them rather than
    # what the first one says.
    fstype="$(findmnt -n -o FSTYPE --target "${parent}" 2>/dev/null | paste -sd, - || true)"
    if [[ -n "${ALLOW_LOCAL_DEST:-}" ]]; then
        log "note: ALLOW_LOCAL_DEST set, writing to ${BACKUP_ROOT} (${fstype:-unknown})"
        return
    fi
    [[ "${fstype}" == *nfs* ]] || fail "${parent} is ${fstype:-not mounted}, with no NFS mount. Refusing to write backups to the local disk."
}

newest_of() {
    find "${BACKUP_ROOT}/$1" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null |
        sort -rn | head -1
}

status() {
    local rc=0 now entry age
    now="$(date +%s)"
    for component in "${COMPONENTS[@]}"; do
        entry="$(newest_of "${component}")"
        if [[ -z "${entry}" ]]; then
            echo "${component}: NO BACKUP"
            rc=1
            continue
        fi
        age=$(( (now - ${entry%%.*}) / 3600 ))
        printf '%-9s %3dh old  %s\n' "${component}" "${age}" "${entry#* }"
        (( age <= STALE_HOURS )) || rc=1
    done
    return "${rc}"
}

if [[ "${1:-}" == "--status" ]]; then
    require_nas
    status
    exit $?
fi

[[ -f "${STACK_DIR}/.env" ]] || fail "no ${STACK_DIR}/.env to read the database passwords from"
set -a
# shellcheck disable=SC1091
source "${STACK_DIR}/.env"
set +a

require_nas

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_ROOT}"
# Staged on the destination filesystem so the move into place is a rename, and a
# run that dies half way through leaves nothing that looks like a backup. Pruning
# by age would otherwise eventually treat a truncated dump as the last good one.
WORK="$(mktemp -d "${BACKUP_ROOT}/.work-XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

log "starting ${TIMESTAMP} -> ${BACKUP_ROOT}"

# ---------------------------------------------------------------- mysql
# MYSQL_PWD rather than -p so the password stays out of the process list.
# --single-transaction gives a consistent InnoDB snapshot without locking writers.
mkdir -p "${BACKUP_ROOT}/mysql"
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" db \
    mysqldump --single-transaction --quick --routines --triggers --events \
    -u root "${MYSQL_DATABASE}" | gzip > "${WORK}/mysql.sql.gz"
gzip -t "${WORK}/mysql.sql.gz" || fail "the mysql dump is not a valid gzip file"
mv "${WORK}/mysql.sql.gz" "${BACKUP_ROOT}/mysql/mysql-${TIMESTAMP}.sql.gz"
log "mysql:    $(du -h "${BACKUP_ROOT}/mysql/mysql-${TIMESTAMP}.sql.gz" | cut -f1)"

# ---------------------------------------------------------------- postgres
# -Fc (custom format) rather than plain SQL: it is compressed, it restores
# selectively, and `pg_restore -l` can prove the archive's table of contents is
# readable, which is a real integrity check rather than a gzip checksum.
mkdir -p "${BACKUP_ROOT}/postgres"
"${COMPOSE[@]}" exec -T postgres pg_dump -U kadm -Fc kadm > "${WORK}/kadm.dump"
# Verified by copying it back into the container, because pg_restore cannot read a
# custom-format archive from a pipe -- fed one on stdin it reports "did not find
# magic string in file header", which looks exactly like a corrupt dump and is not.
# The host has no postgres client tools, and taking the image name from the running
# container rather than naming it here keeps this from drifting from the compose file.
pg_cid="$("${COMPOSE[@]}" ps -q postgres)"
[[ -n "${pg_cid}" ]] || fail "the postgres container is not running"
docker cp "${WORK}/kadm.dump" "${pg_cid}:/tmp/verify.dump" >/dev/null
docker exec "${pg_cid}" pg_restore -l /tmp/verify.dump >/dev/null \
    || fail "the postgres dump has no readable table of contents"
docker exec "${pg_cid}" rm -f /tmp/verify.dump
mv "${WORK}/kadm.dump" "${BACKUP_ROOT}/postgres/kadm-${TIMESTAMP}.dump"
log "postgres: $(du -h "${BACKUP_ROOT}/postgres/kadm-${TIMESTAMP}.dump" | cut -f1)"

# ---------------------------------------------------------------- webroot
# sudo reads; the shell writes. tar itself never runs as root against the NAS,
# because the share squashes root and a root-owned write there fails or lands as
# nobody. Exit 1 is tar's "a file changed as we read it", which a live webroot
# will produce and which does not invalidate the archive.
mkdir -p "${BACKUP_ROOT}/webroot"
tar_rc=0
sudo tar -czf - --warning=no-file-changed \
    -C "$(dirname "${WEBROOT}")" "$(basename "${WEBROOT}")" \
    > "${WORK}/webroot.tar.gz" || tar_rc=$?
if (( tar_rc == 1 )); then
    log "webroot:  note -- files changed while being read, archive kept"
elif (( tar_rc != 0 )); then
    fail "tar of ${WEBROOT} exited ${tar_rc}"
fi
gzip -t "${WORK}/webroot.tar.gz" || fail "the webroot archive is not a valid gzip file"
mv "${WORK}/webroot.tar.gz" "${BACKUP_ROOT}/webroot/webroot-${TIMESTAMP}.tar.gz"
log "webroot:  $(du -h "${BACKUP_ROOT}/webroot/webroot-${TIMESTAMP}.tar.gz" | cut -f1)"

# ---------------------------------------------------------------- retention
# The databases are small enough (tens of MB) that a month of dailies is cheap;
# the webroot is a couple of hundred MB an archive, so it keeps a fortnight.
find "${BACKUP_ROOT}/mysql"    -maxdepth 1 -type f -mtime "+${DB_RETENTION_DAYS}"      -delete
find "${BACKUP_ROOT}/postgres" -maxdepth 1 -type f -mtime "+${DB_RETENTION_DAYS}"      -delete
find "${BACKUP_ROOT}/webroot"  -maxdepth 1 -type f -mtime "+${WEBROOT_RETENTION_DAYS}" -delete
# Anything left behind by a run that was killed rather than failed.
find "${BACKUP_ROOT}" -maxdepth 1 -type d -name '.work-*' -mtime +1 -exec rm -rf {} +

date -u '+%FT%TZ' > "${BACKUP_ROOT}/last-success"
log "complete ${TIMESTAMP}"
