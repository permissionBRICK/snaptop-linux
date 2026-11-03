#!/usr/bin/env python3
"""Ask the user for the LUKS passphrase on a local virtual console of the laptop (live system, root).

The console must have the same keymap as the boot prompt (luks-encrypt.sh prompt loads it from the SteamOS root). The passphrase
is entered twice with hidden input, must be printable ASCII (identical bytes at every prompt) and at least 8
characters; it is written to /run/s15-luks/pass (no newline) and never shown or sent anywhere. Then the generated
key (/run/s15-luks/rk-plain) is shown once as a temporary safety net, and /run/s15-luks/confirmed is created.
Afterwards the console shows /run/s15-luks/progress until it says DONE or FAILED.

usage: luks-passphrase.py [vt]   (started by luks-encrypt.sh prompt)
"""
import fcntl
import os
import subprocess
import sys
import termios
import time

VT = int(sys.argv[1]) if len(sys.argv) > 1 else 8
D = "/run/s15-luks"
TTY = f"/dev/tty{VT}"
KEY = open(f"{D}/rk-plain").read().strip()
GROUPS = " ".join(KEY[i:i + 8] for i in range(0, len(KEY), 8))

with open("/dev/tty0", "wb", buffering=0) as t0:
    fcntl.ioctl(t0, 0x5606, VT)  # VT_ACTIVATE
    fcntl.ioctl(t0, 0x5607, VT)  # VT_WAITACTIVE
if os.path.exists(f"{D}/console-font"):  # the boot prompt's font (luks-encrypt.sh prompt copies it)
    subprocess.run(["setfont", "-C", TTY, f"{D}/console-font"], stderr=subprocess.DEVNULL, check=False)

fd = os.open(TTY, os.O_RDWR | os.O_NOCTTY)
termios.tcflush(fd, termios.TCIFLUSH)


def out(s=""):
    os.write(fd, (s + "\n").encode())


def readline(hidden):
    old = termios.tcgetattr(fd)
    if hidden:
        new = termios.tcgetattr(fd)
        new[3] &= ~termios.ECHO
        termios.tcsetattr(fd, termios.TCSANOW, new)
    try:
        buf = b""
        while not buf.endswith(b"\n"):
            c = os.read(fd, 256)
            if not c:
                time.sleep(0.1)
            buf += c
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old)
        if hidden:
            os.write(fd, b"\n")
    return buf[:-1]


os.write(fd, b"\033[2J\033[H")
out("  Linux (SteamOS) disk encryption - your passphrase")
out()
out("  You type it at boot whenever the TPM cannot unlock the disk.")
out("  Keyboard layout: the same as at the boot prompt.")
out("  Letters, digits and symbols only - no umlauts, no ss-ligature.")
out("  At least 8 characters. What you type is not shown.")
out()
while True:
    os.write(fd, b"  Choose passphrase: ")
    a = readline(True)
    if len(a) < 8:
        out("  Too short (at least 8 characters).\n")
        continue
    if any(b < 0x20 or b > 0x7E for b in a):
        out("  Contains characters outside plain ASCII (umlauts, ss, ...). Please choose another.\n")
        continue
    os.write(fd, b"  Repeat passphrase: ")
    if readline(True) != a:
        out("  The two entries differ. Once more.\n")
        continue
    break
old = os.umask(0o077)
with open(f"{D}/pass", "wb") as f:
    f.write(a)
os.umask(old)
del a
out()
out("  Passphrase set.")
out()
out("  Safety net for tonight only - please take a photo of this key:")
out()
out(f"      {GROUPS}")
out()
out("  It also unlocks the disk, in case the passphrase does not work at the")
out("  first boot. Once it has worked there, this key is removed from the")
out("  disk and you can delete the photo.")
out()
out("  Press Enter when you have the photo.")
readline(False)
open(f"{D}/confirmed", "w").close()
os.write(fd, b"\033[2J\033[H")
out("  The encryption is running - please do not switch off the laptop.")
out()
last = None
while True:
    try:
        p = open(f"{D}/progress").read().strip()
    except OSError:
        p = "starting ..."
    if p != last:
        os.write(fd, ("\r  " + p[-70:].ljust(72)).encode())
        last = p
    if p.startswith("DONE") or p.startswith("FAILED"):
        out()
        break
    time.sleep(2)
