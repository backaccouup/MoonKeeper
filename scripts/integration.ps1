param(
    [ValidateSet('single', 'existing')][string]$Mode = 'single',
    [string]$HostName = '127.0.0.1',
    [ValidateRange(1, 65535)][int]$Port = 21819
)
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path -Parent $PSScriptRoot
$composePath = Join-Path $repoPath 'integration/compose.yaml'
$projectName = "moonkeeper-handshake-$PID"
$oldHost = $env:MOONKEEPER_ZK_HOST
$oldPort = $env:MOONKEEPER_ZK_PORT
$started = $false
Push-Location -LiteralPath $repoPath
try {
    if (-not (Get-Command moon -ErrorAction SilentlyContinue)) { throw 'MoonBit is required; install the documented toolchain first.' }
    $env:MOONKEEPER_ZK_HOST = $HostName
    $env:MOONKEEPER_ZK_PORT = "$Port"
    if ($Mode -eq 'single') {
        if ($HostName -ne '127.0.0.1') { throw 'single mode binds loopback only; use existing mode for another host.' }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker with Compose is required for single mode. Start an external ZooKeeper and use -Mode existing if Docker is unavailable.' }
        docker compose version
        if ($LASTEXITCODE -ne 0) { throw 'Docker Compose is unavailable.' }
        $started = $true
        docker compose -p $projectName -f $composePath up -d --wait --wait-timeout 60
        if ($LASTEXITCODE -ne 0) { throw 'ZooKeeper container failed to become healthy.' }
    }
    moon build --target native --deny-warn
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }
    # Each protocol readiness probe has the client's 10-second deadline.
    $ready = $false
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        moon run cmd/connect --target native -- $HostName "$Port"
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "ZooKeeper handshake readiness failed at ${HostName}:$Port." }
    moon test integration --target native --include-skipped --deny-warn
    if ($LASTEXITCODE -ne 0) { throw 'Real ZooKeeper handshake tests failed.' }
} finally {
    if ($started) {
        docker compose -p $projectName -f $composePath down --volumes --remove-orphans
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not clean up Compose project $projectName" }
    }
    [Environment]::SetEnvironmentVariable('MOONKEEPER_ZK_HOST', $oldHost, 'Process')
    [Environment]::SetEnvironmentVariable('MOONKEEPER_ZK_PORT', $oldPort, 'Process')
    Pop-Location
}
