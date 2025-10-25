@description('Prefix applied to most resource names.')
param namePrefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Fully qualified hostname clients use to reach the PDS (e.g. pds.example.com).')
param pdsHostname string

@description('Container image tag for ghcr.io/bluesky-social/pds (e.g. 0.4).')
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
param pdsJwtSecretName string

@description('Name of the Key Vault secret containing the PDS admin password.')
param pdsAdminPasswordSecretName string

@description('Name of the Key Vault secret containing the PLC rotation key (hex).')
param pdsPlcRotationKeySecretName string

@description('Name of the Key Vault secret containing the SMTP connection string or password.')
param smtpSecretName string

@description('From address to use when PDS sends email.')
param emailFromAddress string

@description('Object ID for an administrator that should have full access to the Key Vault.')
param adminObjectId string

@description('Quota in GiB allocated to the Azure Files share that stores PDS state.')
param fileShareQuotaGiB int = 256

@description('Optional DNS zone name (e.g. example.com). Leave empty to skip DNS record creation.')
param dnsZoneName string = ''

@description('Optional relative record for the container app within the DNS zone (e.g. pds). Ignored when dnsZoneName is empty.')
param dnsRecordName string = 'pds'

@description('Retention in days for Log Analytics data.')
param logAnalyticsRetentionDays int = 30

var tenantId = subscription().tenantId
var pdsImage = 'ghcr.io/bluesky-social/pds:${pdsImageTag}'
var storageAccountName = toLower(substring(replace('${namePrefix}${uniqueString(resourceGroup().id)}', '-', ''), 0, 24))
var containerAppName = '${namePrefix}-pds-app'
var keyVaultName = '${namePrefix}-kv'
var logAnalyticsName = '${namePrefix}-law'
var managedEnvName = '${namePrefix}-cae'
var fileShareName = 'pds'
var storageShareStorageName = 'pdsfiles'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    retentionInDays: logAnalyticsRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
  sku: {
    name: 'PerGB2018'
  }
}

resource managedEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: managedEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: listKeys(logAnalytics.id, '2020-08-01').primarySharedKey
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
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: managedEnv.id
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
      secrets: [
        {
          name: 'storage-key'
          value: listKeys(storageAccount.id, '2022-09-01').keys[0].value
        }
        {
          name: 'pds-jwt-secret'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsJwtSecretName}'
        }
        {
          name: 'pds-admin-password'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsAdminPasswordSecretName}'
        }
        {
          name: 'pds-plc-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${pdsPlcRotationKeySecretName}'
        }
        {
          name: 'pds-smtp-secret'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${smtpSecretName}'
        }
      ]
      storage: [
        {
          name: storageShareStorageName
          azureFile: {
            accountName: storageAccount.name
            shareName: fileShareName
            accessMode: 'ReadWrite'
            accountKeySecretRef: 'storage-key'
          }
        }
      ]
    }
    template: {
      revisionSuffix: toLower(format('r{0}', uniqueString(pdsImage)))
      containers: [
        {
          name: 'caddy'
          image: caddyImage
          resources: {
            requests: {
              cpu: caddyCpu
              memory: caddyMemory
            }
          }
          volumeMounts: [
            {
              name: storageShareStorageName
              mountPath: '/pds'
            }
          ]
          ports: [
            {
              port: 80
            }
            {
              port: 443
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
            requests: {
              cpu: pdsCpu
              memory: pdsMemory
            }
          }
          volumeMounts: [
            {
              name: storageShareStorageName
              mountPath: '/pds'
            }
          ]
          env: [
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
              value: emailFromAddress
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
              name: 'PDS_EMAIL_SMTP_URL'
              secretRef: 'pds-smtp-secret'
            }
          ]
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
}

resource kvPolicyApp 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  name: '${keyVault.name}/add'
  properties: {
    accessPolicies: [
      {
        tenantId: tenantId
        objectId: containerApp.identity.principalId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ]
  }
  dependsOn: [
    containerApp
  ]
}

resource containerAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${containerApp.name}-logs'
  scope: containerApp
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'ContainerAppConsoleLogs'
        enabled: true
      }
      {
        category: 'SystemLogs'
        enabled: true
      }
    ]
  }
}

resource dnsZone 'Microsoft.Network/dnsZones@2020-06-01' = if (dnsZoneName != '') {
  name: dnsZoneName
  location: 'global'
}

resource dnsRecord 'Microsoft.Network/dnsZones/CNAME@2020-06-01' = if (dnsZoneName != '') {
  name: '${dnsZone.name}/${dnsRecordName}'
  properties: {
    ttl: 300
    cnameRecord: {
      cname: containerApp.properties.configuration.ingress.fqdn
    }
  }
}

resource dnsWildcardRecord 'Microsoft.Network/dnsZones/CNAME@2020-06-01' = if (dnsZoneName != '') {
  name: '${dnsZone.name}/*.${dnsRecordName}'
  properties: {
    ttl: 300
    cnameRecord: {
      cname: containerApp.properties.configuration.ingress.fqdn
    }
  }
}

output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output storageAccountId string = storageAccount.id
output fileSharePath string = storageFileShare.name
output keyVaultUri string = keyVault.properties.vaultUri
