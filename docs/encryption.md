# Disk encryption (LUKS2 + TPM)

Optional. The SteamOS partition (`SNAPSTEAM-NVME`) can be encrypted in place with LUKS2. The firmware TPM
([tpm.md](tpm.md)) unlocks it at boot without a prompt, like BitLocker on the Windows side; a passphrase is the
fallback. After kernel and initramfs updates the TPM unlock is re-sealed automatically.

## What it protects and what not

The TPM releases the key only if PCR 0, 2, 4, 9 and 15 have the values of one of the SteamOS boot entries on
`S15BOOT`:

| PCR | Measured by | Contents | Changes when |
|---|---|---|---|
| 0 | firmware | the firmware's own code (version, configuration) | a BIOS update |
| 2 | firmware, systemd-boot | firmware drivers before the boot loader; after it, EFI drivers that systemd-boot loads (`\EFI\systemd\drivers`) | an extra EFI driver is loaded |
| 4 | firmware | boot applications: `QcomChargerApp`, the separator, then the Authenticode hashes of systemd-boot and of the kernel | another boot loader or kernel |
| 9 | kernel EFI stub | the kernel command line (`LOADED_IMAGE::LoadOptions`, UTF-16LE, it names the initrd), then the initrd | an edited command line, another initrd |
| 15 | systemd-cryptsetup | zero until a LUKS volume is opened; then its volume key (`tpm2-measure-pcr=yes`) | every boot, right after the unlock |

So everything that runs before the root file system with the released key is measured: firmware, boot loader,
kernel, its command line and initramfs. Escaping into the boot menu, a changed command line (`init=/bin/sh`,
`rd.break`, `systemd.unit=emergency.target`; the menu's editor is off, so this means a boot entry changed on
`S15BOOT`), another kernel or initrd, an EFI shell or a live USB system all work, but each ends at the passphrase
prompt instead of an unlocked disk. Only the normal boot path, which ends at the
login screen ([login.md](login.md)), unlocks with the TPM. Without a login password that protection is moot: the
normal path then logs in automatically.

Closed on top of the PCR binding:

- **A fake root file system.** An attacker could add a partition with the same LUKS UUID that opens without a
  passphrase; the initramfs would then boot the attacker's system on the unchanged boot path, and that system could
  ask the TPM for the real key. PCR 15 prevents it: opening any volume measures its key into PCR 15, after which the
  TPM refuses the token. The real volume is opened first and only once per boot.
- **systemd's GPT auto-discovery** (`systemd.gpt_auto=0` on the command line): it would mount partitions by type
  from the disk without asking the boot entry.
- **Two unmeasured inputs of the kernel** (an initrd named by the devicetree, the `SystemdOptions` EFI variable):
  closed by kernel patches 0012 and 0013 ([kernel.md](kernel.md#our-patches-boot-fixes-for-the-tpm-unlock)). A
  kernel without them is not sealed.

Not part of the binding:

- **PCR 7 (Secure Boot state):** Windows updates the Secure Boot revocation list (dbx) now and then, which changes
  PCR 7; Linux would then ask for the passphrase after Windows updates. Secure Boot is off on this install anyway.
- **PCR 1, 3, 5, 6** (firmware settings, boot order, GPT): they change with BIOS settings, boot order changes by
  Windows, or the partition table, and none of them changes what runs on the measured path.
- **The devicetree** (`x1e80100-asus-vivobook-s15-ec.dtb` on `S15BOOT`): systemd-boot does not measure it. It only
  describes the hardware; patch 0012 keeps it from naming an initrd. Someone could still describe the hardware
  wrongly in it, e.g. to keep a device from working, but not run their own code with the key.

Limits:

- **Without Secure Boot nothing checks what the firmware starts before the passphrase is typed.** Someone with the
  laptop in their hands could put a lookalike prompt on `S15BOOT` that records the passphrase, then come back for
  the laptop. The TPM would not unlock on that path, but a typed passphrase is enough. If a passphrase prompt
  appears without a reason (no BIOS update, no kernel change), boot Windows or a known live system and check
  `S15BOOT` before typing it.
- **Physical attacks on the running laptop** (memory or bus probing) and attacks on the firmware TPM itself are out
  of scope, as for BitLocker without a PIN.
- **The measurements come from the firmware itself.** A firmware that measured something other than what it runs
  would get the key. Replacing it needs a firmware that the SoC accepts (Snapdragon SoCs check the boot firmware's
  signature before it runs; not verified on this unit), and a different signed BIOS changes PCR 0 and gets the
  passphrase prompt.

This protects the data on a lost or stolen laptop against reading the SSD elsewhere and against booting it on another
path.

## Layout

- LUKS2, `aes-xts-plain64`, 512-bit key, 4096-byte sectors, label `SNAPSTEAM`, data offset 16 MiB. The GPT
  partition label stays `SNAPSTEAM-NVME`. Opened as `/dev/mapper/root` with `discard` (TRIM passes through).
- Key slots: the passphrase (argon2id, about 2 s), the re-seal key (`/var/lib/s15-luks/reseal.key`, 64 random
  bytes, root only, inside the encrypted file system; slot priority "prefer", so unlocking with it does not first run
  the passphrase slot's argon2id), one systemd-tpm2 token per boot entry and firmware variant.
- When testing which slot a key opens, add `--disable-external-tokens`, so that cryptsetup does not try the TPM
  tokens first.
- Boot entries (`S15BOOT/loader/entries/s15*.conf`): `root=/dev/mapper/root rd.luks.name=<UUID>=root
  rd.luks.options=<UUID>=discard,tpm2-device=auto,tpm2-measure-pcr=yes systemd.gpt_auto=0`. `install-esp.sh` and
  `luks-encrypt.sh finish` write these options when the partition is LUKS; `login-lock.sh enable` adds the last two
  to the entries of an install encrypted before 2026-11-04. The old GRUB entry cannot open the partition.
- The initramfs ([steamos.md](steamos.md#initramfs)) has `sd-encrypt`, the TPM driver, keyboard, console keymap
  and font, and the display (the DSPs start in the initramfs), so the prompt is visible and typed with the right layout.

Boot (2026-11-03): the TPM unlocks at about 4.2 s; the whole boot takes 0.3 s longer than unencrypted. With a
passphrase (tested 2026-11-04): the TPM tokens are refused at about 7 s, the Caps Lock light starts blinking and the
prompt appears at the same moment; after the passphrase the volume is open about 2.3 s later.

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

Runs at every boot (`s15-luks-reseal.service`, in the background at low priority, so the desktop does not wait for
it) and after every `s15-update-esp` (so after `install-kernel.sh`).
For every boot entry that opens this partition and every known firmware variant of the installed BIOS, it predicts
PCR 0, 2, 4 and 9 from the files on `S15BOOT` (PCR 15 is always zero), computes the policy digest of each
prediction (`TPM2_PolicyPCR`, the token's `tpm2-policy-hash`), enrolls the missing ones
(`systemd-cryptenroll --tpm2-pcrs=0:sha256=...+2:...+4:...+9:...+15:...`, unlocked with the re-seal key) and
removes tokens that no entry produces any more. Log: `journalctl -u s15-luks-reseal`; preview:
`s15-luks-reseal --dry-run`.

- Only boot entries are sealed, never the running boot as such: a boot on another path (an edited command line, a
  debug option, an extra EFI driver) must keep asking for the passphrase. The tool only reports whether the running
  boot matches an entry.
- An entry is skipped (it asks for the passphrase) if its kernel lacks patch 0012 or 0013, or its command line lacks
  `tpm2-measure-pcr=yes`. If no entry can be sealed, nothing is changed.
- "Firmware variants" are the PCR 0, 2 and 4 events up to the separator (`/var/lib/s15-luks/firmware-variants.json`).
  The variant of every boot is recorded, so a new one (a BIOS update, other charger state, the ESC boot menu)
  costs one passphrase prompt and is known from then on. Variants unused for 180 days are dropped, and so are all
  variants of another BIOS (other PCR 0): after a BIOS update, going back to the previous BIOS needs the passphrase.
- The two systemd-boot entries need separate tokens even with identical files: the kernel command line names the
  initrd (`initrd=\EFI\S15\initramfs-s15.img.old`), which changes PCR 9.
- After the unlock PCR 15 holds the volume key's measurement, so a running system cannot test a token; the tool
  only checks that the token it enrolled has the predicted policy. Before changing anything it checks that PCR 0
  and 2 in the TPM equal their event log up to the separator, the basis of every prediction.
- Tested 2026-11-03 (PCR 4+9): prediction = event log = TPM for the current entry; a token enrolled from the
  prediction alone unlocked the "previous kernel" entry, which had not been booted since the encryption.

## TPM state

systemd-cryptenroll seals under the TPM's existing storage key at `0x81000001` (Windows' SRK, used read-only as
the parent; the token stores its public key). Nothing is created or changed in the TPM: persistent handles, the
authorization flags and the dictionary-attack counter are the same before and after. A PCR mismatch does not count
as a failed authorization (the counter stays 0). If Windows ever recreated its SRK (TPM clear), the TPM unlock
fails safely and the boot asks for the passphrase; `s15-luks-reseal` then seals again under the new key.

## Recovery

- **Passphrase prompt at boot:** something measured changed (see above). Type the passphrase. After a BIOS update
  or a new firmware variant the next boot unlocks with the TPM again; a boot path that is not one of the entries
  keeps asking. Check `S15BOOT` first if there is no reason for the prompt ("Limits" above). The display driver
  is only started for the prompt, and its takeover from the firmware failed in a third of the boots where it started
  that early ([known-issues.md](known-issues.md), "Display takeover"). The
  **Caps Lock light blinks while the passphrase is requested**; the prompt does not wait for the display, so when it
  blinks, type the passphrase and press Enter even if the screen stays black or plain blue.
- **From a live system** (e.g. a btrfs problem):
  `cryptsetup open /dev/disk/by-partlabel/SNAPSTEAM-NVME root` (passphrase), then work on `/dev/mapper/root`
  (`btrfs check --readonly`, `btrfs rescue zero-log`, mount).
- Without the passphrase and without a working TPM unlock the data is gone; there is no other key.
