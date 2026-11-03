# Disk encryption (LUKS2 + TPM)

Optional. The SteamOS partition (`SNAPSTEAM-NVME`) can be encrypted in place with LUKS2. The firmware TPM
([tpm.md](tpm.md)) unlocks it at boot without a prompt, like BitLocker on the Windows side; a passphrase is the
fallback. After kernel and initramfs updates the TPM unlock is re-sealed automatically.

## What it protects and what not

The TPM releases the key only if PCR 4 and PCR 9 have the expected values:

| PCR | Measured by | Contents |
|---|---|---|
| 4 | firmware | firmware applications run before the boot option (here `QcomChargerApp`), the separator, then the Authenticode hashes of systemd-boot and of the kernel |
| 9 | kernel EFI stub | the kernel command line (`LOADED_IMAGE::LoadOptions`, UTF-16LE), then the initrd |

So a changed boot loader, kernel, initramfs or kernel command line on the unencrypted `S15BOOT` gets the
passphrase prompt instead of the key. Not part of the binding:

- **PCR 7 (Secure Boot state):** Windows updates the Secure Boot revocation list (dbx) now and then, which changes
  PCR 7; Linux would then ask for the passphrase after Windows updates. Secure Boot is off on this install anyway.
- **PCR 0/2 (firmware code):** BIOS updates would need the passphrase every time.
- **The devicetree** (`x1e80100-asus-vivobook-s15-ec.dtb` on `S15BOOT`): systemd-boot does not measure it into
  PCR 4 or 9.

This protects the data on a lost or stolen laptop against reading the SSD elsewhere and against a modified boot
chain. It does not protect against someone who can change the firmware.

## Layout

- LUKS2, `aes-xts-plain64`, 512-bit key, 4096-byte sectors, label `SNAPSTEAM`, data offset 16 MiB. The GPT
  partition label stays `SNAPSTEAM-NVME`. Opened as `/dev/mapper/root` with `discard` (TRIM passes through).
- Key slots: the passphrase (argon2id, about 2 s), the re-seal key (`/var/lib/s15-luks/reseal.key`, 64 random
  bytes, root only, inside the encrypted file system), one systemd-tpm2 token per boot entry and firmware variant.
- Boot entries (`S15BOOT/loader/entries/s15*.conf`):
  `root=/dev/mapper/root rd.luks.name=<UUID>=root rd.luks.options=<UUID>=discard,tpm2-device=auto`.
  `install-esp.sh` writes these options itself when the partition is LUKS. The old GRUB entry cannot open it.
- The initramfs ([steamos.md](steamos.md#initramfs)) has `sd-encrypt`, the TPM driver, keyboard, console keymap
  and font, and the display (the DSPs start in the initramfs), so the prompt is visible and typed with the right layout.

Boot (2026-11-03): the TPM unlocks at about 4.2 s; the whole boot takes 0.3 s longer than unencrypted.

## Encrypting

From a live ARM64 system (docs/live-system.md), SteamOS not running, about 50 minutes for the 499 GB partition:

1. Before: in SteamOS set the console keymap in `/etc/vconsole.conf` (`KEYMAP=de-latin1-nodeadkeys` for a
   German keyboard; the setup script adds `FONT=latarcyrheb-sun32`) and rebuild the initramfs
   (`steamos/install-kernel.sh` or `mkinitcpio -c /etc/mkinitcpio-s15.conf ...` + `s15-update-esp`).
2. In the live system: `sudo steamos/luks-encrypt.sh run`. It checks the machine, the partition and the tools
   (needs `cryptsetup`, `btrfs-progs`, `kbd`), loads the keymap and font from the SteamOS partition (mounted
   read-only), and asks for the passphrase on console 8 (Ctrl+Alt+F8): twice, hidden, printable ASCII only (no
   umlauts: they can be encoded differently at the two prompts), at least 8 characters. It shows a temporary
   generated key (32 letters, the same on QWERTY and QWERTZ) as a safety net for the first boot; take a photo.
3. Then it encrypts in place (`cryptsetup reencrypt --encrypt --reduce-device-size 32M`, after shrinking btrfs by
   32 MiB). This is crash-safe: after an interruption run `luks-encrypt.sh encrypt` again (it resumes). The Micron
   2400 (QLC) writes 1.1 GB/s until its SLC cache is full (~130 GB), then 125-170 MB/s.
4. `finish`: read-only `btrfs check`, the passphrase and re-seal key slots, `fstrim` of the free space (the
   encryption wrote every block, so the SSD considers the whole partition in use and gets slow: boots took 30-37 s
   instead of 15 s until a TRIM of 482 GB), the boot entries, BootNext.
5. Restart: the boot asks for the passphrase once. `s15-luks-reseal.service` then enrolls the TPM tokens; the next
   boot unlocks without a prompt. Remove the temporary key and delete the photo:
   `systemd-cryptenroll --unlock-key-file=/var/lib/s15-luks/reseal.key --wipe-slot=0 /dev/disk/by-partlabel/SNAPSTEAM-NVME`

## Automatic re-sealing (`s15-luks-reseal`)

Runs at every boot (`s15-luks-reseal.service`) and after every `s15-update-esp` (so after `install-kernel.sh`).
For every boot entry that opens this partition and every firmware variant seen at boot within 180 days, it
predicts PCR 4 and 9 from the files on `S15BOOT`, computes the policy digest of each prediction (`TPM2_PolicyPCR`,
the token's `tpm2-policy-hash`), enrolls the missing ones (`systemd-cryptenroll --tpm2-pcrs=4:sha256=...+9:sha256=...`,
unlocked with the re-seal key) and removes tokens that no entry produces any more. It always keeps a token for the
PCR values of the running boot: after a boot that needed the passphrase (BIOS update, an unknown boot path) the
next boot unlocks with the TPM again. Log: `journalctl -u s15-luks-reseal`; preview: `s15-luks-reseal --dry-run`.

- "Firmware variants" are the PCR 4 events before the separator (`/var/lib/s15-luks/firmware-variants.json`). A
  new one (other charger state, the ESC boot menu, a BIOS update) costs one passphrase prompt; from then on it is
  known. Only one has been seen so far.
- The two systemd-boot entries need separate tokens even with identical files: the kernel command line names the
  initrd (`initrd=\EFI\S15\initramfs-s15.img.old`), which changes PCR 9.
- Tested 2026-11-03: prediction = event log = TPM for the current entry; a token enrolled from the prediction alone
  unlocked the "previous kernel" entry, which had not been booted since the encryption.

## TPM state

systemd-cryptenroll seals under the TPM's existing storage key at `0x81000001` (Windows' SRK, used read-only as
the parent; the token stores its public key). Nothing is created or changed in the TPM: persistent handles, the
authorization flags and the dictionary-attack counter are the same before and after. A PCR mismatch does not count
as a failed authorization (the counter stays 0). If Windows ever recreated its SRK (TPM clear), the TPM unlock
fails safely and the boot asks for the passphrase; `s15-luks-reseal` then seals again under the new key.

## Recovery

- **Passphrase prompt at boot:** something measured changed (see above). Type the passphrase; the TPM is re-sealed
  during that boot. The display driver is only started for the prompt, and its takeover from the firmware failed in
  a third of the boots where it started that early ([known-issues.md](known-issues.md), "Display takeover"). If the
  screen stays plain blue instead of showing the prompt, typing does not help (tested: the prompt only starts after
  the display check, which hangs with the display): hold the power button and boot again until the prompt appears.
- **From a live system** (e.g. a btrfs problem):
  `cryptsetup open /dev/disk/by-partlabel/SNAPSTEAM-NVME root` (passphrase), then work on `/dev/mapper/root`
  (`btrfs check --readonly`, `btrfs rescue zero-log`, mount).
- Without the passphrase and without a working TPM unlock the data is gone; there is no other key.
