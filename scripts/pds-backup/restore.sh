#!/usr/bin/env sh
set -euo pipefail

DATA_DIR=${DATA_DIR:-/data}
WORK_DIR=${WORK_DIR:-/work}
SNAPSHOT_CONTAINER=${SNAPSHOT_CONTAINER:-pds-sqlite}
SNAPSHOT_PREFIX=${SNAPSHOT_PREFIX:-snapshots}
ACCOUNT_NAME=${AZURE_STORAGE_ACCOUNT_NAME:?AZURE_STORAGE_ACCOUNT_NAME is required}
ACCOUNT_KEY=${AZURE_STORAGE_ACCOUNT_KEY:?AZURE_STORAGE_ACCOUNT_KEY is required}
PDS_ID=${PDS_ID:-default}
SENTINEL_PATH=${SENTINEL_PATH:-"$DATA_DIR/.restore-complete"}
DOWNLOAD_PATH="$WORK_DIR/restore.tar.zst"

mkdir -p "$DATA_DIR" "$WORK_DIR"

if [ "$(find "$DATA_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  echo "[restore] Data directory already populated; skipping snapshot restore."
  touch "$SENTINEL_PATH"
  exit 0
fi

echo "[restore] Looking for latest snapshot in container '$SNAPSHOT_CONTAINER' with prefix '$SNAPSHOT_PREFIX/$PDS_ID'"
LATEST_BLOB=$(az storage blob list \
  --account-name "$ACCOUNT_NAME" \
  --account-key "$ACCOUNT_KEY" \
  --container-name "$SNAPSHOT_CONTAINER" \
  --prefix "$SNAPSHOT_PREFIX/$PDS_ID/" \
  --query "max_by(@, &properties.lastModified).name" -o tsv 2>/dev/null || true)

if [ -z "${LATEST_BLOB:-}" ]; then
  echo "[restore] No snapshots found; starting with empty state."
  touch "$SENTINEL_PATH"
  exit 0
fi

echo "[restore] Downloading snapshot blob $LATEST_BLOB"
az storage blob download \
  --account-name "$ACCOUNT_NAME" \
  --account-key "$ACCOUNT_KEY" \
  --container-name "$SNAPSHOT_CONTAINER" \
  --name "$LATEST_BLOB" \
  --file "$DOWNLOAD_PATH" \
  --overwrite true >/dev/null

if [ ! -s "$DOWNLOAD_PATH" ]; then
  echo "[restore] Downloaded archive is empty; aborting."
  exit 1
fi

echo "[restore] Extracting archive into $DATA_DIR"
rm -rf "$DATA_DIR"/*
zstd -d -c "$DOWNLOAD_PATH" | tar -x -C "$DATA_DIR"

touch "$SENTINEL_PATH"
echo "[restore] Restore complete."
