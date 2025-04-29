@sys.description('The name of the Azure Application Insights resource. Default: appi-lecertrenew-$<uniqueSuffix>')
@sys.minLength(1)
@sys.maxLength(260)
param appInsightsName string = 'appi-lecertrenew-${uniqueSuffix}'

@sys.description('The name of the Azure App Service Plan.. Default: asp-lecertrenew-$<uniqueSuffix>')
@sys.minLength(2)
@sys.maxLength(60)
param appServicePlanName string = 'asp-lecertrenew-${uniqueSuffix}'

@sys.description('The name of the Azure Storage Account Blob container. Default: acme')
@sys.minLength(3)
@sys.maxLength(63)
param blobContainerName string = 'acme'

@sys.description('The Azure Resource ID of the existing Azure DNS Zone. Default: resourceGroup().name')
param dnsZoneResourceId string

@sys.description('The name of the Azure Function App. Default: func-lecertrenew-$<uniqueSuffix>')
@sys.minLength(2)
@sys.maxLength(60)
param functionAppName string = 'func-lecertrenew-${uniqueSuffix}'

@sys.description('The name of the Azure Key Vault. Default: kv-lecertrenew-$<uniqueSuffix>')
@sys.minLength(3)
@sys.maxLength(24)
param keyVaultName string = 'kv-lecertrenew-${uniqueSuffix}'

@sys.description('The Azure Region to deploy the resources into. Default: resourceGroup().location')
param location string = resourceGroup().location

@sys.description('The name of the Azure Log Analytics Workspace that Diagnostic Settings will be connected to. Default: log-lecertrenew-$<uniqueSuffix>')
@sys.minLength(4)
@sys.maxLength(63)
param logAnalyticsWorkspaceName string = 'log-lecertrenew-${uniqueSuffix}'

@sys.description('If Azure Diagnostics Settings are enabled for the resources. Default: false')
param diagnosticSettingsEnabled bool = false

@sys.description('The name of the Azure Storage Account. Default: stlecertrenew$<uniqueSuffix>')
@sys.minLength(3)
@sys.maxLength(24)
param storageAccountName string = 'stlecertrenew${replace(uniqueSuffix, '-', '')}'

@sys.description('A unique string to add as a suffix to all resources. Default: substring(uniqueString(resourceGroup().id), 0, 5)')
@sys.maxLength(5)
param uniqueSuffix string = substring(uniqueString(resourceGroup().id), 0, 5)

// Split DNS Zone Resource ID into scope components
var dnsZoneSubscription = split(dnsZoneResourceId, '/')[2]
var dnsZoneResourceGroup = split(dnsZoneResourceId, '/')[4]
var dnsZoneName = split(dnsZoneResourceId, '/')[8]

// Built-in RBAC Role definitions
@sys.description('Built-in Storage Blob Data Contributor role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#storage-blob-data-contributor')
resource storageBlobContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: subscription()
}

@sys.description('Built-in Key Vault Certificates Officer role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#key-vault-certificates-officer')
resource keyVaultCertificatesOfficerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'a4417e6f-fecd-4de8-b567-7b0420556985'
  scope: subscription()
}

// RBAC Role assignments
@sys.description('Allows Function App Managed Identity to write to Storage Account.')
resource funcMIBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, storageAccount.id, storageBlobContributorRole.id)
  properties: {
    roleDefinitionId: storageBlobContributorRole.id
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
  scope: resourceGroup()
}

@sys.description('Allows Function App Managed Identity to manage Key Vault Certificates.')
resource funcMIVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, keyVault.id, keyVaultCertificatesOfficerRole.id)
  properties: {
    roleDefinitionId: keyVaultCertificatesOfficerRole.id
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
  scope: resourceGroup()
}

// DNS Zone Role assignment
module funcMIDnsRole 'dns.bicep' = {
  name: 'DNSZoneRoleAssignment'
  params: {
    dnsZoneName: dnsZoneName
    functionAppPrincipalId: functionApp.identity.principalId
    uniqueSuffix: uniqueSuffix
  }
  scope: resourceGroup(dnsZoneSubscription, dnsZoneResourceGroup)
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
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

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  properties: {
    reserved: true
  }
  sku: {
    name: 'Y1'
    tier: 'Consumption'
  }
}

resource appServicePlanDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettingsEnabled) {
  name: 'All Logs and Metrics'
  scope: appServicePlan
  properties: {
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspace.id
  }
}

// Function App
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    endToEndEncryptionEnabled: true
    httpsOnly: true
    keyVaultReferenceIdentity: 'SystemAssigned'
    reserved: true
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureFunctionsJobHost__functionTimeout'
          value: '00:10:00'
        }
        {
          name: 'AzureFunctionsJobHost__managedDependency__enabled'
          value: 'true'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
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
          name: 'BLOB_CONTAINER_NAME'
          value: blobContainerName
        }
        {
          name: 'KEY_VAULT_NAME'
          value: keyVault.name
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccount.name
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: 'https://github.com/RylandDeGregory/AzFuncCertRenewal/blob/main/src.zip?raw=true'
        }
      ]
      alwaysOn: false
      ftpsState: 'Disabled'
      linuxFxVersion: 'POWERSHELL|7.4'
      http20Enabled: false
      minTlsVersion: '1.3'
      remoteDebuggingEnabled: false
    }
  }

  resource ftpPublishing 'basicPublishingCredentialsPolicies' = {
    name: 'ftp'
    properties: {
      allow: false
    }
  }

  resource scmPublishing 'basicPublishingCredentialsPolicies' = {
    name: 'scm'
    properties: {
      allow: false
    }
  }
}

resource funcDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettingsEnabled) {
  name: 'All Logs and Metrics'
  scope: functionApp
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspace.id
  }
}

// Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 30
    tenantId: tenant().tenantId
  }
}

resource kvDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettingsEnabled) {
  name: 'All Logs and Metrics'
  scope: keyVault
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspace.id
  }
}

// Resource Group Lock
resource rgLock 'Microsoft.Authorization/locks@2020-05-01' = {
  scope: resourceGroup()
  name: 'DoNotDelete'
  properties: {
    level: 'CanNotDelete'
    notes: 'This lock prevents the accidental deletion of resources'
  }
}

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
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

  resource blobService 'blobServices' = {
    name: 'default'
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

    resource blobContainer 'containers' = {
      name: blobContainerName
    }
  }
}

resource blobServiceDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnosticSettingsEnabled) {
  name: 'All Logs and Metrics'
  scope: storageAccount::blobService
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspace.id
  }
}
