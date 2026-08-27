<#
.SYNOPSIS
  Clean up after a failed azd up so the next attempt starts from a known state.

.DESCRIPTION
  Three things survive a resource group delete or a partial deployment and then produce
  conflicts on the next run:

    1. Cognitive Services accounts are SOFT DELETED. Recreating one with the same name fails
       until it is purged, and the resource group delete does not purge it.
    2. Role assignments keyed on a site resource id outlive the site's managed identity.
       infra/main.bicep now keys them on the principal id instead, so this is handled, but an
       assignment left by an older revision of the template can still be in the way.
    3. Flex Consumption plans keep a site attached. One site per plan, so a leftover site
       blocks the plan.

  This deletes the resource group, waits, then purges the soft deleted account.

.EXAMPLE
  pwsh ./test/reset.ps1 -ResourceGroup rg-ffb -Location swedencentral
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [Parameter(Mandatory)] [string]$Location,
  [switch]$KeepResourceGroup
)

$ErrorActionPreference = 'Stop'

# Capture the account names before the group goes, because purge needs them afterwards.
$accounts = @()
if (az group exists --name $ResourceGroup | Select-String -Quiet 'true') {
  $accounts = az cognitiveservices account list `
    --resource-group $ResourceGroup `
    --query "[].name" -o tsv 2>$null

  if (-not $KeepResourceGroup -and $PSCmdlet.ShouldProcess($ResourceGroup, 'delete resource group')) {
    Write-Host "==> Deleting resource group $ResourceGroup" -ForegroundColor Cyan
    az group delete --name $ResourceGroup --yes
  }
}
else {
  Write-Host "Resource group $ResourceGroup does not exist." -ForegroundColor Yellow
}

if (-not $accounts) {
  Write-Host "No Cognitive Services accounts recorded. Nothing to purge." -ForegroundColor Yellow
}

foreach ($name in $accounts) {
  Write-Host "==> Purging soft deleted account $name in $Location" -ForegroundColor Cyan
  az cognitiveservices account purge `
    --name $name `
    --resource-group $ResourceGroup `
    --location $Location 2>&1 | Write-Host
}

Write-Host ""
Write-Host "Also worth checking, since neither is removed by a group delete:" -ForegroundColor Cyan
Write-Host "  az cognitiveservices account list-deleted -o table"
Write-Host "  azd env refresh   # if azd still holds outputs from the failed run"
