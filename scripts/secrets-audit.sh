#!/bin/bash
#
# Secrets Audit Script for Azure PDS
# 
# This script performs security auditing of the repository and deployment
# to identify potential secret leaks or security issues.
#
# Usage: ./secrets-audit.sh [--scan-repo] [--scan-deployment] [--all]
#

set -euo pipefail

# Configuration
SCAN_REPO=false
SCAN_DEPLOYMENT=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

log_finding() {
    echo -e "${RED}🔍 FINDING: $1${NC}"
}

# Show usage information
show_usage() {
    cat << EOF
Azure PDS Secrets Audit Script

This script scans for potential security issues including:
- Hardcoded secrets in source code
- Insecure configurations
- Improper file permissions
- Deployment security settings

Usage: $0 [OPTIONS]

OPTIONS:
    --scan-repo          Scan repository for hardcoded secrets
    --scan-deployment    Scan deployment configuration for security issues
    --all               Perform all scans
    --help              Show this help message

EXAMPLES:
    # Scan repository only
    $0 --scan-repo
    
    # Scan deployment configuration
    $0 --scan-deployment
    
    # Perform all scans
    $0 --all

EOF
}

# Parse command line arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --scan-repo)
                SCAN_REPO=true
                shift
                ;;
            --scan-deployment)
                SCAN_DEPLOYMENT=true
                shift
                ;;
            --all)
                SCAN_REPO=true
                SCAN_DEPLOYMENT=true
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

# Check if required tools are available
check_tools() {
    local missing_tools=()
    
    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi
    
    if ! command -v grep &> /dev/null; then
        missing_tools+=("grep")
    fi
    
    if ! command -v find &> /dev/null; then
        missing_tools+=("find")
    fi
    
    if [[ "$SCAN_DEPLOYMENT" == "true" ]] && ! command -v az &> /dev/null; then
        missing_tools+=("az (Azure CLI)")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools:"
        printf ' - %s\n' "${missing_tools[@]}"
        exit 1
    fi
}

# Common secret patterns to search for
get_secret_patterns() {
    cat << 'EOF'
# API Keys and tokens
[aA][pP][iI][_-]?[kK][eE][yY].*['\''"][0-9a-zA-Z]{16,}['\''"]
[aA][cC][cC][eE][sS][sS][_-]?[tT][oO][kK][eE][nN].*['\''"][0-9a-zA-Z]{16,}['\''"]
[sS][eE][cC][rR][eE][tT][_-]?[kK][eE][yY].*['\''"][0-9a-zA-Z]{16,}['\''"]

# Azure specific patterns
['\''"][0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}['\''"]
[aA][zZ][uU][rR][eE][_-]?[cC][lL][iI][eE][nN][tT][_-]?[sS][eE][cR][eE][tT]
[aA][zZ][uU][rR][eE][_-]?[sS][tT][oO][rR][aA][gG][eE][_-]?[kK][eE][yY]

# JWT tokens
eyJ[A-Za-z0-9-_]*\.[A-Za-z0-9-_]*\.[A-Za-z0-9-_]*

# Base64 encoded secrets (common pattern)
['\''"][A-Za-z0-9+/]{40,}={0,2}['\''"]

# Connection strings
[sS][qQ][lL].*[cC][oO][nN][nN][eE][cC][tT][iI][oO][nN][_-]?[sS][tT][rR][iI][nN][gG]
[sS][mM][tT][pP].*://.+:.+@

# Private keys
-----BEGIN [A-Z ]*PRIVATE KEY-----
-----BEGIN RSA PRIVATE KEY-----
-----BEGIN EC PRIVATE KEY-----

# Passwords in common formats
[pP][aA][sS][sS][wW][oO][rR][dD].*['\''"][^'\''\"]{8,}['\''"]
[pP][wW][dD].*['\''"][^'\''\"]{8,}['\''"]
EOF
}

# Scan repository for potential secrets
scan_repository() {
    log_info "Scanning repository for potential secrets..."
    local findings=0
    
    # Change to project root
    cd "$PROJECT_ROOT"
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir &> /dev/null; then
        log_warning "Not in a git repository, scanning current directory instead"
    fi
    
    # Files to exclude from scanning
    local exclude_patterns=(
        "*.git*"
        "node_modules"
        "*.log"
        "dist/"
        "build/"
        "coverage/"
        "*.min.js"
        "*.map"
    )
    
    # Build find command with exclusions
    local find_cmd="find . -type f"
    for pattern in "${exclude_patterns[@]}"; do
        find_cmd+=" ! -path '*/$pattern' ! -name '$pattern'"
    done
    
    # Get list of files to scan
    local temp_patterns="/tmp/secret_patterns.txt"
    get_secret_patterns > "$temp_patterns"
    
    log_info "Scanning files for secret patterns..."
    
    # Scan for secret patterns
    while IFS= read -r pattern; do
        [[ "$pattern" =~ ^#.*$ ]] && continue  # Skip comments
        [[ -z "$pattern" ]] && continue        # Skip empty lines
        
        local matches
        if matches=$(eval "$find_cmd" -exec grep -l -E "$pattern" {} \; 2>/dev/null); then
            if [[ -n "$matches" ]]; then
                log_finding "Potential secret pattern found:"
                echo "$matches" | while read -r file; do
                    echo "  File: $file"
                    # Show context without revealing actual secrets
                    grep -n -E "$pattern" "$file" | head -3 | sed 's/\([^:]*:\)\(.*\)/  Line \1 [PATTERN MATCH REDACTED]/'
                done
                echo
                ((findings++))
            fi
        fi
    done < "$temp_patterns"
    
    rm -f "$temp_patterns"
    
    # Check for common secret files
    log_info "Checking for common secret files..."
    local secret_files=(
        ".env"
        ".env.local"
        ".env.production"
        "secrets.json"
        "config/secrets.yml"
        "private.key"
        "*.pem"
        "*.p12"
        "*.pfx"
        "id_rsa"
        "id_dsa"
        "id_ecdsa"
        "id_ed25519"
    )
    
    for pattern in "${secret_files[@]}"; do
        if eval "$find_cmd" -name "$pattern" | grep -q .; then
            log_finding "Potential secret file found:"
            eval "$find_cmd" -name "$pattern" | sed 's/^/  /'
            echo
            ((findings++))
        fi
    done
    
    # Check file permissions
    log_info "Checking file permissions..."
    local world_readable
    if world_readable=$(find . -type f -perm /o+r -not -path "./.git/*" 2>/dev/null); then
        if [[ -n "$world_readable" ]]; then
            log_warning "World-readable files found (consider restricting permissions):"
            echo "$world_readable" | sed 's/^/  /'
            echo
        fi
    fi
    
    # Check for hardcoded IPs and domains
    log_info "Checking for hardcoded IPs and domains..."
    local ip_pattern='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    local suspicious_domains='(localhost|127\.0\.0\.1|0\.0\.0\.0|192\.168\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)'
    
    if eval "$find_cmd" -exec grep -l -E "$suspicious_domains" {} \; 2>/dev/null | grep -v -E '\.(md|txt|log)$' | head -5; then
        log_warning "Hardcoded local/private IP addresses found (may indicate test configurations)"
        echo
    fi
    
    log_info "Repository scan complete. Found $findings potential issues."
    return $findings
}

# Scan deployment configuration for security issues
scan_deployment() {
    log_info "Scanning deployment configuration for security issues..."
    local findings=0
    
    # Check if Azure CLI is logged in
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure. Please run 'az login' to scan deployment."
        return 1
    fi
    
    # Scan Bicep template for security issues
    log_info "Analyzing Bicep template security..."
    local bicep_file="$PROJECT_ROOT/infra/main.bicep"
    
    if [[ -f "$bicep_file" ]]; then
        # Check for hardcoded secrets in template
        if grep -q -E '['\''"][A-Za-z0-9+/]{20,}['\''"]' "$bicep_file"; then
            log_finding "Potential hardcoded secrets in Bicep template"
            ((findings++))
        fi
        
        # Check for insecure configurations
        if grep -q -i "allowBlobPublicAccess.*true" "$bicep_file"; then
            log_finding "Blob public access is enabled (security risk)"
            ((findings++))
        fi
        
        if grep -q -i "supportsHttpsTrafficOnly.*false" "$bicep_file"; then
            log_finding "HTTPS-only traffic is disabled (security risk)"
            ((findings++))
        fi
        
        if grep -q -i "minimumTlsVersion.*1.0\|minimumTlsVersion.*1.1" "$bicep_file"; then
            log_finding "Weak TLS version configured (should be 1.2+)"
            ((findings++))
        fi
        
        # Check for missing encryption settings
        if ! grep -q -i "encryption" "$bicep_file"; then
            log_warning "No explicit encryption configuration found"
        fi
        
        log_success "Bicep template security analysis complete"
    else
        log_warning "Bicep template not found at $bicep_file"
    fi
    
    # Check for environment-specific issues
    log_info "Checking for environment configuration issues..."
    
    # Look for test/dev configurations in production files
    local prod_indicators=("prod" "production" "live")
    local test_indicators=("test" "dev" "development" "staging" "localhost")
    
    for test_term in "${test_indicators[@]}"; do
        if find "$PROJECT_ROOT" -name "*.json" -o -name "*.yaml" -o -name "*.yml" | xargs grep -l -i "$test_term" 2>/dev/null | grep -E "(prod|production)" > /dev/null; then
            log_finding "Test/development configuration found in production files"
            ((findings++))
            break
        fi
    done
    
    log_info "Deployment configuration scan complete. Found $findings potential issues."
    return $findings
}

# Additional security checks
additional_security_checks() {
    log_info "Performing additional security checks..."
    local findings=0
    
    # Check .gitignore for proper exclusions
    local gitignore_file="$PROJECT_ROOT/.gitignore"
    if [[ -f "$gitignore_file" ]]; then
        local required_patterns=(
            "*.env*"
            "secrets*"
            "*.key"
            "*.pem"
            ".azure/"
        )
        
        for pattern in "${required_patterns[@]}"; do
            if ! grep -q "$pattern" "$gitignore_file"; then
                log_warning "Missing .gitignore pattern: $pattern"
            fi
        done
    else
        log_finding ".gitignore file not found - secrets may be committed accidentally"
        ((findings++))
    fi
    
    # Check for pre-commit hooks
    if [[ ! -f "$PROJECT_ROOT/.pre-commit-config.yaml" ]] && [[ ! -d "$PROJECT_ROOT/.git/hooks" ]]; then
        log_warning "No pre-commit hooks detected - consider adding secret scanning"
    fi
    
    # Check for CI/CD configuration security
    local ci_files=(
        ".github/workflows/*.yml"
        ".github/workflows/*.yaml"
        ".azure-pipelines.yml"
        "azure-pipelines.yml"
        ".gitlab-ci.yml"
        "Jenkinsfile"
    )
    
    for pattern in "${ci_files[@]}"; do
        if find "$PROJECT_ROOT" -path "*/$pattern" -o -name "$pattern" 2>/dev/null | head -1 | read -r file; then
            log_info "Found CI/CD configuration: $file"
            if grep -q -E '['\''"][A-Za-z0-9+/]{20,}['\''"]' "$file" 2>/dev/null; then
                log_finding "Potential hardcoded secrets in CI/CD configuration: $file"
                ((findings++))
            fi
        fi
    done
    
    return $findings
}

# Generate security report
generate_report() {
    local total_findings=$1
    
    echo
    echo "==============================================="
    echo "           SECURITY AUDIT REPORT"
    echo "==============================================="
    echo "Scan Date: $(date)"
    echo "Project: Azure PDS Infrastructure"
    echo
    
    if [[ $total_findings -eq 0 ]]; then
        log_success "No security issues found!"
        echo
        echo "Recommendations:"
        echo "• Regularly run this audit script"
        echo "• Implement pre-commit hooks for secret scanning"
        echo "• Use automated security scanning in CI/CD"
        echo "• Regularly rotate secrets and credentials"
        echo "• Review access controls and permissions"
    else
        log_warning "Found $total_findings potential security issues"
        echo
        echo "Immediate Actions Required:"
        echo "• Review all flagged files and configurations"
        echo "• Remove any hardcoded secrets or credentials"
        echo "• Update .gitignore to prevent future commits"
        echo "• Rotate any exposed credentials"
        echo "• Implement proper secret management"
        echo
        echo "Long-term Recommendations:"
        echo "• Set up automated secret scanning"
        echo "• Implement security policies and training"
        echo "• Regular security audits and penetration testing"
        echo "• Monitor for suspicious activities"
    fi
    
    echo
    echo "For more information, see:"
    echo "• docs/secrets.md - Secret management guidelines"
    echo "• Azure Security Best Practices documentation"
    echo "• OWASP security guidelines"
    echo
}

# Main execution function
main() {
    echo "Azure PDS Security Audit"
    echo "========================"
    echo
    
    parse_args "$@"
    check_tools
    
    local total_findings=0
    
    if [[ "$SCAN_REPO" == "true" ]]; then
        scan_repository || total_findings=$((total_findings + $?))
        echo
    fi
    
    if [[ "$SCAN_DEPLOYMENT" == "true" ]]; then
        scan_deployment || total_findings=$((total_findings + $?))
        echo
    fi
    
    # Always run additional checks
    additional_security_checks || total_findings=$((total_findings + $?))
    
    generate_report $total_findings
    
    # Exit with non-zero code if issues found
    if [[ $total_findings -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main "$@"