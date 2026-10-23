<#
.SYNOPSIS
  Installs the latest GitHub release into the WoW AddOns folder using the GitHub CLI.
  Works with a private repo (unlike addon managers, which need a public one). Requires `gh auth login`.
.PARAMETER Client
  retail or forever: the client to install into, found by find-wow-addons.ps1. Defaults to forever.
.PARAMETER AddOnsPath
  An Interface\AddOns folder to install into instead.
#>
param(
  [string]$Repo = "jkloss4/dynamic-camera-zoom",
  [ValidateSet("retail", "forever")][string]$Client = "forever",
  [string]$AddOnsPath
)
if (-not $AddOnsPath) { $AddOnsPath = & (Join-Path $PSScriptRoot "find-wow-addons.ps1") -Client $Client }
$tmp = Join-Path $env:TEMP "dynamic-camera-zoom-update"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

gh release download --repo $Repo --pattern "DynamicCameraZoom-*.zip" --dir $tmp
if ($LASTEXITCODE -ne 0) { throw "gh release download failed" }

$zip = Get-ChildItem $tmp -Filter *.zip | Select-Object -First 1
Expand-Archive $zip.FullName -DestinationPath $tmp\out -Force
foreach ($name in "DynamicCameraZoom") {
  robocopy (Join-Path $tmp "out\$name") (Join-Path $AddOnsPath $name) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name (exit $LASTEXITCODE)" }
}
Write-Host "Installed $($zip.Name). In game: /reload"
Remove-Item $tmp -Recurse -Force

# robocopy exit codes 1-7 mean success; don't leak them as the script's exit code
exit 0
