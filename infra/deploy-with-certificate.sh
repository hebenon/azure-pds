#!/bin/bash

# Example deployment script for Bluesky PDS with separate certificate management
# This script demonstrates the two-step process: certificate creation + infrastructure deployment

set -e

# Configuration - Update these values for your environment
RESOURCE_GROUP="${RESOURCE_GROUP:-"pds-production"}"
NAME_PREFIX="${NAME_PREFIX:-"pdsprod"}"
HOSTNAME="${HOSTNAME:-"pds.example.com"}"
DNS_ZONE="${DNS_ZONE:-"example.com"}"
LOCATION="${LOCATION:-"eastus"}"
PDS_IMAGE_TAG="${PDS_IMAGE_TAG:-"latest"}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Bluesky PDS Deployment with Certificate Management ===${NC}"
echo ""

# Step 1: Create or get existing certificate
echo -e "${YELLOW}Step 1: Certificate Management${NC}"
echo "Checking for existing certificate..."

# Check if certificate already exists
CERT_NAME="${NAME_PREFIX}-managed-cert"
MANAGED_ENV_NAME="${NAME_PREFIX}-cae"

CERT_ID=$(az containerapp env certificate list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$MANAGED_ENV_NAME" \
    --certificate "$CERT_NAME" \
    --managed-certificates-only \
    --query "[0].id" \
    -o tsv 2>/dev/null || echo "")

if [[ -n "$CERT_ID" ]]; then
    echo -e "${GREEN}✓ Found existing certificate${NC}"
    echo "Certificate ID: $CERT_ID"
else
    echo "Certificate not found. Creating new certificate..."
    echo ""
    
    # Create certificate using the script
    if [[ -f "./create-managed-certificate.sh" ]]; then
        ./create-managed-certificate.sh \
            -g "$RESOURCE_GROUP" \
            -n "$NAME_PREFIX" \
            -d "$HOSTNAME" \
            -l "$LOCATION" \
            -v HTTP
        
        # Get the certificate ID
        CERT_ID=$(az containerapp env certificate list \
            --resource-group "$RESOURCE_GROUP" \
            --name "$MANAGED_ENV_NAME" \
            --certificate "$CERT_NAME" \
            --managed-certificates-only \
            --query "[0].id" \
            -o tsv)
        
        if [[ -z "$CERT_ID" ]]; then
            echo "Failed to get certificate ID after creation"
            exit 1
        fi
    else
        echo "Error: create-managed-certificate.sh not found"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}✓ Certificate ready${NC}"
echo "Certificate ID: $CERT_ID"
echo ""

# Step 2: Deploy infrastructure
echo -e "${YELLOW}Step 2: Infrastructure Deployment${NC}"
echo "Deploying Azure resources..."

# Check if main.bicep exists
if [[ ! -f "./main.bicep" ]]; then
    echo "Error: main.bicep not found in current directory"
    exit 1
fi

# Deploy the infrastructure
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file ./main.bicep \
    --parameters \
        namePrefix="$NAME_PREFIX" \
        pdsHostname="$HOSTNAME" \
        pdsImageTag="$PDS_IMAGE_TAG" \
        certificateResourceId="$CERT_ID" \
        enableCustomDomain=true \
        dnsZoneName="$DNS_ZONE" \
        dnsRecordName="pds" \
        location="$LOCATION" \
    --output table

echo ""
echo -e "${GREEN}✓ Infrastructure deployment completed${NC}"
echo ""

# Step 3: Verification
echo -e "${YELLOW}Step 3: Verification${NC}"
echo "Checking deployment status..."

# Get container app FQDN
CONTAINER_APP_NAME="${NAME_PREFIX}-pds-app"
FQDN=$(az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --query "properties.configuration.ingress.fqdn" \
    -o tsv)

echo "Container App FQDN: $FQDN"
echo ""

# Check custom domain configuration
echo "Custom domain configuration:"
az containerapp show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --query "properties.configuration.ingress.customDomains" \
    --output table

echo ""

# Check certificate status
echo "Certificate status:"
az containerapp env certificate list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$MANAGED_ENV_NAME" \
    --certificate "$CERT_NAME" \
    --managed-certificates-only \
    --query "[0].{Name:name,Status:properties.provisioningState,Subject:properties.subjectName}" \
    --output table

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
echo "Your Bluesky PDS is available at:"
echo "  Public URL: https://$FQDN"
echo "  Custom Domain: https://$HOSTNAME"
echo ""
echo "Next steps:"
echo "1. Verify DNS records are properly configured"
echo "2. Configure your PDS secrets in Key Vault"
echo "3. Test the PDS endpoint"
echo ""

# Optional: Wait for the app to be ready and show logs
echo -e "${YELLOW}Waiting for container to start...${NC}"
sleep 30

echo "Recent container logs:"
az containerapp logs show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CONTAINER_APP_NAME" \
    --tail 20 \
    --output tsv || echo "Could not retrieve logs (container may still be starting)"

echo ""
echo -e "${GREEN}✓ Deployment script finished${NC}"