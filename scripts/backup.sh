#!/usr/bin/env bash
#
# Backup the WordPress multisite + MySQL stack: a consistent DB dump plus a full
# webroot archive (includes wp-content AND .htaccess / root customizations),
# with local retention pruning and an optional offsite copy.
#
# Schedule with cron, e.g. nightly at 03:00:
#   0 3 * * * /path/to/wp-home-stack/scripts/backup.sh >> /var/log/wp-backup.log 2>&1
#
# IMPORTANT: this is now the ONLY copy of your site. Configure the offsite step
# (section 4) so a dead disk / lost machine doesn't lose everything.

set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${STACK_DIR}/backups"
COMPOSE="docker compose -f ${STACK_DIR}/docker-compose.yml"
DB_SERVICE="db"
RETENTION_DAYS=14
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Load MYSQL_* values from .env.
set -a
# shellcheck disable=SC1091
source "${STACK_DIR}/.env"
set +a

mkdir -p "${BACKUP_DIR}"
echo "[$(date)] Starting backup ${TIMESTAMP}"

# 1. Database dump. --single-transaction = consistent InnoDB snapshot, no lock.
#    Password passed via MYSQL_PWD (env) so it stays out of the process list.
${COMPOSE} exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "${DB_SERVICE}" \
  mysqldump --single-transaction --quick --routines --triggers \
  -u root "${MYSQL_DATABASE}" \
  | gzip > "${BACKUP_DIR}/db-${TIMESTAMP}.sql.gz"

# 2. Full webroot (wp-content, .htaccess, core, any root files).
tar -czf "${BACKUP_DIR}/webroot-${TIMESTAMP}.tar.gz" -C "${STACK_DIR}" wordpress

# 3. Prune local backups older than the retention window.
find "${BACKUP_DIR}" -type f -name '*.gz' -mtime "+${RETENTION_DAYS}" -delete

# 4. OPTIONAL offsite copy. Strongly recommended. Configure an rclone remote
#    once (rclone config) pointing at Backblaze B2, S3, etc., then uncomment:
# rclone copy "${BACKUP_DIR}" remote:my-wp-backups --max-age 25h

echo "[$(date)] Backup complete: db-${TIMESTAMP}.sql.gz, webroot-${TIMESTAMP}.tar.gz"
