<#
.SYNOPSIS
  Set the environment variables the test scripts expect. DOT SOURCE this.

.DESCRIPTION
  Environment variables live only in the shell that set them, and configure.ps1 can only
  print them because a child process cannot modify its parent's environment. So every new
  terminal starts empty and every script then fails with "Missing an argument".

  Dot source this instead, note the leading dot and space:

      . ./test/env.ps1 -ResourceGroup rg-function-foundry-boundry

  Running it without the dot does nothing useful: it sets the variables in a child scope
  that disappears immediately.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup
)

$apps = az functionapp list -g $ResourceGroup -o json | ConvertFrom-Json

# [string](@(...)[0].name) forces a scalar. Left as an array, PowerShell splats it into
# native commands as separate arguments and az reports an unrelated error.
$tools   = [string](@($apps | Where-Object { $_.name -like '*-tools-*'   })[0].name)
$durable = [string](@($apps | Where-Object { $_.name -like '*-durable-*' })[0].name)

if (-not $tools)   { Write-Host "No tools app found in $ResourceGroup" -ForegroundColor Red; return }
if (-not $durable) { Write-Host "No durable app found in $ResourceGroup" -ForegroundColor Yellow }

$env:TOOLS_APP_URL = "https://$tools.azurewebsites.net"
$env:TOOLS_KEY     = az functionapp keys list -g $ResourceGroup -n $tools --query functionKeys.default -o tsv

if ($durable) {
  $env:DURABLE_APP_URL = "https://$durable.azurewebsites.net"
  $env:DURABLE_KEY     = az functionapp keys list -g $ResourceGroup -n $durable --query functionKeys.default -o tsv
}

Write-Host "TOOLS_APP_URL   $env:TOOLS_APP_URL" -ForegroundColor Green
Write-Host "TOOLS_KEY       $(if ($env:TOOLS_KEY) { 'set' } else { 'EMPTY' })" -ForegroundColor Green
Write-Host "DURABLE_APP_URL $env:DURABLE_APP_URL" -ForegroundColor Green
Write-Host "DURABLE_KEY     $(if ($env:DURABLE_KEY) { 'set' } else { 'EMPTY' })" -ForegroundColor Green
