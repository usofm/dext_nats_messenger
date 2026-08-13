param(
  [string]$DextRoot = (Join-Path $env:TEMP 'codex-dext-412ed292'),
  [string]$DextNatsRoot = 'C:\apps_delphi\Comp12\dext_nats',
  [string]$Delphi12Root = 'C:\Program Files (x86)\Embarcadero\Studio\23.0',
  [string]$Delphi13Root = 'C:\Program Files (x86)\Embarcadero\Studio\37.0'
)

$ErrorActionPreference = 'Stop'
$expectedDextSha = '412ed29207d2d1dc5d4a259a7739a615aed0c626'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'dext-messenger-compile-' + [guid]::NewGuid().ToString('N'))

function Assert-Path([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Description not found: $Path"
  }
}

function Get-RecursiveUnitPath([string[]]$Roots) {
  $dirs = [System.Collections.Generic.List[string]]::new()
  foreach ($root in $Roots) {
    $dirs.Add((Resolve-Path -LiteralPath $root).Path)
    Get-ChildItem -LiteralPath $root -Directory -Recurse | ForEach-Object {
      $dirs.Add($_.FullName)
    }
  }
  return ($dirs | Select-Object -Unique) -join ';'
}

function Invoke-DelphiCompile(
  [string]$Name,
  [string]$Compiler,
  [string]$BuildDir,
  [string]$UnitPath,
  [string]$Target
) {
  $arguments = @(
    '-Q', '-W+', '-DDEXT_ENABLE_DB_POSTGRES',
    "-E$BuildDir", "-N0$BuildDir", "-NU$BuildDir",
    "-U$BuildDir;$UnitPath", "-I$BuildDir;$UnitPath", $Target
  )
  $output = @(& $Compiler @arguments 2>&1)
  $compilerExitCode = $LASTEXITCODE
  if (($compilerExitCode -ne 0) -and ($output.Count -eq 0)) {
    Write-Warning "$Name compiler exited without diagnostics; retrying once: $Target"
    Start-Sleep -Milliseconds 500
    $output = @(& $Compiler @arguments 2>&1)
    $compilerExitCode = $LASTEXITCODE
  }
  $diagnostics = @($output | Where-Object {
    [string]$_ -match '\b(Warning|Hint):\s+[WH]\d+'
  })
  if ($diagnostics.Count -gt 0) {
    $diagnostics | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
  }
  if ($compilerExitCode -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "$Name compilation failed: $Target"
  }
  if ($diagnostics.Count -gt 0) {
    throw "$Name emitted compiler warnings or hints: $Target"
  }
}

function Run-Suite([string]$Name, [string]$Compiler) {
  $buildDir = Join-Path $tempRoot $Name
  New-Item -ItemType Directory -Path $buildDir | Out-Null

  $unitPath = Get-RecursiveUnitPath @(
    (Join-Path $DextRoot 'Sources'),
    (Join-Path $DextNatsRoot 'Source'),
    (Join-Path $repoRoot 'Source'),
    (Join-Path $repoRoot 'Tests'),
    (Join-Path $repoRoot 'Demo\VCLClient')
  )
  $sourceUnits = @(Get-ChildItem (Join-Path $repoRoot 'Source') `
    -Recurse -File -Filter '*.pas' | Sort-Object FullName)

  Write-Host "Compiling $($sourceUnits.Count) source units with $Name..." `
    -ForegroundColor Cyan
  foreach ($unit in $sourceUnits) {
    Invoke-DelphiCompile $Name $Compiler $buildDir $unitPath $unit.FullName
  }

  Invoke-DelphiCompile $Name $Compiler $buildDir $unitPath `
    (Join-Path $repoRoot 'Tests\Dext.Messenger.Tests.dpr')
  Invoke-DelphiCompile $Name $Compiler $buildDir $unitPath `
    (Join-Path $repoRoot 'Demo\VCLClient\VCLMessengerClient.dpr')

  $testExecutable = Join-Path $buildDir 'Dext.Messenger.Tests.exe'
  Assert-Path $testExecutable "$Name unit-test executable"
  Assert-Path (Join-Path $buildDir 'VCLMessengerClient.exe') `
    "$Name VCL executable"

  Write-Host "Running $Name unit tests..." -ForegroundColor Cyan
  $testOutput = & $testExecutable 2>&1
  $testExitCode = $LASTEXITCODE
  $testOutput | ForEach-Object { Write-Host $_ }
  if ($testExitCode -ne 0) {
    throw "$Name unit tests failed with exit code $testExitCode"
  }
  Write-Host "$Name compile gate passed." -ForegroundColor Green
}

try {
  Assert-Path $DextRoot 'Pinned Dext worktree'
  Assert-Path $DextNatsRoot 'dext_nats repository'
  $dextSha = (& git -C $DextRoot rev-parse HEAD).Trim()
  if ($dextSha -ne $expectedDextSha) {
    throw "Pinned Dext worktree has unexpected SHA $dextSha"
  }

  $dcc12 = Join-Path $Delphi12Root 'bin\dcc32.exe'
  $dcc13 = Join-Path $Delphi13Root 'bin\dcc32.exe'
  Assert-Path $dcc12 'Delphi 12 Win32 compiler'
  Assert-Path $dcc13 'Delphi 13 Win32 compiler'

  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  Run-Suite 'Delphi12' $dcc12
  Run-Suite 'Delphi13' $dcc13
  Write-Host 'All Delphi 12/13 compile gates passed.' -ForegroundColor Green
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $leaf = [IO.Path]::GetFileName($resolvedTemp)
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) `
      -and $leaf.StartsWith('dext-messenger-compile-', `
        [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
    else {
      Write-Warning "Refusing to remove unexpected compile directory: $resolvedTemp"
    }
  }
}
