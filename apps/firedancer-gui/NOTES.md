# Firedancer GUI: design notes

How `main.lua` works and why it is drawn the way it is, moved out of its comments (the
store takes at most 64 KB of source a file). The README says what the app shows.

## What the app shows

Firedancer on the badge: a badge-sized take on the Firedancer dashboard, fed by one
(gui.firedancer.io by default) through a relay. It follows one validator: the
dashboard's own unless another is chosen (VALIDATOR, or a slot in SCHEDULE, then
SELECT), which the badge keeps. LEFT / RIGHT change view; the strip on top says which.

**LIVE**

- Leader carousel: five leader windows, the past on the left, the future on the right, the current one framed in teal. Each card shows the leader and its four slots: the slot being made fills up as it happens, then turns blue (completed), dark teal (notarized) and teal (rooted), or pink if skipped. The cards move one place left when the next leader takes over. The followed validator's cards are orange.
- TX / SLOT: one bar per slot of the cluster, a step left with each slot.
- Validator panel: its stake, rank, an epoch ring, the countdown to its next window; while it is leader, its transactions and fees as they come.

**SCHEDULE**

- The leader schedule after the dashboard's: the next leaders, the current one in a teal frame, then the past ones, each with its four slots (state, transactions, fees, tips, time, compute used). UP / DOWN pick a slot: the list stops there and a panel shows the slot in full; SELECT follows its leader. UP past the newest, BACK, another view or a minute without a key, and it follows live again.

**VALIDATOR**

- The followed validator: name, rank, version, stake, commission, skip rate, blocks made this epoch, its next windows on a 10-minute timeline, the countdown to the next one, its last 16 blocks (transactions each). SELECT: a list to follow another (the default, the last ones chosen, the 20 biggest by stake).

LEDs: while the validator is leader the six top LEDs fill slot by slot (orange to
teal, red for a skip), then flash and fade. The side LEDs breathe as its next
window comes and, in "full" mode, tick with every slot of the cluster.
SELECT in LIVE: LED mode (full / validator only / off). CANCEL: exit.

Data: the relay (server.ts or worker/), over a WebSocket: "f" ten times a second
(the slot and the TPS), "w" for a leader window whenever it changes, "info" every
2 s. The badge says whom it follows ("follow", core.ts).

Speed. on_tick runs every 30 ms, and on the badge the screen costs ~1.4 us a pixel
redrawn (measured with this app: 1.0 to 1.7 by view) plus ~1 ms an area, all on the
one CPU the app shares. So nothing is redrawn unless it changed and nothing big
moves: what changes on its own (the slot being made, the spinning icons) lives in
small canvases of its own, redrawn at most ten times a second (the carousel's slot
cells every tick since 1.0.3: a cell is 264 pixels, and at 10 Hz a 215 ms slot filled
in two steps); big canvases are
redrawn once a slot or when their picture changes, never to animate a slide; labels,
colours and LEDs are set only when they change, and countdowns show tenths only in
their last 10 s. Each view stays under ~200,000 pixels a second (~70% of the CPU).
Drawing into a canvas is Lua's own cost: ~50 us a call (rect, pixel, image), whatever
its size, plus ~0.14 us a pixel; a label's new text ~1 ms. So the chart is a conveyor
that draws only new bars, a card's slots are redrawn one by one, the schedule's
backgrounds only when they look different, and text only when it changes.
Labels wrap at their width, and the fonts aren't monospaced: names are cut where they
fit (fit). The badge holds 128 objects: this app uses 127.

Numbers: a badge has 32-bit integers and 32-bit floats. Slot numbers (469 million)
stay integers; only differences between slots ever become floats.

## LIVE: the leader carousel

Leader carousel: per card, a canvas for its frame (redrawn when the leader moves)
and a small one for its four slots, so a slot filling up redraws 52 x 24 pixels,
not the card. The cards' transaction bars grow as their slots come: they are one
see-through 320 x 2 strip over the cards, not five frames redrawn.

## LIVE: the TX / SLOT chart

transactions per slot: one bar per slot, 5 px a slot, a step left as each slot is
made. On the badge each canvas call costs ~50 us whatever its size (a pixel 0.14 us):
redrawing the 66 bars each slot took ~30 ms, 4.5 times a second. So the chart is a
conveyor: a canvas twice the screen's width that moves 5 px left each slot, where
only the new bar and the bars whose data changed are drawn; it is drawn whole only
when it runs out (every ~62 slots) or the scale changes. Moving it redraws the same
screen area as before. Its top 12 rows hold only the labels: the canvas starts below.

## SCHEDULE

SCHEDULE view, after the Firedancer dashboard's leader schedule: the next leaders
on top, the current one in a teal frame, then the past ones, newest first, each with
its four slots (state, transactions, fees, tips, time, compute used). The list moves
down a card as each leader takes over. UP / DOWN pick a slot, one at a time: the list
stops there (new leaders wait) and a panel at the bottom shows the slot in full;
SELECT follows its leader. UP past the newest slot, BACK, a minute without a key or
another view, and it follows live again.
The cards' backgrounds are one canvas, redrawn only when the list moves; each card's
state icons are a small canvas of their own (a spinning icon redraws 9 x 48 pixels);
the text is labels, a column of four lines each. Three cards' labels are enough: no
more fit on screen.

## SCHEDULE: UP / DOWN

UP / DOWN in the schedule: a row at a time, as the screen shows them. The cards go
back in time downwards but each lists its four slots in order, so DOWN is the next
slot within a card, then the first slot of the older card below. UP past the newest
slot made, or BACK, follows live again. While a slot is selected the list stays as
it was: new leaders wait.

## Messages: the inbox

Messages wait for the next tick, and only what still matters is read then: the
newest frame, the newest info, the newest version of each window; slots, lists and
the answer to a choice keep their order. When the link stalls and then delivers ten
seconds at once, reading every message kept the CPU busy past the watchdog (5 s).

## Wi-Fi: the keepalive

Twice a second the badge sends the relay "{}" (it ignores it). The badge's Wi-Fi
sleeps between the access point's beacons unless something keeps it busy; asleep,
it now and then lost packets and the relay's TCP backed off: no data for 8 to 25 s,
then all of it at once (5 runs of 6, 4 minutes each). Bluetooth on had hidden it.
Sending wakes the radio, and the waiting packets come with it: 0 stalls in 8 minutes.
