# hub-keeper.ps1 v2 - external guardian for CANNLabDevSpace port-forward-hub (1.1.2)
# Verified plugin behavior this relies on:
#   - hub liveness watchdog resets ONLY on HTTP GET /heartbeat on its control port
#     (35s idle / 10min with active connections -> hub exits, killing the SSH tunnel)
#   - hub writes "pid|ctrlPort" into .hub/vscode/1.1.2.LOCK at startup
#   - a hub may log "port-forward-hub exiting..." but hang forever on keep-alive
#     sockets, still holding the forward port (zombie)
#   - forward ports live in .atomgitdevenv/.ssh/config (one per devenv, can migrate)
# Every cycle, for each forward port AND the lock-file hub:
#   1. heartbeat the hub that actually owns the port (or holds the lock)
#   2. kill zombies: (a) logged exit >15s ago but still alive
#                   (b) holds a forward port but no control plane found 3 cycles in a row
#   3. correct 1.1.2.LOCK to point at the hub we keep alive
# Usage:  powershell -ExecutionPolicy Bypass -File hub-keeper.ps1        (loop)
#         powershell -ExecutionPolicy Bypass -File hub-keeper.ps1 -Once  (single pass)
# Log:    %USERPROFILE%\.atomgitdevenv\hub-keeper.log

param([switch]$Once,[int[]]$ExtraPorts)
$ErrorActionPreference = 'SilentlyContinue'
$base      = Join-Path $env:USERPROFILE '.atomgitdevenv'
$hubLog    = Join-Path $base '.hub\vscode\logs\latest.log'
$lockFile  = Join-Path $base '.hub\vscode\1.1.2.LOCK'
$sshCfg    = Join-Path $base '.ssh\config'
$keeperLog = Join-Path $base 'hub-keeper.log'
$INTERVAL  = 15
$ZOMBIE_GRACE = 15
$NOCTRL_STRIKES = 3
$script:strikes = @{}   # key "port:pid" -> consecutive no-control-plane cycles

function KLog($msg) {
  $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $keeperLog -Value $line -Encoding UTF8
}

function Get-ForwardPorts {
  $ports = @()
  if (Test-Path $sshCfg) {
    foreach ($ln in (Get-Content $sshCfg)) {
      if ($ln -match '^\s*Port\s+(\d+)\s*$') { $ports += [int]$Matches[1] }
    }
  }
  if ($ports.Count -eq 0) { $ports = @(30455) }
  if ($ExtraPorts) { $ports += $ExtraPorts }
  return $ports | Select-Object -Unique
}

function Get-PortOwnerPid([int]$fwdPort) {
  $lines = netstat -ano -p tcp | Select-String (":$fwdPort\s+\S+\s+LISTENING")
  foreach ($l in $lines) {
    $parts = ($l.ToString() -split '\s+') | Where-Object { $_ -ne '' }
    if ($parts.Count -ge 5) { return [int]$parts[-1] }
  }
  return $null
}

function Get-HubInfoFromLog([int]$targetPid) {
  if (-not (Test-Path $hubLog)) { return $null }
  $tail = Get-Content $hubLog -Tail 4000
  $pidTag = '"pid":' + $targetPid + ','
  $startedPort = $null; $exitTime = $null
  foreach ($ln in $tail) {
    if ($ln -notlike ('*' + $pidTag + '*')) { continue }
    if ($ln -match '"msg":"port-forward-hub started"') {
      if ($ln -match '"port":(\d+)') { $startedPort = [int]$Matches[1] }
    }
    if ($ln -match '"msg":"port-forward-hub exiting') {
      if ($ln -match '"time":"([^"]+)"') { $exitTime = $Matches[1] }
    }
  }
  return @{ port = $startedPort; exitTime = $exitTime }
}

function Http-Get([int]$port, [string]$path) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}{1}" -f $port, $path) -TimeoutSec 3 -UseBasicParsing
    return $r.StatusCode
  } catch { return $null }
}

function Http-Post([int]$port, [string]$path) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}{1}" -f $port, $path) -Method Post -TimeoutSec 3 -UseBasicParsing
    return $r.StatusCode
  } catch { return $null }
}

function Fix-Lock([int]$pid_, [int]$ctrlPort) {
  $want = "{0}|{1}" -f $pid_, $ctrlPort
  $cur = ''
  if (Test-Path $lockFile) { $cur = [string](Get-Content $lockFile -Raw -ErrorAction SilentlyContinue) }
  if ($null -ne $cur) { $cur = $cur.Trim() }
  if ($cur -ne $want) {
    Set-Content -Path $lockFile -Value $want -NoNewline -Encoding ASCII
    KLog "lock corrected: '$cur' -> '$want'"
  }
}

function Guard-Pid([int]$pid_, [string]$key, [int]$fwdPort) {
  # returns $true if this pid is (or was) holding a forward port
  if (-not (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) { $script:strikes.Remove($key) | Out-Null; return }

  $info = Get-HubInfoFromLog $pid_
  if ($info -and $info.exitTime) {
    $exitTs = [DateTime]::Parse($info.exitTime.Replace('Z','+00:00')).ToUniversalTime()
    $age = ([DateTime]::UtcNow - $exitTs).TotalSeconds
    if ($age -gt $ZOMBIE_GRACE) {
      Stop-Process -Id $pid_ -Force
      KLog ("ZOMBIE(exiting) killed: pid={0} logged exit {1:N0}s ago, key={2}" -f $pid_, $age, $key)
    } else {
      # let it finish exiting; nudge with /exit in case it hangs later
      if ($info.port) { Http-Post $info.port '/exit' | Out-Null }
    }
    $script:strikes.Remove($key) | Out-Null
    return
  }

  $ctrl = $null
  if ($info -and $info.port -and ((Http-Get $info.port '/version') -eq 200)) { $ctrl = $info.port }
  if (-not $ctrl) {
    $cands = (Get-NetTCPConnection -State Listen -OwningProcess $pid_ -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ne $fwdPort }).LocalPort | Select-Object -Unique
    foreach ($p in $cands) { if ((Http-Get $p '/version') -eq 200) { $ctrl = $p; break } }
  }

  if ($ctrl) {
    Http-Get $ctrl '/heartbeat' | Out-Null
    Fix-Lock $pid_ $ctrl
    $script:strikes.Remove($key) | Out-Null
    return
  }

  # no control plane found
  if ($fwdPort -gt 0) {
    $script:strikes[$key] = 1 + [int]$script:strikes[$key]
    if ($script:strikes[$key] -ge $NOCTRL_STRIKES) {
      Stop-Process -Id $pid_ -Force
      KLog ("ZOMBIE(no-ctrl) killed after {0} strikes: pid={1} held :{2}" -f $script:strikes[$key], $pid_, $fwdPort)
      $script:strikes.Remove($key) | Out-Null
    } else {
      KLog ("WARN no ctrl plane ({0}/{1}): pid={2} port={3}" -f $script:strikes[$key], $NOCTRL_STRIKES, $pid_, $fwdPort)
    }
  }
}

function Tick {
  foreach ($fwd in (Get-ForwardPorts)) {
    $owner = Get-PortOwnerPid $fwd
    if ($owner) { Guard-Pid $owner ("fwd:$fwd") $fwd }
  }
  # also guard the lock-holder hub (it is the one extensions will reuse)
  if (Test-Path $lockFile) {
    $raw = [string](Get-Content $lockFile -Raw -ErrorAction SilentlyContinue)
    if ($raw -match '^(\d+)\|(\d+)') {
      $lp = [int]$Matches[1]
      if (Get-Process -Id $lp -ErrorAction SilentlyContinue) {
        $fwdForLock = 0
        foreach ($fwd in (Get-ForwardPorts)) { if ((Get-PortOwnerPid $fwd) -eq $lp) { $fwdForLock = $fwd } }
        if ($fwdForLock -eq 0) { Guard-Pid $lp "lock:$lp" 0 }
      }
    }
  }
}

KLog ("keeper v2 started (mode=" + $(if ($Once) { 'Once' } else { 'Loop' }) + ")")
do {
  try { Tick } catch { KLog ("ERROR: " + $_.Exception.Message) }
  if (-not $Once) { Start-Sleep -Seconds $INTERVAL }
} while (-not $Once)
