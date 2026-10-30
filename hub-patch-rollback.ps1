# hub-patch-rollback.ps1 - restore port-forward-hub.js from the newest backup
$ErrorActionPreference = 'Stop'
$hub = Join-Path $env:USERPROFILE '.vscode\extensions\atomgit-cloudenv.cannlabdevspace-1.1.2\dist\src\helper\port-forward-hub.js'
$dir  = Split-Path $hub
$name = Split-Path $hub -Leaf
$baks = Get-ChildItem -Path $dir -Filter ($name + '.bak-*') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($baks) {
  Copy-Item $baks[0].FullName $hub -Force
  Write-Output ("Restored original from " + $baks[0].FullName)
} else {
  Write-Output 'No backup found - nothing restored.'
}
