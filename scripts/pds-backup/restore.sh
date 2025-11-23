#!/usr/bin/env sh
set -euo pipefail

# Install Azure CLI if not present (for containers without it pre-installed)
if ! command -v az >/dev/null 2>&1; then
  echo "[restore] Azure CLI not found, installing..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null && apt-get install -y curl gpg >/dev/null
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  elif command -v apk >/dev/null 2>&1; then
    # Try to install azure-cli from Alpine repository first
    if apk info azure-cli >/dev/null 2>&1; then
      apk add --no-cache azure-cli
    else
      # Fall back to pip install with --break-system-packages
      apk add --no-cache py3-pip gcc musl-dev python3-dev libffi-dev openssl-dev cargo make
      pip3 install --no-cache-dir --break-system-packages azure-cli
    fi
  else
    echo "[restore] ERROR: Could not install Azure CLI - no supported package manager found" >&2
    exit 1
  fi
  echo "[restore] Azure CLI installed successfully"
fi

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

# Check for actual PDS data (sqlite db or actors directory) rather than just any files
if [ -f "$DATA_DIR/pds.sqlite" ] || [ -d "$DATA_DIR/actors" ]; then
  echo "[restore] Data directory already populated; skipping snapshot restore."
  touch "$SENTINEL_PATH"
  exit 0
fi

# Also check if we've already attempted restoration (sentinel exists)
if [ -f "$SENTINEL_PATH" ]; then
  echo "[restore] Restore sentinel exists; skipping snapshot restore."
  exit 0
fi

# Ensure work directory exists for restoration process
mkdir -p "$WORK_DIR"

echo "[restore] Looking for latest snapshot in container '$SNAPSHOT_CONTAINER' with prefix '$SNAPSHOT_PREFIX/$PDS_ID'"
LATEST_BLOB=$(az storage blob list \
  --account-name "$ACCOUNT_NAME" \
  --account-key "$ACCOUNT_KEY" \
  --container-name "$SNAPSHOT_CONTAINER" \
  --prefix "$SNAPSHOT_PREFIX/$PDS_ID/" \
  --query "max_by(@, &properties.lastModified).name" -o tsv)

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
