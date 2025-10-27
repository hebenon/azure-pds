# Azure Communication Services Email Setup

This guide explains how to configure Azure Communication Services (ACS) for email verification in your Azure PDS deployment. The infrastructure template provisions the core ACS resources and Key Vault wiring; a post-deployment script now handles the Microsoft Entra application, SMTP username, and secret population so that the stack remains stable across re-deployments.

## Overview

Azure Communication Services Email enables your PDS to send user verification emails via SMTP relay. The infrastructure includes:

- **Azure Communication Services**: Core communication resource
- **Email Communication Service**: Email-specific service with domain management
- **Microsoft Entra Application**: Service principal for SMTP authentication
- **SMTP Relay**: Secure email sending via `smtp.azurecomm.net`

## Domain Options

### Option 1: Azure-Managed Domain (Recommended for Development)
- **Advantages**: No DNS configuration required, works immediately
- **Format**: `donotreply@xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.azurecomm.net`
- **Use Case**: Development, testing, proof-of-concept

### Option 2: Custom Domain (Recommended for Production)
- **Advantages**: Professional appearance, brand consistency
- **Format**: `noreply@notify.yourdomain.com`
- **Requirements**: Domain ownership verification, DNS configuration

## Deployment

### Automatic Email Address Configuration

During deployment the Bicep template stores a placeholder `donotreply@placeholder.azurecomm.net` value in Key Vault when ACS is enabled without a custom domain. After the ACS domain is verified, run `scripts/acs-smtp-setup.sh` to:

- Create or reuse a Microsoft Entra application with an SMTP client secret
- Assign the Communication and Email Service Owner role to the application
- Provision an SMTP username bound to the ACS resource
- Update the Key Vault secrets for both the SMTP connection string and the verified email-from address

If you provide an explicit `emailFromAddress` parameter the template stores that value instead; the script respects the override and only updates the SMTP connection string.

> **Important**: The Bicep template also seeds a temporary SMTP connection string so the Container App can provision successfully. Every time you redeploy the template you must rerun `scripts/acs-smtp-setup.sh` to restore the real SMTP secret.

### Enable Communication Services in Deployment

Deploy the infrastructure with Communication Services enabled, then run the SMTP setup script once the domain is ready.

```bash
# Deploy with Azure-managed domain (infrastructure only)
az deployment group create \
  --resource-group mensmachina \
  --template-file infra/main.bicep \
  --parameters namePrefix=pds \
               pdsHostname=pds.mensmachina.com \
               pdsImageTag=0.4 \
               enableCommunicationServices=true \
               adminObjectId=your-admin-object-id \
               pdsJwtSecretName=PDS-JWT-SECRET \
               pdsAdminPasswordSecretName=PDS-ADMIN-PASSWORD \
               pdsPlcRotationKeySecretName=PDS-PLC-ROTATION-KEY-K256-PRIVATE-KEY-HEX \
               smtpSecretName=PDS-SMTP-URL \
               dnsZoneName=mensmachina.com

# Custom domain deployment (requires DNS/verification)
az deployment group create \
  --resource-group mensmachina \
  --template-file infra/main.bicep \
  --parameters namePrefix=pds \
               pdsHostname=pds.mensmachina.com \
               pdsImageTag=0.4 \
               enableCommunicationServices=true \
               emailCustomDomain=notify.mensmachina.com \
               adminObjectId=your-admin-object-id \
               pdsJwtSecretName=PDS-JWT-SECRET \
               pdsAdminPasswordSecretName=PDS-ADMIN-PASSWORD \
               pdsPlcRotationKeySecretName=PDS-PLC-ROTATION-KEY-K256-PRIVATE-KEY-HEX \
               smtpSecretName=PDS-SMTP-URL \
               dnsZoneName=mensmachina.com

# After the deployment succeeds (and the domain shows Verified), populate SMTP credentials
./scripts/acs-smtp-setup.sh \
  --resource-group mensmachina \
  --communication-service pds-acs \
  --email-service pds-email \
  --key-vault <name from deployment output> \
  --smtp-secret-name PDS-SMTP-URL \
  --email-secret-name PDS-EMAIL-FROM-ADDRESS
```

> **Tip**: The script requires Azure CLI permissions to create Microsoft Entra applications. Run it as an operator with the **Application Administrator** role (or equivalent) in the tenant.

### SMTP Setup Script

`scripts/acs-smtp-setup.sh` automates the ACS integration work that cannot be expressed directly in Bicep. The script is idempotent—it reuses existing resources when present and rotates credentials safely. The infrastructure template expects the SMTP connection string to live in the `PDS-SMTP-URL` Key Vault secret unless you override the `smtpSecretName` parameter.

| Parameter | Description |
|-----------|-------------|
| `--resource-group` | Resource group that hosts the ACS resources |
| `--communication-service` | Communication Service name (default pattern: `<prefix>-acs`) |
| `--email-service` | Email Service name (default pattern: `<prefix>-email`) |
| `--key-vault` | Key Vault name output from the deployment |
| `--smtp-secret-name` | Secret that stores the SMTP connection string (defaults to `PDS-SMTP-URL`) |
| `--email-secret-name` | Secret that stores the email-from address (defaults to `PDS-EMAIL-FROM-ADDRESS`) |
| `--custom-domain` | Optional: skip Azure-managed domain polling and use your custom domain value |
| `--email-from-address` | Optional override for the email-from address if you do not want `donotreply@domain` |

The script installs the Azure Communication Services CLI extension on first use, waits for the Azure-managed domain to report `Verified`, and then pushes the secrets to Key Vault. Container Apps pick up the updated values automatically because the environment uses Key Vault references.

## Custom Domain Setup

If using a custom domain, you must verify domain ownership and configure sender authentication:

### 1. Domain Verification

Add a TXT record to your DNS:

| Record Type | Name | Value |
|-------------|------|-------|
| TXT | @ | `ms-domain-verification=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |

### 2. Sender Policy Framework (SPF)

Add an SPF record to authorize Azure Communication Services:

| Record Type | Name | Value |
|-------------|------|-------|
| TXT | notify.yourdomain.com | `v=spf1 include:spf.protection.outlook.com -all` |

### 3. DomainKeys Identified Mail (DKIM)

Add DKIM CNAME records for email signing:

| Record Type | Name | Value |
|-------------|------|-------|
| CNAME | `selector1-azurecomm-prod-net._domainkey.notify.yourdomain.com` | `selector1-azurecomm-prod-net._domainkey.azurecomm.net` |
| CNAME | `selector2-azurecomm-prod-net._domainkey.notify.yourdomain.com` | `selector2-azurecomm-prod-net._domainkey.azurecomm.net` |

### 4. Verify Domain Status

Check domain verification in the Azure Portal:

1. Navigate to your Email Communication Service
2. Go to **Provision Domains**
3. Verify the domain status shows as **Verified**
4. Confirm SPF and DKIM show as **Verified**

## SMTP Configuration

The deployment automatically configures SMTP authentication:

### SMTP Settings
- **Server**: `smtp.azurecomm.net`
- **Port**: `587` (recommended) or `25`
- **Security**: TLS/StartTLS (required)
- **Authentication**: Username/Password fetched from the Key Vault secret configured above

### Credentials
- **Username**: SMTP username created by the script (defaults to the email-from address)
- **Password**: Microsoft Entra client secret stored in Key Vault
- **Connection String**: Secret value in Key Vault (default secret name `PDS-SMTP-URL`)

## Security Configuration

### Microsoft Entra Application

Run `scripts/acs-smtp-setup.sh` after each deployment to ensure:

1. A Microsoft Entra application exists (created if missing) with an active 2-year client secret
2. The application has the **Communication and Email Service Owner** role scoped to the Communication Service
3. An SMTP username resource links the application to ACS for SMTP authentication
4. Key Vault secrets contain both the SMTP connection string and the canonical email-from address

### Key Vault Integration

SMTP credentials are securely stored in Key Vault:
- **Secret Name**: `PDS-SMTP-URL` (configurable via `smtpSecretName` parameter)
- **Format**: `smtps://appid:secret@smtp.azurecomm.net:587`
- **Access**: Container App has read-only access via system-assigned managed identity

## Testing Email Configuration

### 1. Verify SMTP Connectivity

Test SMTP connection manually:

```bash
# Install telnet if not available
sudo apt-get install telnet

# Test SMTP connection
telnet smtp.azurecomm.net 587
```

### 2. Send Test Email via Azure Portal

1. Navigate to Communication Services resource
2. Go to **Try Email** 
3. Send a test email to verify configuration

### 3. Check PDS Email Functionality

Monitor PDS logs for email sending:

```bash
# View Container App logs
az containerapp logs show \
  --name pds-pds-app \
  --resource-group mensmachina \
  --follow
```

## Troubleshooting

### Common Issues

#### Domain Verification Failed
- **Cause**: DNS TXT record not propagated or incorrect
- **Solution**: Wait 15-30 minutes, verify DNS record with `nslookup -q=TXT yourdomain.com`

#### SMTP Authentication Failed
- **Cause**: Incorrect credentials or expired client secret
- **Solution**: Regenerate client secret, update Key Vault secret

#### Email Delivery Issues
- **Cause**: Missing SPF/DKIM records, recipient blocking
- **Solution**: Verify all DNS records, check spam folders

#### Entra Application Creation Failed
- **Cause**: Insufficient permissions for deployment script
- **Solution**: Ensure deployment identity has Application Administrator role

### Diagnostic Commands

```bash
# Check Communication Services status
az communication list --resource-group mensmachina

# Check Email Service domains
az communication email domain list \
  --email-service-name pds-email \
  --resource-group mensmachina

# Verify Key Vault secret
az keyvault secret show \
  --vault-name pds-xxxxx-kv \
  --name PDS-SMTP-URL \
  --query value

# Inspect SMTP username bindings
az communication smtp-username list \
  --comm-service-name pds-acs \
  --resource-group mensmachina
```

## Cost Optimization

### Pricing Considerations
- **Azure Communication Services**: Pay-per-use for emails sent
- **Email Service**: No base charge, transaction-based pricing
- **SMTP Relay**: Included with Communication Services
- **Storage**: Minimal cost for credential storage

### Cost Management
- Monitor email volume in Azure Portal
- Set up billing alerts for unexpected usage
- Consider email throttling in PDS configuration

## Next Steps

1. **Deploy Infrastructure**: Run the updated Bicep template
2. **Configure DNS**: Set up domain verification and authentication records
3. **Test Email Flow**: Send verification emails through PDS
4. **Monitor Usage**: Set up alerts and monitoring
5. **Scale Considerations**: Plan for user growth and email volume

## References

- [Azure Communication Services Email Documentation](https://learn.microsoft.com/en-us/azure/communication-services/concepts/email/)
- [SMTP Authentication Setup](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication)
- [Custom Domain Configuration](https://learn.microsoft.com/en-us/azure/communication-services/quickstarts/email/add-custom-verified-domains)
- [DNS Record Management](https://learn.microsoft.com/en-us/azure/dns/)