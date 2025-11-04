# Operator Environment Prerequisites

Document the requirements an operator must satisfy before deploying the Azure PDS infrastructure. Validate each item prior to running the quickstart workflow.

## Accounts and Permissions
- Azure subscription with quota to create Container Apps, Log Analytics, Storage, and Key Vault resources.
- User or service principal assigned **Contributor** on the target resource group and **Key Vault Secrets Officer** if access policy management is restricted.
- Role assignment for **DNS Zone Contributor** on the hosting zone (required only when dnsZoneName is provided).

## Local Workstation Requirements
- Azure CLI **2.60.0+** installed and authenticated (`az login`).
- Bicep CLI **0.27.1+** available via `az bicep version`.
- Bash shell capable of executing deployment helper scripts (macOS, Linux, or Windows WSL).
- Optional: `zstd` and `sqlite3` locally if you plan to inspect snapshot archives on your workstation.

## Network Access
- Outbound HTTPS access to Azure management endpoints.
- Ability to reach `ghcr.io` for pulling the PDS container image during deployment.
- Optional: Port 443 accessible from validation workstation to the deployed PDS hostname.

## Configuration Inputs to Collect
- `namePrefix` (3–12 characters, alphanumeric) unique within the subscription to avoid storage name collisions.
- `pdsHostname` (FQDN) already delegated or to be CNAMEd to the Container App.
- `pdsImageTag` referencing an approved build from `ghcr.io/bluesky-social/pds`.
- Desired snapshot cadence (interval seconds and retention count) aligned to RPO/RTO targets.

## Security Practices
- Store secret material (JWT, admin password, PLC key, SMTP credentials) in a secure vault prior to deployment.
- Enforce multi-factor authentication for all operator accounts.
- Review Key Vault access policies after deployment to remove unneeded principals.

## Next Steps
Proceed to `docs/quickstart.md` after verifying the above prerequisites. Document any deviations or compensating controls in the team runbook repository.
