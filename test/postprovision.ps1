# azd postprovision hook.
#
# This exists because azd provision rewrites siteConfig.appSettings from the Bicep, which
# does NOT contain TOOL_LAYER_KEY. Any key set by hand is wiped on the next provision, and
# the failure is silent: the durable agent's tool calls come back 401, the agent reports that
# the order cannot be found, and the orchestration completes with a wrong answer.
#
# Running configure.ps1 here means the wiring survives every provision. The alternative, a
# listKeys() expression in the template, writes the key into the ARM deployment history in
# clear text and leaves it there.

$ErrorActionPreference = 'Continue'

$rg = $env:AZURE_RESOURCE_GROUP
if (-not $rg) { $rg = (azd env get-value AZURE_RESOURCE_GROUP 2>$null) }

if (-not $rg) {
  Write-Host "AZURE_RESOURCE_GROUP not set. Run test/configure.ps1 -ResourceGroup <rg> by hand." -ForegroundColor Yellow
  return
}

$configure = Join-Path $PSScriptRoot 'configure.ps1'
Write-Host "==> postprovision: wiring the durable agent to the action layer" -ForegroundColor Cyan
& $configure -ResourceGroup $rg
