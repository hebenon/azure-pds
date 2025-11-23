#!/usr/bin/env sh
set -euo pipefail

# Restore script using Azure Storage REST API (curl + openssl)

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

if [ -f "$DATA_DIR/pds.sqlite" ] || [ -d "$DATA_DIR/actors" ]; then
  echo "[restore] Data directory already populated; skipping snapshot restore."
  touch "$SENTINEL_PATH"
  exit 0
fi

if [ -f "$SENTINEL_PATH" ]; then
  echo "[restore] Restore sentinel exists; skipping snapshot restore."
  exit 0
fi

bin2hex() {
  od -A n -t x1 | tr -d ' \n'
}

sign_request() {
  local method=$1
  local resource=$2
  local query_params=$3
  local headers=$4
  local content_length=${5:-}
  local content_type=${6:-}
  
  local date=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
  local version="2021-06-08"
  
  local canon_headers="x-ms-date:$date\nx-ms-version:$version"
  local canon_res="/$ACCOUNT_NAME$resource"
  if [ -n "$query_params" ]; then
    canon_res="$canon_res\n$query_params"
  fi
  
  local string_to_sign="$method\n\n\n$content_length\n\n$content_type\n\n\n\n\n\n\n$canon_headers\n$canon_res"
  local hex_key=$(echo -n "$ACCOUNT_KEY" | base64 -d | bin2hex)
  local signature=$(echo -n -e "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$hex_key" -binary | base64 -w 0)
  
  echo "Authorization: SharedKey $ACCOUNT_NAME:$signature"
  echo "x-ms-date: $date"
  echo "x-ms-version: $version"
}

echo "[restore] Looking for latest snapshot in container '$SNAPSHOT_CONTAINER' with prefix '$SNAPSHOT_PREFIX/$PDS_ID'"

# List Blobs
# CanonicalizedResource: /account/container\ncomp:list\nprefix:...\nrestype:container
prefix="$SNAPSHOT_PREFIX/$PDS_ID/"
query_params="comp:list\nprefix:$prefix\nrestype:container"
auth_output=$(sign_request "GET" "/$SNAPSHOT_CONTAINER" "$query_params" "")
auth_header=$(echo "$auth_output" | grep "Authorization:")
date_header=$(echo "$auth_output" | grep "x-ms-date:")
version_header=$(echo "$auth_output" | grep "x-ms-version:")

list_url="https://$ACCOUNT_NAME.blob.core.windows.net/$SNAPSHOT_CONTAINER?restype=container&comp=list&prefix=$prefix"

# Capture HTTP status code and body
# We use a temporary file for the body to avoid pipe masking exit codes and to separate body from status
response_body_file=$(mktemp)
http_code=$(curl -s -w "%{http_code}" -X GET \
  -H "$auth_header" \
  -H "$date_header" \
  -H "$version_header" \
  -o "$response_body_file" \
  "$list_url")

if [ "$http_code" != "200" ]; then
  echo "[restore] ERROR: Failed to list blobs. HTTP Status: $http_code"
  echo "[restore] Response body:"
  cat "$response_body_file"
  rm -f "$response_body_file"
  exit 1
fi

list_response=$(cat "$response_body_file")
rm -f "$response_body_file"

# Extract latest blob
# Note: Alpine grep doesn't support -P, so we use sed
LATEST_BLOB=$(echo "$list_response" | sed -n 's/.*<Name>\(.*\)<\/Name>.*/\1/p' | grep "$SNAPSHOT_PREFIX/$PDS_ID/" | sort | tail -1 || true)

if [ -z "${LATEST_BLOB:-}" ]; then
  # Check if the response was actually a valid empty list (contains <Blobs /> or <Blobs></Blobs> or just <Blobs>)
  # If it's a valid XML response but no blobs match, that's fine.
  # But if we got 200 OK, it should be valid XML.
  echo "[restore] No snapshots found matching prefix '$SNAPSHOT_PREFIX/$PDS_ID/'; starting with empty state."
  touch "$SENTINEL_PATH"
  exit 0
fi

echo "[restore] Downloading snapshot blob $LATEST_BLOB"

# Download Blob
auth_output=$(sign_request "GET" "/$SNAPSHOT_CONTAINER/$LATEST_BLOB" "" "")
auth_header=$(echo "$auth_output" | grep "Authorization:")
date_header=$(echo "$auth_output" | grep "x-ms-date:")
version_header=$(echo "$auth_output" | grep "x-ms-version:")

curl -s -X GET \
  -H "$auth_header" \
  -H "$date_header" \
  -H "$version_header" \
  -o "$DOWNLOAD_PATH" \
  "https://$ACCOUNT_NAME.blob.core.windows.net/$SNAPSHOT_CONTAINER/$LATEST_BLOB"

if [ ! -s "$DOWNLOAD_PATH" ]; then
  echo "[restore] Downloaded archive is empty; aborting."
  exit 1
fi

echo "[restore] Extracting archive into $DATA_DIR"
rm -rf "$DATA_DIR"/*
zstd -d -c "$DOWNLOAD_PATH" | tar -x -C "$DATA_DIR"

touch "$SENTINEL_PATH"
echo "[restore] Restore complete."