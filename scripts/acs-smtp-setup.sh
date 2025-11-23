#!/usr/bin/env bash
set -euo pipefail

show_usage() {
  cat <<'EOF'
Usage: acs-smtp-setup.sh --resource-group <name> --communication-service <name> \
         --email-service <name> --key-vault <name> [options]

Options:
  --smtp-secret-name <name>        Key Vault secret name for the SMTP connection string (default: PDS-SMTP-URL)
  --email-secret-name <name>       Key Vault secret name for the email-from address (default: PDS-EMAIL-FROM-ADDRESS)
  --app-display-name <name>        Display name for the Microsoft Entra application (default: <communication-service>-smtp-app)
  --smtp-resource-name <name>      Resource name for the SMTP username (default: <communication-service>-smtp)
  --smtp-username <value>          SMTP username/email to register (default: email-from address)
  --email-from-address <value>     Override the email-from address stored in Key Vault
  --custom-domain <value>          Custom domain already provisioned on the Email Service (skip Azure-managed domain lookup)
  --tenant-id <id>                 Microsoft Entra tenant ID (defaults to az account show)
  --poll-seconds <seconds>         Interval when waiting for domain verification (default: 15)
  --timeout-seconds <seconds>      Timeout when waiting for domain verification (default: 600)
  -h | --help                      Show this help message

This script creates or reuses a Microsoft Entra application for Azure Communication
Services SMTP authentication, links it to the Communication Service, provisions an SMTP
username, and stores the resulting SMTP connection string plus email-from address in Key Vault.
Re-run the script any time you redeploy the infrastructure template so the SMTP secret is refreshed.
EOF
}

REQUIRED_ARGS=(resource_group communication_service email_service key_vault)
declare -A ARGS=(
  [smtp_secret_name]="PDS-SMTP-URL"
  [email_secret_name]="PDS-EMAIL-FROM-ADDRESS"
  [app_display_name]=""
  [smtp_resource_name]=""
  [smtp_username]=""
  [email_from_address]=""
  [custom_domain]=""
  [tenant_id]=""
  [poll_seconds]="15"
  [timeout_seconds]="600"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      ARGS[resource_group]="$2"; shift 2 ;;
    --communication-service)
      ARGS[communication_service]="$2"; shift 2 ;;
    --email-service)
      ARGS[email_service]="$2"; shift 2 ;;
    --key-vault)
      ARGS[key_vault]="$2"; shift 2 ;;
    --smtp-secret-name)
      ARGS[smtp_secret_name]="$2"; shift 2 ;;
    --email-secret-name)
      ARGS[email_secret_name]="$2"; shift 2 ;;
    --app-display-name)
      ARGS[app_display_name]="$2"; shift 2 ;;
    --smtp-resource-name)
      ARGS[smtp_resource_name]="$2"; shift 2 ;;
    --smtp-username)
      ARGS[smtp_username]="$2"; shift 2 ;;
    --email-from-address)
      ARGS[email_from_address]="$2"; shift 2 ;;
    --custom-domain)
      ARGS[custom_domain]="$2"; shift 2 ;;
    --tenant-id)
      ARGS[tenant_id]="$2"; shift 2 ;;
    --poll-seconds)
      ARGS[poll_seconds]="$2"; shift 2 ;;
    --timeout-seconds)
      ARGS[timeout_seconds]="$2"; shift 2 ;;
    -h|--help)
      show_usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      show_usage
      exit 1 ;;
  esac
done

for name in "${REQUIRED_ARGS[@]}"; do
  if [[ -z "${ARGS[$name]:-}" ]]; then
    echo "Missing required argument: --${name//_/ -}" >&2
    show_usage
    exit 1
  fi
done

RG="${ARGS[resource_group]}"
COMM_NAME="${ARGS[communication_service]}"
EMAIL_SERVICE="${ARGS[email_service]}"
KEY_VAULT="${ARGS[key_vault]}"
SMTP_SECRET_NAME="${ARGS[smtp_secret_name]}"
EMAIL_SECRET_NAME="${ARGS[email_secret_name]}"
APP_DISPLAY_NAME="${ARGS[app_display_name]}"
SMTP_RESOURCE_NAME="${ARGS[smtp_resource_name]}"
SMTP_USERNAME="${ARGS[smtp_username]}"
EMAIL_FROM_ADDRESS="${ARGS[email_from_address]}"
CUSTOM_DOMAIN="${ARGS[custom_domain]}"
TENANT_ID="${ARGS[tenant_id]}"
POLL_SECONDS="${ARGS[poll_seconds]}"
TIMEOUT_SECONDS="${ARGS[timeout_seconds]}"

if [[ -z "$APP_DISPLAY_NAME" ]]; then
  APP_DISPLAY_NAME="${COMM_NAME}-smtp-app"
fi

if [[ -z "$SMTP_RESOURCE_NAME" ]]; then
  SMTP_RESOURCE_NAME="${COMM_NAME}-smtp"
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required." >&2
  exit 1
fi

if ! az extension show --name communication >/dev/null 2>&1; then
  echo "Installing Azure Communication Services CLI extension..."
  az extension add --name communication >/dev/null
fi

if [[ -z "$TENANT_ID" ]]; then
  TENANT_ID=$(az account show --query tenantId -o tsv)
fi

COMM_ID=$(az communication show -g "$RG" -n "$COMM_NAME" --query id -o tsv)
EMAIL_SERVICE_ID=$(az communication email show -g "$RG" -n "$EMAIL_SERVICE" --query id -o tsv 2>/dev/null || true)
if [[ -z "$COMM_ID" ]]; then
  echo "Unable to resolve Communication Service $COMM_NAME in $RG" >&2
  exit 1
fi

if [[ -z "$EMAIL_SERVICE_ID" ]]; then
  echo "Unable to resolve Email Service $EMAIL_SERVICE in $RG" >&2
  exit 1
fi

lookup_domain_status() {
  az communication email domain show \
    --resource-group "$RG" \
    --email-service-name "$EMAIL_SERVICE" \
    --name "$1" \
    --query properties.domainStatus -o tsv 2>/dev/null || true
}

resolve_mail_domain() {
  az communication email domain show \
    --resource-group "$RG" \
    --email-service-name "$EMAIL_SERVICE" \
    --name "$1" \
    --query properties.mailFromSenderDomain -o tsv
}

if [[ -z "$CUSTOM_DOMAIN" ]]; then
  DOMAIN_RESOURCE_NAME="AzureManagedDomain"
  echo "Waiting for Azure-managed domain verification..."
  end_time=$((SECONDS + TIMEOUT_SECONDS))
  while true; do
    status=$(lookup_domain_status "$DOMAIN_RESOURCE_NAME")
    if [[ "$status" == "Verified" ]]; then
      break
    fi
    if (( SECONDS >= end_time )); then
      echo "Timed out waiting for Azure-managed domain verification." >&2
      exit 1
    fi
    sleep "$POLL_SECONDS"
  done
  MAIL_DOMAIN=$(resolve_mail_domain "$DOMAIN_RESOURCE_NAME")
else
  DOMAIN_RESOURCE_NAME="$CUSTOM_DOMAIN"
  MAIL_DOMAIN="$CUSTOM_DOMAIN"
fi

if [[ -z "$MAIL_DOMAIN" ]]; then
  echo "Unable to resolve sender domain. Ensure the Email Service domain is provisioned." >&2
  exit 1
fi

if [[ -z "$EMAIL_FROM_ADDRESS" ]]; then
  EMAIL_FROM_ADDRESS="donotreply@${MAIL_DOMAIN}"
fi

if [[ -z "$SMTP_USERNAME" ]]; then
  SMTP_USERNAME="$EMAIL_FROM_ADDRESS"
fi

existing_app_id=$(az ad app list --display-name "$APP_DISPLAY_NAME" --query '[0].appId' -o tsv)
if [[ -z "$existing_app_id" ]]; then
  echo "Creating Microsoft Entra application $APP_DISPLAY_NAME..."
  APP_ID=$(az ad app create \
    --display-name "$APP_DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
else
  APP_ID="$existing_app_id"
  echo "Using existing Microsoft Entra application $APP_DISPLAY_NAME ($APP_ID)."
fi

if ! az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  echo "Creating service principal for app $APP_ID..."
  az ad sp create --id "$APP_ID" >/dev/null
fi

echo "Creating fresh client secret..."
CLIENT_SECRET=$(az ad app credential reset --id "$APP_ID" --display-name smtp --years 2 --query password -o tsv)

echo "Ensuring role assignment (Communication and Email Service Owner)..."
az role assignment create \
  --role "Communication and Email Service Owner" \
  --assignee "$APP_ID" \
  --scope "$COMM_ID" \
  >/dev/null 2>&1 || true

if az communication smtp-username show \
    --resource-group "$RG" \
    --comm-service-name "$COMM_NAME" \
    --smtp-username "$SMTP_RESOURCE_NAME" >/dev/null 2>&1; then
  echo "Updating existing SMTP username resource $SMTP_RESOURCE_NAME..."
  az communication smtp-username update \
    --resource-group "$RG" \
    --comm-service-name "$COMM_NAME" \
    --smtp-username "$SMTP_RESOURCE_NAME" \
    --username "$SMTP_USERNAME" \
    --entra-application-id "$APP_ID" \
    --tenant-id "$TENANT_ID" \
    >/dev/null
else
  echo "Creating SMTP username resource $SMTP_RESOURCE_NAME..."
  az communication smtp-username create \
    --resource-group "$RG" \
    --comm-service-name "$COMM_NAME" \
    --smtp-username "$SMTP_RESOURCE_NAME" \
    --username "$SMTP_USERNAME" \
    --entra-application-id "$APP_ID" \
    --tenant-id "$TENANT_ID" \
    >/dev/null
fi

url_encode() {
  python3 - <<PY
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=''))
PY
}

ENCODED_USERNAME=$(url_encode "$SMTP_USERNAME")
ENCODED_SECRET=$(url_encode "$CLIENT_SECRET")
SMTP_CONNECTION="smtps://${ENCODED_USERNAME}:${ENCODED_SECRET}@smtp.azurecomm.net:587"

echo "Updating Key Vault secrets..."
az keyvault secret set --vault-name "$KEY_VAULT" --name "$SMTP_SECRET_NAME" --value "$SMTP_CONNECTION" >/dev/null
az keyvault secret set --vault-name "$KEY_VAULT" --name "$EMAIL_SECRET_NAME" --value "$EMAIL_FROM_ADDRESS" >/dev/null

echo
echo "Azure Communication Services SMTP setup complete."
echo "  Communication Service : $COMM_NAME"
if [[ -z "$CUSTOM_DOMAIN" ]]; then
  echo "  Domain (managed)      : $MAIL_DOMAIN"
else
  echo "  Domain (custom)       : $MAIL_DOMAIN"
fi
echo "  Entra app display name: $APP_DISPLAY_NAME"
echo "  SMTP username         : $SMTP_USERNAME"
echo "  Email from address    : $EMAIL_FROM_ADDRESS"
echo "  SMTP secret stored in : $KEY_VAULT/$SMTP_SECRET_NAME"
echo "  From address secret   : $KEY_VAULT/$EMAIL_SECRET_NAME"
