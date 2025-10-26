#!/bin/bash
#
# Key Vault Secret Population Script
# 
# This script securely populates Azure Key Vault with the required secrets for PDS deployment.
# No secrets are stored in this script - they are generated or provided interactively.
#
# Usage: ./kv-populate.sh [--key-vault-name <name>] [--dry-run]
#

set -euo pipefail

# Default configuration
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
DRY_RUN=false
INTERACTIVE=true

# Secret names (configurable)
JWT_SECRET_NAME="${JWT_SECRET_NAME:-PDS-JWT-SECRET}"
ADMIN_PASSWORD_SECRET_NAME="${ADMIN_PASSWORD_SECRET_NAME:-PDS-ADMIN-PASSWORD}"
PLC_KEY_SECRET_NAME="${PLC_KEY_SECRET_NAME:-PDS-PLC-KEY}"
SMTP_SECRET_NAME="${SMTP_SECRET_NAME:-PDS-SMTP-SECRET}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Show usage information
show_usage() {
    cat << EOF
Azure PDS Key Vault Secret Population Script

Usage: $0 [OPTIONS]

OPTIONS:
    --key-vault-name <name>    Specify Key Vault name (required)
    --dry-run                  Show what would be done without making changes
    --non-interactive          Run without prompts (requires all secrets via environment)
    --help                     Show this help message

ENVIRONMENT VARIABLES:
    KEY_VAULT_NAME            Key Vault name (overridden by --key-vault-name)
    JWT_SECRET_NAME           Name for JWT secret (default: PDS-JWT-SECRET)
    ADMIN_PASSWORD_SECRET_NAME Name for admin password (default: PDS-ADMIN-PASSWORD)
    PLC_KEY_SECRET_NAME       Name for PLC key (default: PDS-PLC-KEY)
    SMTP_SECRET_NAME          Name for SMTP secret (default: PDS-SMTP-SECRET)
    
    For non-interactive mode, provide these variables:
    PDS_JWT_SECRET            JWT secret value
    PDS_ADMIN_PASSWORD        Admin password value
    PDS_PLC_KEY               PLC key hex value
    PDS_SMTP_SECRET           SMTP connection string

EXAMPLES:
    # Interactive mode
    $0 --key-vault-name mypds-kv
    
    # Dry run to preview changes
    $0 --key-vault-name mypds-kv --dry-run
    
    # Non-interactive with environment variables
    export KEY_VAULT_NAME="mypds-kv"
    export PDS_JWT_SECRET="\$(openssl rand -base64 32)"
    export PDS_ADMIN_PASSWORD="\$(openssl rand -base64 24)"
    export PDS_PLC_KEY="your-hex-key"
    export PDS_SMTP_SECRET="smtps://user:pass@smtp.example.com:465"
    $0 --non-interactive

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --key-vault-name)
                KEY_VAULT_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI not found. Please install Azure CLI."
        exit 1
    fi
    
    # Check Azure login
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure. Please run 'az login'."
        exit 1
    fi
    
    # Validate Key Vault name
    if [[ -z "$KEY_VAULT_NAME" ]]; then
        log_error "Key Vault name is required. Use --key-vault-name or set KEY_VAULT_NAME environment variable."
        exit 1
    fi
    
    # Check Key Vault accessibility
    if ! az keyvault show --name "$KEY_VAULT_NAME" &> /dev/null; then
        log_error "Cannot access Key Vault '$KEY_VAULT_NAME'. Check name and permissions."
        exit 1
    fi
    
    # Check required tools for secret generation
    if ! command -v openssl &> /dev/null; then
        log_error "OpenSSL not found. Required for secure secret generation."
        exit 1
    fi
    
    log_success "Prerequisites validated."
}

# Generate a secure JWT secret
generate_jwt_secret() {
    openssl rand -base64 32
}

# Generate a secure admin password
generate_admin_password() {
    openssl rand -base64 24
}

# Prompt for secret value with validation
prompt_for_secret() {
    local secret_name="$1"
    local secret_description="$2"
    local validation_function="$3"
    local value=""
    
    while true; do
        echo
        log_info "Enter $secret_description:"
        echo "Press Enter to auto-generate (recommended) or type custom value:"
        read -rs value
        
        if [[ -z "$value" ]]; then
            # Auto-generate
            case "$secret_name" in
                "$JWT_SECRET_NAME")
                    value=$(generate_jwt_secret)
                    log_info "Auto-generated JWT secret (32 bytes, base64-encoded)"
                    ;;
                "$ADMIN_PASSWORD_SECRET_NAME")
                    value=$(generate_admin_password)
                    log_info "Auto-generated admin password (24 bytes, base64-encoded)"
                    ;;
                *)
                    log_error "Cannot auto-generate $secret_name. Please provide a value."
                    continue
                    ;;
            esac
        fi
        
        # Validate if validation function provided
        if [[ -n "$validation_function" ]] && ! $validation_function "$value"; then
            log_error "Invalid value for $secret_name. Please try again."
            continue
        fi
        
        break
    done
    
    echo "$value"
}

# Validation functions
validate_jwt_secret() {
    local value="$1"
    [[ ${#value} -ge 32 ]]
}

validate_admin_password() {
    local value="$1"
    [[ ${#value} -ge 16 ]]
}

validate_plc_key() {
    local value="$1"
    # Basic hex validation (even length, hex characters only)
    [[ ${#value} -gt 0 ]] && [[ $((${#value} % 2)) -eq 0 ]] && [[ "$value" =~ ^[0-9a-fA-F]+$ ]]
}

validate_smtp_secret() {
    local value="$1"
    # Basic SMTP URL validation
    [[ "$value" =~ ^smtps?:// ]] || [[ ${#value} -gt 0 ]]
}

# Check if secret already exists
secret_exists() {
    local secret_name="$1"
    az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$secret_name" &> /dev/null
}

# Set secret in Key Vault
set_secret() {
    local secret_name="$1"
    local secret_value="$2"
    local description="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would set secret: $secret_name"
        return 0
    fi
    
    if az keyvault secret set \
        --vault-name "$KEY_VAULT_NAME" \
        --name "$secret_name" \
        --value "$secret_value" \
        --description "$description" \
        --output none; then
        log_success "Successfully set secret: $secret_name"
    else
        log_error "Failed to set secret: $secret_name"
        return 1
    fi
}

# Collect secrets interactively
collect_secrets_interactive() {
    log_info "Collecting secrets interactively..."
    
    # JWT Secret
    if secret_exists "$JWT_SECRET_NAME"; then
        log_warning "Secret '$JWT_SECRET_NAME' already exists."
        echo -n "Overwrite? (y/N): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            JWT_SECRET=$(prompt_for_secret "$JWT_SECRET_NAME" "JWT Secret (for token signing)" "validate_jwt_secret")
        else
            JWT_SECRET=""
        fi
    else
        JWT_SECRET=$(prompt_for_secret "$JWT_SECRET_NAME" "JWT Secret (for token signing)" "validate_jwt_secret")
    fi
    
    # Admin Password
    if secret_exists "$ADMIN_PASSWORD_SECRET_NAME"; then
        log_warning "Secret '$ADMIN_PASSWORD_SECRET_NAME' already exists."
        echo -n "Overwrite? (y/N): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            ADMIN_PASSWORD=$(prompt_for_secret "$ADMIN_PASSWORD_SECRET_NAME" "Admin Password" "validate_admin_password")
        else
            ADMIN_PASSWORD=""
        fi
    else
        ADMIN_PASSWORD=$(prompt_for_secret "$ADMIN_PASSWORD_SECRET_NAME" "Admin Password" "validate_admin_password")
    fi
    
    # PLC Key
    if secret_exists "$PLC_KEY_SECRET_NAME"; then
        log_warning "Secret '$PLC_KEY_SECRET_NAME' already exists."
        echo -n "Overwrite? (y/N): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            PLC_KEY=$(prompt_for_secret "$PLC_KEY_SECRET_NAME" "PLC Key (hex-encoded private key)" "validate_plc_key")
        else
            PLC_KEY=""
        fi
    else
        PLC_KEY=$(prompt_for_secret "$PLC_KEY_SECRET_NAME" "PLC Key (hex-encoded private key)" "validate_plc_key")
    fi
    
    # SMTP Secret
    if secret_exists "$SMTP_SECRET_NAME"; then
        log_warning "Secret '$SMTP_SECRET_NAME' already exists."
        echo -n "Overwrite? (y/N): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            SMTP_SECRET=$(prompt_for_secret "$SMTP_SECRET_NAME" "SMTP Secret (connection string)" "validate_smtp_secret")
        else
            SMTP_SECRET=""
        fi
    else
        SMTP_SECRET=$(prompt_for_secret "$SMTP_SECRET_NAME" "SMTP Secret (connection string)" "validate_smtp_secret")
    fi
}

# Collect secrets from environment variables
collect_secrets_non_interactive() {
    log_info "Collecting secrets from environment variables..."
    
    JWT_SECRET="${PDS_JWT_SECRET:-}"
    ADMIN_PASSWORD="${PDS_ADMIN_PASSWORD:-}"
    PLC_KEY="${PDS_PLC_KEY:-}"
    SMTP_SECRET="${PDS_SMTP_SECRET:-}"
    
    # Validate required secrets are provided
    local missing_secrets=()
    
    if [[ -z "$JWT_SECRET" ]]; then
        missing_secrets+=("PDS_JWT_SECRET")
    fi
    
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        missing_secrets+=("PDS_ADMIN_PASSWORD")
    fi
    
    if [[ -z "$PLC_KEY" ]]; then
        missing_secrets+=("PDS_PLC_KEY")
    fi
    
    if [[ -z "$SMTP_SECRET" ]]; then
        missing_secrets+=("PDS_SMTP_SECRET")
    fi
    
    if [[ ${#missing_secrets[@]} -gt 0 ]]; then
        log_error "Missing required environment variables in non-interactive mode:"
        printf ' - %s\n' "${missing_secrets[@]}"
        exit 1
    fi
    
    # Validate secret values
    if ! validate_jwt_secret "$JWT_SECRET"; then
        log_error "Invalid JWT secret (minimum 32 characters required)"
        exit 1
    fi
    
    if ! validate_admin_password "$ADMIN_PASSWORD"; then
        log_error "Invalid admin password (minimum 16 characters required)"
        exit 1
    fi
    
    if ! validate_plc_key "$PLC_KEY"; then
        log_error "Invalid PLC key (must be hex-encoded)"
        exit 1
    fi
    
    if ! validate_smtp_secret "$SMTP_SECRET"; then
        log_error "Invalid SMTP secret"
        exit 1
    fi
}

# Set all secrets in Key Vault
set_all_secrets() {
    log_info "Setting secrets in Key Vault..."
    
    local errors=0
    
    if [[ -n "$JWT_SECRET" ]]; then
        set_secret "$JWT_SECRET_NAME" "$JWT_SECRET" "JWT secret for token signing" || ((errors++))
    fi
    
    if [[ -n "$ADMIN_PASSWORD" ]]; then
        set_secret "$ADMIN_PASSWORD_SECRET_NAME" "$ADMIN_PASSWORD" "Administrative password for PDS" || ((errors++))
    fi
    
    if [[ -n "$PLC_KEY" ]]; then
        set_secret "$PLC_KEY_SECRET_NAME" "$PLC_KEY" "PLC rotation key (hex-encoded private key)" || ((errors++))
    fi
    
    if [[ -n "$SMTP_SECRET" ]]; then
        set_secret "$SMTP_SECRET_NAME" "$SMTP_SECRET" "SMTP connection string for email notifications" || ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Failed to set $errors secret(s)"
        exit 1
    fi
    
    log_success "All secrets set successfully!"
}

# Show summary of what will be done
show_summary() {
    echo
    log_info "Summary of operations:"
    echo "Key Vault: $KEY_VAULT_NAME"
    echo "Secrets to be set:"
    
    [[ -n "$JWT_SECRET" ]] && echo "  - $JWT_SECRET_NAME"
    [[ -n "$ADMIN_PASSWORD" ]] && echo "  - $ADMIN_PASSWORD_SECRET_NAME"
    [[ -n "$PLC_KEY" ]] && echo "  - $PLC_KEY_SECRET_NAME"
    [[ -n "$SMTP_SECRET" ]] && echo "  - $SMTP_SECRET_NAME"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "DRY RUN MODE - No changes will be made"
    fi
    echo
}

# Main execution function
main() {
    echo "Azure PDS Key Vault Secret Population"
    echo "====================================="
    echo
    
    parse_args "$@"
    validate_prerequisites
    
    if [[ "$INTERACTIVE" == "true" ]]; then
        collect_secrets_interactive
    else
        collect_secrets_non_interactive
    fi
    
    show_summary
    
    if [[ "$DRY_RUN" == "false" && "$INTERACTIVE" == "true" ]]; then
        echo -n "Proceed with setting secrets? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled by user."
            exit 0
        fi
    fi
    
    set_all_secrets
    
    echo
    log_success "Secret population complete!"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        echo
        log_info "Next steps:"
        echo "1. Verify secrets in Azure portal or via Azure CLI"
        echo "2. Restart Container App if deployment is already complete"
        echo "3. Test PDS functionality with new secrets"
        echo
        log_warning "Remember to securely store or dispose of any generated secrets shown above"
    fi
}

# Cleanup function
cleanup() {
    # Clear sensitive variables
    unset JWT_SECRET ADMIN_PASSWORD PLC_KEY SMTP_SECRET
    unset PDS_JWT_SECRET PDS_ADMIN_PASSWORD PDS_PLC_KEY PDS_SMTP_SECRET
}

# Set up cleanup trap
trap cleanup EXIT

# Run main function
main "$@"