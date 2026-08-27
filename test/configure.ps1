<#
.SYNOPSIS
  Post-deployment wiring. Run this once after azd up, before the smoke tests.

.DESCRIPTION
  Two things the Bicep deliberately does not do.

  1. The durable agent needs a function key to call the action layer, because HttpTools uses
     AuthorizationLevel.Function. The template could fetch it with listKeys(), but that writes
     the key into the ARM deployment history in plain text, where it stays. Setting it from a
     script keeps it out of the template and out of that history.

  2. It prints the mcp_extension system key and MCP endpoint, which option 1 needs when it
     creates the Foundry prompt agent.

.EXAMPLE
  pwsh ./test/configure.ps1 -ResourceGroup rg-function-foundry-boundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$ToolsAppName,
  [string]$DurableAppName
)

$ErrorActionPreference = 'Stop'

function Resolve-AppName($provided, $pattern, $label) {
  if ($provided) { return $provided }

  $found = az functionapp list --resource-group $ResourceGroup `
    --query "[?contains(name, '$pattern')].name" -o tsv

  $names = @($found | Where-Object { $_ })
  if ($names.Count -ne 1) {
    throw "Could not identify the $label app in $ResourceGroup (found: $($names -join ', ')). Pass it explicitly."
  }
  return $names[0]
}

$ToolsAppName = Resolve-AppName $ToolsAppName '-tools-' 'tools'
$DurableAppName = Resolve-AppName $DurableAppName '-durable-' 'durable'

Write-Host "Tools app   : $ToolsAppName" -ForegroundColor Cyan
Write-Host "Durable app : $DurableAppName" -ForegroundColor Cyan
Write-Host ""

# --- 1. function key for the action layer -----------------------------------
Write-Host "==> Reading the default function key from $ToolsAppName" -ForegroundColor Cyan
$toolsKey = az functionapp keys list -g $ResourceGroup -n $ToolsAppName `
  --query functionKeys.default -o tsv

if (-not $toolsKey -or $toolsKey -eq 'null') {
  throw "No default function key on $ToolsAppName. Has the app finished deploying?"
}

Write-Host "==> Setting TOOL_LAYER_KEY on $DurableAppName" -ForegroundColor Cyan
az functionapp config appsettings set -g $ResourceGroup -n $DurableAppName `
  --settings "TOOL_LAYER_KEY=$toolsKey" --output none

# Read it back. `az ... set` returning 0 means ARM accepted the write, not that the setting
# is what you think it is, and this exact setting has now been silently erased twice by a
# later `azd provision` rewriting siteConfig.appSettings from the Bicep. A write you did not
# verify is a write you are guessing about.
$readBack = az functionapp config appsettings list -g $ResourceGroup -n $DurableAppName `
  --query "[?name=='TOOL_LAYER_KEY'].value | [0]" -o tsv

if ($readBack -ne $toolsKey) {
  throw "TOOL_LAYER_KEY did not stick on $DurableAppName. Read back: '$readBack'."
}
Write-Host "    verified: TOOL_LAYER_KEY matches the tools app default key." -ForegroundColor Green

# Setting an app setting restarts the host. Give it a moment, otherwise the first smoke run
# races the restart and fails with a 401 that has already been fixed.
Write-Host "    waiting ~30s for the durable host to restart with the new setting" -ForegroundColor Gray
Start-Sleep -Seconds 30

# --- 2. keys and endpoints the rest of the flow needs ------------------------
$durableKey = az functionapp keys list -g $ResourceGroup -n $DurableAppName `
  --query functionKeys.default -o tsv

$mcpKey = az functionapp keys list -g $ResourceGroup -n $ToolsAppName `
  --query systemKeys.mcp_extension -o tsv 2>$null

Write-Host ""
Write-Host "Done. Environment for the smoke tests:" -ForegroundColor Green
Write-Host ""
Write-Host "  `$env:TOOLS_APP_URL   = 'https://$ToolsAppName.azurewebsites.net'"
Write-Host "  `$env:TOOLS_KEY       = '$toolsKey'"
Write-Host "  `$env:DURABLE_APP_URL = 'https://$DurableAppName.azurewebsites.net'"
Write-Host "  `$env:DURABLE_KEY     = '$durableKey'"
Write-Host ""

if ($mcpKey -and $mcpKey -ne 'null') {
  Write-Host "MCP endpoint for the Foundry prompt agent (option 1):" -ForegroundColor Green
  Write-Host "  https://$ToolsAppName.azurewebsites.net/runtime/webhooks/mcp"
  Write-Host "  x-functions-key: $mcpKey"
}
else {
  Write-Host "No mcp_extension system key yet." -ForegroundColor Yellow
  Write-Host "That key is created when the MCP extension first loads, so give the app a"
  Write-Host "moment after deployment and re-run this script before doing option 1."
}
