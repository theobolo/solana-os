# Solana OS (badge firmware) and Firedancer GUI

This repository is the firmware of the Solana Breakpoint 2026 badge (ESP32-C5, see
`README.md`). The owner's project lives in `apps/firedancer-gui/`: a Firedancer
dashboard on the badge. The owner writes in French; answer in French.

## What exists (all on branch `claude/solana-breakpoint-badge-mod-llhnwp`)

Published in the badge App Store (listed, Tools): 1.0.0 on 2026-11-15, then 1.0.1 (the
Wi-Fi keepalive), approved by an organiser after the automatic check flagged it. A new
version goes through `/apps/submit?id=firedancer-gui` ("Edit your app"): load
`dist/firedancer-gui.zip`, bump `version` in app.json first.

- `apps/firedancer-gui/main.lua`, `app.json`: the badge app "Firedancer GUI" (id
  `firedancer-gui`). Three views (LIVE, SCHEDULE, VALIDATOR), LEDs. Data comes as
  messages `f` (slot, TPS, 10 Hz), `w` (one leader window in full), `info`, `slot`,
  `list`: JSON over Wi-Fi (`ws`). Store zip for /apps/submit: `dist/firedancer-gui.zip`.
- `core.ts`: the relay's logic (`Relay`) and the badges' sockets (`Hub`). Hosts:
  `worker/` (Cloudflare Worker + Durable Object, deployed at
  `firedancer-gui-relay.theo-b59.workers.dev`) and `server.ts` (Bun). It follows
  `wss://gui.firedancer.io/websocket` (Jump's dashboard). Each badge follows one
  validator: by default the dashboard's own (or `IDENTITY` / `VOTE`), else the one it
  asks for (`/live?v=<identity>`, or the messages `follow` and `list`, top of core.ts).
- `NOTES.md`: how main.lua works and why it draws the way it does (its long comments
  live there: the store takes at most 64 KB of source a file; main.lua is ~57 KB). A
  split into modules (`kit`, `schedule`, `validator`) is on the local branch
  `wip/firedancer-modules`: pixel-identical, but ~+0.5% CPU on SCHEDULE measured on the
  badge, so not shipped.
- `tools/`: tests (below).
- Removed 2026-11-15 (the owner won't use it; in git history before that date): the
  Bluetooth path for an app outside the store (`worker/src/install.html`, a Chrome page
  installing over USB and relaying over Bluetooth; `android/`, the same as an Android
  app; `/phone`, `/install`, the APK route; the binary packers and their tests).
- `main/core/console.c`: an added console command, `fdbench` (see "Next").

Why a relay: the badge's `ws` closes on any message over 4 KB
(`OS_SOCKET_MSG_MAX`, `main/core/os_socket.h`), and the dashboard sends megabytes.
An app that is not in the badge's store (nor in a "test run") is refused every
server-mediated call, `ws` included (`"denied"`): it shows "Wi-Fi denied".

## Rules learned the hard way

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
- **Lua's own drawing cost, on the badge** (2026-11-15): a canvas call (`rect`, `pixel`,
  `image`, `clear`) ~50 us whatever its size, plus ~0.14 us a pixel; a label's new text
  ~1 ms; decoding and reading a message 0.5 (`f`) to 5 ms (`info`), ~4% of the CPU in all.
  The simulator charges only VM instructions and screen pixels, not this: profile on the
  badge (a copy of main.lua that sums `sys.millis()` by section of `on_tick` over 5 s and
  prints it). Count calls, not pixels: the chart is a conveyor canvas (2x the screen,
  moved 5 px a slot, only new or changed bars drawn), carousel cells redraw one by one,
  schedule backgrounds only when their look changes. LIVE Lua 261 -> 153 ms/s, 25 -> 28
  ticks/s; SCHEDULE 244 -> 167; VALIDATOR 124 -> 108.
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
- **128 UI objects** (the app uses 127) and **200 locals** in main.lua's main chunk
  (176 used; the badge's compiler counts a top-level `for` loop's hidden locals too and
  refused a copy at 197 + one loop that the simulator ran): group new state in tables. A label's text can fail "low on memory" (SRAM): the `L`
  wrapper, toasts and the picker go through `pcall`. Bluetooth would take ~30 KB of that
  SRAM (with it on, the diagnostic build stopped the app with "label:text: low on
  memory"): the app no longer uses it.
- **The badge's Wi-Fi sleeps** (modem sleep, `WIFI_PS_MIN_MODEM`, `main/core/os_radio.c`)
  unless something keeps it busy; no Lua API changes that. Asleep on the hotel Wi-Fi it
  lost packets now and then and the relay's TCP backed off: no data for 8 to 25 s, then
  a burst (5 runs of 6 without Bluetooth, 0 of 3 with it on: Bluetooth had hidden it).
  The relay's own feed never stalled (`/status` polled meanwhile). main.lua sends "{}"
  every 500 ms; 2 runs of 4 minutes: no stall over 2 s.
- **Bursts after a stall**: the link (hotel Wi-Fi, -77 dBm) sometimes stalls 8 to 25 s,
  then delivers it all at once. Reading every message then kept the CPU busy past the
  task watchdog (5 s, official firmware). main.lua queues messages (`post`) and reads
  each tick only the newest frame, info and version of each window (`drain`); a 238-
  message burst then cost one 5 s window at ~15 ticks/s, no watchdog. The prefix match
  needs the relay's compact JSON (`JSON.stringify`); anything else is read in order.
- **Badge screenshots** (`tools/badge.py ... "shot"`) take ~20 s over serial and stall the
  app meanwhile: LIVE then shows "no data" in its header. Not a relay gap (measured).

## Testing without a badge (`apps/firedancer-gui/tools/`)

Needs Python with `lupa`, `pillow` (`uv run --with lupa --with pillow python3 ...`); Bun.

```sh
cd apps/firedancer-gui
# record 45 s from a local relay (or use tools/sample.jsonl)
DEV_NO_TICKET=1 PORT=8080 bun server.ts &            # then:
bun tools/record.ts rec.jsonl
python3 -c "import json;[print(json.loads(l)['at'], l.strip()) for l in open('rec.jsonl') if l.strip()]" > rec.ws
# run main.lua in a simulator of the screen, then the screen-cost report
mkdir out && KEYS="6000:right,20010:down,30000:back,33000:right" SHOT_MS=1500 \
  python3 tools/bench.py main.lua ws rec.ws out
python3 tools/report.py out       # ms of screen per tick, by phase of that key scenario
```

Times in `KEYS` and `SHOT_MS` must be multiples of the 30 ms tick (9000 and 1500, not
10000 and 1000), or they never happen. `STORE='{"follow": "..."}'`
presets the app's storage; `EXTRA=file` adds "ms {json}" messages to a ws replay.
Live, against a real relay (`DEV_NO_TICKET=1 PORT=8090 bun server.ts`, or `npx wrangler
dev --port 8788 --var DEV_NO_TICKET:1` in `worker/`): `SECONDS=40 KEYS=... python3
tools/bench.py main.lua live ws://localhost:8090/live out` (needs `websockets`); what
the app sends goes to the relay, and the run prints it.

`bench.py` writes `out/<mode>_NN.png` screenshots and pickles.

## Deploying

```sh
cd apps/firedancer-gui/worker && npx wrangler deploy          # the relay
cd .. && zip -j dist/firedancer-gui.zip main.lua app.json      # what /apps/submit takes
```

- Cloudflare: `npx wrangler login` on this machine (the cloud session used an API
  token that is not here). Account subdomain `theo-b59`, plan Workers Paid.
- Left on Cloudflare after the phone path went (ask the owner before deleting): the
  Worker secret `PHONE_KEY` and the KV namespace `firedancer-gui-files` with the old
  `firedancer-gui.apk` (no longer bound to the Worker).
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
(was 6.1), VALIDATOR 3.9 (was 5.2).

2026-11-15, redraw pass (same picture): carousel frames only for a new leader, the tx
bars in one 320x2 strip, the chart 12 rows shorter, the schedule's countdowns in their
own labels, the list jumps, a paused list isn't redrawn per leader, the timeline every
2 s, Bluetooth only when needed. On the badge (`top`, diagnostic build, Wi-Fi):
LIVE 59% CPU / 135 kpx/s (was ~65% / 171), SCHEDULE 65% / 140 (was ~69% / 179),
SCHEDULE paused 30% / 15, VALIDATOR 31% / 33 (was ~49%). Then the Bluetooth path was
removed (the owner's call).

The Wi-Fi path needs the badge server's ticket: the store, or a test run from
`/apps/submit` ("Run on badge", desktop Chrome, 12 h). `tools/badgeput.py` copies a
new main.lua onto a badge that has the app; it runs with Wi-Fi while a test run lasts.

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
