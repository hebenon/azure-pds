# Deployment Verification Guide

This guide provides comprehensive verification steps to ensure the Azure PDS infrastructure deployment is successful and operational. Follow the checklist in order after deployment completion.

## Prerequisites
- Completed deployment using `docs/quickstart.md`
- Access to the Azure portal and CLI
- Deployment outputs captured (Key Vault URI, Container App FQDN, etc.)

## 1. Infrastructure Verification

### Azure Resources Check
Verify all expected resources were created:

```bash
# List all resources in the resource group
az resource list --resource-group <RESOURCE_GROUP> --output table
```

**Expected resources:**
- [ ] Log Analytics Workspace (`<namePrefix>-law`)
- [ ] Container Apps Environment (`<namePrefix>-cae`)
- [ ] Storage Account (`<namePrefix><uniqueString>`)
- [ ] Snapshot Blob Container (`<snapshotContainerName>`)
- [ ] Key Vault (`<namePrefix>-kv`)
- [ ] Container App (`<namePrefix>-pds-app`)
- [ ] DNS Zone (if `dnsZoneName` was specified)
- [ ] DNS CNAME Records (if DNS was configured)

### Container App Health
1. **Verify Container App is running:**
   ```bash
   az containerapp show \
     --name <CONTAINER_APP_NAME> \
     --resource-group <RESOURCE_GROUP> \
     --query "properties.runningStatus"
   ```
   Expected result: `"Running"`

2. **Check replica count:**
   ```bash
   az containerapp replica list \
     --name <CONTAINER_APP_NAME> \
     --resource-group <RESOURCE_GROUP>
   ```
   Expected: At least 1 running replica

3. **Health endpoint check:**
   ```bash
   curl -f https://<PDS_HOSTNAME>/xrpc/_health
   ```
   Expected: HTTP 200 response

### Storage Account Verification
1. **Verify Azure Files share exists:**
   ```bash
   az storage share show \
     --name pds \
     --account-name <STORAGE_ACCOUNT_NAME>
   ```

2. **Check share quota:**
   ```bash
   az storage share show \
     --name pds \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --query "properties.quota"
   ```
   Expected: Configured quota value (default 256 GiB)

### Key Vault Verification
1. **Verify Key Vault accessibility:**
   ```bash
   az keyvault show --name <KEY_VAULT_NAME>
   ```

2. **Check required secrets exist:**
   ```bash
   az keyvault secret list --vault-name <KEY_VAULT_NAME> --output table
   ```
   Expected secrets:
   - [ ] `PDS-JWT-SECRET` (or configured name)
   - [ ] `PDS-ADMIN-PASSWORD` (or configured name)
   - [ ] `PDS-PLC-KEY` (or configured name)
   - [ ] `PDS-SMTP-SECRET` (or configured name)
   - [ ] `storage-account-key` (created by template)

## 2. Snapshot Agent Verification

### Blob Storage Checks
1. **Confirm the snapshot container exists:**
   ```bash
   az storage container show \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --name <SNAPSHOT_CONTAINER_NAME>
   ```

2. **List the most recent archives:**
   ```bash
   az storage blob list \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --container-name <SNAPSHOT_CONTAINER_NAME> \
     --prefix <SNAPSHOT_PREFIX>/<NAME_PREFIX>/ \
     --num-results 3 \
     --query "[].{name:name, lastModified:properties.lastModified}"
   ```
   Expect at least one `snap-YYYYmmdd-HHMMSS.tar.zst` entry once the sidecar has completed a cycle.

### Sidecar Health
1. **Ensure the `snapshot-agent` container is configured:**
   ```bash
   az containerapp show \
     --resource-group <RESOURCE_GROUP> \
     --name <CONTAINER_APP_NAME> \
     --query "properties.template.containers[?name=='snapshot-agent']"
   ```
   Expected: JSON object describing the sidecar container.

2. **Tail snapshot-agent logs for recent activity:**
   ```bash
   az containerapp logs show \
     --resource-group <RESOURCE_GROUP> \
     --name <CONTAINER_APP_NAME> \
     --container snapshot-agent \
     --tail 20
   ```
   Look for `[backup] Uploading` and `[backup] Enforcing retention` messages without errors.

3. **Cold-start restore validation (optional):**
   - Stop the revision or scale replicas to zero temporarily.
   - Start the app and tail the snapshot-agent logs.
   - Confirm `[restore]` log entries appear before the PDS container begins serving traffic.

### Key Vault & Secret Checks
- Confirm the `storage-account-key` secret exists in Key Vault (already covered in Section 1).
- Ensure the container app managed identity has the Key Vault `Secrets User` role (see outputs/role assignments in the deployment step).

## 3. Application Functionality Verification

### PDS Service Checks
1. **Basic connectivity test:**
   ```bash
   curl -I https://<PDS_HOSTNAME>
   ```
   Expected: HTTP response (2xx or 3xx)

2. **WebSocket endpoint test:**
   ```bash
   curl -I https://<PDS_HOSTNAME>/xrpc/com.atproto.sync.subscribeRepos \
     -H "Connection: Upgrade" \
     -H "Upgrade: websocket"
   ```
   Expected: WebSocket upgrade response

3. **Admin interface accessibility (if configured):**
   ```bash
   curl -f https://<PDS_HOSTNAME>/admin
   ```

### Log Analytics Integration
1. **Verify logs are flowing:**
   ```bash
   az monitor log-analytics query \
     --workspace <LOG_ANALYTICS_WORKSPACE_ID> \
     --analytics-query "ContainerAppConsoleLogs_CL | limit 10"
   ```
   Expected: Recent log entries from Container App

## 4. DNS and TLS Verification (if applicable)

### DNS Resolution
1. **Verify CNAME record:**
   ```bash
   nslookup <PDS_HOSTNAME>
   ```
   Expected: Resolution to Container App FQDN

2. **Verify wildcard CNAME:**
   ```bash
   nslookup test.<PDS_HOSTNAME>
   ```
   Expected: Resolution to Container App FQDN

### TLS Certificate
1. **Check certificate validity:**
   ```bash
   echo | openssl s_client -servername <PDS_HOSTNAME> -connect <PDS_HOSTNAME>:443 2>/dev/null | openssl x509 -noout -dates
   ```
   Expected: Valid certificate with future expiration

## 5. Performance and Scale Verification

### Resource Utilization
1. **Check CPU and memory usage:**
   ```bash
   az containerapp show \
     --name <CONTAINER_APP_NAME> \
     --resource-group <RESOURCE_GROUP> \
     --query "properties.template.containers[*].resources"
   ```

2. **Monitor scaling behavior:**
   - Generate test load and observe replica scaling
   - Verify scale-down after load reduction

### Storage Performance
1. **Verify file share performance:**
   - Mount Azure Files share locally
   - Perform basic read/write operations
   - Measure latency for critical operations

## 6. Security Verification

### Network Security
1. **Verify HTTPS enforcement:**
   ```bash
   curl -I http://<PDS_HOSTNAME>
   ```
   Expected: HTTP redirect to HTTPS

2. **Check for unnecessary open ports:**
   ```bash
   nmap -p 1-1000 <PDS_HOSTNAME>
   ```
   Expected: Only ports 80 and 443 responding

### Access Control
1. **Verify Key Vault access policies:**
   ```bash
   az keyvault show --name <KEY_VAULT_NAME> --query "properties.accessPolicies"
   ```
   Expected: Only necessary principals with minimal permissions

## 7. Backup System Verification

### Snapshot Archive Validation
1. **List the most recent archive:**
   ```bash
   az storage blob list \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --container-name <SNAPSHOT_CONTAINER_NAME> \
     --prefix <SNAPSHOT_PREFIX>/<NAME_PREFIX>/ \
     --num-results 1 \
     --query "[0].{name:name, lastModified:properties.lastModified}"
   ```
   Expected: The blob timestamp is recent (within 1–2 intervals of the snapshot cadence).

2. **Download and inspect (optional):**
   ```bash
   az storage blob download \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --container-name <SNAPSHOT_CONTAINER_NAME> \
     --name <BLOB_NAME> \
     --file snapshot.tar.zst
   zstd -d snapshot.tar.zst -o snapshot.tar
   tar -tf snapshot.tar | head
   ```
   Confirm SQLite files (`*.sqlite`) and repo directories are present.

## Troubleshooting Common Issues

### Container App Not Starting
- Check container logs: `az containerapp logs show --name <APP_NAME> --resource-group <RG>`
- Verify all secrets are populated in Key Vault
- Confirm the snapshot-agent logs show `[restore]` before the PDS container starts

### Snapshot Agent Failures
- Tail snapshot-agent logs for errors related to uploads or permissions
- Ensure the `storage-account-key` secret exists and matches the storage account key
- Verify the storage account allows shared key authentication (enabled by default)

### DNS Resolution Issues
- Verify DNS zone delegation is correct
- Check CNAME record TTL and propagation
- Confirm wildcard record syntax

### Performance Issues
- Review Log Analytics for error patterns
- Check resource limits and scaling configuration
- Monitor Azure Files share performance metrics

## Success Criteria Checklist

Mark each item as complete after verification:

- [ ] All Azure resources deployed successfully
- [ ] Container App is running and accessible
- [ ] Health endpoint returns HTTP 200
- [ ] All required secrets are stored in Key Vault
- [ ] Backup automation is configured and scheduled
- [ ] DNS resolves correctly (if configured)
- [ ] TLS certificate is valid and auto-renewing
- [ ] Log Analytics is receiving application logs
- [ ] Storage account is accessible and performing well
- [ ] Security controls are properly configured

## Post-Verification Steps

After completing verification:

1. Document any deviations from expected results
2. Update monitoring dashboards and alerts
3. Schedule first backup test for validation
4. Create operational playbooks for common maintenance tasks
5. Review and update incident response procedures

## Deployment Timing Expectations

Track deployment phases to establish baseline performance:

- [ ] Resource group preparation: < 1 minute
- [ ] Infrastructure deployment: 10-15 minutes
- [ ] Secret population: 2-5 minutes  
- [ ] Container app revision deployment: 3-7 minutes
- [ ] DNS propagation (if applicable): 5-60 minutes
- [ ] TLS certificate issuance: 2-10 minutes

**Total expected deployment time: 30-60 minutes**

Document actual timing for future reference and capacity planning.

## Nameprefix Collision Remediation

If deployment fails due to storage account name collisions:

### Symptoms
- Deployment error: "Storage account name already exists"
- Resource creation fails during storage account provisioning

### Resolution Steps
1. **Choose a new namePrefix:**
   ```bash
   # Generate a unique suffix
   UNIQUE_SUFFIX=$(date +%s)
   NEW_PREFIX="${ORIGINAL_PREFIX}${UNIQUE_SUFFIX}"
   ```

2. **Retry deployment with new prefix:**
   ```bash
   az deployment group create \
     --resource-group <RESOURCE_GROUP> \
     --template-file infra/main.bicep \
     --parameters namePrefix=$NEW_PREFIX [other-parameters]
   ```

3. **Update documentation and scripts:**
   - Update all references to use the new prefix
   - Modify monitoring and alerting configurations
   - Update operational procedures

### Prevention
- Use organization-specific prefixes
- Include environment indicators (dev, staging, prod)
- Consider using subscription ID in prefix generation
- Test naming in development environments first

### Alternative Solutions
- Modify the Bicep template to use a different unique string algorithm
- Implement custom naming logic with additional entropy sources
- Use Azure naming conventions that include timestamp or deployment ID