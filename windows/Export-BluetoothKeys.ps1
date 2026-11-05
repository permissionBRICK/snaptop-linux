<#
.SYNOPSIS
  Copies Windows' Bluetooth pairing keys onto S15BOOT, so SteamOS can use the same pairings
  (docs/steamos.md, "Bluetooth devices in both systems").
.DESCRIPTION
  A Bluetooth device keeps one key per host address, and Windows and SteamOS share the laptop's address, so pairing
  in one system breaks the pairing in the other. Pair the device in SteamOS first, then in Windows, run this script
  in an elevated PowerShell, start SteamOS and run `sudo s15-bt-import`, which gives SteamOS Windows' keys.
  Windows keeps the keys under HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys, readable only by
  SYSTEM: a scheduled task running as SYSTEM exports them, and is removed again. The file s15-bt-keys.reg on S15BOOT
  holds the keys unencrypted until s15-bt-import deletes it.
#>
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$vol = Get-Volume -FileSystemLabel S15BOOT -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vol) { throw 'S15BOOT not found (windows\Prepare-S15.ps1 creates it).' }
$p = $vol | Get-Partition
$tmp = Join-Path $env:WINDIR ('Temp\s15-bt-{0}' -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$out = Join-Path $tmp 'keys.reg'
$task = 's15-bt-export'
$letter = $null; $added = $false
try {
  $arg = '/c reg export "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys" "{0}" /y' -f $out
  $action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\cmd.exe') -Argument $arg
  # A task does not start on battery unless its settings allow it.
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
  Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -User 'NT AUTHORITY\SYSTEM' `
    -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName $task
  $deadline = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Milliseconds 500 }
  while (((Get-ScheduledTask -TaskName $task).State -eq 'Running' -or -not (Test-Path $out)) -and (Get-Date) -lt $deadline)
  if (-not (Test-Path $out)) {
    $r = (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult
    throw ('The export as SYSTEM produced no file (task result 0x{0:X8}).' -f $r)
  }

  $lines = Get-Content -LiteralPath $out
  $classic = @($lines | Where-Object { $_ -match '^"([0-9a-f]{12})"=hex:' } | ForEach-Object { $Matches[1] })
  $le = @($lines | Where-Object { $_ -match '^\[.*\\Keys\\[0-9a-f]{12}\\([0-9a-f]{12})\]$' } | ForEach-Object { $Matches[1] })
  $fmt = { param($m) (($m -split '(..)' | Where-Object { $_ }) -join ':').ToUpper() }
  'Paired devices with keys: {0} classic, {1} Bluetooth LE' -f $classic.Count, $le.Count
  foreach ($m in $classic) { '  classic  {0}' -f (& $fmt $m) }
  foreach ($m in $le) { '  LE       {0}' -f (& $fmt $m) }

  $p = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber
  $letter = $p.DriveLetter
  if (-not $letter -or $letter -eq [char]0) {
    $p | Add-PartitionAccessPath -AssignDriveLetter
    $letter = (Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber).DriveLetter
    $added = $true
  }
  Copy-Item -LiteralPath $out -Destination ('{0}:\s15-bt-keys.reg' -f $letter) -Force
  'Written to S15BOOT\s15-bt-keys.reg. Start SteamOS and run: sudo s15-bt-import'
} finally {
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($added) {
    Remove-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath ('{0}:\' -f $letter)
  }
}
