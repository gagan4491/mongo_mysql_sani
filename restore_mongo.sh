#!/usr/bin/env bash
set -euo pipefail

# ── Settings ──────────────────────────────────────────────────────
BACKUP_DIR="/mongo/dump_mongodb"
DATA_DIR="/var/lib/mongodb"
LOG_FILE="/var/log/mongodb/mongod.log"

SERVICE_NAME="mongod"
MONGO_USER="mongod"
MONGO_GROUP="mongod"
MONGO_SHELL="mongo"
MONGO_HOST="127.0.0.1"
MONGO_PORT="27017"

# ── Validate before deleting anything ─────────────────────────────
[[ "$EUID" -eq 0 ]] || {
  echo "Run this script as root."
  exit 1
}

for cmd in rsync systemctl "$MONGO_SHELL"; do
  command -v "$cmd" >/dev/null || {
    echo "Required command not found: $cmd"
    exit 1
  }
done

[[ -d "$BACKUP_DIR" && -d "$DATA_DIR" ]] || {
  echo "Backup and data directories must already exist."
  exit 1
}

BACKUP_DIR="$(realpath "$BACKUP_DIR")"
DATA_DIR="$(realpath "$DATA_DIR")"

[[ "$DATA_DIR" != "/" &&
   "$BACKUP_DIR" != "$DATA_DIR" &&
   "$BACKUP_DIR" != "$DATA_DIR/"* &&
   "$DATA_DIR" != "$BACKUP_DIR/"* ]] || {
  echo "Unsafe paths: directories must be separate and cannot overlap."
  exit 1
}

[[ -n "$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo "Backup directory is empty."
  exit 1
}

# ── Stop MongoDB and restore files ────────────────────────────────
systemctl stop "$SERVICE_NAME"

echo "Deleting existing files in $DATA_DIR"
find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

rsync -aH --info=progress2 \
  "$BACKUP_DIR/" \
  "$DATA_DIR/"

chown -R "$MONGO_USER:$MONGO_GROUP" "$DATA_DIR"
chmod 750 "$DATA_DIR"

# ── Start MongoDB ────────────────────────────────────────────────
systemctl start "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager
tail -n 80 "$LOG_FILE"

# Wait up to 60 seconds for MongoDB.
READY=false
for ((attempt = 1; attempt <= 60; attempt++)); do
  if "$MONGO_SHELL" --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" \
    --eval 'quit(db.adminCommand({ping: 1}).ok === 1 ? 0 : 1)' \
    >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 1
done

[[ "$READY" == true ]] || {
  echo "MongoDB did not become ready within 60 seconds."
  exit 1
}

# ── Remove replica-set metadata ───────────────────────────────────
"$MONGO_SHELL" --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" <<'MONGO'
var localDB = db.getSiblingDB("local");

localDB.replset.minvalid.drop();
localDB.replset.oplogTruncateAfterPoint.drop();
localDB.replset.election.drop();

localDB.system.replset.remove({});
localDB.system.replset_backup.drop();
localDB.oplog.rs.drop();

print("Replica configurations remaining: " +
      localDB.system.replset.find().count());
MONGO

echo "Restore and replica metadata cleanup completed."