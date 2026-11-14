#!/usr/bin/env python3
"""Copy one file of an installed app onto the badge over its console (lua put).

    python3 tools/badgeput.py firedancer-gui main.lua [name on the badge] [--port PORT]

Opening the port resets the badge on macOS; the app must not be running (it isn't,
after the reset). Writing a file drops the store's compiled code: the app then runs
from its source until the store installs it again. ~35 s for main.lua.
"""
import argparse, base64, sys, time
import serial

p = argparse.ArgumentParser()
p.add_argument("app")
p.add_argument("path")
p.add_argument("name", nargs="?")
p.add_argument("--port", default="/dev/cu.usbserial-110")
a = p.parse_args()
name = a.name or a.path.rsplit("/", 1)[-1]
data = base64.b64encode(open(a.path, "rb").read()).decode()

s = serial.Serial()
s.port, s.baudrate, s.timeout = a.port, 115200, 0.05
s.dtr = s.rts = False
s.open()
buf, end = b"", time.time() + 25
while time.time() < end and b"console ready" not in buf:
    buf += s.read(4096)
time.sleep(2)
s.read(65536)

def cmd(line, wait=5):
    s.write(line.encode() + b"\r\n")
    out, end = b"", time.time() + wait
    while time.time() < end:
        out += s.read(4096)
        if out.rstrip().endswith(b"sol>"):
            break
    return out.decode("utf-8", "replace")

cmd(f"lua put {a.app} {name} begin")
for i in range(0, len(data), 128):           # at most 128 base64 characters a line
    o = cmd(f"lua put {a.app} {name} {data[i:i + 128]}")
    if "error" in o.lower():
        sys.exit(o)
print(cmd(f"lua put {a.app} {name} end", 15).strip().splitlines()[-2])
