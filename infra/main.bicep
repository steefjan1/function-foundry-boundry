targetScope = 'resourceGroup'

@description('Short name used as a prefix for every resource.')
param namePrefix string = 'ffb'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Model deployment name the agents call. The code references this, never the model name.')
param modelDeploymentName string = 'gpt-5.4-mini'

@description('Model to deploy into the Foundry account. gpt-4o-mini is closed to new deployments and its Global Standard retirement is 1 October 2026.')
param modelName string = 'gpt-5.4-mini'

@description('Model version. Leave empty to let Azure pick the default version for this model in this region, which is the safer choice.')
param modelVersion string = ''

@description('Tokens per minute in thousands. Lower this if the region reports no available capacity.')
param modelCapacity int = 30

@description('Change this to any new string to force fresh role assignment names. Only needed if an orphaned assignment from a previous deployment points at a dead identity.')
param roleAssignmentSeed string = ''


var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('${namePrefix}st${suffix}')
var toolsAppName = '${namePrefix}-tools-${suffix}'
var agentAppName = '${namePrefix}-durable-${suffix}'

// ---------------------------------------------------------------------------
// Shared platform
// ---------------------------------------------------------------------------

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs-${suffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// Shared key access is off. Both function apps reach storage with a managed identity,
// which is the same posture the APIM sample used and the one an enterprise review expects.
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

// One deployment container PER APP, never a shared one.
//
// Flex Consumption keeps the deployed package in the container named here. Point two apps at
// the same container and the second deployment overwrites the first, so one app silently
// starts running the other app's code. It does not fail: the host starts cleanly, registers
// whatever functions it found, and every route you expected answers 404.
resource toolsDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deployments-tools'
}

resource agentDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deployments-durable'
}

// ---------------------------------------------------------------------------
// Foundry account and project. Agents themselves are data plane, so they are
// created by agents/scripts/*.sh rather than here. See docs/verification.md.
// ---------------------------------------------------------------------------

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: '${namePrefix}-foundry-${suffix}'
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: '${namePrefix}-foundry-${suffix}'
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: '${namePrefix}-project'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Functions and Foundry boundary'
    description: 'Companion project for the three orchestration substrates sample.'
  }
}

// version is omitted entirely when the parameter is empty, so Azure resolves the default
// version for this model in this region. Pinning a version that the region does not carry
// is the single most common reason this template fails to provision.
resource model 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: modelDeploymentName
  sku: { name: 'GlobalStandard', capacity: modelCapacity }
  properties: {
    model: union(
      {
        format: 'OpenAI'
        name: modelName
      },
      empty(modelVersion) ? {} : { version: modelVersion })
  }
}

// ---------------------------------------------------------------------------
// Flex Consumption plan and the two function apps
// ---------------------------------------------------------------------------

// Two plans, not one.
//
// Flex Consumption allows exactly one site per server farm: "There can only be one site per
// Flex Consumption serverfarm." So the action layer and the orchestrator cannot share a plan
// even if you want them to.
//
// That is not just a quota quirk to route around. The original diagram calls the action layer
// "independently scalable" as a design aspiration. On Flex Consumption it is not optional:
// the substrate above the boundary and the action layer below it scale on separate plans by
// construction, and neither can starve the other of instances.
resource toolsPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${namePrefix}-plan-tools-${suffix}'
  location: location
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

resource agentPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${namePrefix}-plan-durable-${suffix}'
  location: location
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}

// FUNCTIONS_WORKER_RUNTIME is deliberately absent.
//
// On Flex Consumption the runtime is declared once, in functionAppConfig.runtime below.
// Setting it as an app setting as well is rejected outright rather than treated as a
// duplicate: "The following app setting ... for Flex Consumption sites is invalid."
// The same applies to FUNCTIONS_EXTENSION_VERSION, WEBSITE_CONTENTAZUREFILECONNECTIONSTRING,
// WEBSITE_CONTENTSHARE and WEBSITE_RUN_FROM_PACKAGE. Local development still needs
// FUNCTIONS_WORKER_RUNTIME in local.settings.json, which is why the sample files keep it.
var commonAppSettings = [
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
  { name: 'AzureWebJobsStorage__accountName', value: storage.name }
  { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
  // Explicit and unambiguous. AzureWebJobsStorage__accountName reaches IConfiguration as
  // AzureWebJobsStorage:accountName, because the double underscore is a hierarchy separator.
  // Reading the literal double-underscore name in code returns null, which silently sent the
  // action layer to its in-memory store while every endpoint kept answering 200.
  { name: 'STATE_STORAGE_ACCOUNT', value: storage.name }
]

// azd matches a service in azure.yaml to a resource by this tag. Without it, provisioning
// succeeds and publishing fails with "unable to find a resource tagged with
// 'azd-service-name: tools'". The tag value must equal the service key in azure.yaml.
resource toolsApp 'Microsoft.Web/sites@2023-12-01' = {
  name: toolsAppName
  location: location
  kind: 'functionapp,linux'
  tags: { 'azd-service-name': 'tools' }
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: toolsPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${toolsDeploymentContainer.name}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
      runtime: { name: 'dotnet-isolated', version: '8.0' }
    }
    siteConfig: { appSettings: commonAppSettings }
  }
}

resource agentApp 'Microsoft.Web/sites@2023-12-01' = {
  name: agentAppName
  location: location
  kind: 'functionapp,linux'
  tags: { 'azd-service-name': 'durable' }
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: agentPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${agentDeploymentContainer.name}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
      runtime: { name: 'dotnet-isolated', version: '8.0' }
    }
    siteConfig: {
      appSettings: concat(commonAppSettings, [
        { name: 'TOOL_LAYER_URL', value: 'https://${toolsApp.properties.defaultHostName}' }
        { name: 'FOUNDRY_PROJECT_ENDPOINT', value: 'https://${foundry.name}.services.ai.azure.com/api/projects/${project.name}' }
        { name: 'MODEL_DEPLOYMENT_NAME', value: modelDeploymentName }
      ])
    }
  }
  dependsOn: [ model ]
}

// ---------------------------------------------------------------------------
// Role assignments. Storage Blob Data Owner for the deployment container, and
// Cognitive Services User so the durable agent can call the model as itself.
// ---------------------------------------------------------------------------

var blobDataOwner = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')

var cognitiveServicesUser = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908')

// Durable Functions does not live in blob storage alone. The task hub uses queues for the
// work item and control queues, and tables for instance and history state. With only a blob
// role, the durable extension fails to initialise, the host never finishes starting, and
// every function in the app returns 404 with no obvious error. Both apps get all three,
// because the Functions host itself uses blob, queue and table for AzureWebJobsStorage.
var storageQueueDataContributor = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88')

var storageTableDataContributor = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')

// Role assignment names are derived from resource ids, never from principalId.
//
// principalId is a runtime output. Bicep rejects it in a roleAssignment name with BCP120,
// because the name must be computable before the deployment starts. Resource ids are.
//
// These assignments are scoped to resources inside this resource group, so deleting the
// group removes them too, and a clean redeploy does not collide. If you ever do end up with
// an orphaned assignment pointing at a dead identity, set roleAssignmentSeed to any new
// string to generate fresh names rather than trying to update the old ones in place.
resource toolsStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, toolsApp.id, blobDataOwner, roleAssignmentSeed)
  properties: {
    roleDefinitionId: blobDataOwner
    principalId: toolsApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, agentApp.id, blobDataOwner, roleAssignmentSeed)
  properties: {
    roleDefinitionId: blobDataOwner
    principalId: agentApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentModelRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, agentApp.id, cognitiveServicesUser, roleAssignmentSeed)
  properties: {
    roleDefinitionId: cognitiveServicesUser
    principalId: agentApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource toolsQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, toolsApp.id, storageQueueDataContributor, roleAssignmentSeed)
  properties: {
    roleDefinitionId: storageQueueDataContributor
    principalId: toolsApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource toolsTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, toolsApp.id, storageTableDataContributor, roleAssignmentSeed)
  properties: {
    roleDefinitionId: storageTableDataContributor
    principalId: toolsApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, agentApp.id, storageQueueDataContributor, roleAssignmentSeed)
  properties: {
    roleDefinitionId: storageQueueDataContributor
    principalId: agentApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agentTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, agentApp.id, storageTableDataContributor, roleAssignmentSeed)
  properties: {
    roleDefinitionId: storageTableDataContributor
    principalId: agentApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output toolsAppName string = toolsApp.name
output toolsAppUrl string = 'https://${toolsApp.properties.defaultHostName}'
output mcpEndpoint string = 'https://${toolsApp.properties.defaultHostName}/runtime/webhooks/mcp'
output agentAppName string = agentApp.name
output agentAppUrl string = 'https://${agentApp.properties.defaultHostName}'
output foundryAccountName string = foundry.name
output foundryProjectEndpoint string = 'https://${foundry.name}.services.ai.azure.com/api/projects/${project.name}'
output modelDeploymentName string = modelDeploymentName
