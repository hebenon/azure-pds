# Quickstart: Deploying Azure PDS Infrastructure

## Prerequisites
- Azure CLI 2.60+ with Bicep CLI installed (`az bicep upgrade`).
- Contributor permissions on target subscription and resource group.
- Access to Azure DNS zone (if using custom domain automation).
- Secrets prepared for JWT, admin password, PLC key, SMTP credentials.

## 1. Prepare Resource Group
```bash
az group create \
  --name <RESOURCE_GROUP> \
  --location <AZURE_REGION>
```

## 2. Run What-If Preview
```bash
az deployment group what-if \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=<PREFIX> \
    pdsHostname=<HOSTNAME> \
    pdsImageTag=<TAG>
```

## 3. Deploy Infrastructure
```bash
az deployment group create \
  --resource-group <RESOURCE_GROUP> \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=<PREFIX> \
    pdsHostname=<HOSTNAME> \
    pdsImageTag=<TAG> \
    dnsZoneName=<DNS_ZONE> \
    dnsRecordName=<DNS_RECORD> \
    maintenanceWindow="Sun 02:00"
```

## 4. Populate Key Vault Secrets
1. Retrieve Key Vault name from deployment output.
2. Create secrets via CLI:
   ```bash
   az keyvault secret set --vault-name <KV> --name PDS-JWT-SECRET --value <VALUE>
   az keyvault secret set --vault-name <KV> --name PDS-ADMIN-PASSWORD --value <VALUE>
   az keyvault secret set --vault-name <KV> --name PDS-PLC-KEY --value <HEX>
   az keyvault secret set --vault-name <KV> --name PDS-SMTP-SECRET --value <SMTP_URL>
   ```
3. Trigger container app revision restart if secrets added after deployment.

## 5. Upload Configuration Files
- Mount the Azure Files share using SMB.
- Copy `pds.env`, Caddy configuration, and any required TLS assets to `/pds` directories.

## 6. Verify Deployment
- Health check: `curl https://<HOSTNAME>/xrpc/_health`
- WebSocket check: confirm `subscribeRepos` endpoint accepts connections.
- Logs: review Container App console logs via `az containerapp log tail`.

## 7. Confirm Backup Automation
- Inspect automation job next run time:
  ```bash
  az automation job list \
    --resource-group <RESOURCE_GROUP> \
    --automation-account-name <AUTO_ACCOUNT> \
    --status Running --max-items 1
  ```
- After first run, verify snapshot existence in Azure Files share.

## 8. Configure DNS (if applicable)
- CNAME `pds.example.com` and `*.pds.example.com` to the container app FQDN.
- Confirm TLS certificate issuance via Caddy logs.
