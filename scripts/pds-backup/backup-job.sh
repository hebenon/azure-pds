#!/usr/bin/env sh
set -euo pipefail

DATA_DIR=${DATA_DIR:-/data}
WORK_DIR=${WORK_DIR:-/work}
ACCOUNT_NAME=${AZURE_STORAGE_ACCOUNT_NAME:?AZURE_STORAGE_ACCOUNT_NAME is required}
ACCOUNT_KEY=${AZURE_STORAGE_ACCOUNT_KEY:?AZURE_STORAGE_ACCOUNT_KEY is required}
SNAPSHOT_CONTAINER=${SNAPSHOT_CONTAINER:-pds-sqlite}
SNAPSHOT_PREFIX=${SNAPSHOT_PREFIX:-snapshots}
PDS_ID=${PDS_ID:-default}
RETAIN_COUNT=${RETAIN_COUNT:-200}

mkdir -p "$WORK_DIR"

cleanup() {
  rm -rf "$WORK_DIR"/snapshot-* "$WORK_DIR"/archive-*.tar.zst 2>/dev/null || true
}

trap cleanup EXIT INT TERM

snapshot_iteration() {
  TS=$(date -u +"%Y%m%d-%H%M%S")
  STAGING="$WORK_DIR/snapshot-$TS"
  ARCHIVE="$WORK_DIR/archive-$TS.tar.zst"

  rm -rf "$STAGING"
  mkdir -p "$STAGING"

  echo "[backup-job] Creating staging copy of $DATA_DIR"
  tar -C "$DATA_DIR" -cf - . | tar -C "$STAGING" -xf -
  find "$STAGING" -type f \( -name "*.sqlite" -o -name "*.sqlite-wal" -o -name "*.sqlite-shm" \) -delete

  echo "[backup-job] Refreshing SQLite backups"
  find "$DATA_DIR" -type f -name "*.sqlite" | while read -r DB; do
    TARGET="$STAGING${DB#$DATA_DIR}"
    mkdir -p "$(dirname "$TARGET")"
    sqlite3 "$DB" ".backup '$TARGET'"
  done

  echo "[backup-job] Packaging snapshot"
  tar -C "$STAGING" -I "zstd -3" -cf "$ARCHIVE" .

  BLOB_NAME="$SNAPSHOT_PREFIX/$PDS_ID/snap-$TS.tar.zst"
  echo "[backup-job] Uploading $BLOB_NAME"
  az storage blob upload \
    --account-name "$ACCOUNT_NAME" \
    --account-key "$ACCOUNT_KEY" \
    --container-name "$SNAPSHOT_CONTAINER" \
    --name "$BLOB_NAME" \
    --file "$ARCHIVE" \
    --overwrite true >/dev/null

  echo "[backup-job] Enforcing retention (keep last $RETAIN_COUNT)"
  az storage blob list \
    --account-name "$ACCOUNT_NAME" \
    --account-key "$ACCOUNT_KEY" \
    --container-name "$SNAPSHOT_CONTAINER" \
    --prefix "$SNAPSHOT_PREFIX/$PDS_ID/" \
    --query "sort_by(@, &name)[].name" -o tsv |
    awk -v keep="$RETAIN_COUNT" 'NF==0 { next } { lines[NR]=$0 } END { for(i=1;i<=NR-keep;i++){ if(lines[i]!="") print lines[i]; } }' |
    while read -r OLD_BLOB; do
      echo "[backup-job] Deleting old snapshot $OLD_BLOB"
      az storage blob delete \
        --account-name "$ACCOUNT_NAME" \
        --account-key "$ACCOUNT_KEY" \
        --container-name "$SNAPSHOT_CONTAINER" \
        --name "$OLD_BLOB" >/dev/null || true
    done
}

echo "[backup-job] Running single snapshot iteration"
snapshot_iteration
cleanup
echo "[backup-job] Backup iteration complete"
