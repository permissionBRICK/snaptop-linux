#!/usr/bin/env python3
"""s15-adsp-power: the system power meter of the Vivobook S 15 (X1E80100), read from the ADSP (docs/power.md).

The ADSP's power-limits firmware keeps power samples in firmware-reserved memory at 0x81F30000 (0x6000 bytes):
two rings of 40-byte records, one per 100 ms and one per second, values as u16 in units of 10 mW. Windows' Energy
Meter (qcpep, counters "SYS", "GPU", "CPU_CLUSTER_x", "PSU_USB", "USBC_TOTAL") reads the newest 1 s record every
second. Read-only: an mmap of /dev/mem (the range is "reserved" in /proc/iomem, so STRICT_DEVMEM allows it), only
aligned 32-bit loads (the mapping is device memory). Nothing is sent to the ADSP.

SYS is the whole system's power, measured where the charger feeds it: on battery it matches the battery's own
energy counter within ~5 %; while charging it includes the charging path, so measure on battery. Under Linux the
CPU and GPU channels read 0 or close to it (Windows' driver seems to feed them).

Usage (root):
  s15-adsp-power                    SYS once per second; Ctrl-C prints the average
  s15-adsp-power --all              all channels and the applied power limits
  s15-adsp-power --duration 120 -q  only the average over the next 120 s (every 1 s record counted once)
  s15-adsp-power --once --header    one record plus the raw header and ring words
  s15-adsp-power --rate             how fast both rings advance
  s15-adsp-power --dump FILE        save the 24 KB block
"""
import argparse
import mmap
import os
import signal
import sys
import time

PHYS, SIZE = 0x81F30000, 0x6000
HDR_LIMITS = 0x10                                   # 3 x u32: system power limits applied by the ADSP (mW)
RINGS = {'fast': (0x0130, 0x0138, 256),             # (index offset, records offset, entries): 10 records/s
         'slow': (0x2938, 0x2940, 128)}             # 1 record/s; newest = (index - 1) % entries
REC = 0x28
FIELDS = [('sys', 0x18, 'SYS'), ('usbc_in', 0x1A, 'USB-C in'), ('usbc_out', 0x1C, 'USB-C out'),
          ('cpu0', 0x08, 'CPU0'), ('cpu1', 0x0A, 'CPU1'), ('cpu2', 0x0C, 'CPU2'), ('gpu', 0x0E, 'GPU')]
LIMITS = [('pl_cpu0', 0x10), ('pl_cpu1', 0x12), ('pl_cpu2', 0x14), ('pl_gpu', 0x16)]


def die(msg):
    print('s15-adsp-power: ' + msg, file=sys.stderr)
    sys.exit(1)


def read_text(path):
    try:
        with open(path, 'rb') as f:
            return f.read().replace(b'\0', b' ').decode(errors='replace').strip()
    except OSError:
        return ''


def check_machine():
    compat = read_text('/sys/firmware/devicetree/base/compatible')
    model = read_text('/sys/firmware/devicetree/base/model')
    if 'qcom,x1e80100' not in compat or 'vivobook' not in (model + compat).lower():
        die('only for the ASUS Vivobook S 15 S5507QA (X1E80100); this is %r' % model)


def check_iomem():
    """Refuse unless the whole block lies in a range the kernel does not use as RAM."""
    end = PHYS + SIZE - 1
    with open('/proc/iomem') as f:
        for line in f:
            rng, _, name = line.strip().partition(' : ')
            a, b = (int(x, 16) for x in rng.split('-'))
            if a == 0 and b == 0:
                die('/proc/iomem shows no addresses: run as root')
            if a <= end and b >= PHYS and name == 'System RAM':
                die('0x%x-0x%x is System RAM on this kernel, refusing' % (PHYS, end))


class Block:
    def __init__(self):
        try:
            fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
        except OSError as e:
            die('cannot open /dev/mem: %s' % e)
        try:
            self.mm = mmap.mmap(fd, SIZE, mmap.MAP_SHARED, mmap.PROT_READ, offset=PHYS)
        except OSError as e:
            die('mmap of 0x%x failed: %s' % (PHYS, e))
        finally:
            os.close(fd)
        self.w = memoryview(self.mm).cast('I')      # one element = one aligned 32-bit load

    def u32(self, off):
        return self.w[off >> 2]

    def u16(self, off):
        v = self.u32(off & ~3)
        return v >> 16 if off & 2 else v & 0xFFFF

    def index(self, ring):
        return self.u32(RINGS[ring][0])

    def record(self, ring, idx):
        """Fields (mW) of the record written as number idx (idx - 1 = the newest)."""
        _, base, n = RINGS[ring]
        off = base + (idx % n) * REC
        v = {k: self.u16(off + o) * 10 for k, o, _ in FIELDS}
        v.update({k: self.u16(off + o) * 10 for k, o in LIMITS})
        return v

    def words(self, off, count):
        return [self.u32(off + 4 * i) for i in range(count)]


def main():
    ap = argparse.ArgumentParser(description='Read the ADSP system power meter (read-only).')
    ap.add_argument('--ring', choices=sorted(RINGS), default='slow', help='slow: 1 s records (default), fast: 100 ms')
    ap.add_argument('--all', action='store_true', help='all channels and the applied limits')
    ap.add_argument('--once', action='store_true', help='print the newest record and exit')
    ap.add_argument('--duration', type=float, metavar='S', help='stop after S seconds and print the average')
    ap.add_argument('-q', '--quiet', action='store_true', help='with --duration: only the average')
    ap.add_argument('--header', action='store_true', help='also print the raw header and newest ring words')
    ap.add_argument('--rate', nargs='?', const=5.0, type=float, metavar='S', help='measure the ring rates')
    ap.add_argument('--dump', metavar='FILE', help='write the 0x6000-byte block to FILE')
    a = ap.parse_args()

    check_machine()
    if os.geteuid() != 0:
        die('run as root (/dev/mem, /proc/iomem)')
    check_iomem()
    blk = Block()

    if a.dump:
        with open(a.dump, 'wb') as f:
            f.write(b''.join(w.to_bytes(4, 'little') for w in blk.words(0, SIZE // 4)))
        print('wrote %d bytes from 0x%x to %s' % (SIZE, PHYS, a.dump))
        return
    if a.header:
        for off in range(0, 0x140, 0x20):
            print('%03x: %s' % (off, ' '.join('%08x' % w for w in blk.words(off, 8))))
        print('applied system limits (mW): %d %d %d' % tuple(blk.words(HDR_LIMITS, 3)))
        for r, (ioff, base, n) in RINGS.items():
            idx = blk.index(r)
            print('ring %s: index %d, newest %s' % (r, idx, ' '.join(
                '%08x' % w for w in blk.words(base + ((idx - 1) % n) * REC, REC // 4))))
    if a.rate is not None:
        start = {r: blk.index(r) for r in RINGS}
        t0 = time.monotonic()
        time.sleep(a.rate)
        dt = time.monotonic() - t0
        for r in RINGS:
            print('ring %s: %.2f records/s' % (r, ((blk.index(r) - start[r]) & 0xFFFFFFFF) / dt))
        return

    n = RINGS[a.ring][2]
    last = blk.index(a.ring)
    total, count, t0 = 0, 0, time.monotonic()

    def finish(*_):
        if count and not a.once:
            print('%s%d records, average SYS %.2f W' % ('' if a.quiet else '\n', count, total / count / 1000))
        sys.exit(0)

    signal.signal(signal.SIGINT, finish)
    signal.signal(signal.SIGTERM, finish)
    while True:
        idx = blk.index(a.ring)
        new = min((idx - last) & 0xFFFFFFFF, n - 1)  # every record written since the last look, counted once
        for i in range(idx - new, idx):
            total += blk.record(a.ring, i)['sys']
            count += 1
        last = idx
        if not a.quiet:
            v = blk.record(a.ring, idx - 1)
            line = '%s SYS %6.2f W' % (time.strftime('%H:%M:%S'), v['sys'] / 1000)
            if a.all:
                line += ''.join('  %s %.2f W' % (lbl, v[k] / 1000) for k, _, lbl in FIELDS[1:])
                line += '  limits %s mW' % '/'.join(str(v[k]) for k, _ in LIMITS)
            print(line, flush=True)
        if a.once or (a.duration and time.monotonic() - t0 >= a.duration):
            finish()
        time.sleep(1.0 if a.ring == 'slow' else 0.1)


if __name__ == '__main__':
    main()
