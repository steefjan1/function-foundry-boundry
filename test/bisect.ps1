<#
.SYNOPSIS
  Run the three bisect orchestrations in order and report which one first fails.

.DESCRIPTION
  FulfilOrder fails with "The orchestrator function completed on a non-orchestrator thread!".
  A, B and C add one suspect at a time:

    A  no session, no try/catch, no custom status, no activity
    B  A plus an explicit AgentSession
    C  A plus custom status and an activity call

  The first one that does not reach Completed names the cause.

.EXAMPLE
  pwsh ./test/bisect.ps1 -DurableAppUrl $env:DURABLE_APP_URL -DurableKey $env:DURABLE_KEY
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$DurableAppUrl,
  [Parameter(Mandatory)] [string]$DurableKey,
  [string]$OrderId = 'ORD-1001',
  [int]$TimeoutSeconds = 150
)

$ErrorActionPreference = 'Continue'
$base = $DurableAppUrl.TrimEnd('/')
$headers = @{ 'x-functions-key' = $DurableKey; 'Content-Type' = 'application/json' }

foreach ($which in 'a', 'b', 'c') {
  Write-Host ""
  Write-Host "=== Bisect $($which.ToUpper()) ===" -ForegroundColor Cyan

  $start = Invoke-WebRequest -Method POST -Uri "$base/api/bisect/$which/$OrderId" `
    -Headers $headers -SkipHttpErrorCheck -MaximumRedirection 0

  if ($start.StatusCode -ne 202) {
    Write-Host "  start failed: HTTP $($start.StatusCode)" -ForegroundColor Red
    Write-Host "  $($start.Content)"
    continue
  }

  $statusUrl = $start.Headers['Location']
  if ($statusUrl -is [array]) { $statusUrl = $statusUrl[0] }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $status = 'Pending'
  $body = $null

  while ((Get-Date) -lt $deadline) {
    $r = Invoke-WebRequest -Uri $statusUrl -SkipHttpErrorCheck
    $body = $r.Content | ConvertFrom-Json
    $status = $body.runtimeStatus
    if ($status -in @('Completed', 'Failed', 'Terminated')) { break }
    Start-Sleep -Seconds 5
  }

  $colour = switch ($status) {
    'Completed' { 'Green' }
    'Failed'    { 'Red' }
    default     { 'Yellow' }
  }

  Write-Host "  runtimeStatus : $status" -ForegroundColor $colour
  if ($body.customStatus) { Write-Host "  customStatus  : $($body.customStatus)" }
  if ($body.output)       { Write-Host "  output        : $($body.output)" }

  if ($status -ne 'Completed') {
    Write-Host ""
    Write-Host "  Bisect $($which.ToUpper()) is the first failure. That names the cause:" -ForegroundColor Red
    switch ($which) {
      'a' { Write-Host "    RunAsync<T> itself does not work in an orchestrator here. Package problem." -ForegroundColor Red }
      'b' { Write-Host "    The explicit AgentSession is the culprit. Drop CreateSessionAsync." -ForegroundColor Red }
      'c' { Write-Host "    Custom status or the activity call is the culprit, not the agent." -ForegroundColor Red }
    }
    break
  }
}

Write-Host ""
Write-Host "Then check for package version skew between the two preview packages:" -ForegroundColor Gray
Write-Host "  dotnet list src/Orders.DurableAgent/Orders.DurableAgent.csproj package --include-transitive" -ForegroundColor Gray
