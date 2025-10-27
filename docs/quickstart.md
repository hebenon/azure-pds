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
    maintenanceWindow="Sun 02:00" \
    backupRetentionDays=30
```

> **Backups**: The automation runbook runs **daily** at the UTC time specified by `maintenanceWindow`. The day token is kept for operator clarity only.

> **Email Prerequisite**: When `enableCommunicationServices=true`, run `scripts/acs-smtp-setup.sh` after the domain reports `Verified` to create the Microsoft Entra application and populate the SMTP secrets.

> **SMTP Placeholder**: The template seeds a temporary `PDS-SMTP-URL` value so the Container App can start. Always rerun `scripts/acs-smtp-setup.sh` after each deployment to refresh the real SMTP credentials in Key Vault.

> **SMTP Secret Name**: The template defaults to the `PDS-SMTP-URL` secret in Key Vault. Only pass `smtpSecretName` if you need to override that name.

> **Runbook Content**: If you are deploying from a feature branch or fork, override `backupRunbookContentUri` (and its matching `backupRunbookContentHash`) so the automation account can download the runbook from your branch.

Record the deployment outputs for Key Vault, Container App, Storage Account, and Automation Account identifiers. These values are referenced throughout the remaining steps.

**Key deployment outputs to capture:**
- `keyVaultUri` - Key Vault URL for secret management
- `containerAppFqdn` - Container App public endpoint
- `automationAccountName` - Automation Account for backup verification
- `storageAccountId` - Storage Account resource ID
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

## 7. Confirm Backup Automation

1. Verify the automation runbook was created successfully:
   ```bash
   az automation runbook show \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTO_ACCOUNT_NAME> \
     --name BackupPdsFiles
   ```

2. Check the backup schedule configuration:
   ```bash
   az automation schedule show \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTO_ACCOUNT_NAME> \
     --name DailyBackupSchedule
   ```

3. Inspect recent and scheduled automation jobs:
   ```bash
   az automation job list \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTO_ACCOUNT_NAME> \
     --max-items 5
   ```

4. After the first scheduled run, verify snapshots exist in the Azure Files share:
   ```bash
   az storage share list \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --account-key <STORAGE_KEY> \
     --include-snapshot
   ```

## 8. Configure DNS (Optional)

- Create a CNAME for the PDS host that points to the Container App FQDN.
- Validate certificate issuance in Caddy logs and via HTTPS checks.

## 9. Next Steps

Proceed to `docs/verification.md` once it exists to follow the detailed validation checklist and success-rate logging guidance.
