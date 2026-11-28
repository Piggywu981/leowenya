param(
  [string]$GameExe,
  [string]$VictoryExe = (Join-Path $PSScriptRoot '..\target\release\victory.exe'),
  [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'VIctory-NVIDIA\highfps-8gb\data'),
  [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'VIctory-NVIDIA\highfps-8gb\cache'),
  [switch]$PreviewOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($GameExe)) { throw 'GameExe is required' }
if (-not (Test-Path -LiteralPath $GameExe)) { throw "game executable not found: $GameExe" }
if (-not $PreviewOnly -and -not (Test-Path -LiteralPath $VictoryExe)) { throw "victory executable not found: $VictoryExe" }

New-Item -ItemType Directory -Path $DataDir, $CacheDir -Force | Out-Null
$env:VICTORY_GAME_DIR = [System.IO.Path]::GetDirectoryName($GameExe)
$env:VICTORY_DATA_DIR = $DataDir
$env:VICTORY_CACHE_DIR = $CacheDir
$env:VICTORY_D3D12_DRED = '1'

$victoryArgs = @(
  'play', $GameExe,
  '--series-s',
  '--fg-type', 'dlss',
  '--fps', '30',
  '--set', 'VICTORY_TEXTURE_FILL=1',
  '--set', 'VICTORY_TEXTURE_NO_WAIT=1',
  '--set', 'VICTORY_OWNERLESS_VIEWS=1',
  '--set', 'VICTORY_VIEW_REMAP=1',
  '--set', 'VICTORY_STREAMLINE_PRESENT=0',
  '--set', 'VICTORY_TEARING=1',
  '--set', 'VICTORY_WATER_LIGHT=1',
  '--set', 'VICTORY_ALLOCATOR_TRIM=0',
  '--set', 'VICTORY_BUDGET_PACK=0',
  '--set', 'VICTORY_KEEP_FREED=1',
  '--set', 'VICTORY_TEXTURE_POOL=1',
  '--set', 'VICTORY_AMBIENT=0.8',
  '--set', 'VICTORY_AMBIENT_AIR=1.5',
  '--set', 'VICTORY_AMBIENT_SPECULAR=1',
  '--set', 'VICTORY_SLOT_EVICT=0',
  '--set', 'VICTORY_SLOT_EVICT_PERCENT=85',
  '--set', 'VICTORY_SLOT_EVICT_LOW_PERCENT=60',
  '--set', 'VICTORY_SLOT_EVICT_MB=512',
  '--set', 'VICTORY_WC_NO_BACK_MIN_KB=1024',
  '--set', 'VICTORY_WARMUP_RESTART=0',
  '--framegen', '2',
  '--set', 'VICTORY_ASYNC_SUBMIT=1',
  '--set', 'VICTORY_TEXTURE_CATCHUP=1',
  '--set', 'VICTORY_TEXTURE_STAGE_MS=32',
  '--set', 'VICTORY_LEVELS_ON_DEMAND=1',
  '--set', 'VICTORY_TEXTURE_ROOM_PERCENT=65',
  '--set', 'VICTORY_CARD_ROOM_FOR_TARGETS_MB=3072',
  '--set', 'VICTORY_CARD_ROOM_FOR_BUFFERS=1',
  '--set', 'VICTORY_THIN=0',
  '--set', 'VICTORY_JOIN_PARTS=0',
  '--set', 'VICTORY_LATE_WAIT=3',
  '--dlss', 'performance',
  '--set', 'VICTORY_DLSS_MODE=performance'
)

if ($PreviewOnly) {
  [pscustomobject]@{
    victoryExe = $VictoryExe
    dataDir = $DataDir
    cacheDir = $CacheDir
    args = $victoryArgs
  } | ConvertTo-Json -Depth 4
  return
}

$process = Start-Process -FilePath $VictoryExe -ArgumentList $victoryArgs -WorkingDirectory ([System.IO.Path]::GetDirectoryName($GameExe)) -PassThru
[pscustomobject]@{
  pid = $process.Id
  victoryExe = $VictoryExe
  dataDir = $DataDir
  cacheDir = $CacheDir
} | ConvertTo-Json
