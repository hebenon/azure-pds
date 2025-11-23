# Azure PDS Infrastructure Parameters Examples

This file provides example parameter configurations for different deployment scenarios.

## Basic Deployment (Azure-Managed Email Domain)

```bash
az deployment group create \
  --resource-group example \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=pds \
    pdsHostname=pds.example.com \
    pdsImageTag=0.4 \
    adminObjectId=12345678-1234-1234-1234-123456789012 \
    enableCommunicationServices=true \
    pdsJwtSecretName=PDS-JWT-SECRET \
    pdsAdminPasswordSecretName=PDS-ADMIN-PASSWORD \
    pdsPlcRotationKeySecretName=PDS-PLC-ROTATION-KEY-K256-PRIVATE-KEY-HEX \
    smtpSecretName=PDS-SMTP-URL \
    dnsZoneName=example.com \
    dnsRecordName=pds
```

> **Note**: The `emailFromAddress` parameter is now optional when using Communication Services. The system automatically uses the Azure-managed domain email address.

## Production Deployment (Custom Email Domain)

```bash
az deployment group create \
  --resource-group example \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=pds \
    pdsHostname=pds.example.com \
    pdsImageTag=0.4 \
    adminObjectId=12345678-1234-1234-1234-123456789012 \
    emailFromAddress=noreply@notify.example.com \
    enableCommunicationServices=true \
    emailCustomDomain=notify.example.com \
    pdsJwtSecretName=PDS-JWT-SECRET \
    pdsAdminPasswordSecretName=PDS-ADMIN-PASSWORD \
    pdsPlcRotationKeySecretName=PDS-PLC-ROTATION-KEY-K256-PRIVATE-KEY-HEX \
    smtpSecretName=PDS-SMTP-URL \
    dnsZoneName=example.com \
    dnsRecordName=pds \
    logAnalyticsRetentionDays=90 \
    snapshotContainerName=pds-sqlite \
    snapshotPrefix=snapshots \
    backupIntervalSeconds=15 \
    backupRetentionCount=400
```

## External SMTP Provider (No Communication Services)

```bash
az deployment group create \
  --resource-group example \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=pds \
    pdsHostname=pds.example.com \
    pdsImageTag=0.4 \
    adminObjectId=12345678-1234-1234-1234-123456789012 \
    emailFromAddress=noreply@example.com \
    enableCommunicationServices=false \
    pdsJwtSecretName=PDS-JWT-SECRET \
    pdsAdminPasswordSecretName=PDS-ADMIN-PASSWORD \
    pdsPlcRotationKeySecretName=PDS-PLC-ROTATION-KEY-K256-PRIVATE-KEY-HEX \
    smtpSecretName=PDS-SMTP-URL \
    dnsZoneName=example.com \
    dnsRecordName=pds
```

## Development/Testing Deployment

```bash
az deployment group create \
  --resource-group pds-dev \
  --template-file infra/main.bicep \
  --parameters \
    namePrefix=dev \
    pdsHostname=dev-pds.example.com \
    pdsImageTag=latest \
    adminObjectId=12345678-1234-1234-1234-123456789012 \
    enableCommunicationServices=true \
    pdsJwtSecretName=PDS-JWT-SECRET \
    pdsAdminPasswordSecretName=PDS-ADMIN-PASSWORD \
    pdsPlcRotationKeySecretName=PDS-PLC-ROTATION-KEY-K256-PRIVATE-KEY-HEX \
    smtpSecretName=PDS-SMTP-URL \
    pdsCpu=0.25 \
    pdsMemory=0.5Gi \
    minReplicas=0 \
    maxReplicas=1 \
    logAnalyticsRetentionDays=7 \
    snapshotContainerName=pds-dev-sqlite \
    snapshotPrefix=snapshots \
    backupIntervalSeconds=30 \
    backupRetentionCount=50
```

> **Note**: Development deployments automatically use Azure-managed email domains for simplicity.

## Parameter Descriptions

| Parameter | Required | Description | Example |
|-----------|----------|-------------|---------|
| `namePrefix` | Yes | Prefix for resource names (3-12 chars) | `pds` |
| `pdsHostname` | Yes | Full hostname for PDS | `pds.example.com` |
| `pdsImageTag` | Yes | Container image tag | `0.4` |
| `adminObjectId` | Yes | Azure AD Object ID for admin | `12345678-...` |
| `emailFromAddress` | No | Email sender address (auto-set if empty) | `noreply@example.com` |
| `enableCommunicationServices` | No | Enable Azure Communication Services | `true` |
| `emailCustomDomain` | No | Custom domain for email (if enabled) | `notify.example.com` |
| `pdsJwtSecretName` | Yes | Key Vault secret name for JWT | `PDS-JWT-SECRET` |
| `pdsAdminPasswordSecretName` | Yes | Key Vault secret name for admin password | `PDS-ADMIN-PASSWORD` |
| `pdsPlcRotationKeySecretName` | Yes | Key Vault secret name for PLC key | `PDS-PLC-ROTATION-KEY...` |
| `smtpSecretName` | No | Key Vault secret name for SMTP URL (defaults to `PDS-SMTP-URL`) | `PDS-SMTP-URL` |
| `dnsZoneName` | No | Azure DNS zone name | `example.com` |
| `dnsRecordName` | No | DNS record name | `pds` |
| `pdsCpu` | No | PDS container CPU request | `0.5` |
| `pdsMemory` | No | PDS container memory request | `1Gi` |
| `minReplicas` | No | Minimum container replicas | `1` |
| `maxReplicas` | No | Maximum container replicas | `2` |
| `logAnalyticsRetentionDays` | No | Log retention days | `30` |
| `snapshotContainerName` | No | Blob container name for snapshot archives | `pds-sqlite` |
| `snapshotPrefix` | No | Blob prefix where archives are written | `snapshots` |
| `backupIntervalSeconds` | No | Seconds between snapshot uploads | `15` |
| `backupRetentionCount` | No | Number of archives to retain | `200` |

## Finding Your Admin Object ID

```bash
# Get your own Object ID
az ad signed-in-user show --query id --output tsv

# Get Object ID for specific user
az ad user show --id user@domain.com --query id --output tsv

# Get Object ID for service principal
az ad sp show --id <app-id> --query id --output tsv
```

## Environment-Specific Configurations

### Development
- Use smaller resource allocations (`pdsCpu`, `pdsMemory`)
- Shorter retention targets (`logAnalyticsRetentionDays`, `backupRetentionCount`)
- Lower replica counts (`minReplicas=0`, `maxReplicas=1`)
- Azure-managed email domain for simplicity

### Staging
- Production-like resource allocations
- Medium retention periods (30-60 days)
- Custom email domain for realistic testing
- Same maintenance windows as production

### Production
- Full resource allocations
- Extended retention periods (90+ days)
- Custom email domain with proper DNS setup
- Scheduled maintenance windows during low-usage periods
- Multiple replicas for high availability

## Regional Considerations

Some parameters may need adjustment for different Azure regions:

- **Location**: Ensure Container Apps and Communication Services are available
- **Data Residency**: Communication Services `dataLocation` for compliance
- **Snapshot Cadence**: Tune `backupIntervalSeconds` and `backupRetentionCount` for compliance and network constraints
- **Compliance**: Check regional requirements for data retention periods

## Next Steps

1. Choose the appropriate example for your environment
2. Replace placeholder values with your actual values
3. Review and adjust optional parameters as needed
4. Run the deployment command
5. Follow the quickstart guide for post-deployment configuration