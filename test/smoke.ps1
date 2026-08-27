<#
.SYNOPSIS
  Smoke tests against the deployed sample. PowerShell port of test/smoke.sh.

.DESCRIPTION
  One test per claim the post makes. Every test hits the same action layer, whichever
  substrate drove it, which is the point: if the boundary holds, these assertions do not
  change when you switch substrate.

  Run test/configure.ps1 first. It sets TOOL_LAYER_KEY on the durable app and prints the
  values below.

.EXAMPLE
  pwsh ./test/smoke.ps1 `
    -ToolsAppUrl https://ffb-tools-x.azurewebsites.net -ToolsKey <key> `
    -DurableAppUrl https://ffb-durable-x.azurewebsites.net -DurableKey <key>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ToolsAppUrl,
  [Parameter(Mandatory)] [string]$ToolsKey,
  [string]$DurableAppUrl,
  [string]$DurableKey,
  [string]$OrderId = 'ORD-1002',
  [int]$TimeoutSeconds = 180,
  # Optional. When given, the durable section preflights TOOL_LAYER_KEY before spending three
  # minutes on an orchestration that is already doomed.
  [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0

$api = "$($ToolsAppUrl.TrimEnd('/'))/api"
$headers = @{ 'x-functions-key' = $ToolsKey; 'Content-Type' = 'application/json' }

function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") {
    Write-Host ("  PASS  {0,-50} {1}" -f $name, $actual) -ForegroundColor Green
    $script:pass++
  }
  else {
    Write-Host ("  FAIL  {0,-50} expected {1}, got {2}" -f $name, $expected, $actual) -ForegroundColor Red
    $script:fail++
  }
}

function Call($method, $url, $body, $hdrs) {
  $args = @{
    Method              = $method
    Uri                 = $url
    Headers             = $hdrs
    SkipHttpErrorCheck  = $true
    MaximumRedirection  = 0
  }
  if ($body) { $args.Body = ($body | ConvertTo-Json -Compress) }
  return Invoke-WebRequest @args
}

Write-Host "== State store ==" -ForegroundColor Cyan

$h = Call GET "$api/tools/health" $null $headers
if ($h.StatusCode -eq 200) {
  $health = $h.Content | ConvertFrom-Json
  Check 'state store is persistent' 'True' $health.persistent
  Write-Host "    store     : $($health.stateStore)"
  Write-Host "    roundTrip : $($health.roundTrip)"
  if ($health.warning) { Write-Host "    $($health.warning)" -ForegroundColor Red }
}
else {
  Write-Host "  health endpoint not deployed yet (HTTP $($h.StatusCode))" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "== Action layer, direct ==" -ForegroundColor Cyan

$r = Call GET "$api/tools/orders/ORD-1001" $null $headers
Check 'known order returns 200' 200 $r.StatusCode

$r = Call GET "$api/tools/orders/ORD-9999" $null $headers
Check 'unknown order returns 404' 404 $r.StatusCode

$r = Call GET "$api/tools/inventory/SKU-DOCK" $null $headers
Check 'SKU-DOCK starts with 2 available' 2 ($r.Content | ConvertFrom-Json).available

Write-Host ""
Write-Host "== Idempotency: the same key never holds stock twice ==" -ForegroundColor Cyan

# SKU-PROBE, not a narrative SKU. Every run of this test holds 2 units forever, and when it
# spent SKU-KEYBOARD it eventually starved ORD-1001 out of its own happy path.
$key = "resv-smoke-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$body = @{ sku = 'SKU-PROBE'; quantity = 2; reservationKey = $key }

$r = Call POST "$api/tools/reservations" $body $headers
Check 'first reservation returns 201' 201 $r.StatusCode

$r = Call POST "$api/tools/reservations" $body $headers
Check 'replayed reservation returns 200' 200 $r.StatusCode
Check 'replay reports created=false' 'False' ($r.Content | ConvertFrom-Json).created

Write-Host ""
Write-Host "== Over-reservation is refused, not negotiated ==" -ForegroundColor Cyan

$over = @{ sku = 'SKU-DOCK'; quantity = 5; reservationKey = "resv-over-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
$r = Call POST "$api/tools/reservations" $over $headers
Check 'reserving more than free stock returns 409' 409 $r.StatusCode

if ($DurableAppUrl -and $DurableKey) {
  Write-Host ""
  Write-Host "== Option 2: durable agent on Functions ==" -ForegroundColor Cyan

  # Preflight. The durable agent calls the action layer with TOOL_LAYER_KEY, and every
  # `azd provision` rewrites siteConfig.appSettings from the Bicep, which erases it. Catching
  # that here costs one ARM read; missing it costs a three-minute orchestration that fails on
  # the first tool call.
  if ($ResourceGroup) {
    $durableAppName = ([uri]$DurableAppUrl).Host.Split('.')[0]
    $configured = az functionapp config appsettings list -g $ResourceGroup -n $durableAppName `
      --query "[?name=='TOOL_LAYER_KEY'].value | [0]" -o tsv 2>$null

    if (-not $configured) {
      Write-Host "  FAIL  TOOL_LAYER_KEY is absent on $durableAppName." -ForegroundColor Red
      Write-Host "        Run test/configure.ps1 -ResourceGroup $ResourceGroup and try again." -ForegroundColor Red
      Write-Host "        (A provision run rewrites app settings from the Bicep and drops it.)" -ForegroundColor Red
      $fail++
    }
    elseif ($configured -ne $ToolsKey) {
      Write-Host "  FAIL  TOOL_LAYER_KEY on $durableAppName is stale: it does not match -ToolsKey." -ForegroundColor Red
      Write-Host "        Run test/configure.ps1 -ResourceGroup $ResourceGroup and try again." -ForegroundColor Red
      $fail++
    }
    else {
      Check 'durable app holds a current TOOL_LAYER_KEY' 'ok' 'ok'
    }
  }

  $durableHeaders = @{ 'x-functions-key' = $DurableKey; 'Content-Type' = 'application/json' }
  $r = Call POST "$($DurableAppUrl.TrimEnd('/'))/api/fulfil/$OrderId" $null $durableHeaders
  Check 'start returns 202 Accepted' 202 $r.StatusCode

  $statusUrl = $r.Headers['Location']
  if ($statusUrl -is [array]) { $statusUrl = $statusUrl[0] }

  if (-not $statusUrl) {
    Write-Host '  FAIL  no Location header on the 202' -ForegroundColor Red
    $fail++
  }
  else {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $status = ''
    while ((Get-Date) -lt $deadline) {
      $s = Call GET $statusUrl $null @{}
      $status = ($s.Content | ConvertFrom-Json).runtimeStatus
      Write-Host "    ... $status"
      if ($status -in @('Completed', 'Failed', 'Terminated')) { break }
      Start-Sleep -Seconds 5
    }
    Check 'orchestration completes' 'Completed' $status

    $final = (Call GET $statusUrl $null @{}).Content | ConvertFrom-Json
    if ($final.output)       { Write-Host "    output       : $($final.output)" }
    if ($final.customStatus) { Write-Host "    customStatus : $($final.customStatus)" }

    if ($status -eq 'Failed') {
      Write-Host "  Orchestration output:" -ForegroundColor Yellow
      Write-Host (Call GET $statusUrl $null @{}).Content
    }
  }

  # The assertion that matters. One fulfilment, one customer message, however many times
  # the orchestration replayed internally.
  #
  # Count nulls out explicitly. ConvertFrom-Json on "[]" yields $null, and @($null) has
  # Count 1, so the naive version reported a pass when the store held nothing at all. That
  # false pass hid an empty state store for hours.
  $n = Call GET "$api/tools/notifications/$OrderId" $null $headers
  $parsed = @(($n.Content | ConvertFrom-Json) | Where-Object { $null -ne $_ })
  Check 'customer notified exactly once' 1 $parsed.Count
}
else {
  Write-Host ""
  Write-Host '== Option 2 skipped: pass -DurableAppUrl and -DurableKey to run it ==' -ForegroundColor Yellow
}

Write-Host ""
Write-Host '-------------------------------------------'
Write-Host ("passed {0}, failed {1}" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
