#!/bin/bash
# 
# Baseline deployment script for User Story 1: Deploy baseline environment
# Validates infra/main.bicep using 'az deployment group what-if'
#

set -euo pipefail

# Configuration - update these values before running
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
PDS_HOSTNAME="${PDS_HOSTNAME:-}"
PDS_IMAGE_TAG="${PDS_IMAGE_TAG:-}"
DNS_ZONE_NAME="${DNS_ZONE_NAME:-}"
DNS_RECORD_NAME="${DNS_RECORD_NAME:-pds}"
ADMIN_OBJECT_ID="${ADMIN_OBJECT_ID:-}"
EMAIL_FROM_ADDRESS="${EMAIL_FROM_ADDRESS:-}"

# Required secret names (ensure these are created in Key Vault)
PDS_JWT_SECRET_NAME="${PDS_JWT_SECRET_NAME:-PDS-JWT-SECRET}"
PDS_ADMIN_PASSWORD_SECRET_NAME="${PDS_ADMIN_PASSWORD_SECRET_NAME:-PDS-ADMIN-PASSWORD}"
PDS_PLC_KEY_SECRET_NAME="${PDS_PLC_KEY_SECRET_NAME:-PDS-PLC-KEY}"
SMTP_SECRET_NAME="${SMTP_SECRET_NAME:-PDS-SMTP-SECRET}"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BICEP_TEMPLATE="${PROJECT_ROOT}/infra/main.bicep"

echo "Azure PDS Infrastructure Deployment Validation"
echo "=============================================="
echo

# Validate prerequisites
function validate_prerequisites() {
    echo "🔍 Validating prerequisites..."
    
    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        echo "❌ Azure CLI not found. Please install Azure CLI 2.60.0 or newer."
        exit 1
    fi
    
    # Check Bicep CLI
    if ! az bicep version &> /dev/null; then
        echo "❌ Bicep CLI not found. Please run 'az bicep install' or 'az bicep upgrade'."
        exit 1
    fi
    
    # Check Azure login
    if ! az account show &> /dev/null; then
        echo "❌ Not logged into Azure. Please run 'az login'."
        exit 1
    fi
    
    # Validate required parameters
    if [[ -z "$RESOURCE_GROUP" ]]; then
        echo "❌ RESOURCE_GROUP environment variable is required."
        exit 1
    fi
    
    if [[ -z "$NAME_PREFIX" ]]; then
        echo "❌ NAME_PREFIX environment variable is required."
        exit 1
    fi
    
    if [[ -z "$PDS_HOSTNAME" ]]; then
        echo "❌ PDS_HOSTNAME environment variable is required."
        exit 1
    fi
    
    if [[ -z "$PDS_IMAGE_TAG" ]]; then
        echo "❌ PDS_IMAGE_TAG environment variable is required."
        exit 1
    fi
    
    if [[ -z "$ADMIN_OBJECT_ID" ]]; then
        echo "❌ ADMIN_OBJECT_ID environment variable is required."
        exit 1
    fi
    
    if [[ -z "$EMAIL_FROM_ADDRESS" ]]; then
        echo "❌ EMAIL_FROM_ADDRESS environment variable is required."
        exit 1
    fi
    
    echo "✅ Prerequisites validated."
    echo
}

# Validate Bicep template
function validate_bicep() {
    echo "🔍 Validating Bicep template..."
    
    if [[ ! -f "$BICEP_TEMPLATE" ]]; then
        echo "❌ Bicep template not found at: $BICEP_TEMPLATE"
        exit 1
    fi
    
    # Build template to check for syntax errors
    echo "Building Bicep template..."
    if ! az bicep build --file "$BICEP_TEMPLATE"; then
        echo "❌ Bicep template build failed."
        exit 1
    fi
    
    echo "✅ Bicep template validation passed."
    echo
}

# Run what-if analysis
function run_what_if() {
    echo "🔍 Running deployment what-if analysis..."
    
    local params=(
        "namePrefix=$NAME_PREFIX"
        "pdsHostname=$PDS_HOSTNAME"
        "pdsImageTag=$PDS_IMAGE_TAG"
        "adminObjectId=$ADMIN_OBJECT_ID"
        "emailFromAddress=$EMAIL_FROM_ADDRESS"
        "pdsJwtSecretName=$PDS_JWT_SECRET_NAME"
        "pdsAdminPasswordSecretName=$PDS_ADMIN_PASSWORD_SECRET_NAME"
        "pdsPlcRotationKeySecretName=$PDS_PLC_KEY_SECRET_NAME"
        "smtpSecretName=$SMTP_SECRET_NAME"
    )
    
    # Add optional DNS parameters if provided
    if [[ -n "$DNS_ZONE_NAME" ]]; then
        params+=("dnsZoneName=$DNS_ZONE_NAME")
        params+=("dnsRecordName=$DNS_RECORD_NAME")
    fi
    
    echo "Parameters:"
    printf " - %s\n" "${params[@]}"
    echo
    
    echo "Running what-if deployment..."
    if az deployment group what-if \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$BICEP_TEMPLATE" \
        --parameters "${params[@]}"; then
        echo "✅ What-if analysis completed successfully."
    else
        echo "❌ What-if analysis failed."
        exit 1
    fi
    echo
}

# Optional: Run actual deployment
function run_deployment() {
    if [[ "${RUN_DEPLOYMENT:-false}" == "true" ]]; then
        echo "🚀 Running actual deployment..."
        
        local params=(
            "namePrefix=$NAME_PREFIX"
            "pdsHostname=$PDS_HOSTNAME"
            "pdsImageTag=$PDS_IMAGE_TAG"
            "adminObjectId=$ADMIN_OBJECT_ID"
            "emailFromAddress=$EMAIL_FROM_ADDRESS"
            "pdsJwtSecretName=$PDS_JWT_SECRET_NAME"
            "pdsAdminPasswordSecretName=$PDS_ADMIN_PASSWORD_SECRET_NAME"
            "pdsPlcRotationKeySecretName=$PDS_PLC_KEY_SECRET_NAME"
            "smtpSecretName=$SMTP_SECRET_NAME"
        )
        
        # Add optional DNS parameters if provided
        if [[ -n "$DNS_ZONE_NAME" ]]; then
            params+=("dnsZoneName=$DNS_ZONE_NAME")
            params+=("dnsRecordName=$DNS_RECORD_NAME")
        fi
        
        if az deployment group create \
            --resource-group "$RESOURCE_GROUP" \
            --template-file "$BICEP_TEMPLATE" \
            --parameters "${params[@]}"; then
            echo "✅ Deployment completed successfully."
            
            # Run post-deployment verification if enabled
            if [[ "${RUN_VERIFICATION:-true}" == "true" ]]; then
                echo
                echo "🔍 Running post-deployment verification..."
                run_post_deployment_verification
            fi
        else
            echo "❌ Deployment failed."
            exit 1
        fi
    else
        echo "ℹ️  To run actual deployment, set RUN_DEPLOYMENT=true"
    fi
    echo
}

# Post-deployment verification
function run_post_deployment_verification() {
    local verification_errors=0
    
    echo "📋 Post-deployment verification checklist:"
    echo
    
    # Verify Container App is running
    echo "🔍 Checking Container App status..."
    local container_app_name="${NAME_PREFIX}-pds-app"
    local running_status
    running_status=$(az containerapp show \
        --name "$container_app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --query "properties.runningStatus" \
        --output tsv 2>/dev/null || echo "NotFound")
    
    if [[ "$running_status" == "Running" ]]; then
        echo "✅ Container App is running"
    else
        echo "❌ Container App status: $running_status"
        ((verification_errors++))
    fi
    
    # Check replica count
    echo "🔍 Checking replica count..."
    local replica_count
    replica_count=$(az containerapp replica list \
        --name "$container_app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --query "length([?properties.runningState=='Running'])" \
        --output tsv 2>/dev/null || echo "0")
    
    if [[ "$replica_count" -gt 0 ]]; then
        echo "✅ Running replicas: $replica_count"
    else
        echo "❌ No running replicas found"
        ((verification_errors++))
    fi
    
    # Verify Key Vault exists and is accessible
    echo "🔍 Checking Key Vault accessibility..."
    local key_vault_name="${NAME_PREFIX}-kv"
    if az keyvault show --name "$key_vault_name" >/dev/null 2>&1; then
        echo "✅ Key Vault is accessible"
        
        # Check for required secrets
        echo "🔍 Verifying required secrets exist..."
        local missing_secrets=()
        
        for secret_name in "$PDS_JWT_SECRET_NAME" "$PDS_ADMIN_PASSWORD_SECRET_NAME" "$PDS_PLC_KEY_SECRET_NAME" "$SMTP_SECRET_NAME"; do
            if ! az keyvault secret show --vault-name "$key_vault_name" --name "$secret_name" >/dev/null 2>&1; then
                missing_secrets+=("$secret_name")
            fi
        done
        
        if [[ ${#missing_secrets[@]} -eq 0 ]]; then
            echo "✅ All required secrets are present"
        else
            echo "⚠️  Missing secrets (must be created manually):"
            printf '   - %s\n' "${missing_secrets[@]}"
        fi
    else
        echo "❌ Key Vault not accessible"
        ((verification_errors++))
    fi
    
    # Verify Storage Account and File Share
    echo "🔍 Checking Storage Account and File Share..."
    local storage_account_name=$(az resource list \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.Storage/storageAccounts" \
        --query "[?starts_with(name, '${NAME_PREFIX,,}')].name" \
        --output tsv | head -1)
    
    if [[ -n "$storage_account_name" ]]; then
        echo "✅ Storage Account found: $storage_account_name"
        
        if az storage share show --name "pds" --account-name "$storage_account_name" >/dev/null 2>&1; then
            echo "✅ Azure Files share 'pds' exists"
        else
            echo "❌ Azure Files share 'pds' not found"
            ((verification_errors++))
        fi
    else
        echo "❌ Storage Account not found"
        ((verification_errors++))
    fi
    
    # Verify Automation Account and Runbook
    echo "🔍 Checking Automation Account..."
    local automation_account_name="${NAME_PREFIX}-auto"
    if az automation account show \
        --name "$automation_account_name" \
        --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
        echo "✅ Automation Account exists"
        
        # Check runbook
        if az automation runbook show \
            --name "BackupPdsFiles" \
            --automation-account-name "$automation_account_name" \
            --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            echo "✅ Backup runbook exists"
        else
            echo "❌ Backup runbook not found"
            ((verification_errors++))
        fi
        
        # Check schedule
        if az automation schedule show \
            --name "DailyBackupSchedule" \
            --automation-account-name "$automation_account_name" \
            --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
            echo "✅ Backup schedule configured"
        else
            echo "❌ Backup schedule not found"
            ((verification_errors++))
        fi
    else
        echo "❌ Automation Account not found"
        ((verification_errors++))
    fi
    
    # Health endpoint check (if publicly accessible)
    echo "🔍 Testing health endpoint..."
    if command -v curl >/dev/null 2>&1; then
        local health_check
        health_check=$(curl -s -o /dev/null -w "%{http_code}" "https://$PDS_HOSTNAME/xrpc/_health" 2>/dev/null || echo "000")
        
        if [[ "$health_check" == "200" ]]; then
            echo "✅ Health endpoint responding (HTTP 200)"
        elif [[ "$health_check" == "000" ]]; then
            echo "⚠️  Cannot reach health endpoint (DNS/network issue or service not ready)"
        else
            echo "⚠️  Health endpoint returned HTTP $health_check (service may be starting)"
        fi
    else
        echo "ℹ️  curl not available, skipping health endpoint check"
    fi
    
    # DNS check (if DNS zone was configured)
    if [[ -n "$DNS_ZONE_NAME" ]]; then
        echo "🔍 Checking DNS configuration..."
        if command -v nslookup >/dev/null 2>&1; then
            if nslookup "$PDS_HOSTNAME" >/dev/null 2>&1; then
                echo "✅ DNS resolution working for $PDS_HOSTNAME"
            else
                echo "⚠️  DNS resolution failed for $PDS_HOSTNAME (may still be propagating)"
            fi
        else
            echo "ℹ️  nslookup not available, skipping DNS check"
        fi
    fi
    
    echo
    echo "📊 Verification Summary:"
    if [[ $verification_errors -eq 0 ]]; then
        echo "✅ All critical components verified successfully!"
        echo
        echo "🎯 Next steps:"
        echo "1. Populate Key Vault secrets if not already done"
        echo "2. Restart Container App if secrets were added post-deployment"
        echo "3. Test PDS functionality with your specific use cases"
        echo "4. Review docs/verification.md for detailed validation procedures"
    else
        echo "❌ Found $verification_errors issues that need attention"
        echo
        echo "🔧 Recommended actions:"
        echo "1. Review failed checks above"
        echo "2. Check Azure portal for detailed error messages"
        echo "3. Verify deployment parameters and retry if needed"
        echo "4. Consult docs/verification.md for troubleshooting guidance"
    fi
    
    return $verification_errors
}

# Display usage information
function show_usage() {
    cat << EOF
Usage: $0

Environment Variables (required):
  RESOURCE_GROUP     - Target Azure resource group
  NAME_PREFIX        - Resource naming prefix (3-12 characters)
  PDS_HOSTNAME       - PDS hostname FQDN
  PDS_IMAGE_TAG      - PDS container image tag
  ADMIN_OBJECT_ID    - Azure AD object ID for Key Vault admin
  EMAIL_FROM_ADDRESS - From address for PDS emails

Environment Variables (optional):
  DNS_ZONE_NAME      - DNS zone name for automatic DNS record creation
  DNS_RECORD_NAME    - DNS record name (default: pds)
  RUN_DEPLOYMENT     - Set to 'true' to run actual deployment after what-if

Secret Name Variables (optional):
  PDS_JWT_SECRET_NAME               - Key Vault secret name (default: PDS-JWT-SECRET)
  PDS_ADMIN_PASSWORD_SECRET_NAME    - Key Vault secret name (default: PDS-ADMIN-PASSWORD)  
  PDS_PLC_KEY_SECRET_NAME           - Key Vault secret name (default: PDS-PLC-KEY)
  SMTP_SECRET_NAME                  - Key Vault secret name (default: PDS-SMTP-SECRET)

Example:
  export RESOURCE_GROUP="rg-pds-prod"
  export NAME_PREFIX="pdsprod"
  export PDS_HOSTNAME="pds.example.com"
  export PDS_IMAGE_TAG="0.4"
  export ADMIN_OBJECT_ID="12345678-1234-1234-1234-123456789012"
  export EMAIL_FROM_ADDRESS="noreply@example.com"
  export DNS_ZONE_NAME="example.com"
  
  # Run what-if only
  $0
  
  # Run actual deployment
  RUN_DEPLOYMENT=true $0

EOF
}

# Main execution
function main() {
    # Show usage if --help is passed
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        show_usage
        exit 0
    fi
    
    validate_prerequisites
    validate_bicep
    run_what_if
    run_deployment
    
    echo "🎉 Script completed successfully!"
}

main "$@"