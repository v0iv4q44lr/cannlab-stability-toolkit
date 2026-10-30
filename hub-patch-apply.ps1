# hub-patch-apply.ps1 - local hotfix for CANNLabDevSpace port-forward-hub.js v1.1.2
# P1: watchdog 35s/10min -> 10min/12h (idle hubs still cleaned; serving hubs never executed mid-session)
# P2: on 4401 "preempted by others": hub WITHOUT active connections yields permanently
#     (clean exit); hub WITH connections keeps fast reconnect. Ends the 1s ping-pong war.
#     (naive "raise attempts" backoff is WRONG here: QP=3 => immediate exhaustion => closes ALL connections)
# P3: call closeAllConnections() before server.close() on exit - http server.close()
#     hangs forever on lingering keep-alive heartbeat sockets, which is exactly how
#     zombie hubs holding port 30455 are born (verified live, pid 35668 case).
# A plugin update overwrites this file - re-run afterwards. Rollback: hub-patch-rollback.ps1

$ErrorActionPreference = 'Stop'
$hub = Join-Path $env:USERPROFILE '.vscode\extensions\atomgit-cloudenv.cannlabdevspace-1.1.2\dist\src\helper\port-forward-hub.js'
$s = [System.IO.File]::ReadAllText($hub)

$patches = @(
  @{ old = 'uR=10*1e3,lR=35*1e3,pR=10*60*1e3'
     new = 'uR=10*1e3,lR=10*60*1e3,pR=12*60*60*1e3' },
  @{ old = 'this.status="closed",B.info({code:u,reason:l},"websocket on close"),this.scheduleWebSocketReconnect()'
     new = 'this.status="closed",B.info({code:u,reason:l},"websocket on close"),u===4401&&!ve.getInstance().hasActiveConnections()?(B.info({code:u},"websocket preempted-yield"),this._closeConnections(),ii(0,"preempted-yield")):this.scheduleWebSocketReconnect()' },
  @{ old = 'dR(),await new Promise(r=>ni.close(()=>r()))'
     new = 'dR(),ni.closeAllConnections&&ni.closeAllConnections(),await new Promise(r=>ni.close(()=>r()))' }
)

$already = ($patches | Where-Object { $s.Contains($_.new) }).Count
if ($already -eq $patches.Count) { Write-Output 'Already patched. Nothing to do.'; exit 0 }

$changed = 0
foreach ($p in $patches) { if ($s.Contains($p.old)) { $s = $s.Replace($p.old, $p.new); $changed++ } }
if ($changed -lt $patches.Count) {
  Write-Output "ERROR: expected $($patches.Count) anchors, matched $changed (plugin updated?). File NOT modified."; exit 1
}

$bak = "$hub.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item $hub $bak
[System.IO.File]::WriteAllText($hub, $s)
Write-Output "Patched OK ($($patches.Count)/$($patches.Count)). Backup: $bak"
Write-Output 'NOTE: running hubs still use old code. Close all VSCode windows (or kill port-forward-hub processes) so the next hub spawns from the patched file.'
