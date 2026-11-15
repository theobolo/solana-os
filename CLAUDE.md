# Solana OS (badge firmware) and Firedancer GUI

This repository is the firmware of the Solana Breakpoint 2026 badge (ESP32-C5, see
`README.md`). The owner's project lives in `apps/firedancer-gui/`: a Firedancer
dashboard on the badge. The owner writes in French; answer in French.

## What exists (all on branch `claude/solana-breakpoint-badge-mod-llhnwp`)

- `apps/firedancer-gui/main.lua`, `app.json`: the badge app "Firedancer GUI" (id
  `firedancer-gui`). Three views (LIVE, SCHEDULE, VALIDATOR), LEDs. Data comes as
  messages `f` (slot, TPS, 10 Hz), `w` (one leader window in full), `info`, `slot`:
  JSON over Wi-Fi (`ws`), or packed binary over Bluetooth (`unpackMsg`).
- `core.ts`: the relay's logic (`Relay`) and the badges' sockets (`Hub`). Hosts:
  `worker/` (Cloudflare Worker + Durable Object, deployed at
  `firedancer-gui-relay.theo-b59.workers.dev`) and `server.ts` (Bun). It follows
  `wss://gui.firedancer.io/websocket` (Jump's dashboard). Each badge follows one
  validator: by default the dashboard's own (or `IDENTITY` / `VOTE`), else the one it
  asks for (`/live?v=<identity>`, or the messages `follow` and `list`, top of core.ts).
  Choosing works over Wi-Fi only: a phone relays the default.
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
- **Redraw cost, on the badge**: ~1.4 µs a pixel rendered (1.0 to 1.7 by view, measured
  2026-11-14) + ~1 ms an area, on the CPU the app and Wi-Fi share; `on_tick` is 30 ms.
  The old 0.45 µs (CHANGELOG 2.1.0) made the simulator 3x optimistic: the app saturated
  the CPU on the badge (watchdog every 5 s) while the simulator said ~3 ms a tick. Keep
  each view under ~200 kpx/s: nothing big slides (jump instead), big canvases redraw
  once a slot, small animated ones at most 10 Hz, countdowns show tenths only < 10 s.
- **Measure on the badge**, not only in the simulator: flash the diagnostic build
  (`sdkconfig.stats`, below) and run `top 60` (per-task CPU, LCD kpx/s, LVGL's flush
  wait) while `key right` switches views; time Lua functions with a copy of main.lua
  that wraps them in `sys.millis()` and prints every 2 s, sent with `tools/badgeput.py`
  and run with `tools/badgerun.py`. Put the real main.lua back after.
- Report what was tested where: the simulator is not the badge.
- **Labels wrap at their width**, and the badge's fonts are not monospaced (12 px "mono"
  is 5 to 9 px a character, `W` is 14 px in the 14 px font). Cut names with `fit()` in
  main.lua (the fonts' widths), never `sub(1, n)`. The simulator draws with the badge's
  own fonts (`tools/badgefont.py`, from `main/assets/sol_*.c`) and prints `WRAPS on the
  badge` for any label that would wrap.
- **128 UI objects** (the app uses 125) and **200 locals** in main.lua's main chunk:
  group new state in tables. A label's text can fail "low on memory" (SRAM): toasts and
  the picker go through `pcall`.

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

Times in `KEYS` and `SHOT_MS` must be multiples of the 30 ms tick (9000 and 1500, not
10000 and 1000), or they never happen. `STORE='{"follow": "..."}'`
presets the app's storage; `EXTRA=file` adds "ms {json}" messages to a ws replay.
Live, against a real relay (`DEV_NO_TICKET=1 PORT=8090 bun server.ts`, or `npx wrangler
dev --port 8788 --var DEV_NO_TICKET:1` in `worker/`): `SECONDS=40 KEYS=... python3
tools/bench.py main.lua live ws://localhost:8090/live out` (needs `websockets`); what
the app sends goes to the relay, and the run prints it.

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

2026-11-14, Run on badge from /apps/submit (official 2.1.0, test run): the Wi-Fi path
works (the badge's ws reaches the relay with its ticket, the relay counts it). The app
then saturated the CPU (watchdog every 5 s, LIVE ~14 ticks/s, SCHEDULE ~8): the chart
slid a 17 kpx canvas ~12 times a second, the schedule slid its 64 kpx list over five
frames per leader, the carousel slid too. Fixed (chart steps once a slot, list and
carousel jump, cells at 10 Hz, countdown tenths < 10 s): LIVE 440 -> 171 kpx/s, CPU
~65%, 25 ticks/s; SCHEDULE 370 -> 179 kpx/s, ~69%, 25 ticks/s; VALIDATOR ~49%, 30
ticks/s; no watchdog on the official firmware. Internal SRAM is tight while it runs
(~37 KB free): once, with `top` started first, `label:text` failed "low on memory".
The badge still has the app's first version `galaxy-live` on its card (`lua rm`).

2026-11-15, UI pass (simulator with the badge's fonts, and live against the relay, Bun
and `wrangler dev`): SCHEDULE pauses while a slot is selected (it kept moving a card
each leader), SELECT there follows that slot's leader; VALIDATOR redone (name, rank,
version, country, stake, commission, skip rate, blocks, timeline, countdown, last 16
blocks) with SELECT for a list (default, last chosen, top 20 by stake); the choice is
kept on the card (`storage`: follow, recent, defname) and sent as `?v=` on connect; a
strip on top says which view; connection states in their own label (they wrapped in
the TPS one). Simulator screen cost: LIVE 4.2 kpx a tick, SCHEDULE navigating 2.5
(was 6.1), VALIDATOR 3.9 (was 5.2). Not yet on the badge.

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

Step 1, done (2026-11-14, owner's badge, hotel Wi-Fi at -77 dBm, 2.4 GHz):
`fdbench [seconds]` (console) connects with `compress-zstd`, reads and discards, and
prints each second KB/s, messages, heap, RSSI, the TCP window and (in a build with
FreeRTOS run-time stats) how busy the CPU was and its three busiest tasks.

| Build | Steady rate | CPU busy | Internal RAM free |
|---|---|---|---|
| `sdkconfig.defaults` (TCP window 2880) | ~255 KB/s, ~350 msgs/s: falls behind | not measured | 132 KB |
| + `sdkconfig.fdbench` (window 32 KB) | keeps up (~410-450 KB/s) | 85-100% (fdbench ~50, wifi ~20, tcpip ~13) | 128 KB |
| + `sdkconfig.fdbench-fast` (Wi-Fi/lwIP IRAM, A-MPDU RX) | keeps up | 70-80% (fdbench ~50, wifi ~11, tcpip ~8) | ~92 KB |

The Mac on the same Wi-Fi got ~410 KB/s, ~530 msgs/s. The 2880-byte window was the
limit (2880 B per ~11 ms round trip to Cloudflare).

Where the fdbench task's time goes (fast build; `fdbench N store|discard|raw`, CPU per
100 KB/s over the seconds at >= 350 KB/s; Cloudflare picks ECDHE-ECDSA-AES128-GCM-SHA256):
store (each message whole in PSRAM) 7.1 / 9.8-10.3%, discard (read, keep nothing) 6.5%,
raw (TLS bytes in 16 KB reads, no framing) 7.2 / 9.6%; wifi+tcpip 3.4-4.2%. The two
figures are two sessions: within one, the modes match, between them the level moves.
So copying and framing cost next to nothing: receiving the TLS stream is the cost.
`fdbench aes` (PSA AES-128-GCM, 16 KB records): 1993 KB/s in PSRAM (where TLS buffers
are), 2990 KB/s in internal RAM: 22% / 15% of the CPU at 450 KB/s (wall time, an upper
bound). At the dashboard's ~450 KB/s a client costs ~50-70% of the CPU; the UI, zstd
and JSON for the wanted topics get the rest. TLS buffers in internal RAM would save
~7 points for ~16 KB of SRAM.

Test builds (separate build dirs, the badge's config untouched; `sdkconfig.stats` is the
shipped config plus run-time stats, for `top`):
`idf.py -B build-fdbench-fast -D SDKCONFIG=build-fdbench-fast/sdkconfig -D
"SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.fdbench;sdkconfig.fdbench-fast" build`
(quote the list: unquoted, zsh hands idf.py one argument). Flash at 230400 baud: the
CH340 drops reads at 460800. `tools/badge.py` doesn't read during `sleep`: for long
output, read the port in a loop (opening it resets the badge on macOS).

Backup: `~/badge-backup/badge-backup.bin` on the owner's Mac (16 MB, sha256
0cfe48b2...455f). It shows the official 2.1.0 in `ota_1` (booted) and 2.0.0 in `ota_0`;
the test builds go to `ota_0` (`write_flash 0xF000 ota_data_initial.bin 0x20000 ...`).
Back to the official firmware: write the backup's 8 KB at 0xF000 (the otadata, which
boots `ota_1`); the whole file only if something else broke.

If the badge keeps up: port `core.ts` to C behind a Lua module (streaming zstd, a
streaming JSON reader for the 370 KB epoch and the multi-MB peers messages), so
`main.lua` gets the same `f` / `w` / `info` / `slot` messages. If not: keep the
relay.
