<#
.SYNOPSIS
  Read the action layer's record of what an agent actually did to an order.

.DESCRIPTION
  The substrate-independent assertion. Whichever orchestrator ran, the question is the same:
  was stock reserved once, and was the customer told once?

  Use this after driving the prompt agent (option 1) or the hosted agent (option 3) by hand,
  since neither has a starter endpoint the smoke tests can call.

.EXAMPLE
  pwsh ./test/verify-notifications.ps1 -ToolsAppUrl $env:TOOLS_APP_URL -ToolsKey $env:TOOLS_KEY -OrderId ORD-1002
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$ToolsAppUrl,
  [Parameter(Mandatory)] [string]$ToolsKey,
  [Parameter(Mandatory)] [string]$OrderId
)

$ErrorActionPreference = 'Stop'
$api = "$($ToolsAppUrl.TrimEnd('/'))/api"
$headers = @{ 'x-functions-key' = $ToolsKey }

$order = Invoke-RestMethod "$api/tools/orders/$OrderId" -Headers $headers
Write-Host "Order       : $($order.orderId)  $($order.sku) x$($order.quantity)" -ForegroundColor Cyan

$inv = Invoke-RestMethod "$api/tools/inventory/$($order.sku)" -Headers $headers
Write-Host "Inventory   : onHand $($inv.onHand), reserved $($inv.reserved), available $($inv.available)" -ForegroundColor Cyan

# Invoke-RestMethod returns $null for an empty JSON array, and @($null) has Count 1 with a
# single null element. Wrapping the call in @() therefore reports one notification when there
# are none, and then prints a blank line for the null. That cost an hour: the count looked
# right, the content looked broken, and the store was innocent the whole time.
#
# So: fetch the raw body, parse it, and drop nulls explicitly.
$raw = (Invoke-WebRequest "$api/tools/notifications/$OrderId" -Headers $headers).Content
$notes = @(($raw | ConvertFrom-Json) | Where-Object { $null -ne $_ })

Write-Host ""
Write-Host "Notifications for ${OrderId}: $($notes.Count)" -ForegroundColor $(
  if ($notes.Count -eq 1) { 'Green' } elseif ($notes.Count -eq 0) { 'Yellow' } else { 'Red' })

foreach ($n in $notes) {
  Write-Host ("  [{0}] {1}" -f $n.sequence, $n.message)
}

Write-Host ""
switch ($notes.Count) {
  0 { Write-Host "The agent has not notified this customer. It either has not run, or it ran and could not reach the action layer." -ForegroundColor Yellow }
  1 { Write-Host "Exactly once. This is the result the post claims." -ForegroundColor Green }
  default { Write-Host "Notified $($notes.Count) times. Duplicate side effects: the model was trusted with a state changing tool and called it more than once." -ForegroundColor Red }
}
