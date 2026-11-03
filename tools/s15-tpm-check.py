#!/usr/bin/env python3
"""Read-only check of the firmware TPM (needs root and the tpm_qcom_crb driver).

Prints the TPM's identity and state (TPM2_GetCapability), reads 16 random bytes, and compares PCR 0-7 with a replay
of the firmware's boot event log: equal values show that the driver talks to the TPM that measured this boot.
Sends only GetCapability, GetRandom and PCR_Read; changes nothing in the TPM.

usage: sudo tools/s15-tpm-check.py [/dev/tpmrm0]
"""
import hashlib
import os
import struct
import sys

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/tpmrm0"
LOG = "/sys/kernel/security/tpm0/binary_bios_measurements"
ALGS = {0x04: "sha1", 0x0B: "sha256", 0x0C: "sha384", 0x0D: "sha512"}


def cmd(cc, body):
    fd = os.open(DEV, os.O_RDWR)
    try:
        os.write(fd, struct.pack(">HII", 0x8001, 10 + len(body), cc) + body)
        r = os.read(fd, 4096)
    finally:
        os.close(fd)
    size, rc = struct.unpack(">II", r[2:10])
    if rc:
        raise RuntimeError(f"TPM error 0x{rc:03x} for command 0x{cc:x}")
    return r[10:size]


def getcap(cap, prop, count):
    return cmd(0x17A, struct.pack(">III", cap, prop, count))


def props(first, count):
    d = getcap(6, first, count)
    n = struct.unpack(">I", d[5:9])[0]
    return dict(struct.unpack(">II", d[9 + 8 * i:17 + 8 * i]) for i in range(n))


def text(v):
    return struct.pack(">I", v).decode("ascii", "replace").strip("\x00 ")


def tpm_pcrs():
    d = cmd(0x17E, struct.pack(">IHB3s", 1, 0x0B, 3, b"\xff\x00\x00"))  # sha256, PCR 0-7
    off = 8
    for _ in range(struct.unpack(">I", d[4:8])[0]):
        off += 3 + d[off + 2]
    out = []
    for _ in range(struct.unpack(">I", d[off:off + 4])[0]):
        n = struct.unpack(">H", d[off + 4:off + 6])[0]
        out.append(d[off + 6:off + 6 + n])
        off += 2 + n
    return out


def log_pcrs():
    data = open(LOG, "rb").read()
    size = struct.unpack("<I", data[28:32])[0]
    spec = data[32:32 + size]
    if not spec.startswith(b"Spec ID Event03"):
        raise RuntimeError("event log is not in the TCG2 crypto-agile format")
    sizes = dict(struct.unpack("<HH", spec[28 + 4 * i:32 + 4 * i]) for i in range(struct.unpack("<I", spec[24:28])[0]))
    pcr = {i: bytearray(32) for i in range(24)}
    off, events = 32 + size, 0
    while off + 12 <= len(data):
        idx, etype, cnt = struct.unpack("<III", data[off:off + 12])
        if not (idx or etype or cnt):
            break
        p, sha256 = off + 12, None
        for _ in range(cnt):
            alg = struct.unpack("<H", data[p:p + 2])[0]
            if alg == 0x0B:
                sha256 = data[p + 2:p + 34]
            p += 2 + sizes[alg]
        esize = struct.unpack("<I", data[p:p + 4])[0]
        event = data[p + 4:p + 4 + esize]
        off = p + 4 + esize
        events += 1
        if etype == 3:  # EV_NO_ACTION: not extended
            if event.startswith(b"StartupLocality\0"):
                pcr[0][-1] = event[16]
            continue
        if sha256 and idx < 24:
            pcr[idx][:] = hashlib.sha256(bytes(pcr[idx]) + sha256).digest()
    return [bytes(pcr[i]) for i in range(8)], events


p = props(0x100, 64)
p.update(props(0x200, 32))
fw1, fw2 = p.get(0x10B, 0), p.get(0x10C, 0)
print(f"TPM {text(p.get(0x100, 0))} by {text(p.get(0x105, 0))}, "
      f"\"{''.join(text(p.get(k, 0)) for k in range(0x106, 0x10A))}\", spec revision {p.get(0x102, 0) / 100}, "
      f"firmware {fw1 >> 16}.{fw1 & 0xffff}.{fw2 >> 16}.{fw2 & 0xffff}")
perm = p.get(0x200, 0)
print(f"ownerAuth set: {perm & 1}, lockoutAuth set: {perm >> 2 & 1}, in lockout: {perm >> 9 & 1}; "
      f"dictionary-attack counter {p.get(0x20E)} of {p.get(0x20F)}")
d = getcap(5, 0, 16)
banks, off = [], 9
for _ in range(struct.unpack(">I", d[5:9])[0]):
    alg, sz = struct.unpack(">HB", d[off:off + 3])
    if int.from_bytes(d[off + 3:off + 3 + sz], "little"):
        banks.append(ALGS.get(alg, hex(alg)))
    off += 3 + sz
d = getcap(1, 0x81000000, 64)
handles = [struct.unpack(">I", d[9 + 4 * i:13 + 4 * i])[0] for i in range(struct.unpack(">I", d[5:9])[0])]
print(f"PCR banks: {', '.join(banks)}; persistent keys: {' '.join(f'0x{h:08x}' for h in handles) or 'none'}")
rnd = cmd(0x17B, struct.pack(">H", 16))
print(f"GetRandom: {rnd[2:].hex()}")

live = tpm_pcrs()
try:
    replay, events = log_pcrs()
except (OSError, RuntimeError) as e:
    sys.exit(f"event log: {e}")
for i in range(8):
    print(f"PCR {i}: {live[i].hex()}  {'= log' if live[i] == replay[i] else 'DIFFERS from log'}")
if live == replay:
    print(f"OK: PCR 0-7 match the replay of the firmware event log ({events} events)")
else:
    sys.exit("PCR 0-7 do not match the firmware event log")
