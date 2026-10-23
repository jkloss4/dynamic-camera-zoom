<#
.SYNOPSIS
  Prints the Interface\AddOns path of an installed WoW client, found by the flavor in its folder's .flavor.info
  (retail "wow", WoW: Forever "wowf"), so the scripts don't depend on Blizzard's folder names.
.PARAMETER Client
  retail or forever.
#>
param(
  [ValidateSet("retail", "forever")][string]$Client = "retail"
)
$flavors = @{ retail = "wow"; forever = "wowf" }
# The game folder, from Battle.net's uninstall entry (or the usual places)
$roots = @(
  (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\World of Warcraft" -ErrorAction SilentlyContinue).InstallLocation,
  "C:\Program Files (x86)\World of Warcraft",
  "C:\Program Files\World of Warcraft"
) | Where-Object { $_ -and (Test-Path $_) }
foreach ($root in $roots) {
  foreach ($dir in Get-ChildItem $root -Directory) {
    $info = Join-Path $dir.FullName ".flavor.info"
    if ((Test-Path $info) -and ((Get-Content $info | Select-Object -Last 1).Trim() -eq $flavors[$Client])) {
      return Join-Path $dir.FullName "Interface\AddOns"
    }
  }
}
throw "No WoW $Client client found (looked in: $($roots -join ', '))"
