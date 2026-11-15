-- Firedancer on the badge: a badge-sized take on the Firedancer dashboard, fed by one
-- (gui.firedancer.io by default) through a relay. It follows one validator: the
-- dashboard's own unless another is chosen (VALIDATOR, or a slot in SCHEDULE, then
-- SELECT), which the badge keeps. LEFT / RIGHT change view; the strip on top says which.
--
-- LIVE
--   Leader carousel: five leader windows, the past on the left, the future on the
--   right, the current one framed in teal. Each card shows the leader and its four
--   slots: the slot being made fills up as it happens, then turns blue (completed),
--   dark teal (notarized) and teal (rooted), or pink if skipped. The cards move one
--   place left when the next leader takes over. The followed validator's cards are orange.
--   TX / SLOT: one bar per slot of the cluster, a step left with each slot.
--   Validator panel: its stake, rank, an epoch ring, the countdown to its next
--   window; while it is leader, its transactions and fees as they come.
-- SCHEDULE
--   The leader schedule after the dashboard's: the next leaders, the current one in
--   a teal frame, then the past ones, each with its four slots (state, transactions,
--   fees, tips, time, compute used). UP / DOWN pick a slot: the list stops there and a
--   panel shows the slot in full; SELECT follows its leader. UP past the newest, BACK,
--   another view or a minute without a key, and it follows live again.
-- VALIDATOR
--   The followed validator: name, rank, version, stake, commission, skip rate, blocks
--   made this epoch, its next windows on a 10-minute timeline, the countdown to the
--   next one, its last 16 blocks (transactions each). SELECT: a list to follow another
--   (the default, the last ones chosen, the 20 biggest by stake). Needs Wi-Fi.
--
-- LEDs: while the validator is leader the six top LEDs fill slot by slot (orange to
-- teal, red for a skip), then flash and fade. The side LEDs breathe as its next
-- window comes and, in "full" mode, tick with every slot of the cluster.
-- SELECT in LIVE: LED mode (full / validator only / off). CANCEL: exit.
--
-- Data: the relay (server.ts or worker/), over Wi-Fi (a WebSocket) or through a
-- phone over Bluetooth: "f" ten times a second (the slot and the TPS, 9 bytes over
-- Bluetooth), "w" for a leader window whenever it changes, "info" every 2 s. Over
-- Wi-Fi the badge says whom it follows ("follow", core.ts); a phone relays the default.
--
-- Speed. on_tick runs every 30 ms, and on the badge the screen costs ~1.4 us a pixel
-- redrawn (measured with this app: 1.0 to 1.7 by view) plus ~1 ms an area, all on the
-- one CPU the app shares. So nothing is redrawn unless it changed and nothing big
-- moves: what changes on its own (the slot being made, the spinning icons) lives in
-- small canvases of its own, redrawn at most ten times a second; big canvases are
-- redrawn once a slot or when their picture changes, never to animate a slide; labels,
-- colours and LEDs are set only when they change, and countdowns show tenths only in
-- their last 10 s. Each view stays under ~200,000 pixels a second (~70% of the CPU).
-- Labels wrap at their width, and the fonts aren't monospaced: names are cut where they
-- fit (fit). The badge holds 128 objects: this app uses 124.
--
-- Numbers: a badge has 32-bit integers and 32-bit floats. Slot numbers (469 million)
-- stay integers; only differences between slots ever become floats.

local RELAY = "wss://firedancer-gui-relay.theo-b59.workers.dev/live"   -- your relay; its host goes in app.json "hosts"

---------------------------------------------------------------------------------
-- Colours and helpers

local BG, PANEL, PANEL_HI, BORDER = 0x000000, 0x111116, 0x1C1B26, 0x2A2935
local GREEN, PINK, BLUE, AQUA = 0x14F195, 0xEB54BC, 0x64A8F2, 0x80ECFF
local TEAL, TEAL_DARK = 0x1FC9A9, 0x12907F     -- Firedancer's teal
local OURS, OURS_BG, OURS_TXT, OURS_HI = 0xFF7A30, 0x2B1706, 0xFFB36B, 0xFFE08A   -- the followed validator: fire orange
local STATE = { [2] = BLUE, [3] = TEAL_DARK, [4] = TEAL, [5] = PINK }
local DOT = " \u{2022} "         -- the badge's fonts have this bullet, not the middle dot

local function mix(a, b, t)      -- blend two 0xRRGGBB colours, t in 0..1
  local function ch(s) return ((a >> s) & 255) + (((b >> s) & 255) - ((a >> s) & 255)) * t end
  return (math.floor(ch(16)) << 16) | (math.floor(ch(8)) << 8) | math.floor(ch(0))
end
local GRAD = {}                  -- fire to teal, in 64 steps
for i = 0, 63 do GRAD[i] = mix(OURS, TEAL, i / 63) end
local function grad(t) return GRAD[math.floor((t < 0 and 0 or t > 1 and 1 or t) * 63 + 0.5)] end

local function big(n)
  if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fK", n / 1000) end
  return tostring(math.floor(n))
end
local function grouped(n)
  local s = tostring(math.floor(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^ ", ""))
end
local function dur(sec)        -- tenths only in the last 10 s: each change redraws the label
  if sec >= 60 then return string.format("%dm%02ds", sec // 60, math.floor(sec % 60)) end
  if sec >= 10 then return string.format("%ds", math.floor(sec)) end
  return string.format("%.1fs", sec)
end

-- The badge's fonts' widths, " " to "~" (main/assets/sol_*.c, a character's code - 48
-- each), so a name can be cut where it fits: a label wraps what is wider than its width.
local ADV = {
  [12] = "55677875556756567677777777557777888887788577798878877889777565675777776775575977776767787766567",
  [14] = "34598;93446835369588888788338987;:9::98::4898=;;9;998:9>988464784788884883373<888857587;7765458",
  [20] = "557=<?=4668;5858<8<<<<<;<<55;<;:@>=??<<??6;=;C??=?==<>=D=<<686:<6:<;<;7<;55:5A;;<<7:7;:@::9757<",
}
local function fit(s, size, px)  -- the longest start of s (ASCII) that is at most px wide
  local a, w = ADV[size], 0
  for i = 1, #s do
    local c = s:byte(i)
    w = w + ((c >= 32 and c <= 126) and (a:byte(c - 31) - 48) or (c >= 0x80 and c < 0xC0) and 0 or 9)   -- the bullet: 9
    if w > px then return s:sub(1, i - 1) end
  end
  return s
end

-- Internal RAM is tight while the app runs (~37 KB free, measured): a call that would
-- leave the badge under 32 KB raises "low on memory". A toast, or a list's text, can
-- wait; the app shouldn't stop for it.
local function toast(s) pcall(ui.toast, s) end

-- Objects that touch the screen only when something changes.
local function L(x, y, text, o)
  local l = ui.label(x, y, text, o)
  return { o = l, t = text,
    text = function(self, s) if self.t ~= s then self.o:text(s) self.t = s end end,
    color = function(self, c) if self.c ~= c then self.o:color(c) self.c = c end end,
    pos = function(self, px, py) if self.x ~= px or self.y ~= py then self.o:pos(px, py) self.x, self.y = px, py end end,
    show = function(self, b) if self.vis ~= b then self.o:show(b) self.vis = b end end }
end
local function R(x, y, w, h, o)
  local r = ui.rect(x, y, w, h, o)
  return { o = r,
    color = function(self, c) if self.c ~= c then self.o:color(c) self.c = c end end,
    show = function(self, b) if self.vis ~= b then self.o:show(b) self.vis = b end end }
end
local function C(x, y, w, h, o)  -- a canvas that knows where it is
  local c = ui.canvas(x, y, w, h, o)
  return { o = c, x = x, y = y,
    pos = function(self, px, py) if self.x ~= px or self.y ~= py then self.o:pos(px, py) self.x, self.y = px, py end end,
    show = function(self, b) if self.vis ~= b then self.o:show(b) self.vis = b end end }
end

---------------------------------------------------------------------------------
-- State from the relay

local info = nil
local est, sd = 0, 400           -- the relay's estimated slot, ms per slot
local pbase, pat = 0, 0          -- our slot clock: slots past `est` at time `pat` (a small float)
local live = false
local lastMsg, lastBle = -10000, -10000
local win = { on = false, tx = 0, fee = 0, skip = false }   -- the validator's window in progress
local blocks = {}                -- the validator's last 16 slots: {tx, skipped}
local slotTx = {}                -- slot -> {ok, fail, ours, skipped}, for the chart
local tickAt = -1000             -- when the cluster last moved to a new slot
local tpsOk, tpsFail = 0, 0

-- The followed validator: the relay's default (the dashboard's own) unless one was
-- chosen (SELECT in VALIDATOR, or on a slot in SCHEDULE). The choice is kept on the card.
local fol = {
  id = storage.get("follow"),                  -- the chosen identity, nil for the default
  recent = storage.get("recent"),              -- the last ones chosen: { {id, name}, ... }
  defName = storage.get("defname"),            -- the default one's name
  cur = nil, def = true,                       -- whom the relay says we follow, and if it's its default
  asked = nil, n = 0,                          -- a choice on its way to the relay: its number
}
if type(fol.id) ~= "string" then fol.id = nil end
if type(fol.recent) ~= "table" then fol.recent = {} end
if type(fol.defName) ~= "string" then fol.defName = nil end
local sock, sockOpen = nil, false

-- Leader windows, from the relay's "w" messages: start -> record
--   { s = start, n = name, o = 1 if ours, k = stake (SOL), c = country,
--     d = { four slots: { state, tx, failed, fees, tips, ms, CU % } },
--     cells = "4421" (the states), tx = all four slots' tx, ver = bumped on each change }
local wins, winOrder, ghosts = {}, {}, {}
local WIN_KEEP = 24              -- 16 for the chart's 64 slots, 8 for the schedule, the 2 next
local EMPTY = { 0, 0, 0, 0, 0, 0, 0 }
local winVer = 0                 -- bumped when a window comes or changes
local function winAt(s)          -- a window, or a stand-in until it comes
  local w = wins[s] or ghosts[s]
  if w then return w end
  w = { s = s, n = "", o = 0, k = 0, c = "", d = { EMPTY, EMPTY, EMPTY, EMPTY }, cells = "0000", tx = 0, ver = 0, ghost = true }
  ghosts[s] = w
  return w
end

-- The relay says which slot it is about ten times a second, over a link that
-- delivers in bursts. Our own clock runs at the cluster's pace and is nudged
-- toward the relay's, so what moves on screen moves steadily.
local function phase(now)
  local p = pbase + (now - pat) / sd
  if p < 0 then p = 0 elseif p > 1.95 then p = 1.95 end
  return p
end
local function newSlot(e, now)
  if est == 0 or e < est or e - est > 8 then
    pbase = 0
  else
    local p = pbase + (now - pat) / sd - (e - est)   -- where our clock puts us in the new slot
    if p > 1.5 or p < -1.5 then p = 0 else p = p * 0.7 end
    pbase = p
  end
  pat, est = now, e
end

---------------------------------------------------------------------------------
-- Header

ui.bg("bg")
local pager = C(0, 0, 320, 2, { color = BORDER })   -- the top strip, a part a view: the current one in teal
ui.image(6, 5, {                 -- a flame, for Firedancer
  "......t......",
  ".....tt......",
  ".....ttt.....",
  "....tttt.....",
  "...ttttt..t..",
  "...tttttt.tt.",
  "..ttttttttttt",
  ".tttttttttttt",
  ".ttttoottttt.",
  "tttttooottttt",
  "ttttoooootttt",
  "ttttoooooottt",
  ".tttoooooottt",
  ".ttttoooottt.",
  "..tttttttttt.",
  "....tttttt...",
}, { palette = { t = TEAL, o = OURS } })
ui.label(24, 4, "FIREDANCER", { size = 20 })
local dot = R(156, 12, 6, 6, { color = "dim", radius = 3 })
local tpsL = L(216, 3, "", { size = 20, w = 62, align = "right" })
local tpsU = L(282, 10, "TPS", { size = 12, color = "dim" })
local statusL = L(216, 9, "", { size = 12, color = "orange", w = 96, align = "right" })   -- instead, while no data comes
statusL:show(false)
local function status(text)      -- nil: data comes, show the TPS
  tpsL:show(text == nil) tpsU:show(text == nil) statusL:show(text ~= nil)
  if text then statusL:text(fit(text, 12, 96)) end
end
local DOTC = {}                  -- the live dot's pulse, 12 steps
for i = 0, 11 do DOTC[i] = mix(0x0A4A40, TEAL, (math.sin(i / 12 * 2 * math.pi) + 1) / 2) end

local views = { live = {}, schedule = {}, validator = {} }
local ORDER = { "live", "schedule", "validator" }
local function V(name, o) local t = views[name] t[#t + 1] = o return o end

---------------------------------------------------------------------------------
-- LIVE view

-- Leader carousel: per card, a canvas for its frame and a small one for its four
-- slots, so a slot filling up redraws 52 x 24 pixels, not the card or the strip.
local CAR_Y, PITCH, CW, CH = 27, 65, 60, 72
local cards = {}
for k = 1, 5 do
  local x = (k - 1) * PITCH
  local c = { x = x }
  c.cv = V("live", C(x, CAR_Y, CW, CH, { color = "bg" }))
  c.cells = V("live", C(x + 4, CAR_Y + 20, 52, 24, { color = "bg" }))
  c.name = V("live", L(x + 4, CAR_Y + 4, "", { size = 12, color = "dim", w = CW - 4 }))
  c.tx = V("live", L(x + 4, CAR_Y + 46, "", { size = 12, color = "dim", w = CW - 4 }))
  cards[k] = c
end

-- transactions per slot: one bar per slot, 5 px a slot, a step left as each slot is
-- made. Drawn once a slot: on the badge the screen costs ~1.4 us a pixel, and sliding
-- this 17,000-pixel strip a pixel at a time took half of the LIVE view's CPU.
local CHART_Y, CHART_H, SLOT_W = 104, 54, 5
local chart = V("live", C(0, CHART_Y, 320, CHART_H, { color = "bg" }))
local chartMax, chartKey, chartTop = 1000, nil, nil
V("live", L(6, CHART_Y + 1, "TX / SLOT", { size = 12, color = "dim" }))
local maxL = V("live", L(240, CHART_Y + 1, "", { size = 12, color = "dim", w = 74, align = "right" }))

-- Validator panel. Its frame is four thin strips: when it pulses, the screen redraws
-- the strips, not the whole panel.
local PY = 162
local frameR = {
  V("live", R(3, PY - 1, 314, 2, { color = OURS })), V("live", R(3, PY + 53, 314, 2, { color = OURS })),
  V("live", R(3, PY - 1, 2, 56, { color = OURS })), V("live", R(315, PY - 1, 2, 56, { color = OURS })),
}
local frameC = OURS
local function frameColor(c)
  if c == frameC then return end
  frameC = c
  for i = 1, 4 do frameR[i]:color(c) end
end
V("live", ui.rect(5, PY + 1, 310, 52, { color = "panel" }))
local nameL = V("live", L(12, PY + 4, "VALIDATOR", { size = 12, color = "dim", w = 126 }))
local stakeL = V("live", L(12, PY + 16, "-", { size = 20, color = TEAL }))
local subL = V("live", L(12, PY + 38, "", { size = 12, color = "dim", w = 126 }))
local RING = 44
local ring = V("live", C(142, PY + 5, RING, RING, { color = "panel" }))
local pctL = V("live", L(142, PY + 20, "", { size = 12, w = RING, align = "center" }))
local capL = V("live", L(196, PY + 4, "NEXT LEADER", { size = 12, color = "dim" }))
local cdL = V("live", L(196, PY + 16, "", { size = 20, color = TEAL, w = 116 }))
local cdSub = V("live", L(196, PY + 38, "", { size = 12, color = "dim", w = 116 }))
local PULSE_L, PULSE_P = {}, {}  -- the frame's pulses, 8 steps each
for i = 0, 7 do
  local t = (math.sin(i / 8 * 2 * math.pi) + 1) / 2
  PULSE_L[i], PULSE_P[i] = mix(OURS, OURS_HI, t), mix(OURS, PINK, t)
end

-- the ring's pixels, worked out once: {x, y, angle 0..1 from the top, clockwise}
local ringPx = {}
do
  local c, r1, r2 = (RING - 1) / 2, 16.5, 21.5
  for y = 0, RING - 1 do
    for x = 0, RING - 1 do
      local dx, dy = x - c, y - c
      local d = math.sqrt(dx * dx + dy * dy)
      if d >= r1 and d <= r2 then
        local a = math.atan(dx, -dy) / (2 * math.pi)
        if a < 0 then a = a + 1 end
        ringPx[#ringPx + 1] = { x, y, a }
      end
    end
  end
end
local ringPct = nil
local function drawRing(pct)
  if pct == ringPct then return end
  ringPct = pct
  local t = pct / 100
  for _, p in ipairs(ringPx) do
    ring.o:pixel(p[1], p[2], p[3] <= t and grad(p[3]) or BORDER)
  end
end

---------------------------------------------------------------------------------
-- SCHEDULE view, after the Firedancer dashboard's leader schedule: the next leaders
-- on top, the current one in a teal frame, then the past ones, newest first, each with
-- its four slots (state, transactions, fees, tips, time, compute used). The list moves
-- down a card as each leader takes over. UP / DOWN pick a slot, one at a time: the list
-- stops there (new leaders wait) and a panel at the bottom shows the slot in full;
-- SELECT follows its leader. UP past the newest slot, BACK, a minute without a key or
-- another view, and it follows live again.
-- The cards' backgrounds are one canvas, redrawn only when the list moves; each card's
-- state icons are a small canvas of their own (a spinning icon redraws 9 x 48 pixels);
-- the text is labels, a column of four lines each. Three cards' labels are enough: no
-- more fit on screen.

local FD_CARD, FD_BORDER, FD_NOW, FD_NOWBG = 0x121821, 0x252B35, 0x1FC9A9, 0x0D2126
local FD_TEXT, FD_DIM, FD_UPBG, FD_RAIL_UP, FD_RAIL_PAST = 0xD0D4DA, 0x777B84, 0x0B0F16, 0x2A3240, 0x1B2433
local LIST_Y = 40
local LIST_H = ui.H - LIST_Y
local UP_H, CARD_H, GAP = 16, 76, 4
local COLS = {   -- x, width, align, title, title colour (the dashboard's)
  { 12, 64, "left", "SLOT", FD_DIM },
  { 92, 40, "right", "TX", 0x61AD6D },
  { 136, 50, "right", "FEES", 0x45B5CE },
  { 190, 50, "right", "TIPS", 0x1ED4A1 },
  { 244, 32, "right", "MS", 0xB7B8B9 },
  { 280, 32, "right", "CU", 0xCE9BFC },
}
local ICON_X = 80

local sch = V("schedule", C(0, LIST_Y, 320, LIST_H, { color = "bg" }))
local pool = {}                  -- what the cards on screen show
for i = 1, 3 do
  local c = { icons = V("schedule", C(ICON_X, LIST_Y, 9, 48)),
              name = V("schedule", L(0, 0, "", { size = 14, color = FD_TEXT, w = 156 })),
              meta = V("schedule", L(0, 0, "", { size = 12, color = FD_DIM, w = 140, align = "right" })), cols = {},
              iconKey = {} }
  for k, col in ipairs(COLS) do
    c.cols[k] = V("schedule", L(0, 0, "", { size = 12, color = k == 1 and FD_DIM or FD_TEXT, w = col[2], align = col[3] }))
  end
  pool[i] = c
end
local ups = {}                   -- the next leaders, one line each
for i = 1, 2 do
  ups[i] = { name = V("schedule", L(0, 0, "", { size = 12, color = FD_DIM, w = 150 })),
             when = V("schedule", L(0, 0, "", { size = 12, color = FD_DIM, w = 150, align = "right" })) }
end
V("schedule", ui.rect(0, 24, 320, LIST_Y - 24, { color = "bg" }))   -- what scrolls past the top slides under this
for _, col in ipairs(COLS) do
  V("schedule", ui.label(col[1], 27, col[4], { size = 12, color = col[5], w = col[2], align = col[3] }))
end

-- The selected slot in full (UP / DOWN pick one), over the bottom of the list
local PANEL_H = 64
local PANEL_Y = ui.H - PANEL_H
local panel = {}
local function P(o) panel[#panel + 1] = o return V("schedule", o) end
P(R(3, PANEL_Y, 314, PANEL_H, { color = 0x0A161A, radius = 6, border = FD_NOW }))
local pTitle = P(L(12, PANEL_Y + 4, "", { size = 12, color = FD_TEXT, w = 210 }))
local pState = P(L(222, PANEL_Y + 4, "", { size = 12, color = FD_NOW, w = 86, align = "right" }))
P(L(12, PANEL_Y + 48, "PAUSED" .. DOT .. "SELECT follow leader" .. DOT .. "BACK live", { size = 12, color = "dim", w = 300 }))
local PCOLS = {   -- x, width, title, title colour
  { 12, 44, "TX", 0x61AD6D }, { 60, 74, "FEES SOL", 0x45B5CE }, { 138, 74, "TIPS SOL", 0x1ED4A1 },
  { 216, 44, "MS", 0xB7B8B9 }, { 264, 44, "CU", 0xCE9BFC },
}
local pVal = {}
for k, c in ipairs(PCOLS) do
  P(L(c[1], PANEL_Y + 18, c[3], { size = 12, color = c[4], w = c[2] }))
  pVal[k] = P(L(c[1], PANEL_Y + 30, "", { size = 14, color = "text", w = c[2] }))
end
local function showPanel(b) for _, o in ipairs(panel) do o:show(b) end end
local STATE_NAME = { [0] = "upcoming", [1] = "in progress", [2] = "completed", [3] = "notarized", [4] = "rooted", [5] = "skipped" }

-- Slot state icons, 9 x 9 pixel art: future, being made (8 turns), completed,
-- notarized, rooted, skipped
local ICON_PAL = { t = 0x1DB9A6, n = 0x0F6E63, d = 0x3A4250, m = PINK }
local function art(rows) return ui.load(rows, { palette = ICON_PAL }) end
local CHECK = { "..ttttt..", ".ttttttt.", "tttttttkt", "ttttttktt", "tktttkttt", "ttktktttt", "tttkttttt", ".ttttttt.", "..ttttt.." }
local RINGROWS = { "..ttttt..", ".t.....t.", "t.......t", "t.......t", "t.......t", "t.......t", "t.......t", ".t.....t.", "..ttttt.." }
local function recolor(rows, from, to)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r:gsub(from, to) end
  return out
end
local function ringArt(pick)     -- the ring, each pixel coloured by its angle (0..1 from the top)
  local rows = {}
  for y = 1, 9 do
    local r = {}
    for x = 1, 9 do
      if RINGROWS[y]:sub(x, x) == "t" then
        local a = math.atan(x - 5, 5 - y) / (2 * math.pi)
        if a < 0 then a = a + 1 end
        r[x] = pick(a)
      else
        r[x] = "."
      end
    end
    rows[y] = table.concat(r)
  end
  return art(rows)
end
-- icons by number: 0 future, 2 completed, 3 notarized, 4 rooted, 5 skipped, 10..17 spinning
local ICON = {
  [0] = art(recolor(RINGROWS, "t", "d")),
  [2] = art(RINGROWS),
  [3] = art(recolor(CHECK, "t", "n")),
  [4] = art(CHECK),
  [5] = art({ "..mmmmm..", ".mmmmmmm.", "mmkmmmkmm", "mmmkmkmmm", "mmmmkmmmm", "mmmkmkmmm", "mmkmmmkmm", ".mmmmmmm.", "..mmmmm.." }),
}
for f = 0, 7 do
  ICON[10 + f] = ringArt(function(a) return (f / 8 - a) % 1 < 0.38 and "t" or "d" end)
end

---------------------------------------------------------------------------------
-- VALIDATOR view

-- Who it is, its numbers, its leader windows over the next 10 minutes, the countdown to
-- the next one, its last 16 blocks. SELECT: follow another validator.
local vv = {}                    -- its objects
vv.name = V("validator", L(8, 26, "", { size = 20, color = OURS_TXT, w = 210 }))
V("validator", ui.label(222, 32, "SELECT change", { size = 12, color = "dim", w = 90, align = "right" }))
vv.sub = V("validator", L(8, 48, "", { size = 12, color = "dim", w = 304 }))
vv.val = {}
-- BLOCKS last and widest: "14830/17072", made so far this epoch / its slots in the epoch
for k, c in ipairs({ { 8, 60, "STAKE" }, { 70, 80, "COMMISSION" }, { 156, 54, "SKIPPED" }, { 216, 98, "BLOCKS" } }) do
  V("validator", ui.label(c[1], 64, c[3], { size = 12, color = TEAL_DARK, w = c[2] }))
  vv.val[k] = V("validator", L(c[1], 76, "-", { size = 14, w = c[2] }))
end
V("validator", ui.label(8, 97, "LEADER WINDOWS" .. DOT .. "NEXT 10 MIN", { size = 12, color = TEAL, w = 304 }))
local TL_Y = 111
vv.tl = V("validator", C(0, TL_Y, 320, 26, { color = "bg" }))
V("validator", ui.label(4, TL_Y + 26, "now", { size = 12, color = "dim" }))
V("validator", ui.label(150, TL_Y + 26, "5m", { size = 12, color = "dim", w = 20, align = "center" }))
V("validator", ui.label(282, TL_Y + 26, "10m", { size = 12, color = "dim", w = 34, align = "right" }))
V("validator", ui.label(8, 155, "NEXT WINDOW", { size = 12, color = "dim" }))
vv.cd = V("validator", L(8, 167, "", { size = 32, color = TEAL, w = 156 }))
vv.slot = V("validator", L(8, 202, "", { size = 12, color = "dim", w = 156 }))
V("validator", ui.label(168, 155, "LAST 16 BLOCKS", { size = 12, color = "dim", w = 144 }))
vv.BAR_H = 44
vv.bars = V("validator", C(168, 170, 144, vv.BAR_H, { color = "bg" }))

-- Choosing the validator (SELECT in VALIDATOR): a list over the view. Its rows are two
-- labels of ten lines (a label a row would take twenty of the badge's 128 objects).
local pick = { open = false, i = 1, top = 1, items = {}, list = nil, Y = 46, ROWS = 10, LINE = 14 }
pick.objs = {
  R(0, 24, 320, ui.H - 24, { color = BG }),
  L(8, 28, "FOLLOW A VALIDATOR", { size = 12, color = TEAL, w = 200 }),
  L(8, 202, "SELECT follow" .. DOT .. "BACK close", { size = 12, color = "dim", w = 304 }),
}
pick.hi = R(4, pick.Y, 312, pick.LINE, { color = 0x22324A })
pick.names = L(10, pick.Y, "", { size = 14, w = 196 })
pick.right = L(150, pick.Y, "", { size = 14, color = "dim", w = 162, align = "right" })
pick.count = L(212, 28, "", { size = 12, color = "dim", w = 100, align = "right" })
for _, k in ipairs({ "hi", "names", "right", "count" }) do pick.objs[#pick.objs + 1] = pick[k] end
function pick.show(b)
  pick.open = b
  for _, o in ipairs(pick.objs) do o:show(b) end
end
pick.show(false)

local view = "live"
local function showView(v)
  view = v
  for name, list in pairs(views) do
    for _, o in ipairs(list) do o:show(name == v) end
  end
  local c = pager.o
  for k, name in ipairs(ORDER) do c:rect((k - 1) * 107, 0, 106, 2, name == v and TEAL or BORDER) end
  c:rect(106, 0, 1, 2, BG) c:rect(213, 0, 1, 2, BG)
end
showView("live")

---------------------------------------------------------------------------------
-- LIVE: drawing

-- A slot's cell: its state's colour, or filling up while it is being made.
local function cell(c, px, py, pw, ph, st, s, live_s, f, now)
  if st >= 2 then
    c:rect(px, py, pw, ph, STATE[st])
    if st == 5 then
      c:line(px + 2, py + 2, px + pw - 3, py + ph - 3, BG) c:line(px + pw - 3, py + 2, px + 2, py + ph - 3, BG)
    end
    return
  end
  c:rect(px, py, pw, ph, BORDER)
  c:rect(px + 1, py + 1, pw - 2, ph - 2, BG)
  if s == live_s then                          -- being made: fill up as the slot goes
    local h = math.floor((ph - 2) * f)
    if h > 0 then c:rect(px + 1, py + ph - 1 - h, pw - 2, h, mix(AQUA, 0xFFFFFF, f)) end
  elseif s < live_s and st == 1 then           -- made, waiting for the network's word
    c:rect(px + 1, py + 1, pw - 2, ph - 2, mix(0x1E3A40, AQUA, (math.sin(now / 80) + 1) * 0.3))
  end
end

-- Does this window have a cell that moves on its own (being made, or waiting)?
local function animated(w, live_s)
  if live_s < w.s then return false end
  return live_s <= w.s + 3 or w.cells:find("[01]") ~= nil
end

-- When the next leader takes over the cards move one place left at once: sliding the
-- whole strip over a few frames cost a fifth of the LIVE view's screen time.
local cellsAt = -1               -- when the moving cells were last drawn (10 times a second)
local function drawCarousel(now, live_s, f)
  local cur = est - est % 4
  local step = now // 100 ~= cellsAt
  if step then cellsAt = now // 100 end
  for k = 1, 5 do
    local card, w = cards[k], winAt(cur + (k - 3) * 4)
    local isCur, ours = k == 3, w.o == 1
    local changed = card.w ~= w or card.ver ~= w.ver or card.cur ~= isCur
    if changed then                            -- the frame, the name, the tx: only when they change
      card.w, card.ver, card.cur = w, w.ver, isCur
      local c = card.cv.o
      c:rect(0, 0, CW, CH, isCur and TEAL or (ours and OURS or BORDER))
      c:rect(1, 1, CW - 2, CH - 2, ours and OURS_BG or PANEL)
      if ours then for i = 0, 5 do c:rect(1 + i * 10, 1, i == 5 and 8 or 10, 2, grad(i / 5)) end end
      local bw = math.floor((CW - 8) * math.min(w.tx, 2400) / 2400)
      c:rect(4, CH - 6, CW - 8, 2, PANEL_HI)
      if bw > 0 then c:rect(4, CH - 6, bw, 2, ours and OURS or TEAL) end
      card.name:text(fit(w.n, 12, CW - 4))
      card.name:color(ours and OURS_TXT or (isCur and "text" or "dim"))
      card.tx:text(w.tx > 0 and (big(w.tx) .. " tx") or (k > 3 and "next" or ""))
      card.tx:color(isCur and "text" or "dim")
    end
    if changed or ((animated(w, live_s) or card.anim) and step) then   -- the four slots: 52 x 24 pixels
      card.anim = animated(w, live_s)
      local c = card.cells.o
      c:clear(ours and OURS_BG or PANEL)
      for j = 0, 3 do cell(c, j * 13, 0, 11, 24, w.d[j + 1][1], w.s + j, live_s, f, now) end
    end
  end
end

local function drawChart(live_s)
  if live_s == chartKey then return end        -- once a slot (new bars wait for it)
  chartKey = live_s
  local c = chart.o
  c:clear(BG)
  local H = CHART_H
  for q = 1, 3 do c:rect(0, H - (H * q) // 4, 320, 1, PANEL) end
  local scale = (H - 14) / chartMax
  local top = 0
  for k = 0, 320 // SLOT_W + 1 do
    local s = live_s - k
    local x = 320 - SLOT_W - k * SLOT_W
    local b = slotTx[s]
    if b then
      if b[3] then c:rect(x, 12, SLOT_W, H - 12, 0x1A0C33) end
      if b[4] then
        c:rect(x, H - 4, SLOT_W - 1, 4, PINK)
      else
        local oh = math.floor(b[1] * scale)
        local fh = math.floor(b[2] * scale)
        if b[3] then
          for yy = 0, oh + fh - 1, 2 do c:rect(x, H - 2 - yy, SLOT_W - 1, 2, grad(yy / (H - 14))) end
        else
          if oh > 0 then c:rect(x, H - oh, SLOT_W - 1, oh, 0x0C5A44) c:rect(x, H - oh, SLOT_W - 1, 1, GREEN) end
          if fh > 0 then c:rect(x, H - oh - fh, SLOT_W - 1, fh, 0x5A1E4A) c:rect(x, H - oh - fh, SLOT_W - 1, 1, PINK) end
        end
        if b[1] + b[2] > top then top = b[1] + b[2] end
      end
    elseif s == live_s then
      c:rect(x, H - 3, SLOT_W - 1, 3, AQUA)
    end
  end
  chartMax = math.max(500, ((top // 250) + 1) * 250)
  if chartTop ~= chartMax then chartTop = chartMax maxL:text(grouped(chartMax) .. " tx") end
end

---------------------------------------------------------------------------------
-- SCHEDULE: drawing

local function cardText(w)       -- the six columns of a card, four lines each
  local c = { {}, {}, {}, {}, {}, {} }
  for j = 1, 4 do
    local x = w.d[j]
    local done = x[1] >= 2 and x[1] ~= 5
    c[1][j] = tostring(w.s + j - 1)
    c[2][j] = done and tostring(x[2]) or "-"
    c[3][j] = done and string.format("%.5f", x[4] / 1000000000) or "-"
    c[4][j] = done and string.format("%.5f", x[5] / 1000000000) or "-"
    c[5][j] = (done and x[6] > 0) and tostring(x[6]) or "-"
    c[6][j] = (done and x[7] > 0) and (x[7] .. "%") or "-"
  end
  for k = 1, 6 do c[k] = table.concat(c[k], "\n") end
  return c
end

local scroll, scrollTo = 0, 0
local sel = nil                  -- the selected slot (UP / DOWN), nil while following live
local frozen = nil               -- while one is: the window that was current then (the list stays as it was)
local keyAt = 0                  -- the last key, to let go after a minute
local items, total = {}, 0       -- the list, rebuilt when the current window or a window changes
local itemsCur, itemsVer = nil, nil
local shape = ""                 -- what the backgrounds depend on: each card's start and colours
local lastOff, bgShape, bgSel, bgCur = nil, nil, nil, nil
local schedDirty = true          -- a window's data changed: labels and icons to check

local function buildItems()
  local cur = frozen or (est - est % 4)
  if cur == itemsCur and winVer == itemsVer then return end
  itemsCur, itemsVer = cur, winVer
  items = {}
  local y = 2
  for k = 2, 1, -1 do items[#items + 1] = { kind = "up", w = winAt(cur + 4 * k), y = y, h = UP_H } y = y + UP_H end
  y = y + 2
  items[#items + 1] = { kind = "now", w = winAt(cur), y = y, h = CARD_H }
  y = y + CARD_H + GAP
  for n = 1, 8 do
    local s = cur - 4 * n
    local w = wins[s] or (n <= 2 and winAt(s)) or nil
    if not w then break end
    items[#items + 1] = { kind = "past", w = w, y = y, h = CARD_H }
    y = y + CARD_H + GAP
  end
  total = y
  local sh = {}
  for i, it in ipairs(items) do sh[i] = it.w.s .. it.kind .. it.w.o end
  shape = table.concat(sh, ",")
end

local function iconOf(st, s, live_s, spin, j)
  if (st == 1 or st == 0) and s <= live_s then return 10 + (spin + j * 2) % 8 end
  return ICON[st] and st or 0
end

local upKey = {}                 -- the countdowns' tenths, so their text changes 10 times a second
-- Following live, the list jumps a card as the next leader takes over (sliding it redrew
-- all 64,000 pixels of it five times over, most of this view's CPU on the badge).
local function drawSchedule(now, live_s, p)
  if est == 0 then return end
  local cur = est - est % 4
  buildItems()
  local maxS = math.max(0, total - LIST_H + (sel and PANEL_H or 0))
  local selIt, selJ = nil, nil
  if sel then
    local oldest = nil
    for _, it in ipairs(items) do
      if it.kind ~= "up" then
        if sel >= it.w.s and sel <= it.w.s + 3 then selIt, selJ = it, sel - it.w.s end
        oldest = it
      end
    end
    if not selIt and oldest and sel < oldest.w.s then sel, selIt, selJ = oldest.w.s, oldest, 0 end   -- it fell off the list
    if selIt then
      -- the selected slot's card at the top (no card is ever cut there); the current
      -- leader's card fits below the next leaders, so that one leaves them in view
      scrollTo = selIt.kind == "now" and 0 or selIt.y - 2
      if scrollTo > maxS then maxS = scrollTo end
    end
  end
  if scrollTo > maxS then scrollTo = maxS end
  -- a fast ease-out: a moving list redraws all of it, so it moves in as few frames as look smooth
  if scroll ~= scrollTo then
    scroll = scroll + (scrollTo - scroll) * 0.55
    if math.abs(scrollTo - scroll) < 2 then scroll = scrollTo end
  end
  local off = math.floor(-scroll + 0.5)
  local moved = off ~= lastOff
  lastOff = off
  local visH = LIST_H - (selIt and PANEL_H or 0)   -- what the panel leaves of the list

  -- 1. the cards' backgrounds: only when the list moved, its shape changed or the selection did
  if moved or shape ~= bgShape or sel ~= bgSel or cur ~= bgCur then
    bgShape, bgSel, bgCur = shape, sel, cur
    local c = sch.o
    c:clear(BG)
    for _, it in ipairs(items) do
      local y = it.y + off
      if y < LIST_H and y + it.h > 0 then
        if it.kind == "up" then
          c:rect(2, y, 3, it.h - 2, FD_RAIL_UP)
          c:rect(8, y, 306, it.h - 2, FD_UPBG)
        else
          local w = it.w
          local isNow, ours = it.kind == "now" and w.s == cur, w.o == 1   -- paused, it may be past now
          c:rect(2, y, 3, it.h, isNow and FD_NOW or FD_RAIL_PAST)
          c:rect(8, y, 306, it.h, isNow and FD_NOW or (ours and OURS or FD_BORDER))
          c:rect(9, y + 1, 304, it.h - 2, isNow and FD_NOWBG or (ours and OURS_BG or FD_CARD))
          if ours then for i = 0, 5 do c:rect(9 + i * 51, y + 1, i == 5 and 49 or 51, 2, grad(i / 5)) end end
          if it == selIt then
            local ry = y + 20 + selJ * 13
            c:rect(9, ry, 304, 13, 0x22324A)
            c:rect(9, ry, 3, 13, FD_NOW)
          end
        end
      end
    end
  end

  -- 2. labels and icons: placed when the list moves, filled when their window changes
  local spin = (now // 90) % 8
  local used, upN = 0, 0
  for _, it in ipairs(items) do
    local y = it.y + off
    local sy = LIST_Y + y
    if y < visH and y + it.h > 0 then
      local w = it.w
      if it.kind == "up" then
        upN = upN + 1
        local u = ups[upN]
        local t = ((w.s - est) - p) * sd / 1000
        local tenths = t > 0 and math.floor(t * 10) or (w.s + 3 >= live_s and -1 or -2)
        if moved or schedDirty or upKey[upN] ~= tenths or u.s ~= w.s then
          upKey[upN], u.s = tenths, w.s
          u.name:text(w.n ~= "" and fit(w.n, 12, 146) or "...")
          u.name:color(w.o == 1 and OURS_TXT or FD_DIM)
          u.when:text(tostring(w.s) .. (tenths >= 0 and string.format("   %.1fs", tenths / 10) or tenths == -1 and "   now" or ""))
          u.name:pos(12, sy + 1) u.when:pos(160, sy + 1)
          u.name:show(y >= -14) u.when:show(y >= -14)
        end
      else
        used = used + 1
        local c = pool[used]
        if c then
          local vis = y >= -14              -- the band above hides what is still under it
          local isNow, ours = it.kind == "now" and w.s == cur, w.o == 1
          if c.w ~= w or c.ver ~= w.ver or c.now ~= isNow then
            c.w, c.ver, c.now = w, w.ver, isNow
            c.name:text(fit(w.n, 14, 152))
            c.name:color(ours and OURS_TXT or (isNow and "text" or FD_TEXT))
            local meta = {}
            if w.k > 0 then meta[#meta + 1] = big(w.k) .. " SOL" end
            if w.c ~= "" then meta[#meta + 1] = w.c end
            c.meta:text(table.concat(meta, DOT))
            local txt = cardText(w)
            for k = 1, #COLS do c.cols[k]:text(txt[k]) end
          end
          if moved or c.y ~= sy then
            c.y = sy
            c.name:pos(12, sy + 4) c.meta:pos(170, sy + 6)
            for k, col in ipairs(COLS) do c.cols[k]:pos(col[1], sy + 20) end
            c.icons:pos(ICON_X, sy + 22)
          end
          c.name:show(vis) c.meta:show(vis)
          for k = 1, #COLS do c.cols[k]:show(vis) end
          c.icons:show(y >= -38)            -- above that it would reach past the band
          -- the icons: redrawn only when one of them changes (a spinning one, 11 times a second)
          local ik, changed = c.iconKey, false
          for j = 1, 4 do
            local n = iconOf(w.d[j][1], w.s + j - 1, live_s, spin, j)
            if ik[j] ~= n then ik[j] = n changed = true end
          end
          if changed then
            local ic = c.icons.o
            ic:clear()
            for j = 1, 4 do ic:image(ICON[ik[j]], 0, (j - 1) * 13) end
          end
        end
      end
    end
  end
  for i = upN + 1, #ups do ups[i].name:show(false) ups[i].when:show(false) end
  for i = used + 1, #pool do
    local c = pool[i]
    c.name:show(false) c.meta:show(false) c.icons:show(false)
    for k = 1, #COLS do c.cols[k]:show(false) end
  end

  -- 3. the selected slot's panel
  showPanel(selIt ~= nil)
  if selIt and (schedDirty or moved or pTitle.sel ~= sel) then
    pTitle.sel = sel
    local w, j = selIt.w, selJ + 1
    local x = w.d[j]
    local done = x[1] >= 2 and x[1] ~= 5
    pTitle:text(fit(grouped(w.s + selJ) .. DOT .. w.n, 12, 206))
    pTitle:color(w.o == 1 and OURS_TXT or FD_TEXT)
    pState:text(STATE_NAME[x[1]] or "")
    pState:color(x[1] == 5 and "pink" or FD_NOW)
    pVal[1]:text(done and grouped(x[2]) or "-")
    pVal[2]:text(done and string.format("%.6f", x[4] / 1000000000) or "-")
    pVal[3]:text(done and string.format("%.6f", x[5] / 1000000000) or "-")
    pVal[4]:text((done and x[6] > 0) and tostring(x[6]) or "-")
    pVal[5]:text((done and x[7] > 0) and (x[7] .. "%") or "-")
  end
  schedDirty = false
end

local function schedLive()       -- back to following live
  sel, frozen, scrollTo = nil, nil, 0
end

-- UP / DOWN in the schedule: a row at a time, as the screen shows them. The cards go
-- back in time downwards but each lists its four slots in order, so DOWN is the next
-- slot within a card, then the first slot of the older card below. UP past the newest
-- slot made, or BACK, follows live again. While a slot is selected the list stays as
-- it was: new leaders wait.
local function schedSelect(dir, live_s)
  if not sel then frozen = est - est % 4 end
  buildItems()
  local newest, oldest = nil, nil
  for _, it in ipairs(items) do
    if it.kind ~= "up" then
      local top = math.min(it.w.s + 3, live_s)
      if top >= it.w.s and (not newest or top > newest) then newest = top end
      if not oldest or it.w.s < oldest then oldest = it.w.s end
    end
  end
  if not newest then frozen = nil return end
  if not sel then
    sel = newest
  elseif dir > 0 then                            -- down a row
    if sel % 4 < 3 and sel < newest then sel = sel + 1
    elseif sel - sel % 4 - 4 >= oldest then sel = sel - sel % 4 - 4 end
  elseif sel % 4 > 0 then                        -- up a row, within the card
    sel = sel - 1
  elseif sel + 4 <= newest then                  -- up to the last row made of the newer card
    sel = math.min(sel + 7, newest)
  else
    schedLive()
  end
end

---------------------------------------------------------------------------------
-- VALIDATOR: drawing

local function nextWindows()
  return info and type(info.next) == "table" and info.next or {}
end

local function drawTimeline(now, p)
  local key = est * 4 + (now // 250) % 4       -- 4 redraws a second is plenty here
  if key == vv.tlKey then return end
  vv.tlKey = key
  local c = vv.tl.o
  c:clear(BG)
  c:rect(10, 22, 300, 1, BORDER)
  for m = 0, 10 do c:rect(10 + m * 30, 20, 1, m % 5 == 0 and 6 or 4, BORDER) end
  for _, w in ipairs(nextWindows()) do
    local t = ((w - est) - p) * sd / 1000
    if t >= -1 and t <= 600 then
      local x = 10 + math.floor(t / 2)          -- 600 s over 300 px
      for yy = 0, 19, 2 do c:rect(x, 1 + yy, 3, 2, GRAD[yy * 63 // 20]) end
    end
  end
  c:rect(9, 0, 2, 26, (now // 250) % 2 == 0 and TEAL or AQUA)
end

local function drawBars()       -- the last 16 blocks, oldest on the left: transactions, pink if skipped
  local c = vv.bars.o
  c:clear(BG)
  local H = vv.BAR_H
  for i = 1, 16 do
    local b = blocks[17 - i]
    local x = (i - 1) * 9
    c:rect(x, H - 1, 7, 1, BORDER)
    if b then
      if b[2] then
        c:rect(x, H - 6, 7, 5, PINK)
      else
        local h = math.max(2, math.floor((H - 2) * math.min(b[1], 1600) / 1600))
        for yy = 0, h - 1, 2 do c:rect(x, H - 2 - yy, 7, 2, grad(yy / (H - 2))) end
      end
    end
  end
end

---------------------------------------------------------------------------------
-- Messages

local skipPct = 0
local cdKey = nil                -- the countdown's tenths: its text changes 10 times a second
local function onInfo(m)
  info = m
  if type(m.sd) == "number" and m.sd > 50 then sd = m.sd end
  local name = (type(m.name) == "string" and m.name ~= "") and m.name or "validator"
  if type(m.id) == "string" and m.id ~= fol.cur then   -- another validator: what we knew is someone else's
    fol.cur = m.id
    blocks, win, cdKey = {}, { on = false, tx = 0, fee = 0, skip = false }, nil
  end
  if m.def ~= nil then fol.def = m.def == 1 end
  if fol.def and m.def ~= nil and name ~= fol.defName then fol.defName = name storage.set("defname", name) end
  if fol.asked and m.n == fol.asked and m.id then     -- the relay's answer to our choice: keep it on the card
    fol.asked = nil
    if fol.def then
      fol.id = nil
      storage.remove("follow")
    else
      fol.id = m.id
      storage.set("follow", m.id)
      local r = { { m.id, name } }
      for _, x in ipairs(fol.recent) do if x[1] ~= m.id and #r < 4 then r[#r + 1] = x end end
      fol.recent = r
      storage.set("recent", r)
    end
  end
  stakeL:text(big(m.stake or 0) .. " SOL")
  local parts = {}
  if (m.rank or 0) > 0 then parts[#parts + 1] = "#" .. m.rank end
  if m.share then parts[#parts + 1] = string.format("%.2f%%", m.share) end
  if m.comm then parts[#parts + 1] = string.format("%g%%", m.comm) end
  subL:text(table.concat(parts, DOT))
  pctL:text((m.pct or 0) .. "%")
  drawRing(m.pct or 0)
  local past = (m.done or 0) + (m.skip or 0)
  skipPct = past > 0 and (m.skip or 0) * 100 / past or 0
  nameL:text(fit(name:upper(), 12, 126))
  -- VALIDATOR
  vv.name:text(fit(name, 20, 208))
  local sub = {}
  if (m.rank or 0) > 0 then sub[#sub + 1] = "rank #" .. m.rank end
  if m.share then sub[#sub + 1] = string.format("%.2f%% of stake", m.share) end
  if type(m.ver) == "string" and m.ver ~= "" then sub[#sub + 1] = "v" .. m.ver end
  if type(m.cc) == "string" and m.cc ~= "" then sub[#sub + 1] = m.cc end
  vv.sub:text(m.delinq and "DELINQUENT" or fit(table.concat(sub, DOT), 12, 304))
  vv.sub:color(m.delinq and "pink" or "dim")
  vv.val[1]:text(big(m.stake or 0))
  vv.val[2]:text(m.comm and string.format("%g%%", m.comm) or "-")
  vv.val[3]:text(string.format("%.2f%%", skipPct))
  vv.val[3]:color(skipPct > 0 and "orange" or "text")
  vv.val[4]:text((m.done or 0) .. "/" .. (m.leader or 0))
  if #blocks == 0 and type(m.last) == "table" then
    for i, b in ipairs(m.last) do
      if type(b) == "table" then blocks[i] = { b[1] or 0, b[2] == 1 } end
    end
    if view == "validator" then drawBars() end
  end
end

-- Asking the relay to follow another validator: {t = "follow", id = ...}, {t = "follow",
-- s = slot} (that slot's leader) or {t = "follow"} (its default). Its answer is an info
-- message, then the windows again (to say which are the new one's).
local function follow(req, name)
  if not (sock and sockOpen) then toast("Choosing needs Wi-Fi") return false end
  fol.n = fol.n + 1
  req.n = fol.n
  if not sock:send(req) then toast("Busy, try again") return false end
  fol.asked = fol.n
  toast("Following " .. name)
  return true
end

-- The picker's rows: the default validator, the last ones chosen, the relay's list.
local function pickItems()
  local items, seen = {}, {}
  local function add(id, name, right)
    if id and seen[id] then return end
    if id then seen[id] = true end
    local on = (id == nil and fol.def) or (id ~= nil and id == fol.cur and not fol.def)
    items[#items + 1] = { id = id, name = name, right = right, on = on }
  end
  add(nil, fol.defName or "Dashboard's own", "default")
  if fol.def and fol.cur then seen[fol.cur] = true end
  for _, x in ipairs(fol.recent) do add(x[1], x[2], "recent") end
  if pick.list then
    for _, x in ipairs(pick.list) do
      if type(x) == "table" and type(x[1]) == "string" then
        add(x[1], tostring(x[2] or "?"), big(tonumber(x[3]) or 0) .. "  " .. tostring(x[4] or ""):sub(1, 8))
      end
    end
  else
    items[#items + 1] = { name = "loading...", right = "", wait = true }
  end
  pick.items = items
end

local function drawPicker()
  local n = #pick.items
  if pick.i > n then pick.i = n end
  if pick.i < pick.top then pick.top = pick.i end
  if pick.i >= pick.top + pick.ROWS then pick.top = pick.i - pick.ROWS + 1 end
  local names, rights = {}, {}
  for k = pick.top, math.min(n, pick.top + pick.ROWS - 1) do
    local it = pick.items[k]
    names[#names + 1] = fit((it.on and "> " or "") .. it.name, 14, 180)
    rights[#rights + 1] = it.right
  end
  pick.names:text(table.concat(names, "\n"))
  pick.right:text(table.concat(rights, "\n"))
  pick.hi.o:pos(4, pick.Y + (pick.i - pick.top) * pick.LINE)
  pick.count:text(pick.i .. " / " .. n)
end

function pick.draw()             -- its text grows: low on memory, close it rather than stop
  if not pcall(drawPicker) then pick.show(false) toast("Low on memory") end
end

local function openPicker()
  if not (sock and sockOpen) then toast("Choosing needs Wi-Fi") return end
  sock:send({ t = "list" })
  pickItems()
  pick.i, pick.top, pick.moved = 1, 1, false
  for k, it in ipairs(pick.items) do if it.on then pick.i = k end end
  pick.show(true)
  pick.draw()
end

local function onList(m)
  if type(m.l) ~= "table" then return end
  pick.list = m.l
  if pick.open then
    local id = pick.items[pick.i] and pick.items[pick.i].id
    pickItems()
    for k, it in ipairs(pick.items) do      -- stay on the row picked, or go to the one followed
      if (pick.moved and id and it.id == id) or (not pick.moved and it.on) then pick.i = k end
    end
    pick.draw()
  end
end

local function onFrame(m, now)
  if type(m.e) ~= "number" then return end
  if m.e ~= est then
    newSlot(m.e, now)
    tickAt = now
    slotTx[est - 100] = nil                 -- the chart shows ~64 slots: forget older ones
    for s in pairs(ghosts) do if s < est - 200 then ghosts[s] = nil end end
  end
  local ok, fail = m.ok or 0, m.fail or 0
  if ok ~= tpsOk or fail ~= tpsFail then
    tpsOk, tpsFail = ok, fail
    tpsL:text(ok + fail < 10000 and grouped(ok + fail) or big(ok + fail))   -- 5 digits would wrap
  end
  if not live then status(nil) end
  live = true
end

local function onWin(m)
  local s = m.s
  local d = m.d
  for j = 1, 4 do
    local x = d[j]
    if type(x) ~= "table" or #x < 7 then return end
    for i = 1, 7 do if type(x[i]) ~= "number" then return end end
  end
  local cells, tx = {}, 0
  for j = 1, 4 do cells[j] = tostring(d[j][1]) tx = tx + d[j][2] end
  m.cells, m.tx = table.concat(cells), tx
  m.k = type(m.k) == "number" and m.k or 0
  m.c = type(m.c) == "string" and m.c or ""
  m.n = m.n:gsub("%s+$", "")
  local old = wins[s]
  m.ver = (old and old.ver or 0) + 1
  if not old then
    winOrder[#winOrder + 1] = s
    table.sort(winOrder)
    -- the oldest go, but not those a paused schedule shows (for a while)
    while #winOrder > WIN_KEEP and not (frozen and winOrder[1] >= frozen - 40 and #winOrder < WIN_KEEP + 100) do
      wins[table.remove(winOrder, 1)] = nil
    end
  end
  wins[s], ghosts[s] = m, nil
  winVer = winVer + 1
  local ours = m.o == 1
  for j = 1, 4 do                           -- the chart's bars
    local x = d[j]
    if x[1] >= 2 then slotTx[s + j - 1] = { x[2] - x[3], x[3], ours, x[1] == 5 } end
  end
  schedDirty = true
end

local ledSlot                    -- defined with the LEDs below

local function onSlot(m)
  local i = m.i + 1
  if i == 1 or not win.on then win = { on = true, tx = 0, fee = 0, skip = false } end
  local ok = m.st == "ok"
  if ok then win.tx = win.tx + (m.tx or 0) win.fee = win.fee + (m.fee or 0) else win.skip = true end
  table.insert(blocks, 1, { m.tx or 0, not ok })
  blocks[17] = nil
  if view == "validator" then drawBars() end
  ledSlot(i, ok)
  if i == 4 then win.on = false win.doneAt = sys.millis() end
end

---------------------------------------------------------------------------------
-- LEDs: written only when they change

local MODES = { "full", "validator", "off" }
local mode = 1
local level = {}
for n = 1, 6 do level[n] = { 0, 0, 0 } end
local fadeAt, FADE_MS = nil, 1200
local ledNow = {}                -- what each LED shows, as 0xRRGGBB
local function ledSet(n, r, g, b)
  local v = (r << 16) | (g << 8) | b
  if ledNow[n] ~= v then ledNow[n] = v led.set(n, r, g, b) end
end

ledSlot = function(i, ok)
  if i == 1 then for n = 1, 6 do level[n] = { 0, 0, 0 } end fadeAt = nil end
  local upto, from = math.ceil(i * 6 / 4), math.ceil((i - 1) * 6 / 4)
  for n = from + 1, upto do
    if ok then
      local c = grad((n - 1) / 5)
      level[n] = { (c >> 16) & 255, (c >> 8) & 255, c & 255 }
    else
      level[n] = { 255, 30, 30 }
    end
  end
  if i == 4 then
    if not win.skip then for n = 1, 6 do level[n] = { 200, 255, 220 } end end
    fadeAt = sys.millis() + 250
  end
end

local function leds(now, left)
  if MODES[mode] == "off" then return end
  local k = 1
  if fadeAt and now > fadeAt then
    k = 1 - (now - fadeAt) / FADE_MS
    if k <= 0 then k = 0 for n = 1, 6 do level[n] = { 0, 0, 0 } end fadeAt = nil end
  end
  for n = 1, 6 do
    local c = level[n]
    ledSet(n, math.floor(c[1] * k), math.floor(c[2] * k), math.floor(c[3] * k))
  end
  if left and left < 10 then
    local speed = 1 + (10 - left) * 0.6
    local b = (math.sin(now / 1000 * speed * math.pi) + 1) / 2
    local p = math.floor(30 + 200 * b * (1 - left / 12))
    ledSet(7, p // 2, p // 4, p) ledSet(8, p // 2, p // 4, p)
  elseif MODES[mode] == "full" and now - tickAt < 60 then
    ledSet(7, 20, 60, 50) ledSet(8, 20, 60, 50)
  else
    ledSet(7, 0, 0, 0) ledSet(8, 0, 0, 0)
  end
end

---------------------------------------------------------------------------------
-- Connections. Two ways in, whichever delivers:
--   Wi-Fi: the relay's websocket. The badge server allows it only for an app that is
--     in the store or in a test run ("denied" otherwise).
--   Bluetooth: a phone (the Android app, or the relay's /install page) follows the
--     relay and writes the same messages, packed, to this badge.

local function dispatch(m, now)
  lastMsg = now
  local t = m.t
  if t == "f" then onFrame(m, now)
  elseif t == "w" then
    if type(m.s) == "number" and type(m.d) == "table" and #m.d == 4 and type(m.n) == "string" then onWin(m) end
  elseif t == "info" then onInfo(m)
  elseif t == "slot" and type(m.i) == "number" and m.i >= 0 and m.i <= 3 then onSlot(m)
  elseif t == "list" then onList(m) end
end

-- Wi-Fi. Asking for a socket keeps the radio busy for a few seconds, which Bluetooth
-- shares: never ask while the phone is feeding us, and rarely once refused.
local retry = 1000
local connect
connect = function()
  if sys.millis() - lastBle < 10000 then timer.after(60000, connect) return end
  sock = ws.open(RELAY .. (fol.id and ("?v=" .. fol.id) or ""), function(event, data)
    if event == "open" then
      retry, sockOpen = 1000, true
    elseif event == "message" then
      local m = json.decode(data)
      if type(m) == "table" then dispatch(m, sys.millis()) end
    else
      sockOpen = false
      local refused = data == "denied" or data == "not linked" or data == "host not allowed"
      if not live then status(refused and "Wi-Fi denied" or tostring(data)) end
      timer.after(refused and 600000 or retry, connect)
      retry = math.min(retry * 2, 30000)
    end
  end)
end
connect()

-- Bluetooth: the Nordic UART service; the phone writes packed messages to RX
local NUS = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
local RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

local function unpackMsg(d)
  local k = d:sub(1, 1)
  if k == "F" and #d == 9 then                 -- the slot and the TPS
    local _, e, ok, fail = string.unpack("<c1I4I2I2", d)
    return { t = "f", e = e, ok = ok, fail = fail }
  elseif k == "W" and #d == 92 then            -- one leader window in full
    local _, s, o, stake, cc, name = string.unpack("<c1I4BI4c2c16", d)
    local dd = {}
    for j = 0, 3 do
      local st, tx, fail, fee, tip, ms, cu = string.unpack("<BI2I2I4I4I2B", d, 29 + j * 16)
      dd[j + 1] = { st, tx, fail, fee, tip, ms, cu }
    end
    return { t = "w", s = s, o = o, k = stake, c = (cc:gsub(" ", "")), n = (name:gsub("[%z ]+$", "")), d = dd }
  elseif k == "S" and #d == 13 then            -- one of our slots
    local _, s, i, ok, tx, fee = string.unpack("<c1I4BBI2I4", d)
    return { t = "slot", s = s, i = i, st = ok == 1 and "ok" or "skip", tx = tx, fee = fee }
  elseif k == "I" and #d >= 50 then            -- info
    local _, stake, share, rank, comm, delinq, epoch, pct, msd, leader, done, skip, up, nNext, nLast =
      string.unpack("<c1I4I2I2I2BI2BI2I2I2I2BBB", d)
    if #d ~= 50 + nNext * 4 + nLast * 2 then return nil end
    local name, ver = string.unpack("<c16c8", d, 27)
    local m = { t = "info", stake = stake, share = share / 1000, rank = rank, delinq = delinq == 1, epoch = epoch,
      pct = pct, sd = msd, leader = leader, done = done, skip = skip, up = up == 1 and "live" or "reconnecting",
      next = {}, last = {}, name = (name:gsub("[%z ]+$", "")), ver = (ver:gsub("[%z ]+$", "")) }
    if comm ~= 0xFFFF then m.comm = comm / 100 end
    local pos = 51
    for n = 1, nNext do m.next[n] = string.unpack("<I4", d, pos) pos = pos + 4 end
    for n = 1, nLast do
      local v = string.unpack("<I2", d, pos) pos = pos + 2
      m.last[n] = { v & 0x7FFF, v >> 15 }
    end
    return m
  end
  return nil
end

if ble and ble.on() then
  local function advertise() ble.advertise({ name = "FD Badge", service = NUS, connectable = true }) end
  local served = ble.serve({ service = NUS, chars = { { uuid = RX, write = true } } }, function(event, a, b)
    if event == "open" then
      toast("Phone connected")
    elseif event == "write" and type(b) == "string" then
      local ok, m = pcall(unpackMsg, b)          -- anyone in range can write: check everything
      if ok and m then
        local now = sys.millis()
        lastBle = now
        dispatch(m, now)
      end
    elseif event == "close" then
      advertise()
    end
  end)
  if served then advertise() end
end

---------------------------------------------------------------------------------
-- Every tick (30 ms)

function on_tick(ms)
  local now = sys.millis()
  if live and now - lastMsg > 3000 then      -- nothing for 3 s: say so, don't just freeze
    live = false
    tpsOk, tpsFail = -1, -1
    status("no data")
  end
  dot:color(live and DOTC[(now // 100) % 12] or 0xFF754A)

  local p = live and phase(now) or 0
  local whole = math.floor(p)
  local live_s, f = est + whole, p - whole

  -- the validator's next window
  local w = nil
  for _, s in ipairs(nextWindows()) do if s + 3 >= est then w = s break end end
  local left = nil
  local leading = win.on or (w ~= nil and w <= live_s)
  if leading then
    if cdKey ~= "lead" .. win.tx then
      cdKey = "lead" .. win.tx
      capL:text("LEADER NOW") capL:color(OURS_TXT)
      cdL:text("+" .. grouped(win.tx) .. " tx") cdL:color(OURS_TXT)
      cdSub:text(string.format("%.4f SOL fees", win.fee / 1000000000)) cdSub:color("green")
    end
    frameColor(PULSE_L[(now // 60) % 8])
  elseif w then
    left = ((w - est) - p) * sd / 1000
    if left < 0 then left = 0 end
    local tenths = math.floor(left * 10)
    if cdKey ~= tenths then
      cdKey = tenths
      capL:text("NEXT LEADER") capL:color("dim")
      cdL:text(dur(left)) cdL:color(left < 10 and "pink" or TEAL)
      if info and info.delinq then
        cdSub:text("DELINQUENT") cdSub:color("pink")
      elseif win.doneAt and now - win.doneAt < 4000 then
        cdSub:text("last +" .. grouped(win.tx) .. " tx") cdSub:color("green")
      else
        cdSub:text(string.format("E%d skip %.2f%%", info and info.epoch or 0, skipPct))
        cdSub:color(skipPct > 0 and "orange" or "dim")
      end
    end
    frameColor(left < 10 and PULSE_P[(now // 100) % 8] or OURS)
  elseif info and cdKey ~= "none" then             -- no window in this epoch or the next
    cdKey = "none"
    capL:text("NEXT LEADER") capL:color("dim")
    cdL:text("none") cdL:color("dim")
    cdSub:text("not in the schedule") cdSub:color("dim")
    frameColor(OURS)
  end
  if sel and now - keyAt > 60000 then schedLive() end   -- a paused schedule lets go after a minute

  if view == "live" then
    drawCarousel(now, live_s, f)
    drawChart(live_s)
  elseif view == "schedule" then
    drawSchedule(now, live_s, p)
  else
    drawTimeline(now, p)
    if leading then vv.cd:text("LEADER") vv.cd:color(OURS_TXT)
    elseif left then vv.cd:text(dur(left)) vv.cd:color(left < 10 and "pink" or TEAL)
    else vv.cd:text("none") vv.cd:color("dim") end
    vv.slot:text(w and ("slot " .. grouped(w)) or (info and "not in the schedule" or ""))
  end
  leds(now, left)
end

local function redraw()          -- what was drawn while hidden is stale: draw the view afresh
  for k = 1, 5 do cards[k].w = nil end
  for k = 1, #pool do pool[k].w, pool[k].y, pool[k].iconKey = nil, nil, {} end
  bgShape, lastOff, schedDirty, upKey = nil, nil, true, {}
  chartKey, vv.tlKey = nil, nil
  if view == "validator" then drawBars() end
end

-- LEFT / RIGHT: views. LIVE: SELECT, the LEDs' mode. SCHEDULE: UP / DOWN pick a slot,
-- SELECT follows its leader, BACK goes live. VALIDATOR: SELECT, choose whom to follow.
function on_key(key)
  keyAt = sys.millis()
  if pick.open then                              -- the validator list has the keys
    if key == "up" or key == "down" then
      pick.i = math.max(1, math.min(#pick.items, pick.i + (key == "down" and 1 or -1)))
      pick.moved = true
      pick.draw()
    elseif key == "select" then
      local it = pick.items[pick.i]
      if it and not it.wait then
        pick.show(false)
        follow(it.id and { t = "follow", id = it.id } or { t = "follow" }, it.name)
      end
    elseif key == "back" or key == "left" or key == "right" then
      pick.show(false)
    end
    return true
  end
  if view == "schedule" then
    if key == "up" or key == "down" then
      local p = live and phase(sys.millis()) or 0
      schedSelect(key == "down" and 1 or -1, est + math.floor(p))
      return true
    elseif key == "back" and sel then
      schedLive()
      return true
    elseif key == "select" then
      if sel then
        local w = wins[sel - sel % 4]
        follow({ t = "follow", s = sel }, w and w.n ~= "" and w.n or "this leader")
      else
        toast("UP / DOWN pick a slot")
      end
      return true
    end
  end
  if key == "left" or key == "right" then
    local i = 1
    for n, v in ipairs(ORDER) do if v == view then i = n end end
    i = (i - 1 + (key == "right" and 1 or -1)) % #ORDER + 1
    if sel then schedLive() end                  -- leaving a paused schedule lets it go
    showView(ORDER[i])
    showPanel(false)
    redraw()
    return true
  elseif key == "select" then
    if view == "validator" then openPicker() return true end
    mode = mode % #MODES + 1
    if MODES[mode] == "off" then led.off() ledNow = {} end
    toast("LEDs: " .. MODES[mode])
    return true
  end
  return false
end
