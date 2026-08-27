<#
.SYNOPSIS
  Work out why a function app misbehaves, and optionally write everything to a JSON file.

.DESCRIPTION
  A Functions host that fails to start registers no functions, and every route then answers
  404 with nothing in the response to say why. A host running the wrong package registers
  functions you did not write. This checks the four places the reason actually lives: the
  registered function list, the app settings, the storage role assignments, and the host
  traces and exceptions in Application Insights.

  Pass -OutFile to capture the lot as JSON, which is easier to share than a screenful of
  console output.

.EXAMPLE
  pwsh ./test/diagnose.ps1 -ResourceGroup rg-function-foundry-boundry

.EXAMPLE
  pwsh ./test/diagnose.ps1 -ResourceGroup rg-function-foundry-boundry -OutFile diagnose.json
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$AppNameContains = '-durable-',
  [int]$TraceMinutes = 30,
  [string]$OutFile,
  [switch]$AllTraces
)

$ErrorActionPreference = 'Continue'

$report = [ordered]@{
  generatedAt     = (Get-Date).ToUniversalTime().ToString('o')
  resourceGroup   = $ResourceGroup
  traceWindowMins = $TraceMinutes
  app             = $null
  functions       = @()
  appSettings     = @()
  storageRoles    = @()
  traces          = @()
  failedRequests  = @()
  notes           = @()
}

function Note($text, $colour = 'Gray') {
  Write-Host $text -ForegroundColor $colour
  $report.notes += $text
}

$app = az functionapp list -g $ResourceGroup `
  --query "[?contains(name, '$AppNameContains')].name" -o tsv | Select-Object -First 1

if (-not $app) { throw "No function app in $ResourceGroup matching '$AppNameContains'." }
$report.app = $app

Write-Host "App: $app" -ForegroundColor Cyan
Write-Host ""

# --- 1. registered functions -------------------------------------------------
Write-Host "=== Registered functions ===" -ForegroundColor Cyan
$funcs = @(az functionapp function list -g $ResourceGroup -n $app --query "[].name" -o tsv 2>$null |
  Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] })

$report.functions = $funcs

if (-not $funcs) {
  Note "  NONE. The host registered no functions, so it failed to start. See the traces." 'Red'
}
else {
  $funcs | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
}

# --- 2. app settings ---------------------------------------------------------
Write-Host ""
Write-Host "=== App settings (names and whether set, never values) ===" -ForegroundColor Cyan
$settings = az functionapp config appsettings list -g $ResourceGroup -n $app -o json |
  ConvertFrom-Json

$report.appSettings = @($settings | ForEach-Object {
    [ordered]@{ name = $_.name; isSet = -not [string]::IsNullOrWhiteSpace($_.value) }
  })

$report.appSettings | ForEach-Object {
  Write-Host ("  {0,-40} {1}" -f $_.name, $(if ($_.isSet) { 'set' } else { 'EMPTY' }))
}

# --- 3. storage roles --------------------------------------------------------
Write-Host ""
Write-Host "=== Role assignments on the storage account ===" -ForegroundColor Cyan
$principal = az functionapp show -g $ResourceGroup -n $app --query identity.principalId -o tsv
$storage = az storage account list -g $ResourceGroup --query "[0].id" -o tsv

if ($principal -and $storage) {
  $roles = @(az role assignment list --assignee $principal --scope $storage `
      --query "[].roleDefinitionName" -o tsv | Where-Object { $_ })

  $report.storageRoles = $roles
  $roles | ForEach-Object { Write-Host "  $_" }

  foreach ($needed in 'Storage Queue Data Contributor', 'Storage Table Data Contributor') {
    if ($roles -notcontains $needed) {
      Note "  MISSING: $needed. Durable Functions needs blob AND queue AND table." 'Red'
    }
  }
}

# --- 4. traces ---------------------------------------------------------------
Write-Host ""
Write-Host "=== Host traces and exceptions, last $TraceMinutes minutes ===" -ForegroundColor Cyan

$ai = az monitor app-insights component show -g $ResourceGroup --query "[0].appId" -o tsv 2>$null

if (-not $ai) {
  Note "  No Application Insights component found, or the CLI extension is missing:" 'Yellow'
  Note "  az extension add --name application-insights" 'Yellow'
}
else {
  $severityFilter = if ($AllTraces) { '' } else { "| where severityLevel >= 2 or itemType == 'exception'" }

  # Filter by cloud_RoleName. Both function apps write to the same Application Insights
  # component, so without this you get the other app's traces and conclude nothing.
  $query = @"
union traces, exceptions
| where timestamp > ago(${TraceMinutes}m)
| where cloud_RoleName == '$app'
$severityFilter
| where message !contains 'Distributed Tracing V2'
| project timestamp, kind = itemType, severity = severityLevel,
          text = coalesce(outerMessage, message),
          problem = tostring(problemId),
          stack = tostring(details), role = cloud_RoleName
| order by timestamp desc
| take 60
"@

  # NB: the generic --query is swallowed by this command, so unwrap the response here.
  $response = az monitor app-insights query --app $ai --analytics-query $query -o json |
    ConvertFrom-Json

  $rows = @()
  if ($response -and $response.tables) { $rows = @($response.tables[0].rows) }

  if (-not $rows) {
    Note "  Nothing in the last $TraceMinutes minutes at this severity." 'Green'
  }
  else {
    foreach ($r in $rows) {
      $entry = [ordered]@{
        timestamp = [string]$r[0]
        kind      = [string]$r[1]
        severity  = $r[2]
        text      = [string]$r[3]
        problem   = [string]$r[4]
        stack     = [string]$r[5]
      }
      $report.traces += $entry

      $when = try { ([datetime]$entry.timestamp).ToString('HH:mm:ss') } catch { '--:--:--' }
      $text = ($entry.text -replace '\s+', ' ')
      if ($text.Length -gt 220) { $text = $text.Substring(0, 220) + '...' }
      $colour = if ($entry.kind -eq 'exception') { 'Red' } else { 'Yellow' }
      Write-Host ("  {0}  {1,-9} {2}" -f $when, $entry.kind, $text) -ForegroundColor $colour
    }
  }
  # --- failed requests -------------------------------------------------------
  Write-Host ""
  Write-Host "=== Failed requests, last $TraceMinutes minutes ===" -ForegroundColor Cyan

  $reqQuery = @"
requests
| where timestamp > ago(${TraceMinutes}m)
| where cloud_RoleName == '$app'
| where success == false
| project timestamp, name, resultCode, duration, operation_Id
| order by timestamp desc
| take 30
"@

  $reqResponse = az monitor app-insights query --app $ai --analytics-query $reqQuery -o json |
    ConvertFrom-Json
  $reqRows = @()
  if ($reqResponse -and $reqResponse.tables) { $reqRows = @($reqResponse.tables[0].rows) }

  if (-not $reqRows) {
    Write-Host "  None." -ForegroundColor Green
  }
  else {
    foreach ($r in $reqRows) {
      $report.failedRequests += [ordered]@{
        timestamp = [string]$r[0]; name = [string]$r[1]
        resultCode = [string]$r[2]; operationId = [string]$r[4]
      }
      # Precompute the timestamp. PowerShell treats try/catch as a STATEMENT, so it cannot
      # sit inline in a -f argument list; assigning it to a variable first is legal and does
      # the same job. (This is the same class of mistake as the null-counting false pass:
      # syntax that reads fine and is not.)
      $when = try { ([datetime]$r[0]).ToString('HH:mm:ss') } catch { '--:--:--' }
      Write-Host ("  {0}  {1,-28} {2}  op {3}" -f $when, $r[1], $r[2], $r[4]) -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Correlate a stack with: exceptions | where operation_Id == '<op>'" -ForegroundColor Gray
  }
}

# --- output ------------------------------------------------------------------
if ($OutFile) {
  $path = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location) $OutFile }
  $report | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding utf8
  Write-Host ""
  Write-Host "Written to $path" -ForegroundColor Green
  Write-Host "Full stack traces are in the JSON even where the console truncated them." -ForegroundColor Gray
}
