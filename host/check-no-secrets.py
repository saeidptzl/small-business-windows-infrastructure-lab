#!/usr/bin/env python3
"""Pre-publish guard: fail if any lab secret or host-specific path appears in the given files.

Checks every file under the given paths (default: the whole repository) for:
  * each value in the local secrets file (lab-runtime/secrets/lab-secrets.env)
  * absolute home paths (/home/<user>/...) and the host user name
Binary files (PNG) are checked too, as raw bytes.

Usage: host/check-no-secrets.py [path ...]      exit code 0 = clean, 1 = findings
"""
import getpass
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RUNTIME = os.environ.get("LAB_RUNTIME") or os.path.join(os.path.dirname(REPO), "lab-runtime")
SECRETS = os.environ.get("LAB_SECRETS_FILE") or os.path.join(RUNTIME, "secrets", "lab-secrets.env")


def needles():
    out = {}
    if os.path.exists(SECRETS):
        for line in open(SECRETS, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                if v:
                    out[f"secret {k}"] = v.encode()
    else:
        print(f"warning: no secrets file at {SECRETS}; only path checks run", file=sys.stderr)
    home = os.path.expanduser("~")
    out["host home path"] = home.encode()
    user = getpass.getuser()
    if len(user) >= 4:
        out["host user name"] = user.encode()
    return out


def main(paths):
    checks = needles()
    findings = 0
    for base in paths or [REPO]:
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d != ".git"]
            for name in files:
                full = os.path.join(root, name)
                if os.path.abspath(full) == os.path.abspath(__file__):
                    continue
                data = open(full, "rb").read()
                for label, needle in checks.items():
                    if needle.lower() in data.lower():
                        print(f"FOUND {label} in {os.path.relpath(full, REPO)}")
                        findings += 1
    print("clean" if not findings else f"{findings} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
