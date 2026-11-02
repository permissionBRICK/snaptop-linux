<#
.SYNOPSIS
  Restart once into the firmware boot entry "SteamOS (S15)" (UEFI BootNext). Windows stays the default afterwards.
  Needs admin rights; Install-RebootShortcut.ps1 wraps it in a scheduled task so a desktop shortcut runs it
  without a UAC prompt.
#>
param([string]$Entry = 'SteamOS (S15)', [switch]$NoRestart)
$ErrorActionPreference = 'Stop'
# bcdedit output is localised, so split it into blocks and match the description text, not the field names.
$blocks = ((bcdedit /enum firmware) -join "`n") -split "`n\s*`n"
$block = $blocks | Where-Object { $_ -match [regex]::Escape($Entry) } | Select-Object -First 1
if (-not $block) { throw "no firmware boot entry '$Entry'" }
$guid = [regex]::Match($block, '\{[0-9a-fA-F-]{36}\}').Value
if (-not $guid) { throw "no identifier in the '$Entry' block" }
bcdedit /set '{fwbootmgr}' bootsequence $guid | Out-Null
if ($LASTEXITCODE) { throw "bcdedit failed ($LASTEXITCODE)" }
if (-not $NoRestart) { shutdown.exe /r /t 0 /d p:0:0 /c "Restart into $Entry" }
