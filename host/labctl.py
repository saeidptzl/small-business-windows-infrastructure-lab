#!/usr/bin/env python3
"""Host-side control tool for the Small Business Windows Infrastructure Lab.

Talks to each VM over local Unix sockets only:
  * QMP (QEMU monitor): power, screenshots, keyboard input.
  * QEMU guest agent (virtio-serial): run commands as LocalSystem, copy files.
Neither channel is a network: the lab LAN stays isolated.

Standard library only. Run `labctl.py -h` for the command list.
"""
import argparse
import base64
import json
import os
import random
import re
import secrets
import socket
import string
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_DIR = os.environ.get("LAB_RUN_DIR") or os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "smallbiz-lab")
RUNTIME = os.environ.get("LAB_RUNTIME") or os.path.join(os.path.dirname(REPO_ROOT), "lab-runtime")
SECRETS_FILE = os.environ.get("LAB_SECRETS_FILE") or os.path.join(RUNTIME, "secrets", "lab-secrets.env")

SECRET_NAMES = [
    "DC01_ADMIN_PASSWORD",      # DC01 built-in Administrator (becomes SMALLBIZ\Administrator)
    "CL01_ADMIN_PASSWORD",      # CL01 local "labadmin"
    "DSRM_PASSWORD",            # Directory Services Restore Mode
    "STAFF_INITIAL_PASSWORD",   # synthetic staff accounts
    "ONBOARD_INITIAL_PASSWORD", # ticket 1: temporary password given to the new hire
    "ONBOARD_NEW_PASSWORD",     # ticket 1: password the new hire chooses at first sign-in
]


def sock(vm, kind):
    return os.path.join(RUN_DIR, f"{vm}-{kind}.sock")


# --------------------------------------------------------------------------- secrets
def gen_password():
    """4 groups of 4 characters joined by '-': upper, lower, digit and symbol present.
    Only characters that are easy to type through QMP send-key are used."""
    alphabet = string.ascii_letters + string.digits
    while True:
        groups = ["".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(4)]
        pw = "-".join(groups)
        if (any(c.isupper() for c in pw) and any(c.islower() for c in pw)
                and any(c.isdigit() for c in pw)):
            return pw


def load_secrets():
    data = {}
    if os.path.exists(SECRETS_FILE):
        with open(SECRETS_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    data[k.strip()] = v.strip()
    return data


def cmd_init_secrets(a):
    os.makedirs(os.path.dirname(SECRETS_FILE), mode=0o700, exist_ok=True)
    data = load_secrets()
    added = [n for n in SECRET_NAMES if n not in data]
    for n in added:
        data[n] = gen_password()
    old_umask = os.umask(0o077)
    try:
        with open(SECRETS_FILE, "w", encoding="utf-8") as f:
            f.write("# Lab-only secrets. Generated locally; never commit this file.\n")
            for n in SECRET_NAMES:
                f.write(f"{n}={data[n]}\n")
    finally:
        os.umask(old_umask)
    os.chmod(SECRETS_FILE, 0o600)
    print(f"secrets file: {SECRETS_FILE} (new: {', '.join(added) or 'none'})")


def cmd_render_unattend(a):
    data = load_secrets()
    with open(a.template, encoding="utf-8") as f:
        text = f.read()
    def repl(m):
        key = m.group(1)
        if key in data:
            return data[key]
        if key in os.environ:
            return os.environ[key]
        sys.exit(f"render-unattend: no value for {{{{{key}}}}}")
    out = re.sub(r"\{\{([A-Z0-9_]+)\}\}", repl, text)
    old_umask = os.umask(0o077)
    try:
        with open(a.output, "w", encoding="utf-8") as f:
            f.write(out)
    finally:
        os.umask(old_umask)
    print(f"rendered {a.output}")


# --------------------------------------------------------------------------- QMP
class QMP:
    def __init__(self, vm, timeout=30):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(sock(vm, "qmp"))
        self.f = self.s.makefile("rwb")
        self._read()                       # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise ConnectionError("QMP connection closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.f.write(json.dumps(req).encode() + b"\n")
        self.f.flush()
        r = self._read()
        if "error" in r:
            raise RuntimeError(f"QMP {name}: {r['error']}")
        return r.get("return")

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


# US keyboard layout -> QEMU qcodes. (shifted, qcode)
_KEYMAP = {" ": (False, "spc"), "\n": (False, "ret"), "\t": (False, "tab"),
           "-": (False, "minus"), "_": (True, "minus"), "=": (False, "equal"), "+": (True, "equal"),
           ".": (False, "dot"), ",": (False, "comma"), "/": (False, "slash"), "\\": (False, "backslash"),
           ";": (False, "semicolon"), ":": (True, "semicolon"), "'": (False, "apostrophe"),
           "!": (True, "1"), "@": (True, "2"), "#": (True, "3"), "$": (True, "4"), "%": (True, "5"),
           "^": (True, "6"), "&": (True, "7"), "*": (True, "8"), "(": (True, "9"), ")": (True, "0"),
           "|": (True, "backslash"), '"': (True, "apostrophe"), "?": (True, "slash"),
           "<": (True, "comma"), ">": (True, "dot"), "[": (False, "bracket_left"),
           "]": (False, "bracket_right"), "{": (True, "bracket_left"), "}": (True, "bracket_right"),
           "`": (False, "grave_accent"), "~": (True, "grave_accent")}


def char_to_keys(ch):
    if ch.isascii() and ch.isalpha():
        return ([{"type": "qcode", "data": "shift"}] if ch.isupper() else []) + \
               [{"type": "qcode", "data": ch.lower()}]
    if ch.isdigit():
        return [{"type": "qcode", "data": ch}]
    if ch in _KEYMAP:
        shifted, code = _KEYMAP[ch]
        return ([{"type": "qcode", "data": "shift"}] if shifted else []) + [{"type": "qcode", "data": code}]
    raise ValueError(f"cannot type character {ch!r}")


def qmp_type(q, text, delay=0.06):
    for ch in text:
        q.cmd("send-key", keys=char_to_keys(ch), **{"hold-time": 40})
        time.sleep(delay)


def qmp_keys(q, combo):
    """combo like 'ctrl-alt-delete' or 'ret'."""
    keys = [{"type": "qcode", "data": k} for k in combo.split("-")] if combo not in ("minus",) else \
        [{"type": "qcode", "data": "minus"}]
    q.cmd("send-key", keys=keys, **{"hold-time": 80})


def cmd_qmp(a):
    q = QMP(a.vm)
    args = json.loads(a.args) if a.args else {}
    print(json.dumps(q.cmd(a.command, **args), indent=2))


def cmd_screenshot(a):
    out = os.path.abspath(a.output)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    q = QMP(a.vm)
    q.cmd("screendump", filename=out, format="png")
    print(out)


def cmd_keys(a):
    q = QMP(a.vm)
    for combo in a.combos:
        qmp_keys(q, combo)
        time.sleep(a.delay)


def cmd_type(a):
    if a.secret:
        text = load_secrets().get(a.secret)
        if text is None:
            sys.exit(f"type: secret {a.secret} not found")
    else:
        text = a.text
    q = QMP(a.vm)
    qmp_type(q, text)
    if a.enter:
        qmp_keys(q, "ret")
    # Never echo the typed text: it may be a password.
    print(f"typed {len(text)} characters" + (" + Enter" if a.enter else ""))


def cmd_spam(a):
    """Press a key repeatedly, e.g. to answer 'Press any key to boot from CD or DVD'."""
    end = time.time() + a.seconds
    n = 0
    while time.time() < end:
        try:
            q = QMP(a.vm, timeout=5)
            while time.time() < end:
                qmp_keys(q, a.key)
                n += 1
                time.sleep(a.interval)
        except (OSError, ConnectionError):
            time.sleep(0.5)
    print(f"sent {a.key} x{n}")


def cmd_powerdown(a):
    QMP(a.vm).cmd("system_powerdown")
    print("ACPI power button pressed")


def cmd_status(a):
    try:
        print(json.dumps(QMP(a.vm, timeout=5).cmd("query-status")))
    except OSError as e:
        print(f"{a.vm}: not running ({e.__class__.__name__})")
        sys.exit(1)


# --------------------------------------------------------------------------- guest agent
class QGA:
    def __init__(self, vm, timeout=60):
        self.vm = vm
        # The agent channel serves one client at a time: serialise access with a lock file,
        # otherwise a second labctl process waits silently in QEMU's accept queue.
        import fcntl
        self._lock = open(os.path.join(RUN_DIR, f"{vm}-qga.lock"), "w")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(sock(vm, "qga"))
        self.buf = b""
        self.sync()

    def _recv(self):
        while True:
            while b"\n" not in self.buf:
                chunk = self.s.recv(65536)
                if not chunk:
                    raise ConnectionError("guest agent socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            line = line.replace(b"\xff", b"").strip()
            if line:
                return json.loads(line)

    def _send(self, obj):
        self.s.sendall(json.dumps(obj).encode() + b"\n")

    def sync(self):
        sid = random.randint(1, 2 ** 31 - 1)
        self.s.sendall(b"\xff")
        self._send({"execute": "guest-sync-delimited", "arguments": {"id": sid}})
        while True:
            r = self._recv()
            if r.get("return") == sid:
                return

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self._send(req)
        r = self._recv()
        if "error" in r:
            raise RuntimeError(f"QGA {name}: {r['error']}")
        return r.get("return")

    def exec(self, path, args, timeout=600, stdin=None):
        params = {"path": path, "arg": args, "capture-output": True}
        if stdin is not None:
            params["input-data"] = base64.b64encode(stdin.encode()).decode()
        pid = self.cmd("guest-exec", **params)["pid"]
        deadline = time.time() + timeout
        while True:
            st = self.cmd("guest-exec-status", pid=pid)
            if st.get("exited"):
                break
            if time.time() > deadline:
                raise TimeoutError(f"guest command still running after {timeout}s (pid {pid})")
            time.sleep(1)
        out = base64.b64decode(st.get("out-data", "")).decode("utf-8", "replace")
        err = base64.b64decode(st.get("err-data", "")).decode("utf-8", "replace")
        return st.get("exitcode", -1), out, err

    def write_file(self, remote, data):
        h = self.cmd("guest-file-open", path=remote, mode="wb")
        try:
            for i in range(0, len(data), 48 * 1024):
                self.cmd("guest-file-write", handle=h,
                         **{"buf-b64": base64.b64encode(data[i:i + 48 * 1024]).decode()})
        finally:
            self.cmd("guest-file-close", handle=h)

    def read_file(self, remote):
        h = self.cmd("guest-file-open", path=remote, mode="rb")
        data = b""
        try:
            while True:
                r = self.cmd("guest-file-read", handle=h, count=48 * 1024)
                data += base64.b64decode(r.get("buf-b64", ""))
                if r.get("eof"):
                    break
        finally:
            self.cmd("guest-file-close", handle=h)
        return data


def cmd_wait_agent(a):
    deadline = time.time() + a.timeout
    last = None
    while time.time() < deadline:
        try:
            g = QGA(a.vm, timeout=5)
            g.cmd("guest-ping")
            info = g.cmd("guest-get-osinfo")
            print(f"{a.vm}: guest agent ready - {info.get('pretty-name')} "
                  f"(kernel {info.get('kernel-release')}), host name {g.cmd('guest-get-host-name')['host-name']}")
            return
        except (OSError, ConnectionError, RuntimeError, json.JSONDecodeError) as e:
            last = e
            time.sleep(5)
    sys.exit(f"{a.vm}: guest agent not ready after {a.timeout}s ({last})")


def _secret_stdin(names):
    if not names:
        return None
    data = load_secrets()
    missing = [n for n in names if n not in data]
    if missing:
        sys.exit(f"missing secrets: {missing}")
    return json.dumps({n: data[n] for n in names})


def _print_result(code, out, err):
    if out:
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
    if err:
        sys.stderr.write(err if err.endswith("\n") else err + "\n")
    return code


def cmd_exec(a):
    g = QGA(a.vm)
    code, out, err = g.exec(a.argv[0], a.argv[1:], timeout=a.timeout)
    sys.exit(_print_result(code, out, err))


def cmd_ps(a):
    """Run a PowerShell script that already exists in the guest (default folder C:\\LabSetup)."""
    script = a.script if re.match(r"^[A-Za-z]:\\", a.script) else "C:\\LabSetup\\" + a.script
    args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script] + a.args
    g = QGA(a.vm)
    stdin = _secret_stdin(a.secrets.split(",") if a.secrets else [])
    code, out, err = g.exec("powershell.exe", args, timeout=a.timeout, stdin=stdin)
    sys.exit(_print_result(code, out, err))


def cmd_pscmd(a):
    """Run an inline PowerShell command as LocalSystem."""
    g = QGA(a.vm)
    code, out, err = g.exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy",
                                               "Bypass", "-Command", a.command], timeout=a.timeout)
    sys.exit(_print_result(code, out, err))


def cmd_push(a):
    g = QGA(a.vm)
    src = os.path.abspath(a.local)
    files = []
    if os.path.isdir(src):
        for root, _, names in os.walk(src):
            for n in names:
                full = os.path.join(root, n)
                rel = os.path.relpath(full, src).replace("/", "\\")
                files.append((full, a.remote.rstrip("\\") + "\\" + rel))
    else:
        files.append((src, a.remote))
    dirs = sorted({r.rsplit("\\", 1)[0] for _, r in files})
    mk = "; ".join(f"New-Item -ItemType Directory -Force -Path '{d}' | Out-Null" for d in dirs)
    # Files first copied from the LABCFG CD keep the read-only attribute: clear it before overwriting.
    mk += "; " + "; ".join(f"if (Test-Path -LiteralPath '{r}') {{ Set-ItemProperty -LiteralPath '{r}' -Name IsReadOnly -Value $false }}"
                           for _, r in files)
    code, out, err = g.exec("powershell.exe", ["-NoProfile", "-Command", mk], timeout=60)
    if code != 0:
        sys.exit(f"mkdir failed: {err}")
    for local, remote in files:
        with open(local, "rb") as f:
            g.write_file(remote, f.read())
    print(f"pushed {len(files)} file(s) to {a.vm}:{a.remote}")


def cmd_pull(a):
    g = QGA(a.vm)
    data = g.read_file(a.remote)
    os.makedirs(os.path.dirname(os.path.abspath(a.local)), exist_ok=True)
    with open(a.local, "wb") as f:
        f.write(data)
    print(f"pulled {len(data)} bytes -> {a.local}")


# --------------------------------------------------------------------------- CLI
def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)

    s = sp.add_parser("init-secrets", help="create the local secrets file (missing entries only)")
    s.set_defaults(fn=cmd_init_secrets)
    s = sp.add_parser("render-unattend", help="fill {{PLACEHOLDERS}} in an answer-file template")
    s.add_argument("template"); s.add_argument("output"); s.set_defaults(fn=cmd_render_unattend)

    s = sp.add_parser("qmp", help="raw QMP command"); s.add_argument("vm"); s.add_argument("command")
    s.add_argument("args", nargs="?"); s.set_defaults(fn=cmd_qmp)
    s = sp.add_parser("screenshot", help="save the VM screen as PNG"); s.add_argument("vm")
    s.add_argument("output"); s.set_defaults(fn=cmd_screenshot)
    s = sp.add_parser("keys", help="send key combos, e.g. ctrl-alt-delete ret tab"); s.add_argument("vm")
    s.add_argument("combos", nargs="+"); s.add_argument("--delay", type=float, default=0.4)
    s.set_defaults(fn=cmd_keys)
    s = sp.add_parser("type", help="type text (or a named secret) into the VM console"); s.add_argument("vm")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--text"); g.add_argument("--secret", help="name of a secret in the secrets file")
    s.add_argument("--enter", action="store_true"); s.set_defaults(fn=cmd_type)
    s = sp.add_parser("spam", help="press one key repeatedly for N seconds"); s.add_argument("vm")
    s.add_argument("key"); s.add_argument("seconds", type=float)
    s.add_argument("--interval", type=float, default=0.5); s.set_defaults(fn=cmd_spam)
    s = sp.add_parser("powerdown", help="press the ACPI power button"); s.add_argument("vm")
    s.set_defaults(fn=cmd_powerdown)
    s = sp.add_parser("status", help="QEMU run state"); s.add_argument("vm"); s.set_defaults(fn=cmd_status)

    s = sp.add_parser("wait-agent", help="wait until the guest agent answers"); s.add_argument("vm")
    s.add_argument("--timeout", type=int, default=1800); s.set_defaults(fn=cmd_wait_agent)
    s = sp.add_parser("exec", help="run a program in the guest as LocalSystem"); s.add_argument("vm")
    s.add_argument("--timeout", type=int, default=600); s.add_argument("argv", nargs=argparse.REMAINDER)
    s.set_defaults(fn=cmd_exec)
    s = sp.add_parser("ps", help="run a PowerShell script in the guest (relative to C:\\LabSetup)")
    s.add_argument("vm"); s.add_argument("--timeout", type=int, default=1800)
    s.add_argument("--secrets", help="comma-separated secret names passed as JSON on stdin")
    s.add_argument("script"); s.add_argument("args", nargs=argparse.REMAINDER); s.set_defaults(fn=cmd_ps)
    s = sp.add_parser("pscmd", help="run an inline PowerShell command in the guest"); s.add_argument("vm")
    s.add_argument("--timeout", type=int, default=600); s.add_argument("command"); s.set_defaults(fn=cmd_pscmd)
    s = sp.add_parser("push", help="copy a file or folder into the guest"); s.add_argument("vm")
    s.add_argument("local"); s.add_argument("remote"); s.set_defaults(fn=cmd_push)
    s = sp.add_parser("pull", help="copy a file out of the guest"); s.add_argument("vm")
    s.add_argument("remote"); s.add_argument("local"); s.set_defaults(fn=cmd_pull)

    a = p.parse_args()
    if getattr(a, "argv", None) and a.argv[0] == "--":
        a.argv = a.argv[1:]
    if getattr(a, "args", None) and isinstance(a.args, list) and a.args and a.args[0] == "--":
        a.args = a.args[1:]
    a.fn(a)


if __name__ == "__main__":
    main()
