# Windows games on SteamOS-on-S15

Windows games run through **Proton 11.0 (ARM64)** (Steam's internal tool name `proton_11-arm64`): an ARM64EC
Wine plus FEX. 64-bit x86 game code runs through FEX inside Wine; 32-bit games run Proton's i386 Wine DLLs fully
under FEX, so anything Wine does on the CPU for them is emulated too. Do **not** use "Proton Experimental" for
non-Steam games: that is the x86 Proton, completely under FEX, and slower.

## Non-Steam games from a Windows game drive

- USB NTFS/exFAT drives mount automatically at `/run/media/steamos/<label>` (`s15-media-mount`, set up by
  `steamos-s15-setup.sh`). Shut Windows down fully first (no Fast Startup/hibernation), or ntfs3 refuses a dirty
  volume.
- The desktop Steam client's "Add a Non-Steam Game → Browse" button does nothing on this image. Use
  `games/steam-add-shortcut.py <userdata dir> "<name>" "<exe>" [launch options] [tool]` with Steam stopped. It
  writes the binary `shortcuts.vdf` and the Proton mapping (`CompatToolMapping` in `config/config.vdf`).
  `games/add-games.sh <games.tsv>` does this for a list of games and clones a prepared prefix for each
  (`games/games.example.tsv`).
- If Steam installed its Linux tools (FEX, Proton, Steam Linux Runtimes, Steamworks Shared) into a library on the
  NTFS drive, move them back: `games/steam-move-tools.sh` (verifies every file before deleting the original).

## Fixes for old 32-bit DirectX 9 games

`games/proton-prefix-tweaks.sh <appid> [--dsoal] [--d3dx9 NN]...` applies these per Proton prefix (the game must
have been started once, and must not be running).

### DSOAL instead of Wine's DirectSound mixer

FlatOut 2 ran fine for 10-15 s and then dropped to a slideshow, worst in crashes with many sounds. `top -H`
showed Wine's dsound mixer thread (`wine_dsound...`) at 99 % of a core: it is x86 code under FEX for a 32-bit game,
and the game thread starved waiting on it. `FEX_X87REDUCEDPRECISION=1` did not help.

The fix is [DSOAL](https://github.com/kcat/dsoal) (DirectSound on OpenAL Soft) as native `dsound.dll` with
`dsound=native,builtin`, plus `alsoft.ini` (`games/alsoft-s15.ini`: 48 kHz, linear resampler, no HRTF, larger
period). `games/fetch-dsoal.sh` downloads it (tested with build r697, Win32 DLLs). After that FlatOut 2 ran smoothly.

### Native d3dx9

Wine's built-in `d3dx9` effect compiler failed on FlatOut 2's shaders ("Failed to create effect:
data/shader/pro_static2x.sha"). The native Microsoft DLL from Steam's DirectX June 2010 redistributable
(`Steamworks Shared/_CommonRedist/DirectX/Jun2010`, which Steam installs anyway) fixes it. `--d3dx9 NN` extracts
`d3dx9_NN.dll` (x86) from the redistributable's cab into the prefix and sets the override. Versions in use:

| Game | d3dx9 | Notes |
|---|---|---|
| FlatOut 2 | 30 | + DSOAL. Tested, smooth. |
| Call of Duty 4 (SP/MP) | 34 | Added, not tested yet. |
| Call of Duty: World at War (SP/MP) | 37 | Added, not tested yet. |
| Gothic, Gothic II | - | Added, not tested yet. |
| Battlefield 2 | 24 (from `RendDX9.dll`) | Launch options `+menu 1 +fullscreen 1`. Added, not tested yet. |

To find the version a game needs, look for `d3dx9_NN.dll` strings in its exe or renderer DLL
(`strings -n5 Game.exe | grep -i d3dx9_`).

The added games use clones of the working FlatOut prefix (DSOAL + d3dx9_30), so they start with both fixes.

## Steam games

No Man's Sky (64-bit, Vulkan) ran well for a while, then froze with a GPU fault (`a6xx_irq gpu fault ring 2`,
hangcheck recovery, offending task NMS.exe). Next tests: `TU_DEBUG=sysmem %command%`, then a newer Turnip.
Anti-cheat games will not work (no kernel anti-cheat on Linux, and EAC/BattlEye Linux support does not cover
this setup).

## Audio in Steam's menus

Every UI sound started loud and faded within a fraction of a second. Measured with a steady tone played on the
speakers and recorded with the built-in mics (raw ALSA on both ends, so PipeWire was ruled out): the level
dropped 5-9 dB about 100 ms after each onset. The cause is the LPASS WSA macro compander (`WSA WSA_COMP1/2
Switch`), which the image's `codecs/qcom-lpass/wsa-macro/Wsa1SpeakerEnableSeq.conf` switches on. The amplifiers'
own `COMP` and `PBR` switches made no difference. `steamos-s15-setup.sh` inlines that sequence into the S15
speaker profile without the compander; the steady-state loudness is unchanged.
