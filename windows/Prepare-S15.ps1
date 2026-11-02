<#
.SYNOPSIS
  Prepares Windows on the ASUS Vivobook S 15 (S5507QA) for install.sh: suspends BitLocker, shrinks C:, creates the
  1 GB FAT32 partition S15BOOT and copies the ASUS firmware that Linux needs onto it (the files may not be
  redistributed, so they come from your own Windows). Safe to run again.
.EXAMPLE
  Elevated PowerShell:  powershell -ExecutionPolicy Bypass -File Prepare-S15.ps1 -LinuxSizeGB 200
#>
#Requires -RunAsAdministrator
param([ValidateRange(64, 2000)][int]$LinuxSizeGB = 200)
$ErrorActionPreference = 'Stop'

$model = (Get-CimInstance Win32_ComputerSystem).Model
if ($model -notmatch 'S5507QA|Vivobook S 15') { throw "This is for the ASUS Vivobook S 15 S5507QA (this PC: $model)" }

# 1. BitLocker: switching Secure Boot off changes what the TPM measures. Suspended (until you resume it), Windows
#    keeps booting without asking for the recovery key.
$bl = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
if ($bl -and $bl.ProtectionStatus -eq 'On') {
  Suspend-BitLocker -MountPoint C: -RebootCount 0 | Out-Null
  'BitLocker on C: suspended (resume later with: Resume-BitLocker -MountPoint C:)'
}

# 2. Partition: shrink C: by LinuxSizeGB + 1 GB, put the 1 GB S15BOOT partition into the gap; the rest stays free for
#    install.sh, which creates the SteamOS partition there.
$c = Get-Partition -DriveLetter C
$vol = Get-Volume -FileSystemLabel S15BOOT -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vol) {
  $p = $vol | Get-Partition
  'S15BOOT exists already (partition {0}); not shrinking C: again' -f $p.PartitionNumber
} else {
  $shrink = ([int64]$LinuxSizeGB + 1) * 1GB
  $min = (Get-PartitionSupportedSize -DriveLetter C).SizeMin
  if ($c.Size - $shrink -lt $min) {
    throw ('C: can shrink by at most {0:N0} GB right now. Free up space or pass a smaller -LinuxSizeGB.' -f (($c.Size - $min) / 1GB))
  }
  Resize-Partition -DriveLetter C -Size ($c.Size - $shrink)
  $p = New-Partition -DiskNumber $c.DiskNumber -Size 1GB
  $p | Format-Volume -FileSystem FAT32 -NewFileSystemLabel S15BOOT -Confirm:$false | Out-Null
  'C: shrunk by {0} GB; S15BOOT created (partition {1})' -f ($LinuxSizeGB + 1), $p.PartitionNumber
}

# 3. Firmware export onto S15BOOT\s15-firmware (temporary drive letter)
$p = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber
$letter = $p.DriveLetter
if (-not $letter -or $letter -eq [char]0) {
  $p | Add-PartitionAccessPath -AssignDriveLetter
  $letter = (Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber).DriveLetter
}
try {
  & (Join-Path $PSScriptRoot 'Export-S15Firmware.ps1') -Destination ('{0}:\s15-firmware' -f $letter)
} finally {
  Remove-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath ('{0}:\' -f $letter)
}

$free = (Get-Disk -Number $c.DiskNumber).LargestFreeExtent
@"

Done. Free for SteamOS: {0:N0} GB. Next:
  1. BIOS (F2 at power-on): Security -> Secure Boot -> Disabled; Boot -> Fast Boot -> Disabled.
  2. Write an ARM64 live Linux to a USB stick (README.md), plug it into the USB-A port, press ESC at power-on, boot it.
  3. In the live system:  sudo ./install.sh
"@ -f ($free / 1GB)
