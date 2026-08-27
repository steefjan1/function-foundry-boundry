<#
.SYNOPSIS
  Option 1. Create the Foundry prompt agent and point it at the Functions MCP endpoint.

.DESCRIPTION
  PowerShell equivalent of agents/scripts/create-prompt-agent.sh.

  Agents are a data plane concern. There is no ARM type for them, so this cannot live in
  infra/main.bicep. That split is worth noticing on its own: the substrate is deployed by
  infrastructure as code, the agent running on it is not.

  This is the least verified script in the repo. The connection and agent version REST shapes
  come from the docs and have not been run before now. Expect to iterate.

.EXAMPLE
  pwsh ./test/create-prompt-agent.ps1 -ResourceGroup rg-function-foundry-boundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$FoundryProjectEndpoint,
  [string]$ToolsAppName,
  [string]$ModelDeploymentName,
  [string]$AgentName = 'FulfilmentPromptAgent',
  [string]$ApiVersion = 'v1',
  [switch]$WhatIfBody,
  [switch]$NoConnection
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

  # ARM names child resources "account/project". Take the last segment or the endpoint
  # comes out as .../api/projects/<account>/<project>, which 404s.
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

Write-Host "Project  : $FoundryProjectEndpoint" -ForegroundColor Cyan
Write-Host "Tools app: $ToolsAppName" -ForegroundColor Cyan
Write-Host "Model    : $ModelDeploymentName" -ForegroundColor Cyan
Write-Host ""

# --- 1. the MCP endpoint and its key -----------------------------------------
$mcpKey = az functionapp keys list -g $ResourceGroup -n $ToolsAppName `
  --query systemKeys.mcp_extension -o tsv

if (-not $mcpKey -or $mcpKey -eq 'null') {
  throw "No mcp_extension system key on $ToolsAppName. The key appears once the MCP extension has loaded; hit the app and retry."
}

$mcpEndpoint = "https://$ToolsAppName.azurewebsites.net/runtime/webhooks/mcp"
Write-Host "MCP endpoint: $mcpEndpoint" -ForegroundColor Green

# --- 2. how the agent authenticates to the action layer -----------------------
#
# Two routes, and the difference matters.
#
# Preferred: a Foundry connection holds the key, so it never appears in the agent definition.
# That needs the "Foundry Connections (Beta)" azd extension (azure.ai.connections), which is
# not installed by default. The script installs it if it can.
#
# Fallback: the documented query string form, https://<app>/runtime/webhooks/mcp?code=<key>.
# This works with no extension at all, and it puts the key inside the agent definition, where
# anyone who can read the agent can read the key. Fine for a demo, wrong for production, and
# the script says so rather than quietly choosing it.
$useConnection = -not $NoConnection

if ($NoConnection) {
  Write-Host ""
  Write-Host "-NoConnection: skipping the Foundry connection." -ForegroundColor Yellow
  Write-Host "The key will ride in the MCP URL and be stored in the agent definition." -ForegroundColor Yellow
}
else {
  Write-Host ""
  Write-Host "==> Creating the remote tool connection" -ForegroundColor Cyan
  Write-Host "    (if this hangs, it is waiting on an interactive prompt: Ctrl+C and re-run with -NoConnection)" -ForegroundColor DarkGray

  # The azure.ai.connections extension resolves its target project from the environment, not
  # from azd's .env file, and errors with "no Foundry project endpoint resolved" otherwise.
  # This script already derived the endpoint, so hand it over. Child processes inherit it.
  $env:FOUNDRY_PROJECT_ENDPOINT = $FoundryProjectEndpoint

  # NOT captured with Out-String. Capturing stdout hides interactive prompts, which makes
  # the command look hung when it is actually waiting for you.
  azd ai connection create 'orders-action-layer' `
    --kind remote-tool `
    --target $mcpEndpoint `
    --auth-type custom-keys `
    --custom-key "x-functions-key=$mcpKey"

  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  Connection create returned $LASTEXITCODE." -ForegroundColor Yellow
    Write-Host "  If the extension is missing: azd extension install azure.ai.connections" -ForegroundColor Yellow
    Write-Host "  Or re-run this script with -NoConnection to use the key in the URL." -ForegroundColor Yellow
    $useConnection = $false
  }
}

# --- 3. the agent version -----------------------------------------------------
$template = Get-Content (Join-Path $root 'agents/prompt-agent/agent.json') -Raw
$body = $template.Replace('MODEL_DEPLOYMENT_NAME', $ModelDeploymentName) | ConvertFrom-Json

$mcpTool = $body.definition.tools | Where-Object { $_.type -eq 'mcp' } | Select-Object -First 1

if ($useConnection) {
  $mcpTool.server_url = $mcpEndpoint
}
else {
  # No connection, so the key rides in the URL and the connection reference comes out.
  $mcpTool.server_url = "$mcpEndpoint`?code=$mcpKey"
  $body.definition.tools = @($body.definition.tools | ForEach-Object {
      $_.PSObject.Properties.Remove('project_connection_id'); $_
    })
}

$bodyText = $body | ConvertTo-Json -Depth 10

if ($WhatIfBody) {
  Write-Host ""
  Write-Host "Request body:" -ForegroundColor Cyan
  Write-Host $bodyText
  return
}

$bodyFile = New-TemporaryFile
Set-Content -Path $bodyFile -Value $bodyText -Encoding utf8

try {
  Write-Host ""
  Write-Host "==> Creating agent version for $AgentName" -ForegroundColor Cyan

  az rest --method POST `
    --url "$FoundryProjectEndpoint/agents/$AgentName/versions?api-version=$ApiVersion" `
    --resource "https://ai.azure.com" `
    --headers "Content-Type=application/json" `
    --body "@$bodyFile" 2>&1 | Write-Host

  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Agent creation failed. Re-run with -WhatIfBody to see the exact payload," -ForegroundColor Yellow
    Write-Host "and compare it against the current MCP tool schema in the Foundry docs." -ForegroundColor Yellow
    exit 1
  }
}
finally {
  Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Created. Exercise it in the Foundry playground with a prompt like:" -ForegroundColor Green
Write-Host "  Fulfil order ORD-1002."
Write-Host ""
Write-Host "Then verify through the action layer, which is the only assertion that matters:" -ForegroundColor Green
Write-Host "  pwsh ./test/verify-notifications.ps1 -ToolsAppUrl `$env:TOOLS_APP_URL -ToolsKey `$env:TOOLS_KEY -OrderId ORD-1002"
