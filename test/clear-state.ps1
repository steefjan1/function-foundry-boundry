<#
.SYNOPSIS
  Empty the action layer's state tables, returning inventory to its seeded levels.

.DESCRIPTION
  Reservations in this sample are held forever, so every smoke run, health probe and agent
  exercise consumes stock that nothing gives back. Eventually a fulfillable order stops being
  fulfillable and every test downstream of it turns misleading. This empties the three state
  tables (reservations, deliveries, notifications) so the demo starts from its seed again.

  It deletes ENTITIES, not tables. Deleting a table in Azure Storage is asynchronous: an
  immediate recreate can 409 with TableBeingDeleted for up to a minute, and the apps only run
  CreateIfNotExists at startup, so a deleted table would 404 until the next restart. Deleting
  rows keeps the tables alive and needs no restart.

  Not reset.ps1, which tears down infrastructure. This touches data only.

.EXAMPLE
  pwsh ./test/clear-state.ps1 -ResourceGroup rg-function-foundry-boundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$StorageAccount
)

$ErrorActionPreference = 'Stop'

# The account the apps actually use is named by STATE_STORAGE_ACCOUNT on the tools app, which
# beats guessing from a list when the group holds more than one account.
if (-not $StorageAccount) {
  $apps = az functionapp list -g $ResourceGroup -o json | ConvertFrom-Json
  $toolsApp = ($apps | Where-Object { $_.name -like '*-tools-*' } | Select-Object -First 1).name
  if (-not $toolsApp) { throw "No tools app found in $ResourceGroup. Pass -StorageAccount." }

  $settings = az functionapp config appsettings list -g $ResourceGroup -n $toolsApp -o json |
    ConvertFrom-Json
  $StorageAccount = ($settings | Where-Object { $_.name -eq 'STATE_STORAGE_ACCOUNT' }).value

  if (-not $StorageAccount) { throw "STATE_STORAGE_ACCOUNT not set on $toolsApp. Pass -StorageAccount." }
}

Write-Host "Storage account: $StorageAccount" -ForegroundColor Cyan

# --- permission preflight ----------------------------------------------------
# The Bicep grants Storage Table Data Contributor to the FUNCTION APPS' identities, not to
# the human running this. One probing query up front turns eighteen copies of the same RBAC
# error into one message with the fix in it.
$probe = az storage entity query --table-name reservations `
  --account-name $StorageAccount --auth-mode login `
  --select PartitionKey --num-results 1 -o json 2>&1

if ($LASTEXITCODE -ne 0) {
  $text = "$probe"
  if ($text -match 'required permissions') {
    Write-Host ""
    Write-Host "Your account has no data-plane access to $StorageAccount." -ForegroundColor Red
    Write-Host "The apps' managed identities have it; you never needed it until now. Grant it:" -ForegroundColor Red
    Write-Host ""
    Write-Host "  `$sa = az storage account show -g $ResourceGroup -n $StorageAccount --query id -o tsv"
    Write-Host "  `$me = az ad signed-in-user show --query id -o tsv"
    Write-Host "  az role assignment create --assignee `$me --role 'Storage Table Data Contributor' --scope `$sa"
    Write-Host ""
    Write-Host "Role assignments take a minute or two to propagate. Then re-run this script." -ForegroundColor Yellow
    exit 1
  }
  if ($text -match 'does not exist') {
    Write-Host "No state tables exist yet. Nothing to clear." -ForegroundColor Yellow
    exit 0
  }
  throw "Probe query failed: $text"
}

foreach ($table in @('reservations', 'deliveries', 'notifications')) {
  Write-Host "==> $table" -ForegroundColor Cyan
  $deleted = 0

  # Re-query after each sweep: entity query pages, and deleting while holding a page is
  # exactly the sort of thing that half works. Loop until a query comes back empty.
  while ($true) {
    $raw = az storage entity query --table-name $table `
      --account-name $StorageAccount --auth-mode login `
      --select PartitionKey RowKey -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
      if ("$raw" -match 'does not exist') { Write-Host "    table does not exist, skipped" -ForegroundColor Yellow; break }
      throw "Query on '$table' failed: $raw"
    }

    $result = $raw | ConvertFrom-Json
    $rows = @($result.items | Where-Object { $null -ne $_ })
    if (-not $rows.Count) { break }

    foreach ($row in $rows) {
      az storage entity delete --table-name $table `
        --account-name $StorageAccount --auth-mode login `
        --partition-key $row.PartitionKey --row-key $row.RowKey --output none
      $deleted++
    }
  }

  Write-Host "    deleted $deleted" -ForegroundColor Green
}

Write-Host ""
Write-Host "State cleared. Inventory is back to its seeded levels:" -ForegroundColor Green
Write-Host "  SKU-KEYBOARD 12, SKU-MONITOR 3, SKU-DOCK 2, SKU-PROBE 1000000"
