#!/bin/bash

# Script to create and validate an Azure Container Apps managed certificate
# This separates certificate creation from infrastructure deployment to avoid idempotency issues

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

print_success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

print_info() {
    echo -e "${YELLOW}INFO:${NC} $1"
}

# Check if required tools are installed
if ! command -v az &> /dev/null; then
    print_error "Azure CLI is not installed. Please install it first."
    exit 1
fi

# Check if user is logged in
if ! az account show &> /dev/null; then
    print_error "Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

# Function to display usage
usage() {
    cat << EOF
Usage: $0 -g <resource-group> -n <name-prefix> -d <hostname> [-l <location>] [-v <validation-method>]

Create and validate an Azure Container Apps managed certificate.

Options:
    -g, --resource-group     Azure resource group name (required)
    -n, --name-prefix        Name prefix for resources (required)
    -d, --hostname           Fully qualified hostname (required)
    -l, --location           Azure region (optional, defaults to resource group location)
    -v, --validation-method  Domain validation method: 'TXT' or 'HTTP' (optional, default: 'HTTP')
    -h, --help               Show this help message

Examples:
    $0 -g my-rg -n mypds -d pds.example.com
    $0 -g my-rg -n mypds -d pds.example.com -l eastus -v TXT

EOF
}

# Parse command line arguments
RESOURCE_GROUP=""
NAME_PREFIX=""
HOSTNAME=""
LOCATION=""
VALIDATION_METHOD="HTTP"

while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -n|--name-prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        -d|--hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -v|--validation-method)
            VALIDATION_METHOD="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$RESOURCE_GROUP" ]]; then
    print_error "Resource group is required"
    usage
    exit 1
fi

if [[ -z "$NAME_PREFIX" ]]; then
    print_error "Name prefix is required"
    usage
    exit 1
fi

if [[ -z "$HOSTNAME" ]]; then
    print_error "Hostname is required"
    usage
    exit 1
fi

if [[ "$VALIDATION_METHOD" != "TXT" && "$VALIDATION_METHOD" != "HTTP" ]]; then
    print_error "Validation method must be 'TXT' or 'HTTP'"
    exit 1
fi

# Get resource group location if not provided
if [[ -z "$LOCATION" ]]; then
    LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
    print_info "Using resource group location: $LOCATION"
fi

# Variables
MANAGED_ENV_NAME="${NAME_PREFIX}-cae"
CERTIFICATE_NAME="${NAME_PREFIX}-managed-cert"

print_info "Creating managed certificate for ${HOSTNAME}..."
print_info "Resource Group: ${RESOURCE_GROUP}"
print_info "Managed Environment: ${MANAGED_ENV_NAME}"
print_info "Certificate Name: ${CERTIFICATE_NAME}"
print_info "Validation Method: ${VALIDATION_METHOD}"

# Check if certificate already exists
print_info "Checking if certificate already exists..."
CERT_EXISTS=$(az containerapp env certificate list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$MANAGED_ENV_NAME" \
    --certificate "$CERTIFICATE_NAME" \
    --managed-certificates-only \
    --query "[?name=='${CERTIFICATE_NAME}'] | length(@)" \
    -o tsv 2>/dev/null || echo "0")

if [[ "$CERT_EXISTS" -gt 0 ]]; then
    print_info "Certificate ${CERTIFICATE_NAME} already exists. Checking its status..."
    
    CERT_STATUS=$(az containerapp env certificate list \
        --resource-group "$RESOURCE_GROUP" \
        --name "$MANAGED_ENV_NAME" \
        --certificate "$CERTIFICATE_NAME" \
        --managed-certificates-only \
        --query "[0].properties.provisioningState" \
        -o tsv 2>/dev/null || echo "")
    
    if [[ "$CERT_STATUS" == "Succeeded" || "$CERT_STATUS" == "Provisioned" ]]; then
        print_success "Certificate already provisioned successfully"
        
        CERT_RESOURCE_ID=$(az containerapp env certificate list \
            --resource-group "$RESOURCE_GROUP" \
            --name "$MANAGED_ENV_NAME" \
            --certificate "$CERTIFICATE_NAME" \
            --managed-certificates-only \
            --query "[0].id" \
            -o tsv)
        
        print_success "Certificate Resource ID: ${CERT_RESOURCE_ID}"
        echo ""
        print_info "Use this resource ID as the certificateResourceId parameter in your Bicep deployment"
        exit 0
    else
        print_info "Certificate exists but status is: ${CERT_STATUS}"
        print_info "Continuing with validation..."
    fi
else
    print_info "Certificate does not exist. Creating..."
    
    # Create the certificate
    az containerapp env certificate create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$MANAGED_ENV_NAME" \
        --certificate-name "$CERTIFICATE_NAME" \
        --hostname "$HOSTNAME" \
        --validation-method "$VALIDATION_METHOD" \
        --location "$LOCATION" \
        --output none
    
    print_success "Certificate creation initiated"
fi

# Wait for certificate to be ready
print_info "Waiting for certificate validation and provisioning..."
print_info "This may take several minutes..."

MAX_ATTEMPTS=60  # 10 minutes with 10-second intervals
ATTEMPT=0

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    CERT_STATUS=$(az containerapp env certificate list \
        --resource-group "$RESOURCE_GROUP" \
        --name "$MANAGED_ENV_NAME" \
        --certificate "$CERTIFICATE_NAME" \
        --managed-certificates-only \
        --query "[0].properties.provisioningState" \
        -o tsv 2>/dev/null || echo "NotFound")
    
    case "$CERT_STATUS" in
        "Succeeded"|"Provisioned")
            print_success "Certificate provisioned successfully!"
            break
            ;;
        "Pending")
            print_info "Certificate validation pending... (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS)"
            ;;
        "Failed")
            print_error "Certificate provisioning failed"
            
            # Get failure details
            FAILURE_REASON=$(az containerapp env certificate list \
                --resource-group "$RESOURCE_GROUP" \
                --name "$MANAGED_ENV_NAME" \
                --certificate "$CERTIFICATE_NAME" \
                --managed-certificates-only \
                --query "[0].properties.error" \
                -o tsv 2>/dev/null || echo "Unknown error")
            
            print_error "Failure reason: $FAILURE_REASON"
            exit 1
            ;;
        *)
            print_info "Certificate status: ${CERT_STATUS} (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS)"
            ;;
    esac
    
    ATTEMPT=$((ATTEMPT + 1))
    
    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
        sleep 10
    fi
done

if [[ $ATTEMPT -eq $MAX_ATTEMPTS ]]; then
    print_error "Timeout waiting for certificate provisioning"
    print_error "Certificate may still be provisioning. Check status in Azure Portal or with:"
    print_error "az containerapp env certificate list -g $RESOURCE_GROUP --name $MANAGED_ENV_NAME --certificate $CERTIFICATE_NAME --managed-certificates-only"
    exit 1
fi

# Get the certificate resource ID
CERT_RESOURCE_ID=$(az containerapp env certificate list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$MANAGED_ENV_NAME" \
    --certificate "$CERTIFICATE_NAME" \
    --managed-certificates-only \
    --query "[0].id" \
    -o tsv)

if [[ -z "$CERT_RESOURCE_ID" ]]; then
    print_error "Failed to get certificate resource ID"
    exit 1
fi

print_success "Certificate creation completed!"
echo ""
print_info "Certificate Resource ID:"
echo "$CERT_RESOURCE_ID"
echo ""
print_info "Use this resource ID as the certificateResourceId parameter in your Bicep deployment"
print_info "Example:"
echo "  az deployment group create \\"
echo "    --resource-group $RESOURCE_GROUP \\"
echo "    --template-file main.bicep \\"
echo "    --parameters certificateResourceId='$CERT_RESOURCE_ID' enableCustomDomain=true"
echo ""
print_info "Certificate details:"
az containerapp env certificate list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$MANAGED_ENV_NAME" \
    --certificate "$CERTIFICATE_NAME" \
    --managed-certificates-only \
    --output table