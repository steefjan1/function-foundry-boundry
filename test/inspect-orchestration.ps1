<#
.SYNOPSIS
  Show what a durable orchestration is actually doing, step by step.

.DESCRIPTION
  A stuck orchestration reports runtimeStatus Running and nothing else. The history is where
  the answer is: it names every event the runtime recorded, so you can see which step was
  scheduled and never completed.

  Read the tail of the history. The last TaskScheduled or EventSent with no matching
  TaskCompleted or TaskFailed is the step it is waiting on.

.EXAMPLE
  pwsh ./test/inspect-orchestration.ps1 -ResourceGroup rg-function-foundry-boundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$AppNameContains = '-durable-',
  [string]$TaskHub = 'OrdersFulfilment',
  [string]$InstanceId,
  [switch]$Terminate
)

$ErrorActionPreference = 'Stop'

$app = az functionapp list -g $ResourceGroup `
  --query "[?contains(name, '$AppNameContains')].name" -o tsv | Select-Object -First 1
if (-not $app) { throw "No function app matching '$AppNameContains' in $ResourceGroup." }

$master = az functionapp keys list -g $ResourceGroup -n $app --query masterKey -o tsv
$base = "https://$app.azurewebsites.net/runtime/webhooks/durabletask"

Write-Host "App: $app   Task hub: $TaskHub" -ForegroundColor Cyan
Write-Host ""

if (-not $InstanceId) {
  Write-Host "=== Recent instances ===" -ForegroundColor Cyan
  $instances = Invoke-RestMethod "$base/instances?taskHub=$TaskHub&code=$master&top=10"

  if (-not $instances) { Write-Host "  none"; return }

  $instances |
    Select-Object instanceId, name, runtimeStatus, createdTime, lastUpdatedTime |
    Format-Table -AutoSize | Out-String | Write-Host

  $InstanceId = ($instances | Sort-Object lastUpdatedTime -Descending | Select-Object -First 1).instanceId
  Write-Host "Inspecting most recent: $InstanceId" -ForegroundColor Cyan
}

$detail = Invoke-RestMethod `
  "$base/instances/$InstanceId`?taskHub=$TaskHub&code=$master&showHistory=true&showHistoryOutput=true"

Write-Host ""
Write-Host "=== Status ===" -ForegroundColor Cyan
$detail | Select-Object runtimeStatus, createdTime, lastUpdatedTime, customStatus |
  Format-List | Out-String | Write-Host

if ($detail.output) {
  Write-Host "=== Output ===" -ForegroundColor Cyan
  $detail.output | ConvertTo-Json -Depth 6 | Write-Host
  Write-Host ""
}

Write-Host "=== History ===" -ForegroundColor Cyan
$detail.historyEvents |
  Select-Object Timestamp, EventType, Name,
    @{n = 'Detail'; e = {
        $t = $_.Result; if (-not $t) { $t = $_.Input }; if (-not $t) { $t = $_.Reason }
        if ($t -and $t.Length -gt 140) { $t.Substring(0, 140) + '...' } else { $t }
      }} |
  Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

Write-Host "Read the tail: the last TaskScheduled or EventSent without a matching" -ForegroundColor Yellow
Write-Host "TaskCompleted or TaskFailed is the step it is waiting on." -ForegroundColor Yellow

if ($Terminate -and $detail.runtimeStatus -eq 'Running') {
  Write-Host ""
  Write-Host "Terminating $InstanceId" -ForegroundColor Cyan
  Invoke-RestMethod -Method Post `
    "$base/instances/$InstanceId/terminate?taskHub=$TaskHub&code=$master&reason=stuck" | Out-Null
  Write-Host "Terminated." -ForegroundColor Green
}
