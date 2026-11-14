#!/usr/bin/env python3
"""Run console commands in turn and print everything the badge says meanwhile.

    python3 tools/badgerun.py "lua run firedancer-gui" 14 "top 60" 20 "key right" 20

Each command is followed by its seconds of listening (tools/badge.py doesn't read
during its sleeps). Opening the port resets the badge on macOS: this waits for the
console and for Wi-Fi first.
"""
import sys, time
import serial

port = "/dev/cu.usbserial-110"
args = sys.argv[1:]
if args[:1] == ["--port"]:
    port, args = args[1], args[2:]
s = serial.Serial()
s.port, s.baudrate, s.timeout = port, 115200, 0.1
s.dtr = s.rts = False
s.open()
buf, end = b"", time.time() + 25
while time.time() < end and b"console ready" not in buf:
    buf += s.read(4096)
end = time.time() + 20
while time.time() < end and b"os_wifi: connected" not in buf:
    buf += s.read(4096)
time.sleep(4)
s.read(65536)
for cmd, secs in zip(args[::2], map(float, args[1::2])):
    s.write(cmd.encode() + b"\r\n")
    end = time.time() + secs
    while time.time() < end:
        d = s.read(4096)
        if d:
            sys.stdout.write(d.decode("utf-8", "replace"))
            sys.stdout.flush()
