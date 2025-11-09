@description('Name of the Azure Container App to bind the managed certificate to.')
@minLength(3)
param containerAppName string

@description('Fully qualified domain name to bind to the container app.')
@minLength(4)
@maxLength(253)
param hostname string

@description('Resource ID of the managed certificate to use for the binding.')
@minLength(1)
param certificateId string

resource targetContainerApp 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: containerAppName
}

resource customDomainBinding 'Microsoft.App/containerApps/customDomains@2024-03-01' = {
  name: hostname
  parent: targetContainerApp
  properties: {
    bindingType: 'SniEnabled'
    certificateId: certificateId
  }
}
