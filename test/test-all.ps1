<#
.SYNOPSIS
  Drive all three substrates against the same action layer, in one run.

.DESCRIPTION
  One scenario per substrate, state cleared between them so each starts from the seeded
  world:

    Option 2, durable agent   ORD-1001 (Ada Lovelace, 2 keyboards of 12)  happy path
    Option 1, prompt agent    ORD-1002 (Grace Hopper, 1 monitor of 3)     happy path
    Option 3, hosted agent    ORD-1002 again, after a state clear         happy path

  The assertion policy is the post's thesis, executable. Runtime guarantees are ASSERTED:
  the orchestration completes, the reservation exists exactly once, state lands in the
  action layer. Instruction level behaviour is OBSERVED and reported, not asserted: the
  notification count is printed with commentary, because this suite has measured a prompt
  agent notifying twice and a hosted agent inventing a delivery slot, and a test that fails
  on model variance teaches nothing. A test that fails on a broken runtime guarantee
  teaches everything.

  Requires: az login with Azure AI Project Manager on the Foundry account and Storage Table
  Data Contributor on the state storage account (clear-state needs it), and both function
  apps deployed. Options 1 and 3 must already be registered (create-prompt-agent.ps1,
  deploy-hosted-agent.ps1).

.EXAMPLE
  pwsh ./test/test-all.ps1 -ResourceGroup rg-function-foundry-boundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [string]$PromptAgentName = 'FulfilmentPromptAgent',
  [string]$HostedAgentName = 'FulfilmentHostedAgent',
  [int]$TimeoutSeconds = 240,
  [switch]$SkipHosted,
  [switch]$SkipPrompt
)

$ErrorActionPreference = 'Stop'
$script:pass = 0
$script:fail = 0
$script:observed = @()

# --- make colours actually render --------------------------------------------
# A legacy Windows console (conhost launched from powershell.exe) ships with virtual
# terminal processing OFF, so ANSI colour codes print as literal [31;1m noise or vanish.
# Flipping the console mode bit makes every colour below render. Harmless elsewhere.
if ($env:OS -eq 'Windows_NT') {
  try {
    Add-Type -Namespace Win32 -Name VT -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction SilentlyContinue
    $handle = [Win32.VT]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
    $mode = 0
    if ([Win32.VT]::GetConsoleMode($handle, [ref]$mode)) {
      [void][Win32.VT]::SetConsoleMode($handle, $mode -bor 0x4)   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    }
  }
  catch { }   # colours degrade to plain text, the tests do not care
}

# PowerShell 7.2+ strips colour on its own when NO_COLOR is set, TERM looks dumb, or host
# detection guesses wrong, and the result is white text regardless of every -ForegroundColor
# below. The VT bit above makes the console ABLE to render ANSI; this line makes PowerShell
# WILLING to emit it. Both are needed.
if (Get-Variable -Name PSStyle -ErrorAction SilentlyContinue) {
  $PSStyle.OutputRendering = 'Ansi'
}

function Assert($name, $expected, $actual) {
  if ("$expected" -eq "$actual") {
    Write-Host ("  PASS  {0,-52} {1}" -f $name, $actual) -ForegroundColor Green
    $script:pass++
  }
  else {
    Write-Host ("  FAIL  {0,-52} expected {1}, got {2}" -f $name, $expected, $actual) -ForegroundColor Red
    $script:fail++
  }
}

function Observe($name, $value, $comment) {
  Write-Host ("  OBSV  {0,-52} {1}  ({2})" -f $name, $value, $comment) -ForegroundColor Yellow
  $script:observed += "{0}: {1}" -f $name, $value
}

# --- discovery ---------------------------------------------------------------
Write-Host "== Discovering the deployment ==" -ForegroundColor Cyan

$apps = az functionapp list -g $ResourceGroup -o json | ConvertFrom-Json
$toolsApp   = ($apps | Where-Object { $_.name -like '*-tools-*' }   | Select-Object -First 1).name
$durableApp = ($apps | Where-Object { $_.name -like '*-durable-*' } | Select-Object -First 1).name
if (-not $toolsApp -or -not $durableApp) { throw "Could not find both function apps in $ResourceGroup." }

$toolsKey   = az functionapp keys list -g $ResourceGroup -n $toolsApp   --query functionKeys.default -o tsv
$durableKey = az functionapp keys list -g $ResourceGroup -n $durableApp --query functionKeys.default -o tsv

$accounts = az cognitiveservices account list -g $ResourceGroup -o json | ConvertFrom-Json
$account = $accounts | Where-Object { $_.kind -eq 'AIServices' } | Select-Object -First 1
$projectsUrl = "https://management.azure.com$($account.id)/projects?api-version=2025-06-01"
$project = (az rest --method GET --url $projectsUrl -o json | ConvertFrom-Json).value | Select-Object -First 1
$projectName = ($project.name -split '/')[-1]
$foundryEndpoint = "https://$($account.name).services.ai.azure.com/api/projects/$projectName"

# One token for every data plane call. Refreshing per call would also work; this is simpler
# and a full run finishes well inside a token's lifetime.
$token = az account get-access-token --resource "https://ai.azure.com" --query accessToken -o tsv

$api = "https://$toolsApp.azurewebsites.net/api"
$toolsHeaders = @{ 'x-functions-key' = $toolsKey }

Write-Host "  tools    : $toolsApp"
Write-Host "  durable  : $durableApp"
Write-Host "  project  : $foundryEndpoint"

function Clear-State {
  Write-Host ""
  Write-Host "== Clearing state ==" -ForegroundColor Cyan
  # In process, not a spawned pwsh: same speed win, and the child script's own colored
  # output renders instead of being flattened by the process boundary.
  & (Join-Path $PSScriptRoot 'clear-state.ps1') -ResourceGroup $ResourceGroup
  if ($LASTEXITCODE -ne 0) { throw "clear-state failed; a shared world would make every later assertion a lie." }
}

function Get-Inventory($sku) {
  (Invoke-RestMethod -Uri "$api/tools/inventory/$sku" -Headers $toolsHeaders)
}

function Get-Notifications($orderId) {
  # ConvertFrom-Json on [] yields $null; @() + Where-Object keeps the count honest.
  $raw = Invoke-RestMethod -Uri "$api/tools/notifications/$orderId" -Headers $toolsHeaders
  return @($raw | Where-Object { $null -ne $_ })
}

# Invoke a Foundry agent by reference through the project's responses API, then poll the
# returned response id until it leaves in_progress.
#
# Two details bought with failed runs. The path is /openai/v1/responses with the version IN
# THE PATH: posting to /responses?api-version=v1 returns NotFound, because that route does
# not exist. And the reference field is agent_reference at the top level, not agent. Both
# are in the REST reference for the project responses API.
#
# Also the lesson from the self hosted run: failure travels INSIDE the response object with
# HTTP 200 around it, so the status field is the only thing worth reading.
function Invoke-FoundryAgent($agentName, $message, [switch]$Hosted) {
  # Two invocation surfaces, and the service enforces the split with a 400 that spells out
  # the right URL. Prompt (and workflow) agents go through the project's shared responses
  # endpoint with an agent_reference in the body. Hosted agents "can only be called through
  # the agent endpoint", a per-agent path where the agent is named in the URL instead.
  # Note the versioning inconsistency, kept faithfully: the shared endpoint carries the
  # version IN THE PATH (/openai/v1/responses) and rejects a query parameter route that
  # does not exist, while the per-agent endpoint carries it as a QUERY PARAMETER and 400s
  # without one. Both facts came from the service's own error messages.
  if ($Hosted) {
    $base = "$foundryEndpoint/agents/$agentName/endpoint/protocols/openai/responses"
    $qs = '?api-version=v1'
    $bodyHash = @{ input = $message }
  }
  else {
    $base = "$foundryEndpoint/openai/v1/responses"
    $qs = ''
    $bodyHash = @{
      agent_reference = @{ type = 'agent_reference'; name = $agentName }
      input           = $message
    }
  }

  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

  try {
    $res = Invoke-RestMethod -Method Post -Uri "$base$qs" `
      -Headers $headers -Body ($bodyHash | ConvertTo-Json -Depth 4)
  }
  catch {
    # Surface the transport failure as a status the caller can assert on, instead of
    # killing the whole run. session_not_ready lands here as an HTTP 424.
    return [pscustomobject]@{
      status = 'transport_error'
      error  = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
    }
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ($res.status -in @('in_progress', 'queued') -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $res = Invoke-RestMethod -Uri "$base/$($res.id)$qs" -Headers $headers
  }
  return $res
}

# =============================================================================
Write-Host ""
Write-Host "== Option 2: durable agent on Azure Functions, ORD-1001 ==" -ForegroundColor Cyan
Clear-State

$durableHeaders = @{ 'x-functions-key' = $durableKey }
$start = Invoke-WebRequest -Method Post -Uri "https://$durableApp.azurewebsites.net/api/fulfil/ORD-1001" `
  -Headers $durableHeaders -SkipHttpErrorCheck
Assert 'durable: start returns 202' 202 $start.StatusCode

$statusUrl = $start.Headers['Location']
if ($statusUrl -is [array]) { $statusUrl = $statusUrl[0] }

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$status = ''
while ((Get-Date) -lt $deadline) {
  $s = (Invoke-RestMethod -Uri $statusUrl)
  $status = $s.runtimeStatus
  if ($status -in @('Completed', 'Failed', 'Terminated')) { break }
  Start-Sleep -Seconds 5
}
Assert 'durable: orchestration completes' 'Completed' $status
Assert 'durable: outcome is fulfilled'    'True'      $s.output.fulfilled

$inv = Get-Inventory 'SKU-KEYBOARD'
Assert 'durable: exactly 2 keyboards reserved' 2 $inv.reserved

$n = Get-Notifications 'ORD-1001'
Assert 'durable: customer notified exactly once' 1 $n.Count
# Asserted, not observed: the notify call is an ACTIVITY here. Exactly once is the
# runtime's promise on this substrate, so this one may fail the build.

# =============================================================================
if (-not $SkipPrompt) {
  Write-Host ""
  Write-Host "== Option 1: Foundry prompt agent over MCP, ORD-1002 ==" -ForegroundColor Cyan
  Clear-State

  $res = Invoke-FoundryAgent $PromptAgentName 'Fulfil order ORD-1002.'
  Assert 'prompt: response status completed' 'completed' $res.status

  $inv = Get-Inventory 'SKU-MONITOR'
  Assert 'prompt: exactly 1 monitor reserved' 1 $inv.reserved
  # Asserted even though the model held the tool, because the reservation key makes a
  # duplicate call idempotent AT THE ACTION LAYER. The guarantee lives below the boundary.

  $n = Get-Notifications 'ORD-1002'
  Observe 'prompt: notification count' $n.Count `
    'instruction says once; this suite has measured 2 from this substrate'
}
else {
  Write-Host ""
  Write-Host "== Option 1 skipped ==" -ForegroundColor Yellow
}

# =============================================================================
if (-not $SkipHosted) {
  Write-Host ""
  Write-Host "== Option 3: Foundry hosted agent, ORD-1002 ==" -ForegroundColor Cyan
  Clear-State

  $res = Invoke-FoundryAgent $HostedAgentName 'Fulfil order ORD-1002.' -Hosted
  Assert 'hosted: response status completed' 'completed' $res.status

  if ($res.status -ne 'completed') {
    Write-Host "  detail: $($res.error)" -ForegroundColor Yellow
    if ("$($res.error)" -match 'session_not_ready') {
      Write-Host '  The active hosted agent version does not speak the responses protocol.' -ForegroundColor Yellow
      Write-Host '  Rebuild and re-register: ./test/deploy-hosted-agent.ps1 -ImageTag v2' -ForegroundColor Yellow
    }
  }

  $inv = Get-Inventory 'SKU-MONITOR'
  Assert 'hosted: exactly 1 monitor reserved' 1 $inv.reserved

  $n = Get-Notifications 'ORD-1002'
  Observe 'hosted: notification count' $n.Count `
    'instruction says once; the model holds this tool directly on this substrate'

  $delivered = @($res.output | Where-Object { $_.type -eq 'function_call' -and $_.name -eq 'arrange_delivery' })
  if ($delivered.Count) {
    $slot = ($delivered[0].arguments | ConvertFrom-Json).slot
    Observe 'hosted: delivery slot the model chose' "'$slot'" `
      'a date means the instruction held; prose means fix 41 reproduced'
  }
}
else {
  Write-Host ""
  Write-Host "== Option 3 skipped ==" -ForegroundColor Yellow
}

# =============================================================================
Write-Host ""
Write-Host '===========================================' -ForegroundColor Cyan
if ($fail -eq 0) {
  Write-Host ("  ASSERTED   {0} passed, 0 failed" -f $pass) -ForegroundColor Green
}
else {
  Write-Host ("  ASSERTED   {0} passed, {1} FAILED" -f $pass, $fail) -ForegroundColor Red
}
foreach ($o in $observed) { Write-Host ("  OBSERVED   {0}" -f $o) -ForegroundColor Yellow }
Write-Host '===========================================' -ForegroundColor Cyan
Write-Host ""
Write-Host "Assertions cover runtime guarantees and fail the run. Observations cover what" -ForegroundColor DarkGray
Write-Host "the model was instructed to do, which this repo has measured varying run to run." -ForegroundColor DarkGray
if ($fail -gt 0) { exit 1 }
