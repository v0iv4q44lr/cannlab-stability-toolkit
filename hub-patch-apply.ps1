# hub-patch-apply.ps1 - local hotfix for CANNLabDevSpace port-forward-hub.js v1.1.2
# Per-patch idempotent: safe to re-run any time (also after plugin updates).
#   P1 anti-suicide : watchdog 35s/10min -> 10min/12h
#   P2 preempt-yield: on 4401, hub WITHOUT connections yields permanently (ends wars)
#                     (naive backoff patch is WRONG: QP exhaustion closes all conns)
#   P3 clean exit   : closeAllConnections() before server.close() (defensive)
#   P4 ride-through : reconnect attempts 3 -> 30 (upstream outages <~8min become
#                     seamless: data queues, WSS resumes; verified by sandbox test)
# Rollback: hub-patch-rollback.ps1

$ErrorActionPreference = 'Stop'
$hub = Join-Path $env:USERPROFILE '.vscode\extensions\atomgit-cloudenv.cannlabdevspace-1.1.2\dist\src\helper\port-forward-hub.js'
if (-not (Test-Path $hub)) { Write-Output "ERROR: hub script not found (plugin updated?)"; exit 1 }
$s = [System.IO.File]::ReadAllText($hub)

$patches = @(
  @{ id = 'P1'
     old = 'uR=10*1e3,lR=35*1e3,pR=10*60*1e3'
     new = 'uR=10*1e3,lR=10*60*1e3,pR=12*60*60*1e3' },
  @{ id = 'P2'
     old = 'this.status="closed",B.info({code:u,reason:l},"websocket on close"),this.scheduleWebSocketReconnect()'
     new = 'this.status="closed",B.info({code:u,reason:l},"websocket on close"),u===4401&&!ve.getInstance().hasActiveConnections()?(B.info({code:u},"websocket preempted-yield"),this._closeConnections(),ii(0,"preempted-yield")):this.scheduleWebSocketReconnect()' },
  @{ id = 'P3'
     old = 'dR(),await new Promise(r=>ni.close(()=>r()))'
     new = 'dR(),ni.closeAllConnections&&ni.closeAllConnections(),await new Promise(r=>ni.close(()=>r()))' },
  @{ id = 'P4'
     old = 'QP=3'
     new = 'QP=30' },
  @{ id = 'P5'
     old = '!e&&!this.disposed&&this.scheduleWebSocketReconnect()'
     new = '!this.disposed&&this.scheduleWebSocketReconnect()'
     alreadyWhenAbsent = $true }   # P5 "applied" = long form gone (short form is a substring of old)
)

$applied = 0; $already = 0; $missing = 0
foreach ($p in $patches) {
  if ($p.alreadyWhenAbsent) {
    if (-not $s.Contains($p.old)) { $already++ } else { $s = $s.Replace($p.old, $p.new); $applied++ }
  }
  elseif ($s.Contains($p.new)) { $already++ }
  elseif (($s.Split([string[]]@($p.old), [StringSplitOptions]::None).Count - 1) -eq 1) { $s = $s.Replace($p.old, $p.new); $applied++ }
  else { Write-Output ("WARN " + $p.id + ": anchor count != 1 (plugin updated?) - skipped"); $missing++ }
}
if ($applied -gt 0) {
  $bak = "$hub.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $hub $bak
  [System.IO.File]::WriteAllText($hub, $s)
  Write-Output ("Patched: " + $applied + " new, " + $already + " already present, " + $missing + " missing. Backup: " + $bak)
} else {
  Write-Output ("Nothing to apply (already=" + $already + ", missing=" + $missing + ")")
}
if ($missing -gt 0) { exit 1 } else { exit 0 }

# ---- P6: extension.js field-name bug (git-ssh-key 400 fix) ----
# Extension v1.1.2 posts {id: devstageId} but backend requires dev_stage_id,
# so key registration 400s 100% of the time -> server keypair and container
# authorized_keys drift apart -> auth deadlock. Fix the field name locally.
$ext = Join-Path $env:USERPROFILE '.vscode\extensions\atomgit-cloudenv.cannlabdevspace-1.1.2\dist\src\extension.js'
if (Test-Path $ext) {
  $es = [System.IO.File]::ReadAllText($ext)
  $p6old = 'instances/git-ssh-key",{id:t,thirdType:0})'
  $p6new = 'instances/git-ssh-key",{"dev_stage_id":t,thirdType:0})'
  if ($es.Contains($p6new)) { Write-Output 'P6: already applied' }
  elseif (($es.Split([string[]]@($p6old), [StringSplitOptions]::None).Count - 1) -eq 1) {
    $ebak = "$ext.bak-p6-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $ext $ebak
    [System.IO.File]::WriteAllText($ext, $es.Replace($p6old, $p6new))
    Write-Output ("P6: applied (git-ssh-key 400 fix). Backup: " + $ebak)
  } else { Write-Output 'P6: anchor not found (extension updated?) - skipped' }
} else { Write-Output 'P6: extension.js not found - skipped' }
