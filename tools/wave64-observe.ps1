# Wave64 -> wave32 lowering observer.
#
# Reads a victory diag run log and prints the evidence that matters before and
# after a lowering change, so the two can be compared directly. Nothing here
# changes the game or the tree; it is a log parser.
#
#   powershell -ExecutionPolicy Bypass -File tools\wave64-observe.ps1 run.log
#   powershell -ExecutionPolicy Bypass -File tools\wave64-observe.ps1 run.log -Baseline before.json
#
# What it reports:
#   * host wave width (the console emits 64-lane waves; a 32-lane host refuses
#     any shader still carrying WaveSize(64) with E_INVALIDARG 0x80070057);
#   * every "host pipeline refused" program: stage + 16-hex hash, the shape a
#     lowering fix is judged by;
#   * programs that do not translate at all;
#   * the peak "dropped ... without a host pipeline" per frame, the on-screen
#     cost of those refusals.
param(
    [Parameter(Mandatory = $true)][string]$Log,
    [string]$Baseline
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Log)) { throw "No log: $Log" }

$lines = Get-Content $Log

# 1. Host wave width, usually one line near startup.
$waveLines = Select-String -InputObject $lines -Pattern 'host wave lanes min=(\d+) max=(\d+)' -AllMatches
$min = $null; $max = $null
foreach ($m in $waveLines) {
    $mm = [regex]::Match($m.Line, 'host wave lanes min=(\d+) max=(\d+)')
    if ($mm.Success) { $min = $mm.Groups[1].Value; $max = $mm.Groups[2].Value; break }
}

# 2. Refused pipelines. The message and the hash are on two physical lines:
#    WARN ... host pipeline refused error=... shaders=[
#    compute 2da4beb386509b77]
$refused = @()
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i] -match 'host pipeline refused') {
        $err = if ($lines[$i] -match 'error=([^\s]+)') { $Matches[1] } else { '?' }
        $next = $lines[$i + 1]
        $hh = [regex]::Match($next, '(compute|pixel|vertex|mesh|geometry|hull|domain)\s+([0-9a-f]{16})')
        if ($hh.Success) {
            $refused += [pscustomobject]@{ stage = $hh.Groups[1].Value; hash = $hh.Groups[2].Value; error = $err; line = $i + 1 }
        } else {
            $refused += [pscustomobject]@{ stage = '?'; hash = '?'; error = $err; line = $i + 1 }
        }
    }
}

# 3. Translation failures (a different failure line from a refused pipeline).
#    "shader does not translate; ... stage="..." hash=<16hex> error=..." - the
#    hash is on the NEXT physical line and must come from hash=, never from a
#    stray 16-hex such as the build id.
$notTranslated = @()
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i] -match 'shader does not translate') {
        $hh = [regex]::Match($lines[$i + 1], 'hash=([0-9a-f]{16})')
        $notTranslated += [pscustomobject]@{ hash = $(if ($hh.Success) { $hh.Groups[1].Value } else { '?' }); line = $i + 1 }
    }
}

# 4. The dedicated per-program drop summary. The reason text is split by the
#    log's column width, so just take the rate and whatever of the reason fits
#    on the line. Typical reasons: "a stage of the ray-tracing structure
#    builder, which is off", "compute <hash>", "refused [<hash>]".
$dropSummary = @()
foreach ($m in (Select-String -InputObject $lines -Pattern 'dropped ([\d.]+)/frame without a host pipeline: (.*)')) {
    $reason = $m.Matches[0].Groups[2].Value
    $hh = [regex]::Match($reason, '([0-9a-f]{16})')
    $dropSummary += [pscustomobject]@{
        rate   = [double]$m.Matches[0].Groups[1].Value
        reason = $reason
        hash   = $(if ($hh.Success) { $hh.Groups[1].Value } else { '' })
    }
}

# 5. Worst per-frame dropped/draws. The frame line wraps at a fixed column,
#    so "pipeline" is cut to "pipe"; match only what stays on the line.
$peakDropped = 0
$peakDraws = 0
for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i - 1] -match 'INFO victory_gpu::host: [\d.]+ fps' -and
        $lines[$i] -match '(\d+) draws/frame, dropped (\d+) without a host') {
        $dr = [int]$Matches[1]
        $dp = [int]$Matches[2]
        if ($dr -gt $peakDraws) { $peakDraws = $dr }
        if ($dp -gt $peakDropped) { $peakDropped = $dp }
    }
}
# Top drop reasons by rate, deduped by reason prefix.
$topDrops = @($dropSummary | Sort-Object rate -Descending |
    Select-Object -First 8 | ForEach-Object {
        $r = $_.reason
        if ($r.Length -gt 70) { $r = $r.Substring(0, 70) }
        "$($_.rate)/frame $r"
    })

$result = [ordered]@{
    log          = (Resolve-Path $Log).Path
    hostWaveMin  = $min
    hostWaveMax  = $max
    refusedCount = $refused.Count
    refused      = @($refused | ForEach-Object { "$($_.stage) $($_.hash) [$($_.error)]" } | Sort-Object -Unique)
    notTranslatedCount = @($notTranslated | Where-Object { $_.hash -ne '?' } | Select-Object -ExpandProperty hash -Unique).Count
    notTranslated = @($notTranslated | Where-Object { $_.hash -ne '?' } | Select-Object -ExpandProperty hash -Unique)
    dropSummaryCount = $dropSummary.Count
    topDropReasons = $topDrops
    peakDroppedPerFrame = $peakDropped
    peakDrawsPerFrame   = $peakDraws
}

Write-Host '=== wave64 observer ==='
$result.GetEnumerator() | ForEach-Object {
    $v = $_.Value
    if ($v -is [array]) { $v = ($v -join ', ') }
    Write-Host ("{0,-22}: {1}" -f $_.Key, $v)
}

# Optional baseline delta: only the numbers, so a lowering run can be diffed.
if ($Baseline) {
    if (-not (Test-Path $Baseline)) { throw "No baseline: $Baseline" }
    $b = Get-Content $Baseline -Raw | ConvertFrom-Json
    Write-Host '=== delta vs baseline ==='
    Write-Host ("refusedCount      : {0} -> {1}" -f $b.refusedCount, $result.refusedCount)
    Write-Host ("notTranslatedCount: {0} -> {1}" -f $b.notTranslatedCount, $result.notTranslatedCount)
    Write-Host ("peakDropped/frame : {0} -> {1}" -f $b.peakDroppedPerFrame, $result.peakDroppedPerFrame)
    Write-Host ("peakDraws/frame   : {0} -> {1}" -f $b.peakDrawsPerFrame, $result.peakDrawsPerFrame)
}

# With -Baseline, also emit a fresh JSON snapshot to reuse next time.
if (-not $Baseline) {
    Write-Host '=== JSON (save for -Baseline next run) ==='
    $result | ConvertTo-Json -Depth 4
}
