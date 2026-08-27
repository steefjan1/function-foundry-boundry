<#
.SYNOPSIS
  Offline validation. Run this first, before azd up.

.DESCRIPTION
  Everything here runs without an Azure subscription:
    1. bicep build on infra/main.bicep
    2. dotnet restore and dotnet build on every project
    3. a shell syntax check on the two agent scripts

  This exists because the repo was authored in an environment with no .NET SDK and no NuGet
  access, so nothing in it had been compiled at the time it was written. See docs/verification.md.
  Treat a clean run of this script as the point where that stops being true.
#>
[CmdletBinding()]
param(
  [switch]$SkipBicep
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = @()

function Step($name, $block) {
  Write-Host ""
  Write-Host "==> $name" -ForegroundColor Cyan
  try {
    & $block
    Write-Host "    PASS" -ForegroundColor Green
  }
  catch {
    Write-Host "    FAIL: $_" -ForegroundColor Red
    $script:failures += $name
  }
}

Step "preflight: no stale central package management file" {
  $stale = Join-Path $root 'Directory.Packages.props'
  if (Test-Path $stale) {
    Remove-Item $stale -Force
    Write-Host "    removed a stale Directory.Packages.props left by an older checkout"
  }

  # Stale obj/ folders cache the old restore graph and will re-raise NU1008 on their own.
  Get-ChildItem -Path (Join-Path $root 'src') -Include bin, obj -Recurse -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Step "bicep build" {
  if ($SkipBicep) { Write-Host "    skipped"; return }

  $template = Join-Path $root 'infra/main.bicep'

  # Standalone bicep first, then the az CLI's bundled copy, which is what most Azure
  # machines actually have. Only give up if neither is present.
  if (Get-Command bicep -ErrorAction SilentlyContinue) {
    & bicep build $template --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bicep build returned $LASTEXITCODE" }
    return
  }

  if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Host "    bicep not on PATH, using 'az bicep build'"
    & az bicep build --file $template --stdout | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "az bicep build returned $LASTEXITCODE" }
    return
  }

  Write-Host "    neither bicep nor az found, skipped (the template is UNVERIFIED)" -ForegroundColor Yellow
}

Step "dotnet restore" {
  & dotnet restore (Join-Path $root 'src/Orders.Tools.Core/Orders.Tools.Core.csproj')
  & dotnet restore (Join-Path $root 'src/Orders.Tools/Orders.Tools.csproj')
  & dotnet restore (Join-Path $root 'src/Orders.DurableAgent/Orders.DurableAgent.csproj')
  & dotnet restore (Join-Path $root 'src/Orders.HostedAgent/Orders.HostedAgent.csproj')
  if ($LASTEXITCODE -ne 0) { throw "restore returned $LASTEXITCODE" }
}

foreach ($proj in @(
    'src/Orders.Tools.Core/Orders.Tools.Core.csproj',
    'src/Orders.Tools/Orders.Tools.csproj',
    'src/Orders.DurableAgent/Orders.DurableAgent.csproj',
    'src/Orders.HostedAgent/Orders.HostedAgent.csproj')) {

  Step "dotnet build $proj" {
    & dotnet build (Join-Path $root $proj) -c Release --no-restore
    if ($LASTEXITCODE -ne 0) { throw "build returned $LASTEXITCODE" }
  }
}

Step "agent framework version skew" {
  # The durable agent packages hook into internals of the core package. Mixing trains
  # compiles, deploys, starts, and then fails at runtime with
  # "The orchestrator function completed on a non-orchestrator thread!". Catch it here.
  $listed = & dotnet list (Join-Path $root 'src/Orders.DurableAgent/Orders.DurableAgent.csproj') `
    package --include-transitive 2>&1

  $versions = @{}
  foreach ($line in $listed) {
    if ($line -match '(Microsoft\.Agents\.AI[\w.]*)\s+.*?(\d+\.\d+)\.[\d\w.\-]+\s*$') {
      $versions[$Matches[1]] = $Matches[2]
    }
  }

  if ($versions.Count -eq 0) {
    Write-Host "    could not parse package versions, skipped" -ForegroundColor Yellow
    return
  }

  $versions.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Host ("    {0,-46} {1}" -f $_.Key, $_.Value)
  }

  $trains = $versions.Values | Sort-Object -Unique
  if ($trains.Count -gt 1) {
    throw "Microsoft.Agents.AI packages span $($trains -join ' and '). Pin them all to one train."
  }
}

Step "shell script syntax" {
  if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Host "    bash not on PATH, skipped"
    return
  }

  # bash on Windows is usually WSL or Git Bash, and neither understands a C:\ path handed
  # to it by PowerShell. Run from the repo root with relative paths so both work.
  Push-Location $root
  try {
    foreach ($script in @('agents/scripts/create-prompt-agent.sh', 'agents/scripts/deploy-hosted-agent.sh')) {
      & bash -n $script 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "    could not check $script with this bash, skipped" -ForegroundColor Yellow
        return
      }
    }
  }
  finally {
    Pop-Location
  }
}

Step "PowerShell script syntax" {
  # Added after test/diagnose.ps1 shipped with a try/catch used as an inline expression inside
  # a -f argument list. It threw twenty-two identical errors on the user's machine, at the
  # exact moment the tool was supposed to explain a different failure.
  #
  # The interesting part is why nothing caught it. It PARSES CLEANLY. PowerShell has two
  # parsing modes, and inside parentheses in argument position it reads `try` as a command
  # name with two script block arguments, which is legal syntax for a command that does not
  # exist. You only learn it is wrong when the line executes and PowerShell looks for a
  # program called `try`. So this step runs two checks, not one:
  #
  #   1. parse errors, the cheap case
  #   2. a reserved statement keyword parsed as a COMMAND, which is never intentional and is
  #      the only signal available for the class of bug above
  #
  # Note the asymmetry with the shell step: `bash -n` catches its equivalent, PowerShell's
  # parser does not. A clean parse is not a promise that the script runs.
  $keywords = @('try', 'catch', 'finally', 'if', 'else', 'elseif', 'foreach', 'while', 'do', 'switch', 'trap')
  $broken = @()

  foreach ($file in (Get-ChildItem -Path $root -Recurse -Filter *.ps1)) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)

    if ($errors.Count) {
      $broken += $file.Name
      foreach ($e in $errors) {
        Write-Host ("    {0} line {1}: {2}" -f $file.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
      }
      continue
    }

    $asCommand = $ast.FindAll(
      { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
      Where-Object { $keywords -contains $_.GetCommandName() }

    foreach ($hit in @($asCommand)) {
      $broken += $file.Name
      Write-Host ("    {0} line {1}: '{2}' parsed as a command, not a statement. " -f
        $file.Name, $hit.Extent.StartLineNumber, $hit.GetCommandName()) -ForegroundColor Red
      Write-Host "      Assign it to a variable first: `$x = try { ... } catch { ... }" -ForegroundColor Red
    }
  }

  if ($broken.Count) { throw "problems in: $(($broken | Sort-Object -Unique) -join ', ')" }
  Write-Host "    all .ps1 files parse, no statement keywords in command position"
}

Write-Host ""
if ($failures.Count -eq 0) {
  Write-Host "All checks passed." -ForegroundColor Green
  exit 0
}

Write-Host "Failed: $($failures -join ', ')" -ForegroundColor Red
exit 1
