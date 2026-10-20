<#
.SYNOPSIS
  Copies the addon folder from this repo into the WoW AddOns folder (for testing local changes).
.PARAMETER AddOnsPath
  Path to Interface\AddOns. Defaults to the WoW: Forever install used on this machine.
#>
param(
  [string]$AddOnsPath = "C:\Games\Battle.net\Games\World of Warcraft\_classic_beta_\Interface\AddOns"
)
$repo = Split-Path -Parent $PSScriptRoot
foreach ($name in "DynamicCameraZoom") {
  # /MIR makes the installed folder an exact mirror (removes files deleted from the repo); only touches this folder.
  robocopy (Join-Path $repo $name) (Join-Path $AddOnsPath $name) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name (exit $LASTEXITCODE)" }
  # Stamp the installed TOC with this build's version, as the release does: the latest tag, plus the commits since
  # and the commit when there are unreleased changes (e.g. 1.8.4-2-gabc1234). The repo's TOC is left as it is.
  $version = git -C $repo describe --tags --always 2>$null
  if ($version) {
    $version = $version -replace '^v', ''
    foreach ($toc in Get-ChildItem (Join-Path $AddOnsPath $name) -Filter *.toc) {
      $text = [IO.File]::ReadAllText($toc.FullName)
      [IO.File]::WriteAllText($toc.FullName, ($text -replace '(?m)^## Version:[^\r\n]*', "## Version: $version"), (New-Object Text.UTF8Encoding $false))
    }
  }
  Write-Host "installed $name"
}
Write-Host "Done. In game: /reload"

# robocopy exit codes 1-7 mean success; don't leak them as the script's exit code
exit 0
