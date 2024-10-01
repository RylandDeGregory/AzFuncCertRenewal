@description('Function App Resource ID to assign Role to')
param functionAppId string

@description('Function App Managed Identity Service Principal ID')
param functionAppPrincipalId string

@description('DNS Zone to assign Role over')
param dnsZoneName string

@description('Unique suffix to add to Custom Role name. Default: substring(uniqueString(resourceGroup().id), 0, 5)')
param uniqueSuffix string = substring(uniqueString(resourceGroup().id), 0, 5)


var customRoleName = guid(resourceGroup().id, string(customRoleActions), uniqueSuffix)
var customRoleActions = [
  'Microsoft.Authorization/*/read'
  'Microsoft.Insights/alertRules/*'
  'Microsoft.Network/dnsZones/TXT/*'
  'Microsoft.Network/dnsZones/read'
  'Microsoft.ResourceHealth/availabilityStatuses/read'
  'Microsoft.Resources/deployments/read'
  'Microsoft.Resources/subscriptions/resourceGroups/read'
]


// DNS Zone
resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' existing = {
  name: dnsZoneName
}

// Custom RBAC Role definition
@description('Custom RBAC role to allow management of TXT records in a DNS Zone')
resource dnsTxtContributrorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: customRoleName
  properties: {
    roleName: 'DNS TXT Contributor - ${uniqueSuffix}'
    description: 'Manage DNS TXT records only.'
    type: 'customRole'
    permissions: [
      {
        actions: customRoleActions
      }
    ]
    assignableScopes: [
      resourceGroup().id
    ]
  }
}

// Custom RBAC Role assigment
@description('Allows Function App Managed Idetity to manage DNS TXT records')
resource funcMIDnsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionAppId, dnsZone.id, dnsTxtContributrorRole.id)
  scope: dnsZone
  properties: {
    roleDefinitionId: dnsTxtContributrorRole.id
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}
