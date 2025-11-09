# Azure Container Apps Certificate Management for Bluesky PDS

This document describes the certificate management approach for the Bluesky PDS deployment on Azure Container Apps, which separates certificate creation from infrastructure deployment to resolve idempotency issues.

## Problem Statement

The previous implementation attempted to create managed certificates as part of the infrastructure deployment, which led to several issues:

1. **Idempotency Problems**: Managed certificates cannot be updated once created, causing failures on subsequent deployments
2. **Circular Dependencies**: Certificate creation required DNS verification records, which in turn required the container app to exist
3. **Verification Failures**: DNS validation timing issues and validation method problems
4. **Deployment Complexity**: Certificate lifecycle was tightly coupled with infrastructure deployment

## Solution Overview

The refactored approach **separates certificate management from infrastructure deployment**:

1. **Certificate Creation**: Use the `create-managed-certificate.sh` script to create and validate certificates
2. **Infrastructure Deployment**: The Bicep template assumes the certificate exists and only handles binding
3. **Clear Separation**: Certificate lifecycle is managed independently from application infrastructure

## Workflow

### Step 1: Create and Validate Certificate

First, create the managed certificate using the CLI script:

```bash
# Make the script executable
chmod +x create-managed-certificate.sh

# Create certificate using HTTP validation (recommended)
./create-managed-certificate.sh \
  -g my-resource-group \
  -n mypds \
  -d pds.example.com \
  -v HTTP

# Or using TXT validation (if HTTP is not suitable)
./create-managed-certificate.sh \
  -g my-resource-group \
  -n mypds \
  -d pds.example.com \
  -v TXT
```

The script will:
- Check if the certificate already exists
- Create the certificate if it doesn't exist
- Wait for validation and provisioning (up to 10 minutes)
- Output the certificate resource ID

### Step 2: Deploy Infrastructure with Certificate Binding

Use the certificate resource ID from Step 1 in your Bicep deployment:

```bash
# Deploy with custom domain and certificate
az deployment group create \
  --resource-group my-resource-group \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=mypds \
    pdsHostname=pds.example.com \
    pdsImageTag=latest \
    certificateResourceId="/subscriptions/xxx/resourceGroups/my-rg/providers/Microsoft.App/managedEnvironments/mypds-cae/managedCertificates/mypds-managed-cert" \
    enableCustomDomain=true \
    dnsZoneName=example.com \
    dnsRecordName=pds
```

### Step 3: Verify Deployment

Check that the custom domain is properly configured:

```bash
# Check certificate status
az containerapp env certificate list \
  --resource-group my-resource-group \
  --name mypds-cae \
  --certificate mypds-managed-cert \
  --managed-certificates-only

# Check container app custom domain
az containerapp show \
  --resource-group my-resource-group \
  --name mypds-pds-app \
  --query "properties.configuration.ingress.customDomains"
```

## Parameters

### Certificate Creation Script

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `-g, --resource-group` | Azure resource group name | Yes | - |
| `-n, --name-prefix` | Name prefix for resources | Yes | - |
| `-d, --hostname` | Fully qualified hostname (e.g., pds.example.com) | Yes | - |
| `-l, --location` | Azure region | No | Resource group location |
| `-v, --validation-method` | Validation method: 'TXT' or 'HTTP' | No | 'HTTP' |

### Bicep Template

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `certificateResourceId` | Resource ID of existing certificate | No (but required for custom domain) | `''` |
| `enableCustomDomain` | Enable custom domain binding | No | `false` |
| `pdsHostname` | Fully qualified hostname | Yes | - |
| `dnsZoneName` | DNS zone name for verification records | No | `''` |
| `dnsRecordName` | DNS record name within zone | No | `pds` |

## Certificate Lifecycle Management

### Certificate Renewal

Azure Container Apps automatically renews managed certificates 30 days before expiration. No manual intervention is required.

### Certificate Replacement

To replace a certificate (e.g., when changing domains):

1. Create a new certificate using the script with the new hostname
2. Update the `certificateResourceId` parameter in your deployment
3. Redeploy the infrastructure

### Certificate Deletion

To remove a certificate:

```bash
# Remove certificate binding from container app
az containerapp env certificate delete \
  --resource-group my-resource-group \
  --name mypds-cae \
  --certificate mypds-managed-cert
```

## Validation Methods

### HTTP Validation (Recommended)

- **Pros**: More reliable, faster validation
- **Cons**: Requires the container app to be publicly accessible
- **Best for**: Most deployments where the PDS is publicly accessible

### TXT Validation

- **Pros**: Works before container app is deployed
- **Cons**: DNS propagation delays, more complex setup
- **Best for**: Pre-deployment validation or when HTTP validation is not possible

## Troubleshooting

### Certificate Creation Fails

1. **Check DNS Configuration**: Ensure the hostname resolves correctly
2. **Validation Method**: Try switching between HTTP and TXT validation
3. **Permissions**: Verify Azure CLI has necessary permissions
4. **Logs**: Check Azure Portal for detailed error messages

### Certificate Binding Fails

1. **Certificate ID**: Verify the `certificateResourceId` parameter is correct
2. **Certificate Status**: Ensure certificate is in "Succeeded" state
3. **Region Mismatch**: Certificate and container app must be in the same region
4. **Dependencies**: Check that DNS verification records exist if using TXT validation

### Custom Domain Not Working

1. **DNS Records**: Verify DNS records point to the container app
2. **Certificate Binding**: Check that certificate is properly bound
3. **Container App**: Ensure container app is running and accessible

## Benefits of This Approach

1. **Idempotency**: Infrastructure deployments are now idempotent
2. **Separation of Concerns**: Certificate lifecycle independent of app deployment
3. **Flexibility**: Easy to use different certificates for different environments
4. **Reliability**: Clear error handling and validation
5. **Maintainability**: Simpler Bicep templates without certificate creation logic

## Example: Complete Deployment

```bash
#!/bin/bash

# Configuration
RESOURCE_GROUP="pds-production"
NAME_PREFIX="pdsprod"
HOSTNAME="pds.example.com"
DNS_ZONE="example.com"
LOCATION="eastus"

# Step 1: Create certificate
echo "Creating certificate..."
CERT_ID=$(./create-managed-certificate.sh \
  -g "$RESOURCE_GROUP" \
  -n "$NAME_PREFIX" \
  -d "$HOSTNAME" \
  -l "$LOCATION" \
  -v HTTP | grep "Certificate Resource ID:" | cut -d' ' -f4-)

if [[ -z "$CERT_ID" ]]; then
    echo "Failed to create certificate"
    exit 1
fi

echo "Certificate created: $CERT_ID"

# Step 2: Deploy infrastructure
echo "Deploying infrastructure..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix="$NAME_PREFIX" \
    pdsHostname="$HOSTNAME" \
    pdsImageTag="latest" \
    certificateResourceId="$CERT_ID" \
    enableCustomDomain=true \
    dnsZoneName="$DNS_ZONE" \
    dnsRecordName="pds" \
    location="$LOCATION"

echo "Deployment complete!"

# Step 3: Verify
echo "Verifying deployment..."
az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "${NAME_PREFIX}-pds-app" \
  --query "properties.configuration.ingress.customDomains"
```

## Notes

- The certificate must be in the same resource group and region as the container app
- Certificate validation can take 5-10 minutes
- The script includes retry logic and timeout handling
- DNS records are automatically created if `dnsZoneName` is provided