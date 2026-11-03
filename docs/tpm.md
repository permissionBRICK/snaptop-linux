# TPM

The laptop has a firmware TPM 2.0 (fTPM) from Qualcomm: manufacturer `QCOM`, vendor string "xCGfTPM", TPM 2.0
specification revision 1.62, firmware 4.0.0.1, one PCR bank (sha256). It runs as the application `qcom.tz.tpm` in
TrustZone. Windows uses it for BitLocker and Windows Hello; the firmware measures the boot into it.

Linux uses it through our driver `tpm_qcom_crb` (kernel patch `0011`, loaded at boot by
`/etc/modules-load.d/s15-tpm.conf`). It provides the usual `/dev/tpm0` and `/dev/tpmrm0`, the firmware's boot event
log in `/sys/kernel/security/tpm0/binary_bios_measurements`, and systemd detects it (`systemd-analyze has-tpm2`,
`systemd-cryptenroll --tpm2-device=list`).

## Check

```sh
sudo tools/s15-tpm-check.py
```

Read-only (GetCapability, GetRandom, PCR_Read). It prints the TPM's identity and state and compares PCR 0-7 with a
replay of the firmware event log; `OK` means Linux talks to the TPM that measured this boot. Tested: identical
values after boot and after suspend/resume; about 0.5 ms per command (the first one after a pause takes about
190 ms).

## Do not

Windows owns this TPM's state. BitLocker and Windows Hello depend on it, and Linux must not change it:

- no `tpm2_clear`, no changes of the owner/endorsement/lockout authorization, no `tpm2_evictcontrol` on or over the
  persistent keys `0x81000001`, `0x81000002`, `0x81000009`, `0x81010001` (Windows' storage and endorsement keys);
- avoid wrong passwords/PINs on TPM objects: the dictionary-attack lockout (32 failures, then one try per 2 hours) is
  shared with Windows;
- systemd's `systemd-tpm2-setup` would put its own storage key at `0x81000001`, where Windows' key already is; it only
  runs with a measured UKI (`ConditionSecurity=measured-uki`), which this install does not use.

Sealing data to the TPM (for example `systemd-cryptenroll --tpm2-device=auto`) only uses these keys as parents and
stores the sealed blob outside the TPM; it changes nothing in the TPM. systemd 257 seals under Windows' storage key
at `0x81000001`; the disk encryption ([encryption.md](encryption.md)) works that way, verified unchanged TPM state.

## How it works

Windows does not see the TPM as an ACPI device. The ACPI TPM2 table says start method 9 (vendor specific; the TCG
specification reserves it) with a TCG Command Response Buffer (CRB) control area at `0x81F10000`; the device behind
it is Qualcomm's TrEE driver (`QCOM04DE`). Its TPM service (in `QcTrEE.sys` from ASUS's Qualcomm board support
package) talks to the TrustZone application over QSEECOM, the same channel Linux already uses for EFI variables
(`qcom.tz.uefisecapp`). Each request starts with a little-endian command id:

| Request | Response | Meaning |
|---|---|---|
| `0x1000` | `{status, 0x1000, 0x00010000}` | application version 1.0 |
| `0x80000` | `{0x80000, status, 0x6654504d}` | TPM type: fTPM (`0x6454504d` would be a discrete TPM behind TrustZone) |
| `0x4012` | `{0x7000, 0x81F10000, 0}` | location of the CRB (Windows maps 0x3000 bytes there) |
| `{0x4008, 0x400}`, padded to 0x408 bytes | 0x404 bytes | run the command in the CRB |

The CRB is the standard TCG layout: control area at `0x81F10000`, command buffer `0x81F10030` and response buffer
`0x81F11030` (4 KB each). To run a command: write it to the command buffer, set `start` to 1, send `0x4008`; the
application runs the command, writes the response into the response buffer and clears `start`. The firmware uses the
same buffer during boot (its last command there is the PCR 5 measurement before handing over to the OS).

Because Linux boots this machine with a devicetree, there is no TPM2 table; the driver gets the CRB location from the
application (`0x4012`) and checks version and type first. It refuses to load on anything but X1E80100.

Why not the upstream driver: Qualcomm posted "tpm: Introduce Qualcomm TPM driver" (series
"Add TPM support via Qualcomm TEE TPM TA", v4, October 2026) for newer platforms. It reaches the application as the
QCOMTEE object service `qcom.tz.tpm` (UID 81). The X1E80100 firmware (QTEE 5.2.0) does not expose that service
(opening UID 81 fails like a nonexistent UID), but its application answers the same vendor requests (`0x1000`,
`0x80000`) over the older QSEECOM interface, where TPM commands go through the CRB instead.

Not done: the CRB `req` bits (cmdReady/goIdle) are not used (the Windows driver only acknowledges them); no power
management (the application keeps its state across suspend, tested); the TPM is not registered as a hardware random
number generator (`tpm_qcom_crb.hwrng=1` enables it); Windows also shares the CRB with TrustZone through an SHM
bridge, which Linux does not need here (`qcom_tzmem` runs without bridges on this platform).
