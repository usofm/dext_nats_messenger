param(
  [switch]$SkipGo,
  [switch]$SkipDelphi
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$required = @(
  'Source/Dext.Messenger.Acceptance.pas',
  'Source/Dext.Messenger.Outbox.pas',
  'Source/Dext.Messenger.Delivery.pas',
  'Source/Dext.Messenger.DeadLetter.pas',
  'Source/Dext.Messenger.Gateway.pas',
  'Source/Dext.Messenger.Gateway.Api.pas',
  'Source/Dext.Messenger.Gateway.SyncApi.pas',
  'Source/Dext.Messenger.Gateway.ReceiptApi.pas',
  'Source/Dext.Messenger.Gateway.MediaApi.pas',
  'Source/Dext.Messenger.Client.Http.pas',
  'Source/Persistence/Dext.Messenger.Persistence.PostgreSQL.pas',
  'database/001_messenger_schema.sql',
  'Tests/Dext.Messenger.Tests.dpr',
  'Benchmarks/loadgen/main.go'
)

foreach ($path in $required) {
  if (-not (Test-Path $path)) {
    throw "Required artifact missing: $path"
  }
}

$pascal = Get-ChildItem Source,Tests,Demo -Recurse -File -Include *.pas,*.dpr
$forbidden = @(
  'IMessengerIdempotencyStore',
  'TMessengerSubjects\.AcceptedMessage\(',
  'Persistence\.pas'
)
foreach ($pattern in $forbidden) {
  $hits = $pascal | Select-String -Pattern $pattern
  if ($hits) {
    Write-Host "Forbidden legacy pattern: $pattern" -ForegroundColor Red
    $hits | ForEach-Object { Write-Host "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
    throw "Legacy architecture pattern detected"
  }
}

$schema = Get-Content 'database/001_messenger_schema.sql' -Raw
foreach ($invariant in @(
  'uq_messenger_sender_client',
  'uq_messenger_conversation_seq',
  'messenger_outbox',
  'lease_until',
  'messenger_user_cursors'
)) {
  if ($schema -notmatch [regex]::Escape($invariant)) {
    throw "Schema invariant missing: $invariant"
  }
}

if (-not $SkipGo) {
  $go = Get-Command go -ErrorAction SilentlyContinue
  if ($go) {
    Push-Location 'Benchmarks/loadgen'
    try {
      & go test ./...
      if ($LASTEXITCODE -ne 0) { throw 'Go load generator build/test failed' }
      & go vet ./...
      if ($LASTEXITCODE -ne 0) { throw 'Go load generator vet failed' }
    }
    finally { Pop-Location }
  }
  else {
    Write-Warning 'go not found; Go quality gate skipped'
  }
}

if (-not $SkipDelphi) {
  $dcc = Get-Command dcc32 -ErrorAction SilentlyContinue
  if ($dcc -and $env:DELPHI_UNIT_PATH) {
    $unitPath = "$root\Source;$root\Source\Persistence;$root\Tests;$env:DELPHI_UNIT_PATH"
    & dcc32 -B -Q -U"$unitPath" -I"$unitPath" 'Tests\Dext.Messenger.Tests.dpr'
    if ($LASTEXITCODE -ne 0) { throw 'Delphi test suite compilation failed' }
  }
  elseif ($dcc) {
    Write-Warning 'dcc32 found but DELPHI_UNIT_PATH is empty; Delphi compilation skipped'
  }
  else {
    Write-Warning 'dcc32 not found; Delphi compilation is expected to run in Codex/Delphi environment'
  }
}

Write-Host 'Dext Messenger quality gate passed.' -ForegroundColor Green
