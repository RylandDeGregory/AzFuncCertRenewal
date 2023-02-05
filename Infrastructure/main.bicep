@description('The Azure Region to deploy the resources into. Default: resourceGroup().location')
param location string = resourceGroup().location

@description('Switch to enable/disable DiagnosticSettings for the resources. Default: false')
param logsEnabled bool = false

@description('A unique string to add as a suffix to all resources. Default: substring(uniqueString(resourceGroup().id), 0, 5)')
param uniqueSuffix string = substring(uniqueString(resourceGroup().id), 0, 5)

@description('Log Analytics Workspace name. Default: log-lecertrenew-$<uniqueSuffix>')
param logAnalyticsWorkspaceName string = 'log-lecertrenew-${uniqueSuffix}'

@description('Application Insights name. Default: appi-lecertrenew-$<uniqueSuffix>')
param appInsightsName string = 'appi-lecertrenew-${uniqueSuffix}'

@description('Storage Account name. Default: stlecertrenew$<uniqueSuffix>')
param storageAccountName string = 'stlecertrenew${uniqueSuffix}'

@description('Blob container name within Storage Account. Default: acme')
param blobContainerName string = 'acme'

@description('App Service Plan name. Default: asp-lecertrenew-$<uniqueSuffix>')
param appServicePlanName string = 'asp-lecertrenew-${uniqueSuffix}'

@description('Function App name. Default: func-lecertrenew-$<uniqueSuffix>')
param functionAppName string = 'func-lecertrenew-${uniqueSuffix}'

@description('Key Vault name. Default: kv-lecertrenew-$<uniqueSuffix>')
param keyVaultName string = 'kv-lecertrenew-${uniqueSuffix}'

@description('DNS Zone Resource Group name. Default: resourceGroup().name')
param dnsZoneResourceGroupName string = resourceGroup().name

@description('DNS Zone name')
param dnsZoneName string

// Default logging policy for all resources
var defaultLogOrMetric = {
  enabled: logsEnabled
  retentionPolicy: {
    days: logsEnabled ? 7 : 0
    enabled: logsEnabled
  }
}

// Resource Group Lock
resource rgLock 'Microsoft.Authorization/locks@2016-09-01' = {
  scope: resourceGroup()
  name: 'DoNotDelete'
  properties: {
    level: 'CanNotDelete'
    notes: 'This lock prevents the accidental deletion of resources'
  }
}

// Built-in RBAC Role definitions
@description('Built-in Storage Blob Data Contributor role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#storage-blob-data-contributor')
resource storageBlobContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

@description('Built-in Key Vault Certificates Officer role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#key-vault-certificates-officer')
resource keyVaultCertificatesOfficerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'a4417e6f-fecd-4de8-b567-7b0420556985'
}

// RBAC Role assignments
@description('Allows Function App Managed Identity to write to Storage Account')
resource funcMIBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(func.id, st.id, storageBlobContributorRole.id)
  scope: st
  properties: {
    roleDefinitionId: storageBlobContributorRole.id
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Allows Function App Managed Identity to manage Key Vault Certificates')
resource funcMIVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(func.id, kv.id, keyVaultCertificatesOfficerRole.id)
  scope: kv
  properties: {
    roleDefinitionId: keyVaultCertificatesOfficerRole.id
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// DNS Zone Role assignment
module funcMIDnsRole 'dns.bicep' = {
  name: 'DNSZoneRoleAssignment'
  scope: resourceGroup(dnsZoneResourceGroupName)
  params: {
    dnsZoneName: dnsZoneName
    functionAppId: func.id
    functionAppPrincipalId: func.identity.principalId
    uniqueSuffix: uniqueSuffix
  }
}

// Log Analytics Workspace
resource log 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource logDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'All Logs and Metrics'
  scope: log
  properties: {
    logs: [ union({ categoryGroup: 'allLogs' }, defaultLogOrMetric) ]
    metrics: [ union({ categoryGroup: 'allMetrics' }, defaultLogOrMetric) ]
    workspaceId: log.id
  }
}

// Application Insights
resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
  // Link Application Insights instance to Function App
  tags: {
    'hidden-link:${resourceId('Microsoft.Web/sites', functionAppName)}': 'Resource'
  }
}

// Storage Account
resource st 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    allowBlobPublicAccess: false
  }
}

// Enable Blob Soft Delete
resource stBlob 'Microsoft.Storage/storageAccounts/blobServices@2022-05-01' = {
  name: 'default'
  parent: st
  properties: {
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
  }
}

// Blob Container
resource stBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-05-01' = {
  name: blobContainerName
  parent: stBlob
}

resource stDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'All Logs and Metrics'
  scope: st
  properties: {
    metrics: [ union({ categoryGroup: 'allMetrics' }, defaultLogOrMetric) ]
    workspaceId: log.id
  }
}

resource stBlobDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'All Logs and Metrics'
  scope: stBlob
  properties: {
    logs: [ union({ categoryGroup: 'allLogs' }, defaultLogOrMetric) ]
    metrics: [ union({ categoryGroup: 'allMetrics' }, defaultLogOrMetric) ]
    workspaceId: log.id
  }
}

// App Service Plan
resource asp 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  properties: {
    reserved: true
  }
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
}

resource aspDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'All Logs and Metrics'
  scope: asp
  properties: {
    metrics: [ union({ category: 'AllMetrics' }, defaultLogOrMetric) ]
    workspaceId: log.id
  }
}

// Function App
resource func 'Microsoft.Web/sites@2022-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    reserved: true
    serverFarmId: asp.id
    keyVaultReferenceIdentity: 'SystemAssigned'
    siteConfig: {
      linuxFxVersion: 'POWERSHELL|7.2'
      appSettings: [
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appi.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appi.properties.ConnectionString
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${st.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${st.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${st.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${st.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: 'https://github.com/RylandDeGregory/AzFuncCertRenewal/blob/master/FunctionApp.zip?raw=true'
        }
        {
          name: 'KEY_VAULT_NAME'
          value: kv.name
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: st.name
        }
        {
          name: 'BLOB_CONTAINER_NAME'
          value: blobContainerName
        }
        {
          name: 'POSHACME_HOME'
          value: './tmp'
        }
      ]
      alwaysOn: false
    }
  }
}

resource funcDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'All Logs and Metrics'
  scope: func
  properties: {
    logs: [ union({ categoryGroup: 'allLogs' }, defaultLogOrMetric) ]
    metrics: [ union({ category: 'AllMetrics' }, defaultLogOrMetric) ]
    workspaceId: log.id
  }
}

// Key Vault
resource kv 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 30
    tenantId: tenant().tenantId
  }
}

resource kvDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'All Logs and Metrics'
  scope: kv
  properties: {
    logs: [ union({ categoryGroup: 'allLogs' }, defaultLogOrMetric) ]
    metrics: [ union({ category: 'AllMetrics' }, defaultLogOrMetric) ]
    workspaceId: log.id
  }
}
