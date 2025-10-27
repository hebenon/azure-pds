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

@description('Optional override for the Caddy container image.')
param caddyImage string = 'caddy:2'

@description('CPU request for the PDS container in cores.')
param pdsCpu string = '0.5'

@description('Memory request for the PDS container.')
param pdsMemory string = '1Gi'

@description('CPU request for the Caddy container in cores.')
param caddyCpu string = '0.25'

@description('Memory request for the Caddy container.')
param caddyMemory string = '0.5Gi'

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

@description('Quota in GiB allocated to the Azure Files share that stores PDS state.')
@minValue(1)
@maxValue(102400)
param fileShareQuotaGiB int = 256

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

@description('Maintenance window for backup operations (e.g., "Sun 02:00").')
@minLength(7)
@maxLength(10)
param maintenanceWindow string = 'Sun 02:00'

@description('Retention in days for Azure Files snapshots.')
@minValue(7)
@maxValue(365)
param backupRetentionDays int = 30

@description('Base date for schedule calculation.')
param baseDateTime string = utcNow('yyyy-MM-dd')

@description('URI hosting the Automation runbook PowerShell script.')
param backupRunbookContentUri string = 'https://raw.githubusercontent.com/bluesky-social/azure-pds/main/scripts/runbooks/BackupPdsFiles.ps1'

@description('SHA256 hash of the Automation runbook script content.')
param backupRunbookContentHash string = '40b3063d62778cebaf5390b6fdfaf2e2d9f9470a7e838e7615676ca273b6656d'

var tenantId = subscription().tenantId
var pdsImage = 'ghcr.io/bluesky-social/pds:${pdsImageTag}'
var cleanedNamePrefix = replace('${namePrefix}${uniqueString(resourceGroup().id)}', '-', '')
var storageAccountName = toLower(length(cleanedNamePrefix) > 24 ? substring(cleanedNamePrefix, 0, 24) : cleanedNamePrefix)
var containerAppName = '${namePrefix}-pds-app'
var containerAppIdentityName = '${namePrefix}-pds-id'
var keyVaultName = '${namePrefix}-${uniqueString(resourceGroup().id)}-kv'
var logAnalyticsName = '${namePrefix}-law'
var managedEnvName = '${namePrefix}-cae'
var automationAccountName = '${namePrefix}-auto'
var runbookName = 'BackupPdsFiles'
var scheduleName = 'DailyBackupSchedule'
var fileShareName = 'pds'
var storageShareStorageName = 'pdsfiles'
var storageAccountKeySecretName = 'storage-account-key'
var communicationServiceName = '${namePrefix}-acs'
var emailServiceName = '${namePrefix}-email'
var hasEmailFromOverride = length(emailFromAddress) > 0
var includeSmtpSecret = length(smtpSecretName) > 0
var maintenanceParts = split(maintenanceWindow, ' ')
var maintenanceTimePart = length(maintenanceParts) > 1 ? maintenanceParts[1] : maintenanceWindow
var maintenanceTimeSegments = split(maintenanceTimePart, ':')
var maintenanceHour = padLeft(maintenanceTimeSegments[0], 2, '0')
var maintenanceMinute = padLeft(length(maintenanceTimeSegments) > 1 ? maintenanceTimeSegments[1] : '00', 2, '0')
var scheduleStartTime = dateTimeAdd('${baseDateTime}T${maintenanceHour}:${maintenanceMinute}:00.000Z', 'P2D')
// Compute the email from address based on configuration
var computedEmailFromAddress = hasEmailFromOverride ? emailFromAddress : enableCommunicationServices && emailCustomDomain != '' ? 'donotreply@${emailCustomDomain}' : enableCommunicationServices ? 'donotreply@placeholder.azurecomm.net' : 'donotreply@example.com'
var smtpPlaceholderValue = 'smtps://pending-update@smtp.azurecomm.net:587'
var backupRunbookContentLink = {
  uri: backupRunbookContentUri
  contentHash: {
    algorithm: 'sha256'
    value: backupRunbookContentHash
  }
}

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

resource storageMount 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  parent: managedEnvironment
  name: storageShareStorageName
  properties: {
    azureFile: {
      accountName: storageAccount.name
      shareName: fileShareName
      accessMode: 'ReadWrite'
      accountKey: storageAccount.listKeys().keys[0].value
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

resource storageFileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2022-09-01' = {
  name: '${storageAccount.name}/default/${fileShareName}'
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
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
        targetPort: 443
        allowInsecure: true
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: concat([
        {
          name: 'pds-jwt-secret'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsJwtSecretName}'
          identity: 'userAssigned'
        }
        {
          name: 'pds-admin-password'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsAdminPasswordSecretName}'
          identity: 'userAssigned'
        }
        {
          name: 'pds-plc-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsPlcRotationKeySecretName}'
          identity: 'userAssigned'
        }
        {
          name: 'pds-email-from-address'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${emailFromAddressSecretName}'
          identity: 'userAssigned'
        }
      ], includeSmtpSecret ? [
        {
          name: 'pds-smtp-secret'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${smtpSecretName}'
          identity: 'userAssigned'
        }
      ] : [])
    }
    template: {
      revisionSuffix: toLower(format('r{0}', uniqueString(pdsImage)))
      containers: [
        {
          name: 'caddy'
          image: caddyImage
          resources: {
            cpu: json(caddyCpu)
            memory: caddyMemory
          }
          volumeMounts: [
            {
              volumeName: storageShareStorageName
              mountPath: '/pds'
            }
          ]
          env: [
            {
              name: 'ACME_AGREE'
              value: 'true'
            }
            {
              name: 'PDS_HOSTNAME'
              value: pdsHostname
            }
          ]
        }
        {
          name: 'pds'
          image: pdsImage
          resources: {
            cpu: json(pdsCpu)
            memory: pdsMemory
          }
          volumeMounts: [
            {
              volumeName: storageShareStorageName
              mountPath: '/pds'
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
              name: 'PDS_SQLITE_DISABLE_WAL_AUTO_CHECKPOINT'
              value: 'true'
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
          name: storageShareStorageName
          storageType: 'AzureFile'
          storageName: storageShareStorageName
        }
      ]
    }
  }
  dependsOn: enableCommunicationServices ? [
    storageMount
    emailFromAddressSecret
    smtpSecretSeed
    kvPolicyApp
  ] : [
    storageMount
    emailFromAddressSecret
    kvPolicyApp
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

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource backupRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  name: runbookName
  parent: automationAccount
  location: location
  properties: {
    runbookType: 'PowerShell'
    description: 'Creates daily snapshots of the PDS Azure Files share and manages retention'
    publishContentLink: {
  uri: backupRunbookContentLink.uri
  contentHash: backupRunbookContentLink.contentHash
    }
  }
}

resource backupSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  name: scheduleName
  parent: automationAccount
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: scheduleStartTime
    timeZone: 'UTC'
    description: 'Daily backup schedule for PDS files'
  }
}

resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  name: guid(automationAccount.id, backupRunbook.id, backupSchedule.id)
  parent: automationAccount
  properties: {
    runbook: {
      name: backupRunbook.name
    }
    schedule: {
      name: backupSchedule.name
    }
    parameters: {
      StorageAccountName: storageAccount.name
      ShareName: fileShareName
      RetentionDays: string(backupRetentionDays)
      ResourceGroupName: resourceGroup().name
    }
  }
}

// Grant Storage Account Contributor role to automation account
resource automationStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, automationAccount.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'storage')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Account Contributor
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Store storage account key in Key Vault for runbook access
resource storageKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: storageAccountKeySecretName
  parent: keyVault
  properties: {
    value: storageAccount.listKeys().keys[0].value
  }
}

// Grant Key Vault Secrets User role to automation account
resource automationKvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, automationAccount.id, '4633458b-17de-408a-b874-0445c86b69e6', 'automation')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grant Key Vault Secrets User role to container app
resource containerAppKvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, containerApp.id, '4633458b-17de-408a-b874-0445c86b69e6', 'containerapp')
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

output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output storageAccountId string = storageAccount.id
output fileSharePath string = storageFileShare.name
output keyVaultUri string = keyVault.properties.vaultUri
output automationAccountName string = automationAccount.name
output automationRunbookId string = backupRunbook.id
output backupScheduleName string = backupSchedule.name
output communicationServiceEndpoint string = enableCommunicationServices ? communicationService!.properties.hostName : ''
output emailServiceName string = enableCommunicationServices ? emailService!.name : ''
output smtpServer string = 'smtp.azurecomm.net'
output smtpPort int = 587
output communicationServiceResourceId string = enableCommunicationServices ? communicationService!.id : ''
output emailDomainResourceId string = enableCommunicationServices ? (emailCustomDomain == '' ? emailDomain!.id : emailCustomDomainResource!.id) : ''
output emailFromAddress string = computedEmailFromAddress
output keyVaultName string = keyVault.name
