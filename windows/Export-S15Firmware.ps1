<#
.SYNOPSIS
  Copies the ASUS-signed Qualcomm firmware that Linux needs on the Vivobook S 15 (X1E80100) out of the Windows
  DriverStore into a Linux firmware tree (usr/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/).
  No elevation needed. The files are not redistributable: keep them local.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Export-S15Firmware.ps1 -Destination E:\s15-firmware
#>
param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$repo = Join-Path $env:WINDIR 'System32\DriverStore\FileRepository'
$want = [ordered]@{
  'qcsubsys_ext_adsp8380.inf_arm64_*'  = @('qcadsp8380.mbn', 'adsp_dtbs.elf', 'adspr.jsn', 'adsps.jsn', 'adspua.jsn', 'battmgr.jsn')
  'qcnspmcdm_ext_cdsp8380.inf_arm64_*' = @('qccdsp8380.mbn', 'cdsp_dtbs.elf', 'cdspr.jsn')
  'qcdx8380.inf_arm64_*'               = @('qcdxkmsuc8380.mbn', 'qcvss8380.mbn')
}
$out = Join-Path $Destination 'usr\lib\firmware\qcom\x1e80100\ASUSTeK\vivobook-s15'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$missing = 0
foreach ($pkg in $want.Keys) {
  # Newest driver package first, in case Windows Update left several versions
  $dirs = Get-ChildItem -Path $repo -Directory -Filter $pkg | Sort-Object LastWriteTime -Descending
  foreach ($f in $want[$pkg]) {
    $src = $dirs | ForEach-Object { Join-Path $_.FullName $f } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($src) { Copy-Item -Path $src -Destination $out -Force; "{0,-20} <- {1}" -f $f, (Split-Path (Split-Path $src) -Leaf) }
    else { Write-Warning "$f not found in $pkg"; $missing++ }
  }
}
if ($missing) { Write-Error "$missing file(s) missing" } else { "done: $out" }
