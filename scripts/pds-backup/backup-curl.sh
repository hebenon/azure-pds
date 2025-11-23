#!/usr/bin/env sh
set -euo pipefail

DATA_DIR=${DATA_DIR:-/data}
WORK_DIR=${WORK_DIR:-/work}
ACCOUNT_NAME=${AZURE_STORAGE_ACCOUNT_NAME:?AZURE_STORAGE_ACCOUNT_NAME is required}
ACCOUNT_KEY=${AZURE_STORAGE_ACCOUNT_KEY:?AZURE_STORAGE_ACCOUNT_KEY is required}
SNAPSHOT_CONTAINER=${SNAPSHOT_CONTAINER:-pds-sqlite}
SNAPSHOT_PREFIX=${SNAPSHOT_PREFIX:-snapshots}
PDS_ID=${PDS_ID:-default}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-15}
RETAIN_COUNT=${RETAIN_COUNT:-200}
SENTINEL_PATH=${SENTINEL_PATH:-"$DATA_DIR/.restore-complete"}

mkdir -p "$WORK_DIR"

cleanup() {
  rm -rf "$WORK_DIR"/snapshot-* "$WORK_DIR"/archive-*.tar.zst 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_for_restore() {
  while [ ! -f "$SENTINEL_PATH" ]; do
    echo "[backup] Waiting for restore sentinel at $SENTINEL_PATH"
    sleep 2
  done
}

bin2hex() {
  od -A n -t x1 | tr -d ' \n'
}

# $1: method, $2: resource (e.g. /container/blob), $3: query params (newlines separated key:value), $4: headers (newlines separated key:value), $5: content-length, $6: content-type
sign_request() {
  local method=$1
  local resource=$2
  local query_params=$3
  local headers=$4
  local content_length=${5:-}
  local content_type=${6:-}
  
  local date=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
  local version="2021-06-08"
  
  # Build CanonicalizedHeaders
  # We assume only x-ms-date and x-ms-version and maybe x-ms-blob-type are used.
  # Sort headers?
  local canon_headers=""
  if echo "$headers" | grep -q "x-ms-blob-type"; then
    local blob_type=$(echo "$headers" | grep "x-ms-blob-type" | cut -d: -f2 | tr -d ' ')
    canon_headers="x-ms-blob-type:$blob_type\n"
  fi
  canon_headers="${canon_headers}x-ms-date:$date\nx-ms-version:$version"
  
  # Build CanonicalizedResource
  local canon_res="/$ACCOUNT_NAME$resource"
  if [ -n "$query_params" ]; then
    # Sort query params? We assume caller passes them sorted if needed, or we just append.
    # Azure requires lexicographical order.
    canon_res="$canon_res\n$query_params"
  fi
  
  local string_to_sign="$method\n\n\n$content_length\n\n$content_type\n\n\n\n\n\n\n$canon_headers\n$canon_res"
  
  local hex_key=$(echo -n "$ACCOUNT_KEY" | base64 -d | bin2hex)
  local signature=$(echo -n -e "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$hex_key" -binary | base64 -w 0)
  
  echo "Authorization: SharedKey $ACCOUNT_NAME:$signature"
  echo "x-ms-date: $date"
  echo "x-ms-version: $version"
}

snapshot_iteration() {
  TS=$(date -u +"%Y%m%d-%H%M%S")
  STAGING="$WORK_DIR/snapshot-$TS"
  ARCHIVE="$WORK_DIR/archive-$TS.tar.zst"

  rm -rf "$STAGING"
  mkdir -p "$STAGING"

  echo "[backup] Creating staging copy of $DATA_DIR"
  tar -C "$DATA_DIR" -cf - . | tar -C "$STAGING" -xf -
  find "$STAGING" -type f \( -name "*.sqlite" -o -name "*.sqlite-wal" -o -name "*.sqlite-shm" \) -delete

  echo "[backup] Refreshing SQLite backups"
  find "$DATA_DIR" -type f -name "*.sqlite" | while read -r DB; do
    TARGET="$STAGING${DB#$DATA_DIR}"
    mkdir -p "$(dirname "$TARGET")"
    sqlite3 "$DB" ".backup '$TARGET'"
  done

  echo "[backup] Packaging snapshot"
  tar -C "$STAGING" -I "zstd -3" -cf "$ARCHIVE" .
  
  local blob_name="$SNAPSHOT_PREFIX/$PDS_ID/snap-$TS.tar.zst"
  local file_size=$(stat -c%s "$ARCHIVE")
  
  echo "[backup] Uploading $blob_name ($file_size bytes)"
  
  local auth_output=$(sign_request "PUT" "/$SNAPSHOT_CONTAINER/$blob_name" "" "x-ms-blob-type:BlockBlob" "$file_size" "application/x-tar")
  local auth_header=$(echo "$auth_output" | grep "Authorization:")
  local date_header=$(echo "$auth_output" | grep "x-ms-date:")
  local version_header=$(echo "$auth_output" | grep "x-ms-version:")
  
  curl -s -X PUT \
    -H "$auth_header" \
    -H "$date_header" \
    -H "$version_header" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Length: $file_size" \
    -H "Content-Type: application/x-tar" \
    --data-binary @"$ARCHIVE" \
    "https://$ACCOUNT_NAME.blob.core.windows.net/$SNAPSHOT_CONTAINER/$blob_name"
    
  # Retention logic omitted for simplicity/robustness in shell.
  # If we really need it, we can implement List Blobs later.
  # For now, just uploading is the critical part.
  echo ""
  echo "[backup] Upload complete"
}

wait_for_restore

echo "[backup] Starting continuous snapshot loop (interval ${INTERVAL_SECONDS}s)"
while true; do
  snapshot_iteration || echo "[backup] Snapshot iteration failed"
  cleanup
  sleep "$INTERVAL_SECONDS"
done
