param(
  [int]$PostgreSqlPort = 55432,
  [int]$NatsClientPort = 4522,
  [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$dextNatsRoot = 'C:\apps_delphi\Comp12\dext_nats'
$dextRoot = Join-Path $env:TEMP 'codex-dext-412ed292'
$pgBin = 'C:\Program Files\PostgreSQL\18\bin'
$pgLib = Join-Path $pgBin 'libpq.dll'
$openSslBin = 'C:\Program Files\PostgreSQL\18\pgAdmin 4\python'
$natsServer = Join-Path $dextNatsRoot '.tools\nats-server-v2.14.5-windows-amd64\nats-server.exe'
$tempRoot = Join-Path $env:TEMP ('dext-messenger-it-' + [guid]::NewGuid().ToString('N'))
$pgData = Join-Path $tempRoot 'postgres-data'
$pgLog = Join-Path $tempRoot 'postgres.log'
$databaseName = 'messenger_it'
$natsProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$postgresStarted = $false

function Assert-Path([string]$Path, [string]$Description) {
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Description not found: $Path"
  }
}

function Wait-TcpPort([int]$Port, [int]$TimeoutMs = 15000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  do {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $task = $client.ConnectAsync('127.0.0.1', $Port)
      if ($task.Wait(250) -and $client.Connected) { return }
    }
    catch { }
    finally { $client.Dispose() }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Port $Port did not become ready within ${TimeoutMs}ms"
}

function Assert-TcpPortClosed([int]$Port) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    if ($task.Wait(300) -and $client.Connected) {
      throw "Outage-test port $Port already has a listener"
    }
  }
  catch [System.AggregateException] { }
  finally { $client.Dispose() }
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

function Compile-Integration([string]$Name, [string]$Compiler) {
  $buildDir = Join-Path $tempRoot ('build-' + $Name)
  New-Item -ItemType Directory -Path $buildDir | Out-Null
  $unitPath = Get-RecursiveUnitPath @(
    (Join-Path $dextRoot 'Sources'),
    (Join-Path $dextNatsRoot 'Source'),
    (Join-Path $repoRoot 'Source'),
    (Join-Path $repoRoot 'Tests\Integration')
  )
  $project = Join-Path $repoRoot 'Tests\Integration\Dext.Messenger.Integration.Tests.dpr'
  $arguments = @(
    '-B', '-Q', '-W+', '-DDEXT_ENABLE_DB_POSTGRES',
    "-E$buildDir", "-N0$buildDir", "-NU$buildDir",
    "-U$unitPath", "-I$unitPath", $project
  )
  Write-Host "Compiling integration suite with $Name..." -ForegroundColor Cyan
  $compilerOutput = @(& $Compiler @arguments 2>&1)
  $compilerExitCode = $LASTEXITCODE
  if (($compilerExitCode -ne 0) -and ($compilerOutput.Count -eq 0)) {
    Write-Warning "$Name compiler exited without diagnostics; retrying once"
    Start-Sleep -Milliseconds 500
    $compilerOutput = @(& $Compiler @arguments 2>&1)
    $compilerExitCode = $LASTEXITCODE
  }
  $compilerOutput | ForEach-Object { Write-Host $_ }
  if ($compilerExitCode -ne 0) {
    throw "$Name integration compilation failed with exit code $compilerExitCode"
  }
  $exe = Join-Path $buildDir 'Dext.Messenger.Integration.Tests.exe'
  Assert-Path $exe "$Name integration executable"
  Copy-Item -LiteralPath (Join-Path $openSslBin 'libcrypto-3.dll') -Destination $buildDir
  Copy-Item -LiteralPath (Join-Path $openSslBin 'libssl-3.dll') -Destination $buildDir
  return $exe
}

function Start-NatsCluster([string]$SuiteName) {
  $clusterRoot = Join-Path $tempRoot ('nats-' + $SuiteName)
  New-Item -ItemType Directory -Path $clusterRoot | Out-Null
  $natsProcesses.Clear()
  for ($i = 0; $i -lt 3; $i++) {
    $clientPort = $NatsClientPort + $i
    $clusterPort = 6522 + $i
    $monitorPort = 8522 + $i
    $storeDir = Join-Path $clusterRoot ('node-' + ($i + 1))
    New-Item -ItemType Directory -Path $storeDir | Out-Null
    $otherRoutes = 0..2 | Where-Object { $_ -ne $i } | ForEach-Object {
      'nats://127.0.0.1:' + (6522 + $_)
    }
    $stdout = Join-Path $clusterRoot ('node-' + ($i + 1) + '.out.log')
    $stderr = Join-Path $clusterRoot ('node-' + ($i + 1) + '.err.log')
    $args = @(
      '-js', '-sd', ('"' + $storeDir + '"'),
      '-p', $clientPort, '-m', $monitorPort,
      '--name', ('messenger-it-' + $SuiteName + '-' + ($i + 1)),
      '--cluster_name', ('MESSENGER_IT_' + $SuiteName),
      '--cluster', ('nats://127.0.0.1:' + $clusterPort),
      '--routes', ('"' + ($otherRoutes -join ',') + '"')
    )
    $process = Start-Process -FilePath $natsServer -ArgumentList $args -PassThru `
      -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $natsProcesses.Add($process)
  }
  for ($i = 0; $i -lt 3; $i++) {
    Wait-TcpPort ($NatsClientPort + $i)
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  do {
    try {
      $ready = $true
      for ($i = 0; $i -lt 3; $i++) {
        $varz = Invoke-RestMethod -Uri ('http://127.0.0.1:' + (8522 + $i) + '/varz') -TimeoutSec 2
        $jsz = Invoke-RestMethod -Uri ('http://127.0.0.1:' + (8522 + $i) + '/jsz') -TimeoutSec 2
        if ($varz.routes -lt 2 -or $jsz.api.level -lt 1) { $ready = $false }
      }
      if ($ready) {
        # The monitoring API can become live just before the JetStream metadata
        # group has registered all placement peers. Give that bounded election
        # a short stabilization window before creating three-replica streams.
        Start-Sleep -Seconds 3
        return
      }
    }
    catch { $ready = $false }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'NATS cluster did not form three connected JetStream nodes'
}

function Stop-NatsCluster {
  foreach ($process in $natsProcesses) {
    try {
      if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(5000) | Out-Null
      }
    }
    catch {
      Write-Warning "Could not stop temporary NATS PID $($process.Id): $($_.Exception.Message)"
    }
  }
  $natsProcesses.Clear()
}

function Run-Suite([string]$Name, [string]$Exe, [int]$Ordinal) {
  Start-NatsCluster $Name
  try {
    $runId = $Name.ToLowerInvariant() + [guid]::NewGuid().ToString('N').Substring(0, 12) + $Ordinal
    $env:MESSENGER_TEST_RUN_ID = $runId
    $env:MESSENGER_TEST_PG = "Server=127.0.0.1;Port=$PostgreSqlPort;Database=$databaseName;User_Name=postgres;VendorLib=$pgLib"
    $env:MESSENGER_TEST_PG_OUTAGE = "Server=127.0.0.1;Port=$($PostgreSqlPort + 1);Database=$databaseName;User_Name=postgres;VendorLib=$pgLib"
    $env:MESSENGER_TEST_NATS_HOST = '127.0.0.1'
    $env:MESSENGER_TEST_NATS_PORT = [string]$NatsClientPort
    $env:MESSENGER_TEST_NATS_KILL_PID = [string]$natsProcesses[0].Id
    $env:PATH = "$pgBin;$env:PATH"
    Write-Host "Running $Name PostgreSQL/NATS/JetStream integration suite..." -ForegroundColor Cyan
    & $Exe
    if ($LASTEXITCODE -ne 0) {
      throw "$Name integration suite failed with exit code $LASTEXITCODE"
    }
  }
  finally {
    Stop-NatsCluster
  }
}

try {
  Assert-Path $dextRoot 'Pinned Dext compatibility worktree'
  $dextSha = (& git -C $dextRoot rev-parse HEAD).Trim()
  if ($dextSha -ne '412ed29207d2d1dc5d4a259a7739a615aed0c626') {
    throw "Pinned Dext worktree has unexpected SHA $dextSha"
  }
  Assert-Path $dextNatsRoot 'dext_nats repository'
  Assert-Path $pgBin 'PostgreSQL 18 binaries'
  Assert-Path $pgLib '64-bit PostgreSQL client library'
  Assert-Path (Join-Path $openSslBin 'libcrypto-3.dll') '64-bit OpenSSL crypto library'
  Assert-Path (Join-Path $openSslBin 'libssl-3.dll') '64-bit OpenSSL TLS library'
  if (-not (Test-Path -LiteralPath $natsServer)) {
    $natsServer = (Get-Command nats-server -ErrorAction Stop).Source
  }
  $dcc12 = 'C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\dcc64.exe'
  $dcc13 = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe'
  Assert-Path $dcc12 'Delphi 12 Win64 compiler'
  Assert-Path $dcc13 'Delphi 13 Win64 compiler'

  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  Assert-TcpPortClosed ($PostgreSqlPort + 1)
  $exe12 = Compile-Integration 'Delphi12' $dcc12
  $exe13 = Compile-Integration 'Delphi13' $dcc13

  Write-Host 'Initializing isolated PostgreSQL 18 cluster...' -ForegroundColor Cyan
  & (Join-Path $pgBin 'initdb.exe') -D $pgData -A trust -U postgres --encoding=UTF8 --no-locale
  if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL initdb failed' }
  & (Join-Path $pgBin 'pg_ctl.exe') -D $pgData -o "-p $PostgreSqlPort -h 127.0.0.1" -l $pgLog -w start
  if ($LASTEXITCODE -ne 0) { throw 'Temporary PostgreSQL start failed' }
  $postgresStarted = $true
  & (Join-Path $pgBin 'createdb.exe') -h 127.0.0.1 -p $PostgreSqlPort -U postgres $databaseName
  if ($LASTEXITCODE -ne 0) { throw 'Temporary PostgreSQL database creation failed' }
  & (Join-Path $pgBin 'psql.exe') -h 127.0.0.1 -p $PostgreSqlPort -U postgres -d $databaseName `
    -v ON_ERROR_STOP=1 -f (Join-Path $repoRoot 'database\001_messenger_schema.sql')
  if ($LASTEXITCODE -ne 0) { throw 'Messenger PostgreSQL schema application failed' }

  Run-Suite 'Delphi12' $exe12 2
  Run-Suite 'Delphi13' $exe13 3
  Write-Host 'All Delphi 12/13 integration gates passed.' -ForegroundColor Green
}
finally {
  Stop-NatsCluster
  if ($postgresStarted) {
    try {
      & (Join-Path $pgBin 'pg_ctl.exe') -D $pgData -m fast -w stop
    }
    catch { Write-Warning "Could not stop temporary PostgreSQL: $($_.Exception.Message)" }
  }
  foreach ($name in @(
    'MESSENGER_TEST_RUN_ID', 'MESSENGER_TEST_PG', 'MESSENGER_TEST_PG_OUTAGE', 'MESSENGER_TEST_NATS_HOST',
    'MESSENGER_TEST_NATS_PORT', 'MESSENGER_TEST_NATS_KILL_PID'
  )) {
    Remove-Item -Path ('Env:' + $name) -ErrorAction SilentlyContinue
  }
  if (-not $KeepArtifacts -and (Test-Path -LiteralPath $tempRoot)) {
    $resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $resolvedTarget = [IO.Path]::GetFullPath($tempRoot)
    if (-not $resolvedTarget.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove integration artifacts outside TEMP: $resolvedTarget"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
  }
  elseif ($KeepArtifacts) {
    Write-Host "Integration artifacts kept at $tempRoot"
  }
}
