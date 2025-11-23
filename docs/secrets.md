# Azure PDS Secrets Management Guide

This guide covers the secure management of secrets for the Azure PDS infrastructure, including creation, rotation, and audit procedures.

## Overview

The Azure PDS deployment uses Azure Key Vault to securely store and manage sensitive configuration data. This approach ensures secrets are never stored in code repositories or deployment templates while providing audit trails and centralized management.

## Required Secrets

The following secrets must be created in the Key Vault before the PDS application can function properly:

### 1. PDS JWT Secret (`PDS-JWT-SECRET`)
- **Purpose**: Used for signing and verifying JWT tokens within the PDS
- **Format**: Base64-encoded random string (minimum 32 characters)
- **Generation**: 
  ```bash
  openssl rand -base64 32
  ```

### 2. PDS Admin Password (`PDS-ADMIN-PASSWORD`)
- **Purpose**: Administrative access to PDS management endpoints
- **Format**: Strong password (minimum 16 characters)
- **Requirements**: Mix of letters, numbers, and special characters
- **Generation**:
  ```bash
  openssl rand -base64 24
  ```

### 3. PLC Rotation Key (`PDS-PLC-KEY`)
- **Purpose**: Private key for Personal Ledger Capacity (PLC) operations
- **Format**: Hexadecimal-encoded private key
- **Generation**: Use the PDS tooling or:
  ```bash
  openssl ecparam -genkey -name secp256k1 -noout -outform DER | xxd -p -c 256
  ```

### 4. SMTP Secret (`PDS-SMTP-SECRET`)
- **Purpose**: Email sending configuration for PDS notifications
- **Format**: SMTP connection string or password
- **Example formats**:
  - `smtps://username:password@smtp.provider.com:465`
  - `smtp://username:password@smtp.provider.com:587`

### 5. Storage Account Key (`storage-account-key`)
- **Purpose**: Automatically created by deployment template
- **Management**: Managed by Azure automation, do not modify manually

## Secret Creation Workflow

### Prerequisites
- Azure CLI authenticated with appropriate permissions
- Key Vault Secrets Officer role on the target Key Vault
- Generated secret values using secure methods

### Step-by-Step Process

1. **Identify the Key Vault name** from deployment outputs:
   ```bash
   # From deployment output or resource listing
   KEY_VAULT_NAME="<namePrefix>-kv"
   ```

2. **Create secrets using Azure CLI**:
   ```bash
   # Set the Key Vault name
   export KEY_VAULT_NAME="your-keyvault-name"
   
   # Create JWT secret
   JWT_SECRET=$(openssl rand -base64 32)
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-JWT-SECRET" \
     --value "$JWT_SECRET"
   
   # Create admin password
   ADMIN_PASSWORD=$(openssl rand -base64 24)
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-ADMIN-PASSWORD" \
     --value "$ADMIN_PASSWORD"
   
   # Create PLC key (example - use proper key generation)
   PLC_KEY="your-generated-hex-key"
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-PLC-KEY" \
     --value "$PLC_KEY"
   
   # Create SMTP secret
   SMTP_SECRET="smtps://user:pass@smtp.example.com:465"
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-SMTP-SECRET" \
     --value "$SMTP_SECRET"
   ```

3. **Verify secret creation**:
   ```bash
   az keyvault secret list \
     --vault-name "$KEY_VAULT_NAME" \
     --query "[].{Name:name, Enabled:attributes.enabled}" \
     --output table
   ```

4. **Restart Container App** (if secrets were created after deployment):
   ```bash
   az containerapp revision restart \
     --name "<CONTAINER_APP_NAME>" \
     --resource-group "<RESOURCE_GROUP>"
   ```

## Secret Rotation Procedures

Regular secret rotation is essential for maintaining security. Follow these procedures for each secret type.

### JWT Secret Rotation
**Frequency**: Every 90 days

**Process**:
1. Generate new JWT secret:
   ```bash
   NEW_JWT_SECRET=$(openssl rand -base64 32)
   ```

2. Update Key Vault:
   ```bash
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-JWT-SECRET" \
     --value "$NEW_JWT_SECRET"
   ```

3. Restart Container App:
   ```bash
   az containerapp revision restart \
     --name "<CONTAINER_APP_NAME>" \
     --resource-group "<RESOURCE_GROUP>"
   ```

4. **Important**: Coordinate rotation to minimize user session disruption

### Admin Password Rotation
**Frequency**: Every 60 days

**Process**:
1. Generate new password:
   ```bash
   NEW_ADMIN_PASSWORD=$(openssl rand -base64 24)
   ```

2. Update Key Vault:
   ```bash
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-ADMIN-PASSWORD" \
     --value "$NEW_ADMIN_PASSWORD"
   ```

3. Restart Container App and update any automation that uses admin access

### PLC Key Rotation
**Frequency**: Every 180 days or as required by security policy

**Process**:
1. Generate new PLC key using PDS tooling
2. Update Key Vault with new key
3. Coordinate with PLC infrastructure if applicable
4. Restart Container App

### SMTP Secret Rotation
**Frequency**: As required by email provider policy

**Process**:
1. Update password/credentials with email provider
2. Update Key Vault with new credentials:
   ```bash
   az keyvault secret set \
     --vault-name "$KEY_VAULT_NAME" \
     --name "PDS-SMTP-SECRET" \
     --value "$NEW_SMTP_SECRET"
   ```
3. Restart Container App
4. Test email functionality

## Container App Restart Procedures

After updating secrets, the Container App must be restarted to load the new values.

### Restart Methods

1. **Graceful restart** (recommended):
   ```bash
   az containerapp revision restart \
     --name "<CONTAINER_APP_NAME>" \
     --resource-group "<RESOURCE_GROUP>"
   ```

2. **Force revision update** (if restart fails):
   ```bash
   az containerapp update \
     --name "<CONTAINER_APP_NAME>" \
     --resource-group "<RESOURCE_GROUP>" \
     --revision-suffix "$(date +%Y%m%d-%H%M%S)"
   ```

### Post-Restart Verification

1. **Check Container App status**:
   ```bash
   az containerapp show \
     --name "<CONTAINER_APP_NAME>" \
     --resource-group "<RESOURCE_GROUP>" \
     --query "properties.runningStatus"
   ```

2. **Verify health endpoint**:
   ```bash
   curl -f https://<PDS_HOSTNAME>/xrpc/_health
   ```

3. **Check application logs** for secret-related errors:
   ```bash
   az containerapp logs show \
     --name "<CONTAINER_APP_NAME>" \
     --resource-group "<RESOURCE_GROUP>" \
     --follow
   ```

## Security Best Practices

### Secret Generation
- Use cryptographically secure random generators
- Never use predictable patterns or dictionary words
- Generate secrets with sufficient entropy (minimum 128 bits)
- Use different secrets for each environment (dev/staging/prod)

### Access Control
- Limit Key Vault access to essential personnel only
- Use Azure AD groups for permission management
- Enable Key Vault access logging and monitoring
- Regularly review access permissions

### Storage and Transit
- Never store secrets in code repositories
- Avoid plain text files or documentation
- Use encrypted channels for secret distribution
- Implement proper secret scanning in CI/CD pipelines

### Monitoring and Auditing
- Enable Key Vault diagnostic logging
- Monitor secret access patterns
- Set up alerts for unusual activity
- Maintain audit trails for all secret operations

## Troubleshooting

### Common Issues

#### Container App Cannot Access Secrets
**Symptoms**: Application startup failures, authentication errors

**Resolution**:
1. Verify managed identity has Key Vault access:
   ```bash
   az keyvault show --name "$KEY_VAULT_NAME" --query "properties.accessPolicies"
   ```

2. Check secret names match template configuration:
   ```bash
   az keyvault secret list --vault-name "$KEY_VAULT_NAME" --output table
   ```

3. Verify secret values are not empty or malformed

#### Secret Rotation Failures
**Symptoms**: Old secrets still in use after rotation

**Resolution**:
1. Confirm Key Vault was updated successfully
2. Restart Container App to load new secrets
3. Check for cached values in application code

#### Key Vault Access Denied
**Symptoms**: Permission errors when accessing secrets

**Resolution**:
1. Verify user has appropriate Key Vault roles
2. Check firewall and access policies
3. Confirm Key Vault is in expected subscription/resource group

### Emergency Procedures

#### Compromised Secret
1. **Immediately rotate** the compromised secret
2. **Audit access logs** to identify potential breach scope
3. **Restart all services** using the secret
4. **Review security policies** and access controls
5. **Document incident** for security review

#### Key Vault Unavailable
1. **Check Azure service health** for Key Vault issues
2. **Verify network connectivity** to Key Vault
3. **Review access policies** and firewall rules
4. **Consider failover procedures** if critical

## Automation and Integration

### CI/CD Integration
- Use Azure DevOps variable groups or GitHub secrets for pipeline variables
- Never commit secrets to version control
- Implement secret scanning in pull request validation
- Use managed identities for service-to-service authentication

### Monitoring Integration
- Set up Azure Monitor alerts for Key Vault access failures
- Create dashboards for secret rotation schedules
- Implement automated testing for secret functionality
- Monitor certificate expiration for HTTPS endpoints

## Compliance Considerations

### Regulatory Requirements
- Maintain audit logs for secret access and modifications
- Implement appropriate retention policies for secret history
- Document secret lifecycle management procedures
- Regular compliance audits and reporting

### Corporate Policies
- Follow organization-specific password policies
- Implement required secret rotation intervals
- Use approved secret generation methods
- Maintain incident response procedures

This guide should be regularly updated to reflect changes in security requirements, Azure services, and organizational policies.