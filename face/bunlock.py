#!/usr/bin/python3 -I
"""The frontend dependencies of the Biopass app from its bun.lock, without bun (SteamOS's repository has none).

  bunlock.py fetch BUN_LOCK DIR             download each package of the lock that linux/arm64 needs into DIR and
                                            check it against the lock's integrity hash (sha512); a file already
                                            there that matches is kept. Online, before the build.
  bunlock.py install BUN_LOCK DIR APP_DIR   unpack them into APP_DIR/node_modules as bun lays them out (the lock's
                                            keys are the install paths) and link the top-level packages' programs
                                            into node_modules/.bin. Offline; every file is checked again.

As bun does, only packages for this platform (os/cpu) are installed and no package scripts run.
"""
import base64
import hashlib
import json
import os
import shutil
import sys
import tarfile
import time
import urllib.request

OS, CPU = "linux", "arm64"
REGISTRY = "https://registry.npmjs.org/"


def die(msg):
    print(f"bunlock: {msg}", file=sys.stderr)
    sys.exit(1)


def strip_trailing_commas(text):
    """bun.lock is JSON with trailing commas."""
    out, in_str, esc, i = [], False, False, 0
    while i < len(text):
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif c == ",":
            j = i + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j >= len(text) or text[j] not in "}]":
                out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def split_key(key):
    """'@a/b/c/@d/e' -> ['@a/b', 'c', '@d/e']: the package names along an install path."""
    parts, names, i = key.split("/"), [], 0
    while i < len(parts):
        if parts[i].startswith("@"):
            names.append(f"{parts[i]}/{parts[i + 1]}")
            i += 2
        else:
            names.append(parts[i])
            i += 1
    return names


def platform_ok(info):
    """bun's rule: a package with os/cpu lists is installed only where they allow it ('!x' excludes)."""
    for field, here in (("os", OS), ("cpu", CPU)):
        want = info.get(field)
        if want is None or want == "none":
            continue
        want = [want] if isinstance(want, str) else want
        allowed = [w for w in want if not w.startswith("!")]
        if f"!{here}" in want or (allowed and here not in allowed):
            return False
    return True


def packages(lock_path):
    """(install path, name, version, url, integrity, bins) for each package to install, parents first."""
    with open(lock_path, encoding="utf-8") as f:
        lock = json.loads(strip_trailing_commas(f.read()))
    if lock.get("lockfileVersion") != 1:
        die(f"{lock_path}: unknown lockfileVersion {lock.get('lockfileVersion')}")
    out, skipped = [], set()
    for key in sorted(lock["packages"], key=lambda k: len(split_key(k))):
        entry = lock["packages"][key]
        spec, registry, info, integrity = (entry + [None] * 4)[:4]
        names = split_key(key)
        if any("/".join(names[:n]) in skipped for n in range(1, len(names))):
            skipped.add(key)
            continue
        if not isinstance(info, dict) or not platform_ok(info):
            skipped.add(key)
            continue
        name, _, version = spec.rpartition("@")
        if not name or not version or not (integrity or "").startswith("sha512-"):
            die(f"{key}: not a registry package ({spec})")
        base = (registry or REGISTRY).rstrip("/")
        url = f"{base}/{name}/-/{name.split('/')[-1]}-{version}.tgz"
        path = "/".join(f"node_modules/{n}" for n in names)
        bins = info.get("bin") or {}
        if isinstance(bins, str):
            bins = {name.split("/")[-1]: bins}
        out.append((path, name, version, url, integrity, bins if len(names) == 1 else {}))
    return out


def file_name(name, version):
    return f"{name.lstrip('@').replace('/', '__')}-{version}.tgz"


def matches(path, integrity):
    h = hashlib.sha512()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except FileNotFoundError:
        return False
    return "sha512-" + base64.b64encode(h.digest()).decode() == integrity


def fetch(lock_path, dest):
    os.makedirs(dest, exist_ok=True)
    pkgs, got = packages(lock_path), 0
    for _, name, version, url, integrity, _ in {p[1:3]: p for p in pkgs}.values():
        target = os.path.join(dest, file_name(name, version))
        if matches(target, integrity):
            continue
        for attempt in range(4):
            try:
                with urllib.request.urlopen(url, timeout=60) as r, open(target + ".part", "wb") as f:
                    shutil.copyfileobj(r, f)
                break
            except OSError as e:
                if attempt == 3:
                    die(f"{url}: {e}")
                time.sleep(2 + 3 * attempt)
        if not matches(target + ".part", integrity):
            os.unlink(target + ".part")
            die(f"{name}@{version}: integrity mismatch ({url})")
        os.replace(target + ".part", target)
        got += 1
    print(f"npm packages: {len(pkgs)} for {OS}/{CPU} checked ({got} downloaded)")


def unpack(tgz, into):
    """The tarball's single top directory ('package/' as a rule) becomes `into`; nothing may leave it."""
    with tarfile.open(tgz, "r:gz") as tar:
        members = []
        for m in tar.getmembers():
            name = m.name.lstrip("./")
            rel = name.split("/", 1)[1] if "/" in name else ""
            if not rel or not (m.isfile() or m.isdir()):
                continue   # the top directory itself; links and devices are not part of npm packages
            m.name = rel
            members.append(tarfile.data_filter(m, into))
        tar.extractall(into, members=members, filter="data")


def install(lock_path, src, app_dir):
    modules = os.path.join(app_dir, "node_modules")
    if os.path.exists(modules):
        shutil.rmtree(modules)
    pkgs = packages(lock_path)
    for path, name, version, _, integrity, _ in pkgs:
        tgz = os.path.join(src, file_name(name, version))
        if not matches(tgz, integrity):
            die(f"{name}@{version}: missing or changed ({tgz}); run fetch first")
        unpack(tgz, os.path.join(app_dir, path))
    bindir = os.path.join(modules, ".bin")
    os.makedirs(bindir, exist_ok=True)
    for path, _, _, _, _, bins in pkgs:
        for cmd, rel in bins.items():
            target = os.path.normpath(os.path.join(app_dir, path, rel))
            if not target.startswith(os.path.join(app_dir, path) + os.sep) or not os.path.isfile(target):
                continue
            os.chmod(target, os.stat(target).st_mode | 0o111)
            link = os.path.join(bindir, cmd)
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink(os.path.relpath(target, bindir), link)
    print(f"node_modules: {len(pkgs)} packages")


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "fetch":
        fetch(args[1], args[2])
    elif len(args) == 4 and args[0] == "install":
        install(args[1], args[2], os.path.abspath(args[3]))
    else:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
