# Firmware from Windows

The audio DSP (ADSP), compute DSP (CDSP), GPU zap shader and video firmware are signed per OEM. Linux needs
the ASUS-signed files, which are not redistributable. They are in the Windows DriverStore of the laptop. **Never
commit them** to this repo.

Target layout (Linux firmware search path):

```
/usr/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/
  qcadsp8380.mbn  adsp_dtbs.elf  adspr.jsn  adsps.jsn  adspua.jsn  battmgr.jsn     (ADSP: audio, battery, USB-C)
  qccdsp8380.mbn  cdsp_dtbs.elf  cdspr.jsn                                          (CDSP)
  qcdxkmsuc8380.mbn                                                                 (GPU zap shader)
  qcvss8380.mbn                                                                     (video)
```

## Export on Windows

`windows/Prepare-S15.ps1` runs `windows/Export-S15Firmware.ps1` for you and puts the files onto the `S15BOOT`
partition (`S15BOOT\s15-firmware\usr\lib\firmware\...`), where `install.sh` picks them up. The export copies them
from `C:\Windows\System32\DriverStore\FileRepository\` and needs no elevation on its own. The source driver
packages are:

| Driver package (folder prefix) | Files |
|---|---|
| `qcsubsys_ext_adsp8380.inf_arm64_*` | `qcadsp8380.mbn`, `adsp_dtbs.elf`, `adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `battmgr.jsn` |
| `qcnspmcdm_ext_cdsp8380.inf_arm64_*` | `qccdsp8380.mbn`, `cdsp_dtbs.elf`, `cdspr.jsn` |
| `qcdx8380.inf_arm64_*` | `qcdxkmsuc8380.mbn`, `qcvss8380.mbn` |

```powershell
powershell -ExecutionPolicy Bypass -File windows\Export-S15Firmware.ps1 -Destination E:\s15-firmware
```

If Windows is already gone: Ubuntu's `qcom-firmware-extract` can pull them from the ASUS driver package.

## The rest

`steamos/fetch-deps.sh` downloads the remaining files from upstream `linux-firmware` (tag 20260916, checked
against pinned sha256): `ath12k/WCN7850/hw2.0` (Wi-Fi; `board-2.bin` contains an S15 variant), `qca/hmt*`
(Bluetooth), `qcom/gen70500_*` (GPU microcode) and the S15 audio topology
`qcom/x1e80100/ASUSTeK/vivobook-s15/X1E80100-ASUS-Vivobook-S15-tplg.bin`. The Steam Frame image has none of these
for this laptop.
