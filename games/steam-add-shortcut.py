#!/usr/bin/env python3
"""Add a non-Steam game to Steam's shortcuts.vdf (binary VDF) and map it to a Proton version.

Usage: steam-add-shortcut.py <userdata dir> "<name>" "<exe path>" [launch options] [compat tool | none]
Steam must not be running (it rewrites both files on exit).
"""
import os, re, struct, sys, zlib


def read_vdf(b, i=0):
    d = {}
    while True:
        t = b[i]; i += 1
        if t == 8:
            return d, i
        j = b.index(b"\x00", i); k = b[i:j].decode("utf-8", "replace"); i = j + 1
        if t == 0:
            d[k], i = read_vdf(b, i)
        elif t == 1:
            j = b.index(b"\x00", i); d[k] = b[i:j].decode("utf-8", "replace"); i = j + 1
        elif t == 2:
            d[k] = struct.unpack("<i", b[i:i + 4])[0]; i += 4
        else:
            raise ValueError(f"unknown VDF type {t}")


def write_vdf(d):
    out = b""
    for k, v in d.items():
        kb = k.encode() + b"\x00"
        if isinstance(v, dict):
            out += b"\x00" + kb + write_vdf(v)
        elif isinstance(v, int):
            out += b"\x02" + kb + struct.pack("<i", v)
        else:
            out += b"\x01" + kb + str(v).encode() + b"\x00"
    return out + b"\x08"


def main():
    udir, name, exe = sys.argv[1], sys.argv[2], sys.argv[3]
    opts = sys.argv[4] if len(sys.argv) > 4 else ""
    tool = sys.argv[5] if len(sys.argv) > 5 else "proton_11-arm64"  # "" or "none": native Linux, no Proton
    sc_path = os.path.join(udir, "config", "shortcuts.vdf")
    if os.path.exists(sc_path):
        raw = open(sc_path, "rb").read()
        root, _ = read_vdf(raw, 0)
    else:
        root = {"shortcuts": {}}
    shortcuts = root.setdefault("shortcuts", {})
    qexe = f'"{exe}"'
    appid = (zlib.crc32((qexe + name).encode()) & 0xFFFFFFFF) | 0x80000000
    signed = struct.unpack("<i", struct.pack("<I", appid))[0]
    present = any(v.get("Exe") == qexe for v in shortcuts.values())
    if present:
        print(f"shortcut already present: {name}")
    else:
      shortcuts[str(len(shortcuts))] = {
        "appid": signed, "AppName": name, "Exe": qexe, "StartDir": f'"{os.path.dirname(exe)}/"',
        "icon": "", "ShortcutPath": "", "LaunchOptions": opts, "IsHidden": 0, "AllowDesktopConfig": 1,
        "AllowOverlay": 1, "OpenVR": 0, "Devkit": 0, "DevkitGameID": "", "DevkitOverrideAppID": 0,
        "LastPlayTime": 0, "FlatpakAppID": "", "tags": {},
    }
      os.makedirs(os.path.dirname(sc_path), exist_ok=True)
      if os.path.exists(sc_path):
          os.replace(sc_path, sc_path + ".bak")
      open(sc_path, "wb").write(write_vdf(root))
    if tool in ("", "none"):
        print(f"{'present' if present else 'added'} {name}: appid {appid} ({signed}), exe {qexe}, native")
        return
    # Proton mapping in config/config.vdf (text VDF): Software/Valve/Steam/CompatToolMapping/<appid>
    steam_root = os.path.dirname(os.path.dirname(udir.rstrip("/")))
    cfg = os.path.join(steam_root, "config", "config.vdf")
    t = open(cfg, encoding="utf-8").read()
    entry = f'\t\t\t\t\t"{appid}"\n\t\t\t\t\t{{\n\t\t\t\t\t\t"name"\t\t"{tool}"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}}\n'
    if f'"{appid}"' not in t:
        m = re.search(r'"CompatToolMapping"\s*\{\n', t)
        if m:
            t = t[:m.end()] + entry + t[m.end():]
        else:
            m = re.search(r'("Steam"\s*\{\n)', t)
            if not m:
                raise SystemExit("config.vdf: no Steam section found")
            block = f'\t\t\t\t"CompatToolMapping"\n\t\t\t\t{{\n{entry}\t\t\t\t}}\n'
            t = t[:m.end()] + block + t[m.end():]
        os.replace(cfg, cfg + ".bak")
        open(cfg, "w", encoding="utf-8").write(t)
    print(f"added {name}: appid {appid} ({signed}), exe {qexe}, tool {tool}")


if __name__ == "__main__":
    main()
