# Azure PDS Infrastructure Quickstart

This guide walks operators through the minimum steps to deploy the Azure-based Personal Data Server (PDS) infrastructure using the provided Bicep template. Work through the sections in order and capture outputs for later validation.

## Tooling Requirements

- Azure CLI **2.60.0** or newer (`az version --query '"azure-cli"' -o tsv`)
- Bicep CLI **0.27.1** or newer (`az bicep version`)
- Logged into the correct Azure subscription (`az account show`)
- Resource group Contributor permissions (plus DNS Zone Contributor if automating DNS)

> Ensure `az bicep upgrade` has been run if your Bicep CLI is behind the listed version.

## 1. Prepare Resource Group

```bash
az group create \
  --name <RESOURCE_GROUP> \
  --location <AZURE_REGION>
```

## 2. Preview Deployment Changes

```bash
az deployment group what-if \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=<PREFIX> \
    pdsHostname=<HOSTNAME> \
    pdsImageTag=<TAG>
```

- Confirm the preview shows only expected additions.
- Resolve any validation errors before proceeding.

## 3. Deploy Infrastructure

```bash
az deployment group create \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=<PREFIX> \
    pdsHostname=<HOSTNAME> \
    pdsImageTag=<TAG> \
    adminObjectId=<ADMIN_OBJECT_ID> \
    enableCommunicationServices=<true|false> \
    emailCustomDomain=<CUSTOM_DOMAIN_OR_EMPTY> \
    pdsJwtSecretName=<JWT_SECRET_NAME> \
    pdsAdminPasswordSecretName=<ADMIN_PASSWORD_SECRET_NAME> \
    pdsPlcRotationKeySecretName=<PLC_KEY_SECRET_NAME> \
    dnsZoneName=<DNS_ZONE> \
    dnsRecordName=<DNS_RECORD> \
    snapshotContainerName=pds-sqlite \
    snapshotPrefix=snapshots \
    backupIntervalSeconds=15 \
    backupRetentionCount=200
```

> **Backups**: The snapshot agent defaults to uploading compressed archives every 15 seconds and retains the newest 200 files. Tune the interval and retention parameters to meet your RPO/RTO targets and storage budget.

> **Email Prerequisite**: When `enableCommunicationServices=true`, run `scripts/acs-smtp-setup.sh` after the domain reports `Verified` to create the Microsoft Entra application and populate the SMTP secrets.

> **SMTP Placeholder**: The template seeds a temporary `PDS-SMTP-URL` value so the Container App can start. Always rerun `scripts/acs-smtp-setup.sh` after each deployment to refresh the real SMTP credentials in Key Vault.

> **SMTP Secret Name**: The template defaults to the `PDS-SMTP-URL` secret in Key Vault. Only pass `smtpSecretName` if you need to override that name.

Record the deployment outputs for Key Vault, Container App, Storage Account, and snapshot container identifiers. These values are referenced throughout the remaining steps.

**Key deployment outputs to capture:**
- `keyVaultUri` - Key Vault URL for secret management
- `containerAppFqdn` - Container App public endpoint
- `storageAccountId` - Storage Account resource ID
- `snapshotContainerResourceId` - Blob container resource ID for archives
- `snapshotContainerName` - Blob container name (convenience output)
- `communicationServiceEndpoint` - Azure Communication Services endpoint (if enabled)
- `smtpServer` - SMTP server hostname (`smtp.azurecomm.net`)
- `smtpPort` - SMTP server port (`587`)

## 4. Populate Key Vault Secrets

1. Retrieve the Key Vault name from the deployment output (`keyVaultUri`).
2. Populate secrets using the Azure CLI. Replace placeholders with actual values:
   ```bash
   az keyvault secret set --vault-name <KV_NAME> --name PDS-JWT-SECRET --value <JWT_SECRET>
   az keyvault secret set --vault-name <KV_NAME> --name PDS-ADMIN-PASSWORD --value <PASSWORD>
   az keyvault secret set --vault-name <KV_NAME> --name PDS-PLC-KEY --value <HEX_VALUE>
  # Optional: If enableCommunicationServices=false, provide your own SMTP URL
  az keyvault secret set --vault-name <KV_NAME> --name PDS-SMTP-URL --value <SMTP_URL>
   ```
  When ACS email is enabled, run:
  ```bash
  ./scripts/acs-smtp-setup.sh \
    --resource-group <RESOURCE_GROUP> \
    --communication-service <PREFIX>-acs \
    --email-service <PREFIX>-email \
    --key-vault <KV_NAME>
  ```

3. Restart the Container App revision if secrets were created after deployment:
   ```bash
   az containerapp revision restart \
     --name <CONTAINER_APP_NAME> \
     --resource-group <RESOURCE_GROUP>
   ```

## 5. Upload Configuration Files to Azure Files Share

1. Mount the share locally:
   ```bash
   sudo mount -t cifs //storageaccount.file.core.windows.net/pds /mnt/pds \
     -o vers=3.0,username=<STORAGE_ACCOUNT>,password=<STORAGE_KEY>,dir_mode=0770,file_mode=0660,serverino
   ```
2. Copy `pds.env`, TLS assets, and Caddy configuration into `/mnt/pds`.
3. Disconnect the mount after completion (`sudo umount /mnt/pds`).

## 6. Validate Service Health

- Perform a health probe:
  ```bash
  curl https://<HOSTNAME>/xrpc/_health
  ```
- Tail Container App logs:
  ```bash
  az containerapp logs show \
    --name <CONTAINER_APP_NAME> \
    --resource-group <RESOURCE_GROUP> \
    --follow
  ```
- Confirm websocket readiness by exercising the `subscribeRepos` feed.

## 7. Confirm Snapshot Agent

1. Verify the snapshot blob container exists:
   ```bash
   az storage container show \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --name <SNAPSHOT_CONTAINER_NAME>
   ```

2. Ensure the `snapshot-agent` sidecar is present on the container app:
   ```bash
   az containerapp show \
     --resource-group <RESOURCE_GROUP> \
     --name <CONTAINER_APP_NAME> \
     --query "properties.template.containers[].name"
   ```
   Confirm the output includes `snapshot-agent`.

3. After the first interval has elapsed, confirm snapshot archives exist:
   ```bash
   az storage blob list \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --container-name <SNAPSHOT_CONTAINER_NAME> \
     --prefix <SNAPSHOT_PREFIX>/<NAME_PREFIX>/ \
     --num-results 5
   ```
   Each blob follows the naming convention `snap-YYYYmmdd-HHMMSS.tar.zst`.

## 8. Configure DNS (Optional)

- Create a CNAME for the PDS host that points to the Container App FQDN.
- Validate certificate issuance in Caddy logs and via HTTPS checks.

## 9. Next Steps

Proceed to `docs/verification.md` once it exists to follow the detailed validation checklist and success-rate logging guidance.
