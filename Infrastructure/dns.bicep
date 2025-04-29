@sys.description('The name of the Azure DNS Zone to assign Azure RBAC Role on.')
@sys.minLength(1)
@sys.maxLength(63)
param dnsZoneName string

@sys.description('Principal ID (Object ID) of the identity to assign Azure RBAC Role to.')
@sys.minLength(36)
@sys.maxLength(36)
param functionAppPrincipalId string

@sys.description('Unique suffix to add to Custom Azure RBAC Role name. Default: substring(uniqueString(resourceGroup().id), 0, 5)')
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
resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' existing = {
  name: dnsZoneName
}

// Custom RBAC Role definition
@sys.description('Custom RBAC role to allow management of TXT records in a DNS Zone.')
resource dnsTxtContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: customRoleName
  properties: {
    assignableScopes: [
      resourceGroup().id
    ]
    description: 'Manage DNS TXT records only.'
    permissions: [
      {
        actions: customRoleActions
      }
    ]
    roleName: 'DNS TXT Contributor - ${uniqueSuffix}'
    type: 'customRole'
  }
}

// Custom RBAC Role assignment
@sys.description('Allows Function App Managed Identity to manage DNS TXT records.')
resource funcMIDnsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dnsZone.id, dnsTxtContributorRole.id, functionAppPrincipalId)
  scope: dnsZone
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: dnsTxtContributorRole.id
  }
}
