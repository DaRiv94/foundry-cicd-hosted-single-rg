// One Foundry account, one project, and one container registry. Dev, test, and prod hosted
// agents all live inside this single project (the lightweight topology), so this template is
// deployed once.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param regionCode string = 'eus'
param workload string = 'hasingle'
param chatModelName string = 'gpt-5-nano'
param chatModelVersion string = '2025-08-07'
@minValue(1)
param chatCapacity int = 10

var accountName = 'msf-ais-${regionCode}-${workload}'
var projectName = 'prj-ais-${regionCode}-${workload}'
var registryName = 'acrais${regionCode}${workload}' // registry names allow letters and digits only
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource account 'Microsoft.CognitiveServices/accounts@2026-05-01' = {
  name: accountName
  location: location
  tags: { workload: workload }
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true // keyless: Entra identities and role assignments only
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = {
  parent: account
  name: projectName
  location: location
  tags: { workload: workload }
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Frankies Bakery hosted agents (dev, test, and prod side by side)'
  }
}

// The deployment is always called chat-model so the agent code never changes.
resource chatModel 'Microsoft.CognitiveServices/accounts/deployments@2026-05-01' = {
  parent: account
  name: 'chat-model'
  sku: { name: 'GlobalStandard', capacity: chatCapacity }
  properties: {
    model: { format: 'OpenAI', name: chatModelName, version: chatModelVersion }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

// Lets the project identity call the account's models (needed by evaluations).
resource projectFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, project.id, foundryUserRoleId)
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
  }
}

// The registry the pipeline builds the agent image into and the platform pulls it from.
resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  tags: { workload: workload }
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    policies: {
      azureADAuthenticationAsArmPolicy: { status: 'enabled' } // required for hosted agent image pulls
    }
  }
}

// The Foundry project pulls the image with its own identity at deploy time. AcrPull, not the
// newer Container Registry Repository Reader role: the registry runs in the default legacy
// permission mode, where only AcrPull grants a pull (the platform error says so too).
resource projectAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, project.id, acrPullRoleId)
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

output accountName string = account.name
output projectName string = project.name
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output registryLoginServer string = registry.properties.loginServer
