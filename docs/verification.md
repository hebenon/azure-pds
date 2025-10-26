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
- [ ] Azure Files Share (`pds`)
- [ ] Key Vault (`<namePrefix>-kv`)
- [ ] Container App (`<namePrefix>-pds-app`)
- [ ] Automation Account (`<namePrefix>-auto`)
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

## 2. Automation Verification

### Backup Runbook Check
1. **Verify runbook exists and is published:**
   ```bash
   az automation runbook show \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTOMATION_ACCOUNT_NAME> \
     --name BackupPdsFiles \
     --query "{name:name, state:state}"
   ```
   Expected state: `"Published"`

2. **Check schedule configuration:**
   ```bash
   az automation schedule show \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTOMATION_ACCOUNT_NAME> \
     --name DailyBackupSchedule
   ```
   Verify:
   - [ ] Frequency matches maintenance window
   - [ ] Next run time is reasonable
   - [ ] Schedule is enabled

3. **Verify job schedule linkage:**
   ```bash
   az automation job-schedule list \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTOMATION_ACCOUNT_NAME>
   ```
   Expected: Job schedule linking runbook to schedule

### Managed Identity Permissions
1. **Verify automation account has storage permissions:**
   ```bash
   az role assignment list \
     --assignee <AUTOMATION_PRINCIPAL_ID> \
     --scope <STORAGE_ACCOUNT_ID> \
     --output table
   ```
   Expected role: `Storage Account Contributor`

2. **Verify automation account has Key Vault permissions:**
   ```bash
   az role assignment list \
     --assignee <AUTOMATION_PRINCIPAL_ID> \
     --scope <KEY_VAULT_ID> \
     --output table
   ```
   Expected role: `Key Vault Secrets User`

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

### Manual Backup Test
1. **Trigger manual backup run (optional):**
   ```bash
   az automation runbook start \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTOMATION_ACCOUNT_NAME> \
     --name BackupPdsFiles \
     --parameters StorageAccountName=<STORAGE_ACCOUNT_NAME> ShareName=pds RetentionDays=30 ResourceGroupName=<RESOURCE_GROUP>
   ```

2. **Monitor job execution:**
   ```bash
   az automation job list \
     --resource-group <RESOURCE_GROUP> \
     --automation-account-name <AUTOMATION_ACCOUNT_NAME> \
     --filter "properties/runbook/name eq 'BackupPdsFiles'" \
     --top 1
   ```

3. **Verify snapshot creation:**
   ```bash
   az storage share list \
     --account-name <STORAGE_ACCOUNT_NAME> \
     --include-snapshot \
     --query "[?name=='pds']"
   ```
   Expected: Base share plus snapshot(s)

## Troubleshooting Common Issues

### Container App Not Starting
- Check container logs: `az containerapp logs show --name <APP_NAME> --resource-group <RG>`
- Verify all secrets are populated in Key Vault
- Check managed identity permissions

### Backup Jobs Failing
- Review automation job output: `az automation job get-output --job-id <JOB_ID>`
- Verify storage account permissions for automation managed identity
- Check Azure PowerShell module availability in automation account

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