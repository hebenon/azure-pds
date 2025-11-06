@description('Prefix applied to most resource names.')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Fully qualified hostname clients use to reach the PDS (e.g. pds.example.com).')
@minLength(4)
@maxLength(253)
param pdsHostname string

@description('Container image tag for ghcr.io/bluesky-social/pds (e.g. 0.4).')
@minLength(1)
@maxLength(128)
param pdsImageTag string

@description('Optional name of a Container Apps certificate resource (within the managed environment) to bind to the ingress. Leave empty to skip automatic binding.')
param ingressCertificateName string = ''

@description('Whether to let Azure Container Apps request and renew a managed certificate when no existing certificate name is provided.')
param enableManagedCertificate bool = true

@description('CPU request for the PDS container in cores.')
param pdsCpu string = '0.5'

@description('Memory request for the PDS container.')
param pdsMemory string = '1Gi'

@description('Whether to allow unauthenticated HTTP (port 80) alongside HTTPS.')
param enableHttp bool = true

@description('Minimum number of replicas the container app should maintain.')
param minReplicas int = 1

@description('Maximum number of replicas the container app may scale to.')
param maxReplicas int = 2

@description('Name of the Key Vault secret containing the PDS JWT secret.')
@minLength(1)
@maxLength(127)
param pdsJwtSecretName string

@description('Name of the Key Vault secret containing the PDS admin password.')
@minLength(1)
@maxLength(127)
param pdsAdminPasswordSecretName string

@description('Name of the Key Vault secret containing the PLC rotation key (hex).')
@minLength(1)
@maxLength(127)
param pdsPlcRotationKeySecretName string

@description('Name of the Key Vault secret containing the SMTP connection string or password.')
@minLength(1)
@maxLength(127)
param smtpSecretName string = 'PDS-SMTP-URL'

@description('Name of the Key Vault secret containing the computed email from address.')
@minLength(1)
@maxLength(127)
param emailFromAddressSecretName string = 'PDS-EMAIL-FROM-ADDRESS'

@description('From address to use when PDS sends email. Leave empty to auto-use Azure-managed domain when enableCommunicationServices=true.')
@maxLength(320)
param emailFromAddress string = ''

@description('Whether to provision Azure Communication Services for email sending.')
param enableCommunicationServices bool = true

@description('Custom domain name for Azure Communication Services Email (e.g. notify.example.com). Leave empty to use Azure-managed domain.')
@maxLength(253)
param emailCustomDomain string = ''

@description('Object ID for an administrator that should have full access to the Key Vault.')
@minLength(36)
@maxLength(36)
param adminObjectId string

@description('Optional DNS zone name (e.g. example.com). Leave empty to skip DNS record creation.')
@maxLength(253)
param dnsZoneName string = ''

@description('Optional relative record for the container app within the DNS zone (e.g. pds). Ignored when dnsZoneName is empty.')
@minLength(1)
@maxLength(63)
param dnsRecordName string = 'pds'

@description('Retention in days for Log Analytics data.')
@minValue(7)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

@description('Name of the blob container used to store SQLite snapshot archives.')
@minLength(3)
@maxLength(63)
param snapshotContainerName string = 'pds-sqlite'

@description('Prefix applied to snapshot blob paths.')
@minLength(1)
param snapshotPrefix string = 'snapshots'

@description('Number of snapshot archives to retain in object storage.')
@minValue(10)
param backupRetentionCount int = 200

@description('URL for the PLC directory service.')
param pdsDidPlcUrl string = 'https://plc.directory'

@description('URL for the Bluesky API service.')
param pdsBskyAppViewUrl string = 'https://api.bsky.app'

@description('DID for the Bluesky API service.')
param pdsBskyAppViewDid string = 'did:web:api.bsky.app'

@description('URL for the Bluesky report service.')
param pdsReportServiceUrl string = 'https://mod.bsky.app'

@description('DID for the Bluesky report service.')
param pdsReportServiceDid string = 'did:plc:ar7c4by46qjdydhdevvrndac'

@description('Crawlers to whitelist for indexing (comma-separated URLs).')
param pdsCrawlers string = 'https://bsky.network'

var tenantId = subscription().tenantId
var pdsImage = 'ghcr.io/bluesky-social/pds:${pdsImageTag}'
var cleanedNamePrefix = replace('${namePrefix}${uniqueString(resourceGroup().id)}', '-', '')
var storageAccountName = toLower(length(cleanedNamePrefix) > 24 ? substring(cleanedNamePrefix, 0, 24) : cleanedNamePrefix)
var containerAppName = '${namePrefix}-pds-app'
var containerAppIdentityName = '${namePrefix}-pds-id'
var keyVaultName = '${namePrefix}-${uniqueString(resourceGroup().id)}-kv'
var logAnalyticsName = '${namePrefix}-law'
var managedEnvName = '${namePrefix}-cae'
var hasIngressCertificate = length(ingressCertificateName) > 0
var useManagedCertificate = !hasIngressCertificate && enableManagedCertificate
var managedCertificateEnabled = useManagedCertificate && dnsZoneName != ''
var managedCertificateName = '${namePrefix}-managed-cert'
var ingressCertificateResourceId = hasIngressCertificate ? resourceId('Microsoft.App/managedEnvironments/certificates', managedEnvName, ingressCertificateName) : ''
var managedCertificateResourceId = managedCertificateEnabled ? resourceId('Microsoft.App/managedEnvironments/managedCertificates', managedEnvName, managedCertificateName) : ''
var ingressCustomDomains = hasIngressCertificate ? [
  {
    name: pdsHostname
    certificateId: ingressCertificateResourceId
    bindingType: 'SniEnabled'
  }
] : []

var storageAccountKeySecretName = 'storage-account-key'
var communicationServiceName = '${namePrefix}-acs'
var emailServiceName = '${namePrefix}-email'
var hasEmailFromOverride = length(emailFromAddress) > 0
var includeSmtpSecret = length(smtpSecretName) > 0
var containerAppDependencies = enableCommunicationServices ? [
  containerAppIdentity
  emailFromAddressSecret
  kvPolicyApp
  managedEnvironment
  storageAccount
  smtpSecretSeed
] : [
  containerAppIdentity
  emailFromAddressSecret
  kvPolicyApp
  managedEnvironment
  storageAccount
]
var backupRestoreScriptContent = loadTextContent('../scripts/pds-backup/restore.sh')
var backupJobScriptContent = loadTextContent('../scripts/pds-backup/backup-job.sh')
var restoreScriptB64 = base64(backupRestoreScriptContent)
var backupJobScriptB64 = base64(backupJobScriptContent)
var computedEmailFromAddress = hasEmailFromOverride ? emailFromAddress : enableCommunicationServices && emailCustomDomain != '' ? 'donotreply@${emailCustomDomain}' : enableCommunicationServices ? 'donotreply@placeholder.azurecomm.net' : 'donotreply@example.com'
var smtpPlaceholderValue = 'smtps://pending-update@smtp.azurecomm.net:587'

resource containerAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: containerAppIdentityName
  location: location
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    retentionInDays: logAnalyticsRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: managedEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
  }
}

resource snapshotContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: '${storageAccount.name}/default/${snapshotContainerName}'
  properties: {
    publicAccess: 'None'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
  enablePurgeProtection: true
  enabledForTemplateDeployment: true
    accessPolicies: [
      {
        tenantId: tenantId
        objectId: adminObjectId
        permissions: {
          secrets: [
            'get'
            'list'
            'set'
            'delete'
            'recover'
            'backup'
            'restore'
          ]
        }
      }
    ]
  }
}

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerAppIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 2583
        allowInsecure: enableHttp
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        customDomains: ingressCustomDomains
      }
      secrets: concat([
        {
          name: 'pds-jwt-secret'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsJwtSecretName}'
          identity: containerAppIdentity.id
        }
        {
          name: 'pds-admin-password'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsAdminPasswordSecretName}'
          identity: containerAppIdentity.id
        }
        {
          name: 'pds-plc-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsPlcRotationKeySecretName}'
          identity: containerAppIdentity.id
        }
        {
          name: 'pds-email-from-address'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${emailFromAddressSecretName}'
          identity: containerAppIdentity.id
        }
        {
          name: 'storage-account-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${storageAccountKeySecretName}'
          identity: containerAppIdentity.id
        }
      ], includeSmtpSecret ? [
        {
          name: 'pds-smtp-secret'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${smtpSecretName}'
          identity: containerAppIdentity.id
        }
      ] : [])
    }
    template: {
      containers: [
        {
          name: 'pds'
          image: pdsImage
          resources: {
            cpu: json(pdsCpu)
            memory: pdsMemory
          }
          command: [
            '/bin/sh'
            '-c'
            'printf "%s" "$RESTORE_SCRIPT_B64" | base64 -d > /scripts/restore.sh; chmod +x /scripts/restore.sh; /scripts/restore.sh; exec node --enable-source-maps index.js'
          ]
          volumeMounts: [
            {
              volumeName: 'pds-data'
              mountPath: '/pds'
            }
            {
              volumeName: 'scripts'
              mountPath: '/scripts'
            }
          ]
          env: concat([
            {
              name: 'PDS_PORT'
              value: '2583'
            }
            {
              name: 'PDS_HOSTNAME'
              value: pdsHostname
            }
            {
              name: 'PDS_DATA_DIRECTORY'
              value: '/pds'
            }
            {
              name: 'PDS_ACTOR_STORE_DIRECTORY'
              value: '/pds/actors'
            }
            {
              name: 'PDS_BLOBSTORE_DISK_LOCATION'
              value: '/pds/blobs'
            }
            {
              name: 'PDS_BLOBSTORE_DISK_TMP_LOCATION'
              value: '/pds/blobs/tmp'
            }
            {
              name: 'PDS_BSKY_APP_VIEW_URL'
              value: pdsBskyAppViewUrl
            }
            {
              name: 'PDS_BSKY_APP_VIEW_DID'
              value: pdsBskyAppViewDid
            }
            {
              name: 'PDS_REPORT_SERVICE_URL'
              value: pdsReportServiceUrl
            }
            {
              name: 'PDS_REPORT_SERVICE_DID'
              value: pdsReportServiceDid
            }
            {
              name: 'PDS_CRAWLERS'
              value: pdsCrawlers
            }
            {
              name: 'PDS_DID_PLC_URL'
              value: '${pdsDidPlcUrl}'
            }
            {
              name: 'PDS_EMAIL_FROM_ADDRESS'
              secretRef: 'pds-email-from-address'
            }
            {
              name: 'PDS_JWT_SECRET'
              secretRef: 'pds-jwt-secret'
            }
            {
              name: 'PDS_ADMIN_PASSWORD'
              secretRef: 'pds-admin-password'
            }
            {
              name: 'PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX'
              secretRef: 'pds-plc-key'
            }
            {
              name: 'RESTORE_SCRIPT_B64'
              value: restoreScriptB64
            }
            {
              name: 'AZURE_STORAGE_ACCOUNT_NAME'
              value: storageAccount.name
            }
            {
              name: 'AZURE_STORAGE_ACCOUNT_KEY'
              secretRef: 'storage-account-key'
            }
            {
              name: 'SNAPSHOT_CONTAINER'
              value: snapshotContainerName
            }
            {
              name: 'SNAPSHOT_PREFIX'
              value: snapshotPrefix
            }
            {
              name: 'PDS_ID'
              value: namePrefix
            }
            {
              name: 'DATA_DIR'
              value: '/pds'
            }
            {
              name: 'WORK_DIR'
              value: '/pds/work'
            }
            {
              name: 'SENTINEL_PATH'
              value: '/pds/.restore-complete'
            }
          ], includeSmtpSecret ? [
            {
              name: 'PDS_EMAIL_SMTP_URL'
              secretRef: 'pds-smtp-secret'
            }
          ] : [])
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
      volumes: [
        {
          name: 'pds-data'
          storageType: 'EmptyDir'
        }
        {
          name: 'scripts'
          storageType: 'EmptyDir'
        }
      ]
    }
  }
  dependsOn: containerAppDependencies
}

resource managedCertificate 'Microsoft.App/managedEnvironments/managedCertificates@2024-03-01' = if (managedCertificateEnabled) {
  name: managedCertificateName
  parent: managedEnvironment
  location: location
  properties: {
    subjectName: pdsHostname
    domainControlValidation: 'TXT'
  }
  dependsOn: [
    dnsVerificationRecord
  ]
}

module enableCustomDomainSni 'containerapp-enable-sni.bicep' = if (managedCertificateEnabled) {
  name: '${namePrefix}-enable-sni'
  params: {
    containerAppName: containerAppName
    hostname: pdsHostname
    certificateId: managedCertificateResourceId
  }
  dependsOn: [
    managedCertificate
    dnsVerificationRecord
  ]
}

resource kvPolicyApp 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  name: 'add'
  parent: keyVault
  properties: {
    accessPolicies: [
      {
        tenantId: tenantId
        objectId: containerAppIdentity.properties.principalId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ]
  }
}

resource containerAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${containerApp.name}-metrics'
  scope: containerApp
  properties: {
    workspaceId: logAnalytics.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource backupJob 'Microsoft.App/jobs@2024-03-01' = {
  name: '${namePrefix}-pds-backup-job'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerAppIdentity.id}': {}
    }
  }
  properties: {
    environmentId: managedEnvironment.id
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: 600
      secrets: [
        {
          name: 'storage-account-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${storageAccountKeySecretName}'
          identity: containerAppIdentity.id
        }
      ]
      scheduleTriggerConfig: {
        cronExpression: '*/5 * * * *'
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    template: {
      containers: [
        {
          name: 'backup-job'
          image: 'mcr.microsoft.com/azure-cli:2.64.0'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          command: [
            '/bin/sh'
            '-c'
            'set -euo pipefail; echo "[backup-job-init] Detecting package manager"; if command -v apt-get >/dev/null 2>&1; then echo "[backup-job-init] Installing deps via apt-get"; DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 zstd tar gawk >/dev/null; elif command -v apk >/dev/null 2>&1; then echo "[backup-job-init] Installing deps via apk"; apk add --no-cache sqlite zstd tar gawk; elif command -v microdnf >/dev/null 2>&1; then echo "[backup-job-init] Installing deps via microdnf"; microdnf install -y sqlite zstd tar gawk; elif command -v dnf >/dev/null 2>&1; then echo "[backup-job-init] Installing deps via dnf"; dnf install -y sqlite zstd tar gawk; elif command -v yum >/dev/null 2>&1; then echo "[backup-job-init] Installing deps via yum"; yum install -y sqlite zstd tar gawk; elif command -v tdnf >/dev/null 2>&1; then echo "[backup-job-init] Installing deps via tdnf"; tdnf install -y sqlite tar gawk zstd; else echo "ERROR: no supported package manager found" >&2; exit 1; fi; printf "%s" "$BACKUP_JOB_SCRIPT_B64" | base64 -d > /scripts/backup-job.sh; chmod +x /scripts/backup-job.sh; exec /scripts/backup-job.sh'
          ]
          env: [
            {
              name: 'AZURE_STORAGE_ACCOUNT_NAME'
              value: storageAccount.name
            }
            {
              name: 'AZURE_STORAGE_ACCOUNT_KEY'
              secretRef: 'storage-account-key'
            }
            {
              name: 'SNAPSHOT_CONTAINER'
              value: snapshotContainerName
            }
            {
              name: 'SNAPSHOT_PREFIX'
              value: snapshotPrefix
            }
            {
              name: 'BACKUP_JOB_SCRIPT_B64'
              value: backupJobScriptB64
            }
            {
              name: 'PDS_ID'
              value: namePrefix
            }
            {
              name: 'RETAIN_COUNT'
              value: string(backupRetentionCount)
            }
            {
              name: 'DATA_DIR'
              value: '/data'
            }
            {
              name: 'WORK_DIR'
              value: '/work'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'pds-data'
              mountPath: '/data'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'pds-data'
          storageType: 'EmptyDir'
        }
      ]
    }
  }
}

// Store storage account key in Key Vault for backup agent access
resource storageKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: storageAccountKeySecretName
  parent: keyVault
  properties: {
    value: storageAccount.listKeys().keys[0].value
  }
}

// Grant Key Vault Secrets User role to container app
resource containerAppKvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, containerAppIdentity.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: containerAppIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure Communication Services for Email
resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = if (enableCommunicationServices) {
  name: emailServiceName
  location: 'global'
  properties: {
    dataLocation: 'United States'
  }
}

resource emailDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (enableCommunicationServices && emailCustomDomain == '') {
  name: 'AzureManagedDomain'
  parent: emailService
  location: 'global'
  properties: {
    domainManagement: 'AzureManaged'
  }
}

resource emailCustomDomainResource 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (enableCommunicationServices && emailCustomDomain != '') {
  name: emailCustomDomain
  parent: emailService
  location: 'global'
  properties: {
    domainManagement: 'CustomerManaged'
  }
}

resource communicationService 'Microsoft.Communication/communicationServices@2023-04-01' = if (enableCommunicationServices) {
  name: communicationServiceName
  location: 'global'
  properties: {
    dataLocation: 'United States'
    linkedDomains: [
      emailCustomDomain == '' ? emailDomain.id : emailCustomDomainResource.id
    ]
  }
}

resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' = if (dnsZoneName != '') {
  name: dnsZoneName
  location: 'global'
}

resource emailFromAddressSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: emailFromAddressSecretName
  parent: keyVault
  properties: {
    value: computedEmailFromAddress
  }
}

resource smtpSecretSeed 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (enableCommunicationServices) {
  name: smtpSecretName
  parent: keyVault
  properties: {
    value: smtpPlaceholderValue
  }
}

resource dnsRecord 'Microsoft.Network/dnsZones/CNAME@2023-07-01-preview' = if (dnsZoneName != '') {
  name: dnsRecordName
  parent: dnsZone
  properties: {
    TTL: 300
    CNAMERecord: {
      cname: containerApp.properties.configuration.ingress.fqdn
    }
  }
}

resource dnsWildcardRecord 'Microsoft.Network/dnsZones/CNAME@2023-07-01-preview' = if (dnsZoneName != '') {
  name: '*.${dnsRecordName}'
  parent: dnsZone
  properties: {
    TTL: 300
    CNAMERecord: {
      cname: containerApp.properties.configuration.ingress.fqdn
    }
  }
}

resource dnsVerificationRecord 'Microsoft.Network/dnsZones/TXT@2023-07-01-preview' = if (dnsZoneName != '') {
  name: 'asuid.${dnsRecordName}'
  parent: dnsZone
  properties: {
    TTL: 300
    TXTRecords: [
      {
        value: [
          containerApp.properties.customDomainVerificationId
        ]
      }
    ]
  }
}

output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output storageAccountId string = storageAccount.id
output snapshotContainerResourceId string = snapshotContainer.id
output snapshotContainerName string = snapshotContainerName
output keyVaultUri string = keyVault.properties.vaultUri
output communicationServiceEndpoint string = enableCommunicationServices ? communicationService!.properties.hostName : ''
output emailServiceName string = enableCommunicationServices ? emailService!.name : ''
output managedCertificateResourceId string = useManagedCertificate ? managedCertificate.id : ingressCertificateResourceId
output containerAppCustomDomainVerificationId string = containerApp.properties.customDomainVerificationId
output smtpServer string = 'smtp.azurecomm.net'
output smtpPort int = 587
output communicationServiceResourceId string = enableCommunicationServices ? communicationService!.id : ''
output emailDomainResourceId string = enableCommunicationServices ? (emailCustomDomain == '' ? emailDomain!.id : emailCustomDomainResource!.id) : ''
output emailFromAddress string = computedEmailFromAddress
output keyVaultName string = keyVault.name
