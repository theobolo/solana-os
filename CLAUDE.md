# Solana OS (badge firmware) and Firedancer GUI

This repository is the firmware of the Solana Breakpoint 2026 badge (ESP32-C5, see
`README.md`). The owner's project lives in `apps/firedancer-gui/`: a Firedancer
dashboard on the badge. The owner writes in French; answer in French.

## What exists (all on branch `claude/solana-breakpoint-badge-mod-llhnwp`)

- `apps/firedancer-gui/main.lua`, `app.json`: the badge app "Firedancer GUI" (id
  `firedancer-gui`). Three views (LIVE, SCHEDULE, VALIDATOR), LEDs. Data comes as
  messages `f` (slot, TPS, 10 Hz), `w` (one leader window in full), `info`, `slot`:
  JSON over Wi-Fi (`ws`), or packed binary over Bluetooth (`unpackMsg`).
- `core.ts`: the relay's logic. Hosts: `worker/` (Cloudflare Worker + Durable
  Object, deployed at `firedancer-gui-relay.theo-b59.workers.dev`) and `server.ts`
  (Bun). It follows `wss://gui.firedancer.io/websocket` (Jump's dashboard) and that
  dashboard's own validator, unless `IDENTITY` / `VOTE` pin another.
- `worker/src/install.html`: a page for Chrome (WebUSB + Web Bluetooth): installs the
  app over the badge's serial console (`lua put`), relays over Bluetooth.
- `android/`: the Android app (no Gradle: `build.sh`). Installs over USB (CH340) and
  relays over Bluetooth in a foreground service.
- `tools/`: tests (below).
- `main/core/console.c`: an added console command, `fdbench` (see "Next").

Why a relay: the badge's `ws` closes on any message over 4 KB
(`OS_SOCKET_MSG_MAX`, `main/core/os_socket.h`), and the dashboard sends megabytes.
Why Bluetooth: an app that is not in the badge's store (nor in a "test run") is
refused every server-mediated call, `ws` included (`"denied"`).

## Rules learned the hard way

- **Three packers must agree**: `packMsg` in `worker/src/install.html`, `Pack.java`,
  and `unpackMsg` in `main.lua`. Change one, change all, and run the parity checks.
- **A Durable Object keeps its old code** while sockets hold it open, even across
  deploys: bump `RELAY_NAME` in `worker/src/index.ts` with any relay change.
- **Badge numbers are 32-bit** (integers and floats): slot numbers stay integers,
  only differences become floats.
- **Badge fonts** have ASCII, `°` and `•` only (no `·`). Labels wrap at their width:
  the 12 px mono font is ~7.2 px a character.
- **Redraw cost**: ~0.45 µs a pixel + ~1 ms an area; `on_tick` is 30 ms. Redraw only
  what changed; things that animate get a small canvas of their own.
- Report what was tested where: the simulator is not the badge.

## Testing without a badge (`apps/firedancer-gui/tools/`)

Needs Python with `lupa`, `pillow`; Node or Bun; a JDK for the Java checks.

```sh
cd apps/firedancer-gui
# record 45 s from a local relay (or use tools/sample.jsonl)
DEV_NO_TICKET=1 PORT=8080 bun server.ts &            # then:
bun tools/record.ts rec.jsonl
# pack it the page's way, and build the two replay files
node tools/pack.mjs worker/src/install.html rec.jsonl rec.hex
python3 -c "import json;[print(json.loads(l)['at'], l.strip()) for l in open('rec.jsonl') if l.strip()]" > rec.ws
# run main.lua in a simulator of the screen: both transports, screen-cost report
mkdir out && KEYS="6000:right,20010:down,30000:back,33000:right" SHOT_MS=1500 \
  python3 tools/bench.py main.lua ws rec.ws out && python3 tools/bench.py main.lua ble rec.hex out
python3 tools/report.py out       # ms of screen per tick, by phase of that key scenario
```

`bench.py` writes `out/<mode>_NN.png` screenshots and pickles; the two modes must
give identical screens (but the very first). `tools/fakebadge.mjs` runs the page's
installer against a fake serial console; `tools/java/` has the same for the Android
installer and the Java-vs-page packer comparison (`tools/cmp.mjs`).

## Deploying

```sh
cd apps/firedancer-gui/worker && npx wrangler deploy          # the relay and the page
cd ../android && ANDROID_HOME=... PHONE_KEY=... KEYSTORE=... VERSION=n ./build.sh
cd ../worker && npx wrangler kv key put --binding FILES firedancer-gui.apk \
  --path ../android/build/firedancer-gui.apk --remote
```

- Cloudflare: `npx wrangler login` on this machine (the cloud session used an API
  token that is not here). Account subdomain `theo-b59`, plan Workers Paid.
- `PHONE_KEY` is a Worker secret (the `k=` of the owner's install link); the owner
  has it. Never commit it.
- The Android signing key (`firedancer-gui.jks`, passwords in `build.sh`) was sent
  to the owner as a file; updates must be signed with it.
- The old Worker `galaxy-live-relay` (the app's first name) was deleted on
  2026-11-14, with its `galaxy-live.apk`. The KV namespace it shared with this relay
  is now titled `firedancer-gui-files` (same id).

## Not yet tested on real hardware

The Wi-Fi path (`ws` with the badge server's ticket: needs the store or a test run
from `/apps/submit`, "Run on badge", desktop Chrome), and everything since the
"optimization pass" and the Firedancer rebrand, were only run in the simulator.
The Bluetooth path, the page installer and the Android app did work on the owner's
badge in earlier versions.

## Next: a client on the badge itself (no relay)

Goal: custom firmware in which the badge reads the dashboard's websocket directly.
Measured from a desktop on gui.firedancer.io with the `compress-zstd` subprotocol:
3.3 MB in the first 5 s, then ~424 KB/s on the wire (1.2 MB/s of JSON), 575
messages a second; each message is its own zstd frame (windows up to 2 MB), so a
client can decompress a message's first bytes, read its topic and skip the rest.
The topics the relay reads are ~96 KB/s on the wire.

Step 1, in progress: `fdbench [seconds]` (console) connects and discards, printing
KB/s each second, to see whether the chip keeps up (TLS at 424 KB/s). Built in the
cloud with ESP-IDF v6.0.1 (`idf.py build`); `solana_os-fdbench.bin` and
`ota_data_initial.bin` were sent to the owner.

1. Back the badge up first (16 MB, the only way back):
   `esptool --chip esp32c5 -p PORT -b 460800 read_flash 0 0x1000000 badge-backup.bin`
2. Flash the test firmware to the first app slot and boot from it:
   `esptool --chip esp32c5 -p PORT -b 460800 write_flash 0xF000 ota_data_initial.bin 0x20000 solana_os-fdbench.bin`
   (partition table: `partitions.csv`; never write the bootloader or the table).
3. On the console (115200 baud; `tools/badge.py`): `fdbench 30`, with Wi-Fi joined;
   `cloud hangup` first if it says there is no memory.
4. To go back: `esptool ... write_flash 0 badge-backup.bin`.

If the badge keeps up: port `core.ts` to C behind a Lua module (streaming zstd, a
streaming JSON reader for the 370 KB epoch and the multi-MB peers messages), so
`main.lua` gets the same `f` / `w` / `info` / `slot` messages. If not: keep the
relay.
