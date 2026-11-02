#!/usr/bin/env python3
"""Sample battery power and what influences it, as CSV.

Usage (root): s15-powerlog.py [--interval 5] [--duration 10800] [--out /var/tmp/s15-power.csv]
Columns: time, ac (barrel/AC input; USB-C PD charging shows as status=Charging with ac=0), status, power_w (battery, positive = discharging), energy_wh, capacity, brightness_pct,
screen (eDP DPMS), cpu_pct (all cores), freq_mhz (per cpufreq policy), gpu_mhz, sysidle_pct (share of the
interval the SoC-wide power domain spent in its idle state), wifi (operstate), usb_devs.
Run s15-powerreport.py on the CSV to get averages per state.
"""
import argparse, glob, os, time

B = "/sys/class/power_supply/qcom-battmgr-bat"
def rd(p, d=""):
    try:
        return open(p).read().strip()
    except OSError:
        return d

def cpu_times():
    f = open("/proc/stat").readline().split()[1:]
    v = list(map(int, f)); idle = v[3] + v[4]
    return sum(v), idle

def sysidle_ms():
    p = "/sys/kernel/debug/pm_genpd/power-domain-system/idle_states"
    try:
        lines = open(p).read().splitlines()[1:]
        return sum(int(l.split()[1]) for l in lines if l.strip())
    except (OSError, IndexError, ValueError):
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=5)
    ap.add_argument("--duration", type=float, default=3 * 3600)
    ap.add_argument("--out", default="/var/tmp/s15-power.csv")
    a = ap.parse_args()
    if not os.path.ismount("/sys/kernel/debug"):
        os.system("mount -t debugfs none /sys/kernel/debug")
    bl = (glob.glob("/sys/class/backlight/*") or [""])[0]
    bmax = int(rd(bl + "/max_brightness", "1") or 1)
    edp = (glob.glob("/sys/class/drm/card*-eDP-1") or [""])[0]
    pol = sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*"))
    gpu = (glob.glob("/sys/class/devfreq/*gpu*") or [""])[0]
    new = not os.path.exists(a.out)
    f = open(a.out, "a", buffering=1)
    if new:
        f.write("time,ac,status,power_w,energy_wh,capacity,brightness_pct,screen,cpu_pct,freq_mhz,gpu_mhz,sysidle_pct,wifi,usb_devs\n")
    t_end = time.time() + a.duration
    c0, i0 = cpu_times(); s0 = sysidle_ms(); w0 = time.time()
    while time.time() < t_end:
        time.sleep(a.interval)
        c1, i1 = cpu_times(); s1 = sysidle_ms(); w1 = time.time()
        cpu = 100.0 * (1 - (i1 - i0) / max(1, c1 - c0))
        si = "" if s0 is None or s1 is None else "%.0f" % min(100, 100.0 * (s1 - s0) / 1000 / max(0.001, w1 - w0))
        c0, i0, s0, w0 = c1, i1, s1, w1
        p = rd(B + "/power_now", "0")
        st = rd(B + "/status")
        pw = abs(int(p)) / 1e6 if p else 0
        if st == "Charging":
            pw = -pw
        usb = len([d for d in os.listdir("/sys/bus/usb/devices") if ":" not in d and not d.startswith("usb")])
        f.write(",".join(map(str, [
            time.strftime("%Y-%m-%dT%H:%M:%S"), rd("/sys/class/power_supply/qcom-battmgr-ac/online"), st,
            "%.3f" % pw, "%.3f" % (int(rd(B + "/energy_now", "0")) / 1e6),
            "%.1f" % (100.0 * int(rd(B + "/energy_now", "0")) / max(1, int(rd(B + "/energy_full", "1") or 1))),
            "%.0f" % (100.0 * int(rd(bl + "/brightness", "0") or 0) / bmax), rd(edp + "/dpms", "?"),
            "%.1f" % cpu, "/".join(str(int(rd(x + "/scaling_cur_freq", "0")) // 1000) for x in pol),
            str(int(rd(gpu + "/cur_freq", "0") or 0) // 1000000) if gpu else "", si,
            rd(next(iter(glob.glob("/sys/class/net/wlan*/operstate")), "/nonexistent"), "-"), usb])) + "\n")

if __name__ == "__main__":
    main()
