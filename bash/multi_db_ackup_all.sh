#!/bin/bash
# Backs up MySQL and PostgreSQL databases

MYSQL_USER="root"
MYSQL_PASS="password"
PG_USER="postgres"
DEST="/backups/$(date +%F)"
mkdir -p "$DEST"
mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASS" --all-databases | gzip > "$DEST/mysql.sql.gz"
sudo -u "$PG_USER" pg_dumpall | gzip > "$DEST/pg.sql.gz"
