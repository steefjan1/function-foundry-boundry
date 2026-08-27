<#
.SYNOPSIS
  Option 3. Build the hosted agent container, push it, and register it with Foundry.

.DESCRIPTION
  PowerShell equivalent of agents/scripts/deploy-hosted-agent.sh.

  infra/main.bicep does not create a container registry, so this creates one if you do not
  pass an existing name. Hosted agent registration and the log streaming it mentions are the
  least verified part of this repo.

.EXAMPLE
  pwsh ./test/deploy-hosted-agent.ps1 -ResourceGroup rg-function-foundry-boundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$AcrName,
  [string]$FoundryProjectEndpoint,
  [string]$ToolsAppName,
  [string]$ModelDeploymentName,
  [string]$AgentName = 'FulfilmentHostedAgent',
  [string]$ImageTag = 'v1',
  [string]$ApiVersion = 'v1'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# az on Windows is a .cmd shim, and cmd.exe mangles JMESPath brackets, which produces
# "].name was unexpected at this time." So: no --query with brackets anywhere in this file.
# Ask for JSON and filter in PowerShell instead.
function Get-AppName($rg, $like) {
  $apps = az functionapp list -g $rg -o json | ConvertFrom-Json
  return ($apps | Where-Object { $_.name -like $like } | Select-Object -First 1 -ExpandProperty name)
}

function Get-FoundryProjectEndpoint($rg) {
  $accounts = az cognitiveservices account list -g $rg -o json | ConvertFrom-Json
  $account = $accounts | Where-Object { $_.kind -eq 'AIServices' } | Select-Object -First 1
  if (-not $account) { return $null }

  # Projects are a child resource; ask ARM directly rather than guessing the name.
  $url = "https://management.azure.com$($account.id)/projects?api-version=2025-06-01"
  $projects = az rest --method GET --url $url -o json 2>$null | ConvertFrom-Json
  $project = $projects.value | Select-Object -First 1

  if (-not $project) { return $null }

  # ARM names child resources "account/project". Take the last segment.
  $projectName = ($project.name -split '/')[-1]
  return "https://$($account.name).services.ai.azure.com/api/projects/$projectName"
}

function FromAzd($name, $fallback) {
  if ($fallback) { return $fallback }
  $v = azd env get-value $name 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $v) { return $null }
  return $v.Trim()
}

$FoundryProjectEndpoint = FromAzd 'FOUNDRY_PROJECT_ENDPOINT' $FoundryProjectEndpoint
$ToolsAppName           = FromAzd 'TOOLS_APP_NAME'           $ToolsAppName
$ModelDeploymentName    = FromAzd 'MODEL_DEPLOYMENT_NAME'    $ModelDeploymentName

if (-not $ToolsAppName)        { $ToolsAppName = Get-AppName $ResourceGroup '*-tools-*' }
if (-not $ModelDeploymentName) { $ModelDeploymentName = 'gpt-5.4-mini' }

# azd only holds the endpoint if a provision captured its outputs. Derive it from Azure
# when it is missing, which is more reliable than depending on azd env state.
if (-not $FoundryProjectEndpoint) {
  Write-Host "FOUNDRY_PROJECT_ENDPOINT not in azd env, deriving it from Azure" -ForegroundColor Yellow
  $FoundryProjectEndpoint = Get-FoundryProjectEndpoint $ResourceGroup
}

if (-not $FoundryProjectEndpoint) { throw "Could not find a Foundry project in $ResourceGroup. Pass -FoundryProjectEndpoint." }
if (-not $ToolsAppName) { throw "Could not find the tools app. Pass -ToolsAppName." }

# --- registry ----------------------------------------------------------------
if (-not $AcrName) {
  $registries = az acr list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
  $AcrName = ($registries | Select-Object -First 1 -ExpandProperty name -ErrorAction SilentlyContinue)
}

if (-not $AcrName) {
  $AcrName = "ffbacr" + [guid]::NewGuid().ToString('N').Substring(0, 10)
  Write-Host "==> Creating container registry $AcrName" -ForegroundColor Cyan
  az acr create -g $ResourceGroup -n $AcrName --sku Basic --admin-enabled false -o none
}

Write-Host "Registry : $AcrName" -ForegroundColor Cyan
$image = "$AcrName.azurecr.io/orders-hosted-agent:$ImageTag"

# --- who pulls the image ------------------------------------------------------
# The FOUNDRY PROJECT's managed identity pulls the image, and it needs AcrPull BEFORE the
# agent version is registered, because the pull fires the moment registration is accepted
# and a failed version stays failed.
#
# Getting here cost three failed versions. The docs point at the per-agent identity, which
# azd grants during its own deploy flow, but that identity is minted fresh at each
# registration, after which it is too late to grant anything. Granting the agent instance
# identity, the blueprint identity and the ACCOUNT identity all left version 2 on ImageError;
# granting the project identity brought version 3 up. The project identity is also the only
# stable one, which dissolves the ordering problem entirely.
$acrId = az acr show -g $ResourceGroup -n $AcrName --query id -o tsv

$accounts = az cognitiveservices account list -g $ResourceGroup -o json | ConvertFrom-Json
$account = $accounts | Where-Object { $_.kind -eq 'AIServices' } | Select-Object -First 1
$projectName = ($FoundryProjectEndpoint -split '/')[-1]

$project = az rest --method GET `
  --url "https://management.azure.com$($account.id)/projects/$projectName`?api-version=2025-06-01" `
  -o json | ConvertFrom-Json

if ($project.identity.principalId) {
  Write-Host "==> Granting AcrPull to the Foundry project identity" -ForegroundColor Cyan
  az role assignment create --assignee-object-id $project.identity.principalId `
    --assignee-principal-type ServicePrincipal --role AcrPull --scope $acrId --output none 2>$null
  # Exit 0 or "already exists" are both fine; a rejected duplicate changes nothing.
}
else {
  Write-Host "WARNING: the Foundry project has no managed identity; the image pull will fail." -ForegroundColor Yellow
}

# --- build -------------------------------------------------------------------
Write-Host "==> Building $image" -ForegroundColor Cyan
az acr build --registry $AcrName `
  --image "orders-hosted-agent:$ImageTag" `
  --file (Join-Path $root 'src/Orders.HostedAgent/Dockerfile') `
  $root

if ($LASTEXITCODE -ne 0) { throw "az acr build failed with $LASTEXITCODE" }

# --- register ----------------------------------------------------------------
$toolsKey = az functionapp keys list -g $ResourceGroup -n $ToolsAppName --query functionKeys.default -o tsv

$body = @{
  definition = @{
    kind   = 'hosted'
    image  = $image
    cpu    = '1'
    memory = '2Gi'
    container_protocol_versions = @(@{ protocol = 'responses'; version = '1.0.0' })

    # No FOUNDRY_* or AGENT_* variables here: the service rejects them as reserved, because
    # the platform injects them into the container itself. FOUNDRY_PROJECT_ENDPOINT arrives
    # that way, which is why Program.cs can require it without this payload supplying it.
    environment_variables = @{
      TOOL_LAYER_URL        = "https://$ToolsAppName.azurewebsites.net"
      TOOL_LAYER_KEY        = $toolsKey
      MODEL_DEPLOYMENT_NAME = $ModelDeploymentName
    }
  }
} | ConvertTo-Json -Depth 8

$bodyFile = New-TemporaryFile
Set-Content -Path $bodyFile -Value $body -Encoding utf8

try {
  Write-Host "==> Registering hosted agent version" -ForegroundColor Cyan
  az rest --method POST `
    --url "$FoundryProjectEndpoint/agents/$AgentName/versions?api-version=$ApiVersion" `
    --resource "https://ai.azure.com" `
    --headers "Content-Type=application/json" "Foundry-Features=HostedAgents=V1Preview" `
    --body "@$bodyFile" 2>&1 | Write-Host
}
finally {
  Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Then: azd ai agent show $AgentName    and    azd ai agent monitor $AgentName" -ForegroundColor Green
