# One arm of the BVH builder visual A/B. See README-bvh-visual-ab.md.
#   powershell -ExecutionPolicy Bypass -File tools\bvh-ab.ps1 -Builder 0
#   powershell -ExecutionPolicy Bypass -File tools\bvh-ab.ps1 -Builder 1
param(
    [Parameter(Mandatory)][ValidateSet(0, 1)][int]$Builder,
    [int]$Seconds = 90,
    [string]$Profile = 'diag',
    [string]$Game = 'G:\Leonida\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "target\$Profile\victory.exe"
if (-not (Test-Path $exe)) { throw "Build first: cargo build --profile $Profile -p victory --features diagnostics" }
if (-not (Test-Path $Game)) { throw "No game exe: $Game" }

$tag = if ($Builder -eq 1) { 'on' } else { 'off' }
$log = Join-Path $root "bvh-ab-$tag.log"

# Same switches as run.ps1's default tune; only the builder switch differs.
$env:VICTORY_GAME_DIR = Split-Path -Parent $Game
$env:VICTORY_CACHE_DIR = "$env:LOCALAPPDATA\ztrx\cache"
$env:VICTORY_DATA_DIR = "$env:LOCALAPPDATA\ztrx\data"
$env:VICTORY_AMBIENT = '0.6'
$env:VICTORY_LEVELS_ON_DEMAND = '1'
$env:VICTORY_RELAY = '2'
$env:VICTORY_LATE_WAIT = '3'
$env:VICTORY_WIDE_BACK = '1'
$env:VICTORY_CARD_REHASH_RUNS = '1'
$env:VICTORY_JOIN_COPIES = '1'
$env:VICTORY_WIDE_REFRESH = '1'
$env:VICTORY_TEXTURE_NO_WAIT = '1'
$env:VICTORY_CARD_FETCH_INFLIGHT = '1'
# The sole variable under test:
if ($Builder -eq 1) { $env:VICTORY_BVH_BUILDER = '1' }
else { Remove-Item Env:VICTORY_BVH_BUILDER -ErrorAction SilentlyContinue }
# Scripted first-run keys so both arms reach the world the same way.
$env:VICTORY_KEYS = '10:Down,14:Down,18:Enter,28:Down,32:Down,36:Enter,' +
    '46:Down,50:Down,54:Enter,64:Down,68:Down,72:Enter,84:Down,88:Down,92:Enter,' +
    '104:Down,108:Down,112:Enter'

Write-Host "BVH builder A/B arm='$tag' -> $log (window $Seconds s)"
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # Run for a bounded window: builder=1 used to crash ~10 s in; a fixed
    # window makes survival itself the measurement, and keeps both arms equal.
    $proc = Start-Process -FilePath $exe `
        -ArgumentList @('run', $Game, '--unimplemented', 'zero', '--execute') `
        -PassThru -RedirectStandardOutput "$log.out" -RedirectStandardError $log
    if (-not $proc.WaitForExit($Seconds * 1000)) {
        Write-Host "window elapsed; stopping PID $($proc.Id)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc.WaitForExit(5000) | Out-Null
        $survived = $true
        $exitCode = 'window-timeout (stopped intentionally)'
    } else {
        $survived = $false
        $exitCode = $proc.ExitCode
    }
} finally {
    $ErrorActionPreference = $saved
}
Get-Process victory -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

# Merge stdout/stderr into one searchable log (the game writes tracing to stderr).
$all = ''
foreach ($p in @($log, "$log.out")) {
    if (Test-Path $p) { $all += (Get-Content $p -Raw -ErrorAction SilentlyContinue) }
}
$all | Out-File $log -Encoding utf8
Remove-Item "$log.out" -Force -ErrorAction SilentlyContinue

# Summarize.
$builderRuns = [regex]::Matches($all, 'the ray-tracing structure builder runs').Count
$builderOff = [regex]::Matches($all, 'the ray-tracing structure builder stays off').Count
$refused = [regex]::Matches($all, 'host pipeline refused').Count
$notTranslated = [regex]::Matches($all, 'shader does not translate;').Count
$removed = [regex]::Matches($all, 'device removed|0x887A0005').Count
$crash = Get-ChildItem "$env:LOCALAPPDATA\ztrx\data\7952987A\temp" -Filter '*.crash.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-$Seconds - 30) } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

Write-Host '=== arm summary ==='
Write-Host "arm              : $tag (VICTORY_BVH_BUILDER=$(if($Builder){'1'}else{'off'}))"
Write-Host "survived window  : $survived"
Write-Host "exit             : $exitCode"
Write-Host "builder runs     : $builderRuns   stays-off: $builderOff"
Write-Host "refused          : $refused"
Write-Host "do-not-translate : $notTranslated"
Write-Host "device removed   : $removed"
if ($crash) { Write-Host "new crash log    : $($crash.Name) @ $($crash.LastWriteTime)" }
else { Write-Host 'new crash log    : none' }
Write-Host "log              : $log"
Write-Host 'Next: compare against the other arm and inspect the same interior with see-now.'
