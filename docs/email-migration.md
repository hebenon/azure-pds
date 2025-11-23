# Migrating to Azure Communication Services Email

This guide helps you upgrade existing Azure PDS deployments to use Azure Communication Services for email sending.

## Overview

If you currently have an Azure PDS deployment using external SMTP providers (like SendGrid, Mailgun, etc.), you can migrate to Azure Communication Services for:

- **Better Integration**: Native Azure service with managed identity authentication
- **Cost Efficiency**: Pay-per-email pricing, often more cost-effective than third-party services  
- **Simplified Management**: No external service accounts or API keys to manage
- **Enhanced Security**: SMTP credentials automatically managed in Key Vault

## Migration Process

### 1. Pre-Migration Assessment

Check your current email configuration:

```bash
# Check current SMTP secret in Key Vault
az keyvault secret show \
  --vault-name <your-keyvault-name> \
  --name PDS-SMTP-URL \
  --query value --output tsv

# Review current email volume (if available)
az monitor metrics list \
  --resource <your-container-app-resource-id> \
  --metric "Requests" \
  --start-time $(date -d '30 days ago' --iso-8601) \
  --end-time $(date --iso-8601)
```

### 2. Update Infrastructure

#### Option A: In-Place Update (Recommended)

Update your existing deployment with Communication Services enabled:

```bash
# Update with same parameters plus Communication Services
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=<your-prefix> \
    pdsHostname=<your-hostname> \
    pdsImageTag=<your-image-tag> \
    adminObjectId=<your-admin-id> \
    emailFromAddress=<new-azure-managed-address> \
    enableCommunicationServices=true \
    pdsJwtSecretName=<existing-jwt-secret> \
    pdsAdminPasswordSecretName=<existing-admin-secret> \
    pdsPlcRotationKeySecretName=<existing-plc-secret> \
    dnsZoneName=<your-dns-zone> \
    dnsRecordName=<your-dns-record> \
    <other-existing-parameters>

> After each infrastructure deployment the template seeds a temporary SMTP value. Run `scripts/acs-smtp-setup.sh` once the deployment finishes (and rerun it after every future redeployment) to restore the real SMTP connection string in Key Vault.
```

#### Option B: Blue-Green Deployment

Deploy new infrastructure alongside existing:

1. Deploy new infrastructure with different `namePrefix`
2. Test email functionality thoroughly
3. Update DNS to point to new deployment
4. Decommission old infrastructure after validation

### 3. Email Address Migration Strategies

#### Strategy 1: Azure-Managed Domain (Fastest)

- **Pros**: No DNS configuration required, works immediately
- **Cons**: Less professional appearance
- **Downtime**: Approximately 5-10 minutes during container restart

```bash
# Use Azure-managed domain format
emailFromAddress=donotreply@xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.azurecomm.net
enableCommunicationServices=true
# Do not set emailCustomDomain parameter
```

#### Strategy 2: Custom Domain (Recommended for Production)

- **Pros**: Professional appearance, brand consistency
- **Cons**: Requires DNS configuration and verification
- **Downtime**: 15-30 minutes (including DNS propagation)

```bash
# Use custom domain
emailFromAddress=noreply@notify.yourdomain.com
enableCommunicationServices=true
emailCustomDomain=notify.yourdomain.com
```

**DNS Configuration Required:**
1. Domain verification TXT record
2. SPF record for sender authentication
3. DKIM CNAME records for email signing

See [docs/email-setup.md](email-setup.md) for detailed DNS configuration.

### 4. Migration Timeline

#### Phase 1: Infrastructure Update (5-10 minutes)
1. Run updated Bicep deployment
2. Communication Services resources are created
3. SMTP credentials automatically generated and stored

#### Phase 2: Container App Update (2-5 minutes)
1. Container App automatically restarts with new configuration
2. New SMTP credentials loaded from Key Vault
3. Health checks verify service availability

#### Phase 3: DNS Propagation (if using custom domain - 15-30 minutes)
1. Add required DNS records
2. Wait for domain verification
3. Monitor email sending functionality

### 5. Validation Steps

#### Test Email Configuration

1. **Check Communication Services Status**:
   ```bash
   az communication list --resource-group <resource-group>
   ```

2. **Verify SMTP Secret Updated**:
   ```bash
   az keyvault secret show \
     --vault-name <keyvault-name> \
     --name PDS-SMTP-URL \
     --query value --output tsv
   ```
   Should show format: `smtps://app-id:secret@smtp.azurecomm.net:587`

3. **Test Container App Health**:
   ```bash
   curl https://<your-hostname>/xrpc/_health
   ```

4. **Monitor Application Logs**:
   ```bash
   az containerapp logs show \
     --name <container-app-name> \
     --resource-group <resource-group> \
     --follow
   ```

#### Functional Testing

1. **Create Test User Account** (if supported by your PDS version)
2. **Trigger Email Verification** process
3. **Check Email Delivery** in target inbox
4. **Verify Email Headers** show proper authentication (SPF, DKIM)

### 6. Rollback Plan

If issues occur during migration:

#### Immediate Rollback (Option 1)

Update the SMTP secret back to your previous provider:

```bash
az keyvault secret set \
  --vault-name <keyvault-name> \
  --name PDS-SMTP-URL \
  --value "<your-previous-smtp-url>"

# Restart container app to pick up old secret
az containerapp revision restart \
  --name <container-app-name> \
  --resource-group <resource-group>
```

#### Infrastructure Rollback (Option 2)

Redeploy with Communication Services disabled:

```bash
az deployment group create \
  --resource-group <resource-group> \
  --template-file infra/main.bicep \
  --parameters \
    enableCommunicationServices=false \
    <all-other-previous-parameters>
```

### 7. Cost Impact Analysis

#### Communication Services Pricing (approximate)

- **Emails**: ~$0.25 per 1,000 emails
- **SMTP Authentication**: Included
- **Domain Verification**: One-time setup, no ongoing cost

#### Cost Comparison

| Service | Cost Model | Typical Monthly Cost (10K emails) |
|---------|------------|-----------------------------------|
| Azure Communication Services | Pay-per-email | ~$2.50 |
| SendGrid Essentials | Monthly plan | $14.95 |
| Mailgun Flex | Pay-as-you-go | ~$8.00 |
| Amazon SES | Pay-per-email | ~$1.00 |

*Costs may vary by region and usage patterns*

### 8. Monitoring and Alerting

Set up monitoring for the new email service:

#### Azure Monitor Alerts

```bash
# Create alert for email sending failures
az monitor metrics alert create \
  --name "Email Sending Failures" \
  --resource-group <resource-group> \
  --scopes <communication-service-resource-id> \
  --condition "count 'Email Send Requests' > 0 where ResultType = 'Failed'" \
  --description "Alert when emails fail to send"
```

#### Log Analytics Queries

Monitor email activity:

```kusto
// Email send success rate
ContainerAppConsoleLogs_CL
| where ContainerName_s == "pds"
| where Log_s contains "email"
| summarize Total = count(), Success = countif(Log_s contains "sent") by bin(TimeGenerated, 1h)
| extend SuccessRate = (Success * 100.0) / Total
```

### 9. Common Migration Issues

#### Issue: Domain Verification Failed
- **Symptom**: Custom domain shows "Failed" status
- **Solution**: Verify DNS TXT record is correctly configured
- **Check**: `nslookup -q=TXT yourdomain.com`

#### Issue: SMTP Authentication Failed  
- **Symptom**: Email sending returns authentication errors
- **Solution**: Verify Entra application has correct role assignments
- **Check**: Communication and Email Service Owner role

#### Issue: Email Delivery Issues
- **Symptom**: Emails sent but not received
- **Solution**: Check SPF/DKIM records, recipient spam folders
- **Check**: Email headers for authentication status

#### Issue: Container App Won't Start
- **Symptom**: Container app in failed state after migration
- **Solution**: Check Key Vault access permissions and secret format
- **Check**: Container app system identity has Key Vault Secrets User role

### 10. Post-Migration Tasks

1. **Update Documentation**: Update any runbooks or documentation with new email configuration
2. **Remove Old Secrets**: Clean up any unused SMTP secrets or external service accounts
3. **Update Monitoring**: Adjust alerts and dashboards for new service
4. **User Communication**: Notify users of new sender email address (if changed)
5. **Backup Configuration**: Document new configuration for disaster recovery

### 11. Advanced Configuration

#### Custom Sender Names

Configure friendly sender names:

```bash
# Update from address with display name
emailFromAddress="PDS Notifications <noreply@notify.yourdomain.com>"
```

#### Multiple Email Domains

For organizations with multiple brands or environments:

1. Create separate Email Communication Services for each domain
2. Link appropriate domains to each Communication Service
3. Use different sender addresses per environment

#### High Volume Considerations

For high email volumes (>100K/month):

1. Monitor for rate limiting
2. Consider multiple Communication Services for load distribution  
3. Implement email queuing in application layer
4. Set up comprehensive monitoring and alerting

## Support and Resources

- [Azure Communication Services Documentation](https://learn.microsoft.com/azure/communication-services/)
- [Email Troubleshooting Guide](https://learn.microsoft.com/azure/communication-services/concepts/email/email-domain-configuration-troubleshooting)
- [Azure Support](https://azure.microsoft.com/support/) for deployment issues
- [Community Forums](https://techcommunity.microsoft.com/azure) for best practices