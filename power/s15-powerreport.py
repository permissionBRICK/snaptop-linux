#!/usr/bin/env python3
"""Average battery power per state from an s15-powerlog CSV.

Usage: s15-powerreport.py <csv> [--since HH:MM] [--min-samples 6]
Groups consecutive discharging samples by (screen, brightness, usb device count) and prints the mean power,
CPU load, SoC-idle share and the estimated runtime on the full battery. The first two samples of each
segment are dropped (transitions).
"""
import csv, sys

def main():
    path = sys.argv[1]
    since = sys.argv[sys.argv.index("--since") + 1] if "--since" in sys.argv else None
    mins = int(sys.argv[sys.argv.index("--min-samples") + 1]) if "--min-samples" in sys.argv else 6
    full = None
    try:
        full = int(open("/sys/class/power_supply/qcom-battmgr-bat/energy_full").read()) / 1e6
    except OSError:
        pass
    rows = [r for r in csv.DictReader(open(path)) if r["status"] == "Discharging" and r["ac"] == "0"]
    if since:
        rows = [r for r in rows if r["time"][11:16] >= since]
    segs, cur, key = [], [], None
    for r in rows:
        k = (r["screen"], r["brightness_pct"], r["usb_devs"])
        if k != key and cur:
            segs.append((key, cur)); cur = []
        key = k; cur.append(r)
    if cur:
        segs.append((key, cur))
    print("%-19s %-8s %-6s %-4s %5s %8s %7s %8s %9s" % ("start", "screen", "bright", "usb", "n", "power_W", "cpu_%", "socidle%", "runtime_h"))
    for (scr, br, usb), rs in segs:
        rs = rs[2:]
        if len(rs) < mins:
            continue
        pw = sum(float(r["power_w"]) for r in rs) / len(rs)
        cpu = sum(float(r["cpu_pct"]) for r in rs) / len(rs)
        si = [float(r["sysidle_pct"]) for r in rs if r["sysidle_pct"]]
        print("%-19s %-8s %-6s %-4s %5d %8.2f %7.1f %8s %9s" % (rs[0]["time"], scr, br + "%", usb, len(rs), pw, cpu,
              "%.0f" % (sum(si) / len(si)) if si else "-", "%.1f" % (full / pw) if full and pw > 0 else "-"))

if __name__ == "__main__":
    main()
