#!/usr/bin/env bash
set -euo pipefail

# Cleanup script for small (truncated) backups
# Usage: ./cleanup-small-backups.sh [delete]

ACTION=${1:-dry-run}
MIN_SIZE_BYTES=10240 # 10KB
CONTAINER=${SNAPSHOT_CONTAINER:-pds-sqlite}
PREFIX=${SNAPSHOT_PREFIX:-snapshots}
PDS_ID=${PDS_ID:-default}
ACCOUNT_NAME=${AZURE_STORAGE_ACCOUNT_NAME:?AZURE_STORAGE_ACCOUNT_NAME is required}

echo "Checking for backups smaller than $MIN_SIZE_BYTES bytes in $CONTAINER/$PREFIX/$PDS_ID..."

# We need to list blobs. Assuming 'az' CLI is available and logged in or using env vars if supported.
# If running in the environment where 'az' is not available but keys are, this might be tricky.
# But the user likely has 'az' on their machine.

if ! command -v az &> /dev/null; then
    echo "Error: 'az' CLI is required for this cleanup script."
    exit 1
fi

# List blobs with size
blobs=$(az storage blob list \
    --account-name "$ACCOUNT_NAME" \
    --container-name "$CONTAINER" \
    --prefix "$PREFIX/$PDS_ID/" \
    --auth-mode login \
    --query "[?properties.contentLength < \`$MIN_SIZE_BYTES\`].{Name:name, Size:properties.contentLength}" \
    -o json)

count=$(echo "$blobs" | jq 'length')

if [ "$count" -eq 0 ]; then
    echo "No small backups found."
    exit 0
fi

echo "Found $count small backups:"
echo "$blobs" | jq -r '.[] | "\(.Name) (\(.Size) bytes)"'

if [ "$ACTION" == "delete" ]; then
    echo ""
    echo "Deleting $count blobs..."
    # Extract names and delete
    echo "$blobs" | jq -r '.[].Name' | while read -r blob_name; do
        echo "Deleting $blob_name..."
        az storage blob delete \
            --account-name "$ACCOUNT_NAME" \
            --container-name "$CONTAINER" \
            --name "$blob_name" \
            --auth-mode login
    done
    echo "Cleanup complete."
else
    echo ""
    echo "Run with 'delete' argument to actually delete these files."
    echo "./cleanup-small-backups.sh delete"
fi
