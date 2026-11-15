#!/usr/bin/python3
"""Tests for steamos/s15-face-run (docs/login.md#face-unlock) without a camera, a display or the laptop: a fake DRM
tree, a fake biopass-helper (exit codes from a list), a temporary state directory and lockout file. Run as root on any
Linux machine (the state and lockout files must be root's here): python3 tools/test-s15-face-run.py
"""
import importlib.machinery
import importlib.util
import os
import struct
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("s15facerun", os.path.join(HERE, "..", "steamos", "s15-face-run"))
spec = importlib.util.spec_from_loader("s15facerun", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

failures = 0


def expect(cond, what):
    global failures
    print(f"[{'PASS' if cond else 'FAIL'}] {what}")
    if not cond:
        failures += 1


T = tempfile.mkdtemp(prefix="s15-face-run-test.")
m.log = lambda msg: None          # no syslog from tests
m.configured = lambda user: True  # the user's Biopass settings: tested on the laptop (s15-face status)
m.faillocked_real, m.faillocked = m.faillocked, lambda user: False
for k in ("POLL_S", "IDLE_S"):
    setattr(m, k, 0.05)
m.CONFIRM_S, m.SETTLE_S, m.FALSE_PAUSE_S = 0.2, 0.1, 0.05
USER = "root"   # files owned by the user: root's here


def drm(states):
    d = tempfile.mkdtemp(dir=T)
    for name, (status, enabled, dpms) in states.items():
        os.makedirs(f"{d}/{name}")
        for a, v in (("status", status), ("enabled", enabled), ("dpms", dpms)):
            open(f"{d}/{name}/{a}", "w").write(v + "\n")
    os.makedirs(f"{d}/card0")   # the card itself: no connector
    return d


def check_display():
    on = drm({"card0-eDP-1": ("connected", "enabled", "On"), "card0-DP-1": ("disconnected", "disabled", "On")})
    off = drm({"card0-eDP-1": ("connected", "enabled", "Off"), "card0-DP-1": ("disconnected", "disabled", "On")})
    gone = drm({"card0-eDP-1": ("connected", "disabled", "On")})
    ext = drm({"card0-eDP-1": ("connected", "disabled", "Off"), "card0-DP-2": ("connected", "enabled", "On")})
    expect(m.display_on(on), "display: eDP connected, enabled, DPMS on -> on")
    expect(not m.display_on(off), "display: eDP DPMS off (a disconnected port says On) -> off")
    expect(not m.display_on(gone), "display: eDP disabled -> off")
    expect(m.display_on(ext), "display: only an external monitor on -> on")
    expect(not m.display_on(f"{T}/nothing"), "display: no DRM directory -> off")


def state():
    d = tempfile.mkdtemp(dir=T)
    open(f"{d}/{USER}", "w").write("fails=0\n")
    return m.State(USER, d)


def conf(**kw):
    c = {k: v[0] for k, v in m.LOCKOUT_KEYS.items()}
    c.update(kw)
    return c


def check_lockout_counting():
    st = state()
    c = conf()
    for n in range(1, 6):
        st.add_false_face(c)
    d = st.read()
    expect(d["fails"] == 5 and "until" not in d, "lockout: 5 false faces, no wait yet (6 free)")
    expect(m.refusal(USER, st, c) is None, "lockout: 5 false faces -> allowed")
    st.add_false_face(c)
    d = st.read()
    left = d["until"] - m.boottime()
    expect(55 < left <= 60, f"lockout: the 6th -> wait 60 s ({left:.0f})")
    r = m.refusal(USER, st, c)
    expect(r is not None and r[0] is False and r[1].startswith("wait"), f"lockout: during the wait -> refused ({r})")
    st.add_false_face(c)
    left = st.read()["until"] - m.boottime()
    expect(115 < left <= 120, f"lockout: the 7th -> 120 s ({left:.0f})")
    for _ in range(6):
        st.add_false_face(c)
    left = st.read()["until"] - m.boottime()
    expect(3595 < left <= 3600, f"lockout: the 13th -> capped at max_wait 3600 s ({left:.0f})")
    st.add_false_face(c)
    st.add_false_face(c)
    r = m.refusal(USER, st, c)
    expect(r is not None and r[0] is True, f"lockout: 15 false faces -> off until a password ({r})")
    st2 = state()
    c0 = conf(first_wait=0)
    for _ in range(14):
        st2.add_false_face(c0)
    expect("until" not in st2.read() and m.refusal(USER, st2, c0) is None, "lockout: first_wait 0 -> no waits")
    expect(m.refusal(USER, m.State(USER, f"{T}/none"), c) == (True, "no login with the password or PIN since boot"),
           "lockout: no state file (no login since boot) -> off")
    # a state file that is a link or someone else's is not used
    d = tempfile.mkdtemp(dir=T)
    os.symlink(f"{T}/elsewhere", f"{d}/{USER}")
    expect(m.State(USER, d).read() is None, "state: a link is not followed")


def check_lockout_conf():
    path = f"{T}/s15-face.conf"
    expect(m.lockout_conf(path) == conf(), "lockout file: missing -> the defaults")
    open(path, "w").write("# comment\nfirst_wait = 30\nmax_wait=99999999\noff_after=abc\nunknown=4\nfree_false_faces=0\n")
    os.chmod(path, 0o644)
    c = m.lockout_conf(path)
    expect(c == conf(first_wait=30, free_false_faces=0), f"lockout file: valid values used, invalid ones default ({c})")
    os.chmod(path, 0o666)
    expect(m.lockout_conf(path) == conf(), "lockout file: writable by others -> the defaults")
    os.chown(path, 1000, 1000)
    os.chmod(path, 0o644)
    expect(m.lockout_conf(path) == conf(), "lockout file: not root's -> the defaults")
    os.unlink(path)
    # the CLI
    import contextlib
    import io

    def cli(*args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = m.cmd_lockout(list(args), path)
        return rc, out.getvalue(), err.getvalue()

    rc, out, _ = cli()
    expect(rc == 0 and out.splitlines()[0] == "run_false_faces=3" and len(out.splitlines()) == 5,
           "lockout CLI: show -> 5 key=value lines")
    rc, out, _ = cli("keys")
    expect(rc == 0 and out.splitlines()[2].startswith("first_wait 60 0 86400 seconds "), "lockout CLI: keys")
    rc, out, _ = cli("set", "first_wait", "120")
    st = os.stat(path)
    expect(rc == 0 and "first_wait=120" in out and st.st_uid == 0 and st.st_mode & 0o777 == 0o644,
           "lockout CLI: set -> written, root's, 0644, new values printed")
    expect("first_wait=120" in open(path).read() and "off_after" not in open(path).read(),
           "lockout CLI: only values that differ from the defaults are written")
    expect(cli("set", "first_wait", "86401")[0] == 2, "lockout CLI: out of range -> exit 2")
    expect(cli("set", "first_wait", "-1")[0] == 2, "lockout CLI: negative -> exit 2")
    expect(cli("set", "nope", "1")[0] == 2, "lockout CLI: unknown key -> exit 2")
    expect(cli("set", "off_after")[0] == 2 and cli("bogus")[0] == 2, "lockout CLI: usage -> exit 2")
    expect(m.lockout_conf(path)["first_wait"] == 120, "lockout CLI: bad input changes nothing")
    rc, out, _ = cli("reset-defaults")
    expect(rc == 0 and not os.path.exists(path) and "first_wait=60" in out, "lockout CLI: reset-defaults")
    sys.stdout.flush()
    pid = os.fork()
    if pid == 0:
        os.setuid(65534)
        with open(os.devnull, "w") as null, contextlib.redirect_stderr(null):
            rc = m.cmd_lockout(["set", "first_wait", "5"], path)
        os._exit(rc)
    _, status = os.waitpid(pid, 0)
    expect(os.WEXITSTATUS(status) == 1 and not os.path.exists(path), "lockout CLI: set as a user -> exit 1, nothing")


def check_faillock():
    d = tempfile.mkdtemp(dir=T)
    c = f"{T}/faillock.conf"
    open(c, "w").write(f"deny = 0\n# ours\ndeny = 3\nunlock_time = 600\ndir = {d}\n")
    now = 1_000_000.0
    rec = lambda t, valid=True: struct.pack("<52sHHQ", b"tty1", 0, 1 if valid else 0, int(t))
    open(f"{d}/{USER}", "wb").write(rec(now - 10) + rec(now - 20))
    expect(not m.faillocked_real(USER, c, now), "faillock: 2 of 3 -> not locked")
    open(f"{d}/{USER}", "ab").write(rec(now - 5))
    expect(m.faillocked_real(USER, c, now), "faillock: 3 within the interval -> locked (the last deny line wins)")
    expect(not m.faillocked_real(USER, c, now + 700), "faillock: unlock_time after the last one -> not locked")
    open(f"{d}/{USER}", "wb").write(rec(now - 10) + rec(now - 20) + rec(now - 5, valid=False))
    expect(not m.faillocked_real(USER, c, now), "faillock: invalidated records do not count")


class Rig:
    """A fake helper (exit codes from a file, each run logged), a display and a lid to flip."""
    def __init__(self):
        self.dir = tempfile.mkdtemp(dir=T)
        self.seq, self.runs = f"{self.dir}/seq", f"{self.dir}/runs"
        self.helper = f"{self.dir}/helper"
        open(self.helper, "w").write(f"""#!/bin/bash
echo "$*" >> {self.runs}
read -r line < {self.seq} || line="3 0.2"
tail -n +2 {self.seq} > {self.seq}.n; mv {self.seq}.n {self.seq}
set -- $line
sleep "${{2:-0.1}}"
exit "$1"
""")
        os.chmod(self.helper, 0o755)
        self.on, self.closed = True, False

    def codes(self, *lines):
        open(self.seq, "w").write("".join(f"{l}\n" for l in lines))

    def n_runs(self):
        return len(open(self.runs).read().splitlines()) if os.path.exists(self.runs) else 0

    def runner(self, st, c, parent=None):
        return m.Runner(USER, "kde-fingerprint", st, c, parent=parent, helper=self.helper,
                        display=lambda: self.on, lid=lambda: self.closed)


def check_runs():
    rig, st = Rig(), state()
    rig.codes("0 0.1")
    expect(rig.runner(st, conf()).run(5000, 10) == ("match", ""), "run: a match with the display on -> match")
    expect("--keep-looking 5000" in open(rig.runs).read() and "--service kde-fingerprint" in open(rig.runs).read(),
           "run: the helper gets --keep-looking and the service")

    rig, st = Rig(), state()
    rig.codes("0 0.1")
    r = rig.runner(st, conf())
    threading.Timer(0.2, lambda: setattr(rig, "on", False)).start()   # Escape: display off just after the match
    res = r.run(5000, 10)
    expect(res == ("stopped", "display off"), f"run: display off within 0.2 s after a match -> not used ({res})")

    rig, st = Rig(), state()
    rig.codes("0 5")   # looking for 5 s
    r = rig.runner(st, conf())
    threading.Timer(0.3, lambda: setattr(rig, "on", False)).start()
    t0 = time.monotonic()
    res = r.run(5000, 10)
    took = time.monotonic() - t0
    expect(res == ("stopped", "display off") and took < 0.8,
           f"run: display off while looking -> helper stopped within {took - 0.3:.2f} s")
    expect(r.proc is None, "run: the stopped helper is reaped")

    rig, st = Rig(), state()
    rig.closed = True
    rig.codes("0 0.1")
    expect(rig.runner(st, conf()).run(5000, 10)[0] == "stopped" and rig.n_runs() == 0,
           "run: lid closed -> no helper at all")

    rig, st = Rig(), state()
    rig.codes("1 0.05", "3 0.05", "1 0.05", "1 0.05", "0 0.05")
    res = rig.runner(st, conf()).run(5000, 10)
    expect(res == ("ended", "3 false faces") and st.read()["fails"] == 3 and rig.n_runs() == 4,
           f"run: 3 false faces end the run; the no-face helper in between did not count ({res})")

    rig, st = Rig(), state()
    rig.codes("3 0.1", "3 0.1", "3 0.1", "3 0.1")
    res = rig.runner(st, conf()).run(5000, 0.25)
    expect(res[0] == "ended" and res[1].startswith("no face") and st.read()["fails"] == 0,
           f"run: no face until the run's limit -> ended, nothing counted ({res})")

    rig, st = Rig(), state()
    rig.codes("2 0.05")
    res = rig.runner(st, conf()).run(5000, 10)
    expect(res[0] == "ended" and "nothing to try" in res[1] and st.read()["fails"] == 0,
           "run: helper exit 2 (nothing to try) -> ended, not counted")

    rig, st = Rig(), state()
    rig.codes("1 0.05", "1 0.05", "0 0.05")
    res = rig.runner(st, conf(free_false_faces=1)).run(5000, 10)
    expect(res[0] == "refused" and res[1][0] is False and st.read()["fails"] == 1,
           f"run: a false face that starts a wait -> the run stops at once ({res})")

    rig, st = Rig(), state()
    open(st.path, "w").write("fails=15\n")
    rig.codes("0 0.05")
    res = rig.runner(st, conf()).run(5000, 10)
    expect(res[0] == "refused" and res[1][0] is True and rig.n_runs() == 0, "run: locked out -> no helper")


def check_watch():
    # A run of 3 false faces ends; Enter (rescan) starts the next, which matches.
    rig, st = Rig(), state()
    rig.codes("1 0.05", "1 0.05", "1 0.05", "0 0.05")
    r = rig.runner(st, conf())
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(r, st)), daemon=True)
    th.start()
    time.sleep(1.5)
    expect(th.is_alive() and rig.n_runs() == 3, f"watch: after 3 false faces it waits ({rig.n_runs()} helpers)")
    st.update(lambda d: d.__setitem__("rescan", d.get("rescan", 0) + 1))
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 4, "watch: Enter -> a new run -> match -> 0")

    # Display off while looking: the helper stops; on again: a new run by itself.
    rig, st = Rig(), state()
    rig.codes("0 5", "0 0.05")
    r = rig.runner(st, conf())
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(r, st)), daemon=True)
    th.start()
    time.sleep(0.5)
    rig.on = False
    time.sleep(1.0)
    expect(th.is_alive() and rig.n_runs() == 1, "watch: display off -> stopped, waits with no helper")
    rig.on = True
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 2, "watch: display on again -> a new run by itself -> match")

    # A run that ended waits for the display to go off and on again, too.
    rig, st = Rig(), state()
    rig.codes("1 0.05", "1 0.05", "1 0.05", "0 0.05")
    r = rig.runner(st, conf())
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(r, st)), daemon=True)
    th.start()
    time.sleep(1.2)
    rig.on = False
    time.sleep(0.3)
    rig.on = True
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 4, "watch: ended run, display off and on -> a new run -> match")

    # Off after off_after false faces: the watch ends (kscreenlocker then hides the face hint).
    rig, st = Rig(), state()
    open(st.path, "w").write("fails=13\n")
    rig.codes("1 0.05", "1 0.05", "1 0.05")
    out = {}
    nowait = conf(first_wait=0)
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(rig.runner(st, nowait), st)), daemon=True)
    th.start()
    th.join(5)
    expect(out.get("rc") == 1 and st.read()["fails"] == 15, "watch: the 15th false face -> off, the watch ends (1)")

    # During a wait it stays and refuses; after the wait the next trigger starts a run.
    rig, st = Rig(), state()
    open(st.path, "w").write(f"fails=6\nuntil={int(m.boottime()) + 2}\n")
    rig.codes("0 0.05")
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(rig.runner(st, conf()), st)), daemon=True)
    th.start()
    time.sleep(0.5)
    expect(th.is_alive() and rig.n_runs() == 0, "watch: during a wait no helper, the watch stays")
    time.sleep(2.0)
    st.update(lambda d: d.__setitem__("rescan", 1))
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 1, "watch: after the wait, Enter -> run -> match")

    # The lock screen ended (greeter exited): the watch ends and its helper with it.
    rig, st = Rig(), state()
    rig.codes("0 10")
    r = m.Runner(USER, "kde-fingerprint", st, conf(), parent=-1, helper=rig.helper, display=lambda: True,
                 lid=lambda: False)
    expect(m.watch_loop(r, st) == 1 and rig.n_runs() == 0, "watch: parent gone -> ends at once")


def check_grace():
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet", "--immediateLock", "--graceTime", "5000"]) == 0,
           "wake: Meta+L (--immediateLock) -> no grace")
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet", "--graceTime", "5000"]) == 5.0,
           "wake: idle lock with --graceTime 5000 -> 5 s of grace")
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet", "--graceTime", "5000", "--nolock"]) is None,
           "wake: --nolock (no password) -> never")
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet"]) == 0, "wake: idle lock, grace 0 -> no grace")


def check_sleep():
    s = m.Sleep()
    expect(not s.slept(), "sleep: no suspend in between")
    s.boot -= 5   # as if CLOCK_BOOTTIME had run on for 5 s more than CLOCK_MONOTONIC
    expect(s.slept(), "sleep: 5 s of suspend in between -> woke from sleep")


if os.geteuid() != 0:
    sys.exit("run as root (state and lockout files must be root's here)")
check_display()
check_lockout_counting()
check_lockout_conf()
check_faillock()
check_runs()
check_watch()
check_grace()
check_sleep()
import shutil
shutil.rmtree(T, ignore_errors=True)
print("ALL PASS" if failures == 0 else f"{failures} FAILED")
sys.exit(1 if failures else 0)
