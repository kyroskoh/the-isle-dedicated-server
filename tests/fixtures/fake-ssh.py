#!/usr/bin/env python3
"""
Stand-in for the ssh client in the API/UI tests (ISLE_SSH points here): answers like a reachable Linux host.
Every call is appended to $FAKE_SSH_LOG. FAKE_SSH_DOWN=1 refuses the login.
"""
import json
import os
import sys

args = sys.argv[1:]
if os.environ.get("FAKE_SSH_LOG"):
    with open(os.environ["FAKE_SSH_LOG"], "a") as log:
        log.write(json.dumps(args) + "\n")
cmd = args[-1] if args else ""
if os.environ.get("FAKE_SSH_DOWN"):
    print("admin@host: Permission denied (publickey).")
    sys.exit(255)
if cmd == "echo isle-ok":
    print("isle-ok")
elif cmd == "uname -s":
    print("Linux")
elif "echo arch=" in cmd:
    print("arch=x86_64\ndistro=Ubuntu 24.04.1 LTS\nadmin=yes\ndocker=yes\ndisk_gb=180\ninstalled=")
sys.exit(0)
