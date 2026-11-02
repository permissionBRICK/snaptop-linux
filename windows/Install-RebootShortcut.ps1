<#
.SYNOPSIS
  One-click "Reboot to SteamOS" for the desktop. Run once elevated. Creates
  C:\ProgramData\S15\Reboot-ToSteamOS.ps1, a scheduled task "\S15\Reboot to SteamOS" (current user, highest
  privileges, only on demand) and a desktop shortcut that starts the task, so there is no UAC prompt per click.
#>
param([string]$User = "$env:USERDOMAIN\$env:USERNAME")
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:ProgramData 'S15'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'Reboot-ToSteamOS.ps1') (Join-Path $dir 'Reboot-ToSteamOS.ps1')
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\Reboot-ToSteamOS.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskPath '\S15\' -TaskName 'Reboot to SteamOS' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Reboot to SteamOS.lnk'
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = Join-Path $env:WINDIR 'System32\schtasks.exe'
$s.Arguments = '/run /tn "\S15\Reboot to SteamOS"'
$s.WindowStyle = 7
$s.IconLocation = "$env:WINDIR\System32\shell32.dll,27"
$s.Description = 'Restart into SteamOS (S15) once'
$s.Save()
"task \S15\Reboot to SteamOS for $User, shortcut $lnk"
