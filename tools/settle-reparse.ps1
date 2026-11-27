# Re-parse settle-ab logs with a world-entry criterion that does NOT depend on
# settle lines (INPLACE=2 cancels settles at the root, so the old sum>400 test
# filtered every world sample out). World entry = first of 3 consecutive frame
# rows with draws>=3000; stable segment = t0 + 30 s. Same criterion for all arms.
param([string[]]$Tags = @('ip_base','ip_l1','ip_l2'), [int]$StableSec = 30)
$root = 'G:\Leonida\_port'
function Stat([double[]]$a) {
  if ($a.Count -eq 0) { return [ordered]@{n=0} }
  $s = @($a | Sort-Object)
  return [ordered]@{ n=$s.Count; min=[math]::Round($s[0],1);
    p10=[math]::Round($s[[int]($s.Count*0.10)],1);
    med=[math]::Round($s[[int]($s.Count*0.50)],1);
    p90=[math]::Round($s[[int]($s.Count*0.90)],1);
    max=[math]::Round($s[-1],1) }
}
foreach ($tag in $Tags) {
  $path = Join-Path $root "ab-$tag.log"
  if (-not (Test-Path $path)) { Write-Host "MISSING $path"; continue }
  $raw = Get-Content $path
  $logical = New-Object System.Collections.Generic.List[string]
  foreach ($ln in $raw) {
    if ($ln -match '^\d{4}-\d\d-\d\dT[\d:.]+Z') { $logical.Add($ln) }
    elseif ($logical.Count -gt 0) { $logical[$logical.Count-1] = $logical[$logical.Count-1] + ' ' + $ln.Trim() }
  }
  $frame = New-Object System.Collections.Generic.List[object]
  $settle = New-Object System.Collections.Generic.List[object]
  $inpl = New-Object System.Collections.Generic.List[object]
  foreach ($L in $logical) {
    $tsm = [regex]::Match($L, '^([\d]{4}-\d\d-\d\dT[\d:.]+)Z')
    if (-not $tsm.Success) { continue }
    $t = [datetime]::Parse($tsm.Groups[1].Value)
    if ($L -match 'victory_gpu::host: [\d.]+ fps') {
      $mf = [regex]::Match($L, '([\d.]+) ms/frame')
      $dr = [regex]::Match($L, '(\d+) draws/frame')
      $dp = [regex]::Match($L, 'dropped (\d+) without')
      $cp = [regex]::Match($L, 'copies ([\d.]+) ms ([\d.]+) MB')
      $gp = [regex]::Match($L, '; ([\d.]+) on the GPU')
      $cb = [regex]::Match($L, '([\d.]+) copying back ([\d.]+) MB')
      if ($mf.Success) {
        $frame.Add([pscustomobject]@{ t=$t; ms=[double]$mf.Groups[1].Value;
          draws=$(if($dr.Success){[int]$dr.Groups[1].Value}else{0});
          dropped=$(if($dp.Success){[int]$dp.Groups[1].Value}else{0});
          gpu=$(if($gp.Success){[double]$gp.Groups[1].Value}else{0});
          copiesMs=$(if($cp.Success){[double]$cp.Groups[1].Value}else{0});
          copiesMB=$(if($cp.Success){[double]$cp.Groups[2].Value}else{0});
          cbMB=$(if($cb.Success){[double]$cb.Groups[2].Value}else{0}) })
      }
    }
    if ($L -match 'of the waiting for the card in settles') {
      $m = [regex]::Match($L, 'shader writes ([\d.]+), title memory read ([\d.]+)')
      if ($m.Success) {
        $sw=[double]$m.Groups[1].Value; $rd=[double]$m.Groups[2].Value
        $settle.Add([pscustomobject]@{t=$t;sw=$sw;rd=$rd;sum=$sw+$rd})
      }
    }
    if ($L -match 'title memory in place: (\d+) windows (\d+) MB, (\d+) title buffers (\d+) MB') {
      $inpl.Add([pscustomobject]@{t=$t;winN=[int]$Matches[1];winMB=[int]$Matches[2];bufN=[int]$Matches[3];bufMB=[int]$Matches[4]})
    }
  }
  # world entry: 3 consecutive frame rows with draws>=3000
  $t0=$null; $consec=0
  foreach ($f in $frame) {
    if ($f.draws -ge 3000) { $consec++; if ($consec -ge 3) { $t0=$f.t; break } }
    else { $consec=0 }
  }
  $stable = $null; if ($t0) { $stable=$t0.AddSeconds($StableSec) }
  $fs = @($frame  | Where-Object { $stable -and $_.t -ge $stable })
  $ss = @($settle | Where-Object { $stable -and $_.t -ge $stable })
  $is = @($inpl    | Where-Object { $stable -and $_.t -ge $stable })
  $out = [ordered]@{
    tag=$tag
    t0=$(if($t0){$t0.ToString('HH:mm:ss')}else{'never'})
    stableFrom=$(if($stable){$stable.ToString('HH:mm:ss')}else{'n/a'})
    frameN=$fs.Count
    frameMs=[pscustomobject](Stat @($fs | ForEach-Object {$_.ms}))
    draws=[pscustomobject](Stat @($fs | ForEach-Object {$_.draws}))
    dropped=[pscustomobject](Stat @($fs | ForEach-Object {$_.dropped}))
    gpuMs=[pscustomobject](Stat @($fs | ForEach-Object {$_.gpu}))
    settleN=$ss.Count
    settleSum=[pscustomobject](Stat @($ss | ForEach-Object {$_.sum}))
    sw=[pscustomobject](Stat @($ss | ForEach-Object {$_.sw}))
    rd=[pscustomobject](Stat @($ss | ForEach-Object {$_.rd}))
    inplaceN=$is.Count
    inplaceWinMB=[pscustomobject](Stat @($is | ForEach-Object {$_.winMB}))
    inplaceBufMB=[pscustomobject](Stat @($is | ForEach-Object {$_.bufMB}))
  }
  $out | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root "ab-reparse-$tag.json") -Encoding utf8
  Write-Host "=== $tag ==="
  $out | ConvertTo-Json -Depth 5 -Compress
}
