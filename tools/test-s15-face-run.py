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

sys.dont_write_bytecode = True   # no steamos/__pycache__ from loading s15-face-run
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


def state(fails=0, until=0):
    """A fresh lockout count (root's file, as the service and the root paths use it)."""
    d = tempfile.mkdtemp(dir=T)
    lk = m.Lockout(USER, directory=d, direct=True)
    lk._file(lambda v: v.update(fails=fails, until=until))
    return lk


def runtime():
    d = tempfile.mkdtemp(dir=T)
    m.make_runtime(USER, d)
    return m.Runtime(USER, d)


def conf(**kw):
    c = {k: v[0] for k, v in m.LOCKOUT_KEYS.items()}
    c.update(kw)
    return c


def check_lockout_counting():
    st = state()
    c = conf()
    for n in range(1, 6):
        st.false_face(c)
    d = st.get()
    expect(d["fails"] == 5 and d["until"] == 0, "lockout: 5 false faces, no wait yet (6 free)")
    expect(m.refusal(USER, st, c) is None, "lockout: 5 false faces -> allowed")
    st.false_face(c)
    left = st.get()["until"] - time.time()
    expect(55 < left <= 60, f"lockout: the 6th -> wait 60 s ({left:.0f})")
    r = m.refusal(USER, st, c)
    expect(r is not None and r[0] is False and r[1].startswith("wait"), f"lockout: during the wait -> refused ({r})")
    st.false_face(c)
    left = st.get()["until"] - time.time()
    expect(115 < left <= 120, f"lockout: the 7th -> 120 s ({left:.0f})")
    for _ in range(6):
        st.false_face(c)
    left = st.get()["until"] - time.time()
    expect(3595 < left <= 3600, f"lockout: the 13th -> capped at max_wait 3600 s ({left:.0f})")
    st.false_face(c)
    st.false_face(c)
    r = m.refusal(USER, st, c)
    expect(r is not None and r[0] is True, f"lockout: 15 false faces -> off until a password ({r})")
    # kept on disk: a new Lockout (a restart) sees the same count
    expect(m.Lockout(USER, directory=st.dir, direct=True).get()["fails"] == 15,
           "lockout: the count is in the file (survives a restart)")
    st.reset()
    expect(st.get() == {"fails": 0, "until": 0} and m.refusal(USER, st, c) is None, "lockout: reset -> allowed")
    st2 = state()
    c0 = conf(first_wait=0)
    for _ in range(14):
        st2.false_face(c0)
    expect(st2.get()["until"] == 0 and m.refusal(USER, st2, c0) is None, "lockout: first_wait 0 -> no waits")
    fresh = m.Lockout(USER, directory=f"{T}/new-lockout-dir", direct=True)
    expect(m.refusal(USER, fresh, c) is None and fresh.get()["fails"] == 0,
           "lockout: no file yet (first login after install or boot) -> allowed")
    fresh.false_face(c)
    expect(os.stat(f"{T}/new-lockout-dir").st_mode & 0o777 == 0o700 and
           os.stat(f"{T}/new-lockout-dir/{USER}").st_mode & 0o777 == 0o600, "lockout: directory 0700, file 0600")
    # a lockout file that is a link, or readable by others, is not used: refused, not "allowed"
    d = tempfile.mkdtemp(dir=T)
    os.symlink(f"{T}/elsewhere", f"{d}/{USER}")
    r = m.refusal(USER, m.Lockout(USER, directory=d, direct=True), c)
    expect(r is not None and r[0] is False and not os.path.exists(f"{T}/elsewhere"),
           f"lockout: a link is not followed -> refused ({r})")
    d = tempfile.mkdtemp(dir=T)
    open(f"{d}/{USER}", "w").write("fails=0\n")
    os.chmod(f"{d}/{USER}", 0o644)
    expect(m.refusal(USER, m.Lockout(USER, directory=d, direct=True), c) is not None,
           "lockout: a file readable by others -> refused")
    # the service is not there: refused (never looks without counting)
    r = m.refusal(USER, m.Lockout(USER, sock=f"{T}/no.sock", direct=False), c)
    expect(r is not None and r[0] is False and "cannot be read" in r[1], "lockout: no service -> refused")


def check_service():
    ld, sd = tempfile.mkdtemp(dir=T), tempfile.mkdtemp(dir=T)
    os.chmod(sd, 0o755)
    req = lambda uid, line: m.serve_request(uid, line, ld, f"{T}/no-such.conf", sd)
    expect(req(65534, "get nobody") == "fails=0 until=0", "service: a user asks about itself -> its count")
    expect(os.stat(f"{sd}/nobody").st_uid == 65534 and os.stat(f"{sd}/nobody").st_mode & 0o777 == 0o600,
           "service: get makes the user's runtime file (the user's, 0600)")
    expect(req(65534, "false nobody") == "fails=1 until=0", "service: false -> counted")
    expect(os.stat(f"{ld}/nobody").st_uid == 0 and os.stat(f"{ld}/nobody").st_mode & 0o777 == 0o600,
           "service: the count is root's file, 0600")
    expect(req(65534, "get root") == "denied" and req(65534, "false root") == "denied"
           and req(65534, "ok root") == "denied", "service: a user asking about another user -> denied")
    expect(req(0, "false nobody") == "fails=2 until=0", "service: root may count for any user")
    for _ in range(4):
        req(65534, "false nobody")
    r = req(65534, "get nobody")
    until = int(r.split("until=")[1])
    expect(r.startswith("fails=6 ") and 55 < until - time.time() <= 60,
           f"service: the 6th -> the default wait of 60 s, from root's numbers ({r})")
    expect(req(65534, "ok nobody") == "fails=0 until=0", "service: ok (after a success) -> reset")
    expect(req(65534, "set nobody 0") == "denied" and req(65534, "get ../etc") == "denied"
           and req(65534, "get nosuchuser1") == "denied" and req(65534, "") == "denied",
           "service: anything else -> denied")


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
    rc, out, _ = cli("set", "off_after", "10", "max_wait", "600")
    expect(rc == 0 and "off_after=10" in out and "max_wait=600" in out and "first_wait=120" in out,
           "lockout CLI: set several at once -> all written, the others kept")
    expect(cli("set", "off_after", "11", "max_wait", "86401")[0] == 2 and
           m.lockout_conf(path)["off_after"] == 10, "lockout CLI: one bad pair -> exit 2, nothing written")
    expect(cli("set", "off_after", "11", "max_wait")[0] == 2, "lockout CLI: a key without a value -> exit 2")
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

    def runner(self, lk, c, parent=None):
        return m.Runner(USER, "kde-fingerprint", lk, c, parent=parent, helper=self.helper,
                        display=lambda: self.on, lid=lambda: self.closed)


def check_runs():
    rig, st = Rig(), state(fails=4)
    rig.codes("0 0.1")
    expect(rig.runner(st, conf()).run(5000, 10) == ("match", ""), "run: a match with the display on -> match")
    expect(st.get()["fails"] == 0, "run: a match resets the count")
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
    expect(res == ("ended", "3 false faces") and st.get()["fails"] == 3 and rig.n_runs() == 4,
           f"run: 3 false faces end the run; the no-face helper in between did not count ({res})")

    rig, st = Rig(), state()
    rig.codes("3 0.1", "3 0.1", "3 0.1", "3 0.1")
    res = rig.runner(st, conf()).run(5000, 0.25)
    expect(res[0] == "ended" and res[1].startswith("no face") and st.get()["fails"] == 0,
           f"run: no face until the run's limit -> ended, nothing counted ({res})")

    rig, st = Rig(), state()
    rig.codes("2 0.05")
    res = rig.runner(st, conf()).run(5000, 10)
    expect(res[0] == "ended" and "nothing to try" in res[1] and st.get()["fails"] == 0,
           "run: helper exit 2 (nothing to try) -> ended, not counted")

    rig, st = Rig(), state()
    rig.codes("1 0.05", "1 0.05", "0 0.05")
    res = rig.runner(st, conf(free_false_faces=1)).run(5000, 10)
    expect(res[0] == "refused" and res[1][0] is False and st.get()["fails"] == 1,
           f"run: a false face that starts a wait -> the run stops at once ({res})")

    rig, st = Rig(), state(fails=15)
    rig.codes("0 0.05")
    res = rig.runner(st, conf()).run(5000, 10)
    expect(res[0] == "refused" and res[1][0] is True and rig.n_runs() == 0, "run: locked out -> no helper")


def check_watch():
    # A run of 3 false faces ends; Enter (rescan) starts the next, which matches.
    rig, st, rt = Rig(), state(), runtime()
    rig.codes("1 0.05", "1 0.05", "1 0.05", "0 0.05")
    r = rig.runner(st, conf())
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(r, rt)), daemon=True)
    th.start()
    time.sleep(1.5)
    expect(th.is_alive() and rig.n_runs() == 3, f"watch: after 3 false faces it waits ({rig.n_runs()} helpers)")
    rt.update(lambda d: d.__setitem__("rescan", d.get("rescan", 0) + 1))
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 4, "watch: Enter -> a new run -> match -> 0")

    # Display off while looking: the helper stops; on again: a new run by itself.
    rig, st, rt = Rig(), state(), runtime()
    rig.codes("0 5", "0 0.05")
    r = rig.runner(st, conf())
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(r, rt)), daemon=True)
    th.start()
    time.sleep(0.5)
    rig.on = False
    time.sleep(1.0)
    expect(th.is_alive() and rig.n_runs() == 1, "watch: display off -> stopped, waits with no helper")
    rig.on = True
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 2, "watch: display on again -> a new run by itself -> match")

    # A run that ended waits for the display to go off and on again, too.
    rig, st, rt = Rig(), state(), runtime()
    rig.codes("1 0.05", "1 0.05", "1 0.05", "0 0.05")
    r = rig.runner(st, conf())
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(r, rt)), daemon=True)
    th.start()
    time.sleep(1.2)
    rig.on = False
    time.sleep(0.3)
    rig.on = True
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 4, "watch: ended run, display off and on -> a new run -> match")

    # Off after off_after false faces: the watch ends (kscreenlocker then hides the face hint).
    rig, st, rt = Rig(), state(fails=13), runtime()
    rig.codes("1 0.05", "1 0.05", "1 0.05")
    out = {}
    nowait = conf(first_wait=0)
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(rig.runner(st, nowait), rt)), daemon=True)
    th.start()
    th.join(5)
    expect(out.get("rc") == 1 and st.get()["fails"] == 15, "watch: the 15th false face -> off, the watch ends (1)")

    # During a wait it stays and refuses; after the wait the next trigger starts a run.
    rig, st, rt = Rig(), state(fails=6, until=int(time.time()) + 2), runtime()
    rig.codes("0 0.05")
    out = {}
    th = threading.Thread(target=lambda: out.setdefault("rc", m.watch_loop(rig.runner(st, conf()), rt)), daemon=True)
    th.start()
    time.sleep(0.5)
    expect(th.is_alive() and rig.n_runs() == 0, "watch: during a wait no helper, the watch stays")
    time.sleep(2.0)
    rt.update(lambda d: d.__setitem__("rescan", 1))
    th.join(5)
    expect(out.get("rc") == 0 and rig.n_runs() == 1, "watch: after the wait, Enter -> run -> match")

    # The lock screen ended (greeter exited): the watch ends and its helper with it.
    rig, st, rt = Rig(), state(), runtime()
    rig.codes("0 10")
    r = m.Runner(USER, "kde-fingerprint", st, conf(), parent=-1, helper=rig.helper, display=lambda: True,
                 lid=lambda: False)
    expect(m.watch_loop(r, rt) == 1 and rig.n_runs() == 0, "watch: parent gone -> ends at once")


def check_grace():
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet", "--immediateLock", "--graceTime", "5000"]) == 0,
           "wake: Meta+L (--immediateLock) -> no grace")
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet", "--graceTime", "5000"]) == 5.0,
           "wake: idle lock with --graceTime 5000 -> 5 s of grace")
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet", "--graceTime", "5000", "--nolock"]) is None,
           "wake: --nolock (no password) -> never")
    expect(m.grace_s(["/usr/lib/kscreenlocker_greet"]) == 0, "wake: idle lock, grace 0 -> no grace")


def alive(pid):
    try:
        return open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def check_kill_tree():
    """A helper whose child sits in a process group of its own (as libcamera's softisp_ipa_proxy does): stopping the
    helper must leave nothing."""
    import subprocess
    d = tempfile.mkdtemp(dir=T)
    h = f"{d}/helper"
    open(h, "w").write(f"""#!/bin/bash
python3 -c 'import os, time; os.setpgid(0, 0); open("{d}/kid.tmp", "w").write(str(os.getpid())); os.rename("{d}/kid.tmp", "{d}/kid"); time.sleep(300)' &
sleep 300
""")
    os.chmod(h, 0o755)
    p = subprocess.Popen([h])
    for _ in range(100):
        if os.path.exists(f"{d}/kid"):
            break
        time.sleep(0.05)
    kid = int(open(f"{d}/kid").read())
    expect(os.getpgid(kid) == kid and alive(kid), "kill tree: the helper's child runs in its own process group")
    m.kill_tree(p)
    time.sleep(0.3)
    expect(p.returncode is not None and not alive(kid), "kill tree: helper and its child are both gone")
    # the runner's stop uses it: display off while a helper with a child looks
    rig, st = Rig(), state()
    open(rig.helper, "w").write(open(h).read().replace(d, rig.dir))
    r = rig.runner(st, conf())
    threading.Timer(0.6, lambda: setattr(rig, "on", False)).start()
    res = r.run(5000, 10)
    time.sleep(0.3)
    kid = int(open(f"{rig.dir}/kid").read())
    expect(res == ("stopped", "display off") and not alive(kid), "kill tree: a stopped run leaves no worker")
    # reading the count creates nothing (the wake service reads it in a read-only file system)
    lk = m.Lockout(USER, directory=f"{T}/never-made", direct=True)
    expect(lk.get() == {"fails": 0, "until": 0} and not os.path.exists(f"{T}/never-made"),
           "lockout: reading a missing count creates nothing")


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
check_service()
check_faillock()
check_runs()
check_watch()
check_grace()
check_sleep()
check_kill_tree()
import shutil
shutil.rmtree(T, ignore_errors=True)
print("ALL PASS" if failures == 0 else f"{failures} FAILED")
sys.exit(1 if failures else 0)
