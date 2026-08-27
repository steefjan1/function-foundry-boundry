<#
.SYNOPSIS
  Dump the real API surface of the Agent Framework assemblies in the local NuGet cache.

.DESCRIPTION
  Three types in this repo could not be confirmed from Microsoft Learn:
  DurableAIAgent, the GetAgent extension on TaskOrchestrationContext, and
  ConfigureDurableAgents. Rather than guess at them a third time, this reads the assemblies
  that restore actually pulled down and prints what is in them.

  Run it, paste the output, and the fix stops being a guess.

  Reflection load will fail to resolve some dependencies. That is expected and handled: the
  script keeps whatever types it can see and ignores the rest.
#>
[CmdletBinding()]
param(
  [string]$PackageRoot = (Join-Path $env:USERPROFILE '.nuget\packages')
)

$ErrorActionPreference = 'Continue'

$patterns = @(
  'microsoft.agents.ai',
  'microsoft.agents.ai.foundry',
  'microsoft.agents.ai.durabletask',
  'microsoft.agents.ai.hosting.azurefunctions',
  'microsoft.durabletask.abstractions',
  'microsoft.azure.functions.worker.extensions.durabletask'
)

Write-Host "Package root: $PackageRoot" -ForegroundColor Cyan
Write-Host ""

$dlls = @()
foreach ($p in $patterns) {
  $dir = Join-Path $PackageRoot $p
  if (-not (Test-Path $dir)) {
    Write-Host "MISSING PACKAGE: $p" -ForegroundColor Yellow
    continue
  }

  # newest version folder, prefer the highest netstandard/net target
  $version = Get-ChildItem $dir -Directory | Sort-Object Name -Descending | Select-Object -First 1
  Write-Host "$p  ->  $($version.Name)" -ForegroundColor Green

  $found = Get-ChildItem (Join-Path $version.FullName 'lib') -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue |
    Group-Object Name |
    ForEach-Object { $_.Group | Sort-Object { $_.Directory.Name } -Descending | Select-Object -First 1 }

  $dlls += $found
}

Write-Host ""
Write-Host "=============== TYPES AND EXTENSION METHODS ===============" -ForegroundColor Cyan

$wanted = 'DurableAIAgent|AgentSession|AgentResponse|ConfigureDurableAgents|GetAgent|AddAIAgent|GetNewThread|AgentThread|AsAIAgent'

foreach ($dll in $dlls) {
  $types = $null
  try {
    $asm = [System.Reflection.Assembly]::LoadFrom($dll.FullName)
    $types = $asm.GetTypes()
  }
  catch [System.Reflection.ReflectionTypeLoadException] {
    $types = $_.Exception.Types | Where-Object { $_ -ne $null }
  }
  catch {
    Write-Host "  could not load $($dll.Name): $($_.Exception.Message)" -ForegroundColor DarkGray
    continue
  }

  if (-not $types) { continue }

  $hits = @()

  foreach ($t in $types) {
    if (-not $t.IsPublic) { continue }

    if ($t.Name -match $wanted) {
      $hits += "  TYPE     $($t.FullName)"
    }

    $methods = @()
    try {
      $methods = $t.GetMethods([System.Reflection.BindingFlags]::Public -bor
                               [System.Reflection.BindingFlags]::Static -bor
                               [System.Reflection.BindingFlags]::Instance -bor
                               [System.Reflection.BindingFlags]::DeclaredOnly)
    } catch { continue }

    foreach ($m in $methods) {
      if ($m.Name -match $wanted) {
        $ps = ($m.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" }) -join ', '
        $kind = if ($m.IsStatic) { 'STATIC  ' } else { 'INSTANCE' }
        $hits += "  $kind $($t.FullName).$($m.Name)($ps) -> $($m.ReturnType.Name)"
      }
    }
  }

  if ($hits.Count -gt 0) {
    Write-Host ""
    Write-Host "--- $($dll.Name) [$($dll.Directory.Name)] ---" -ForegroundColor Yellow
    $hits | Sort-Object -Unique | ForEach-Object { Write-Host $_ }
  }
}

Write-Host ""
Write-Host "=============== NAMESPACES IN THE AGENT PACKAGES ===============" -ForegroundColor Cyan
foreach ($dll in $dlls | Where-Object { $_.Name -like 'Microsoft.Agents.AI*' }) {
  try {
    $asm = [System.Reflection.Assembly]::LoadFrom($dll.FullName)
    $ns = $asm.GetTypes() | Where-Object { $_.IsPublic } | Select-Object -ExpandProperty Namespace -Unique
  }
  catch [System.Reflection.ReflectionTypeLoadException] {
    $ns = $_.Exception.Types | Where-Object { $_ -ne $null -and $_.IsPublic } |
          Select-Object -ExpandProperty Namespace -Unique
  }
  catch { continue }

  Write-Host ""
  Write-Host "--- $($dll.Name) ---" -ForegroundColor Yellow
  $ns | Sort-Object | ForEach-Object { Write-Host "  $_" }
}
