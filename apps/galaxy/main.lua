-- Galaxy Live: the Solana cluster making blocks, live, with Galaxy front and centre.
-- A badge-sized take on the Firedancer dashboard. LEFT / RIGHT change view.
--
-- LIVE
--   Leader carousel: five leader windows, the past on the left, the future on the
--   right, the current one framed in green. Each card shows the leader and its four
--   slots: the slot being made fills up as it happens, then turns blue (completed),
--   light purple (notarized) and green (rooted), or pink if skipped. The cards
--   slide left when the next leader takes over. Galaxy's cards are purple.
--   TX / SLOT: one bar per slot of the cluster, scrolling; Galaxy's in the gradient.
--   Galaxy panel: active stake, rank, an epoch ring, the countdown to its next
--   window; while it is leader, its transactions and fees as they come.
-- SCHEDULE
--   The leader schedule as a table, like the dashboard's: the two next leaders, the
--   current one, then the last six, each with its four slots, transactions, fees
--   (SOL) and time per slot (ms).
-- GALAXY
--   Galaxy's next windows on a 10-minute timeline, a big countdown, and its last
--   16 blocks as bars (transactions each).
--
-- LEDs: while Galaxy is leader the six top LEDs fill slot by slot (purple to
-- green, red for a skip), then flash and fade. The side LEDs breathe as its next
-- window comes and, in "full" mode, tick with every slot of the cluster.
-- SELECT: LED mode (full / Galaxy / off). CANCEL: exit.
--
-- Data: the relay (server.ts or worker/), about 10 messages a second, over Wi-Fi
-- (a WebSocket) or through a phone over Bluetooth (the relay's /install page).
--
-- Numbers: a badge has 32-bit integers and 32-bit floats. Slot numbers (469 million)
-- stay integers; only differences between slots ever become floats.

local RELAY = "wss://galaxy-live-relay.theo-b59.workers.dev/live"   -- your relay; its host goes in app.json "hosts"
local OWNER = "ghosty"

---------------------------------------------------------------------------------
-- Colours and helpers

local BG, PANEL, PANEL_HI, BORDER = 0x000000, 0x111116, 0x1C1B26, 0x2A2935
local PURPLE, GREEN, PINK, LPURPLE, BLUE, AQUA, LIME = 0x9945FF, 0x14F195, 0xEB54BC, 0xB6B0FF, 0x64A8F2, 0x80ECFF, 0xACFF9B
local OURS_BG = 0x221040
local STATE = { [2] = BLUE, [3] = LPURPLE, [4] = GREEN, [5] = PINK }
local DOT = " \u{2022} "         -- the badge's fonts have this bullet, not the middle dot

local function mix(a, b, t)      -- blend two 0xRRGGBB colours, t in 0..1
  local function ch(s) return ((a >> s) & 255) + (((b >> s) & 255) - ((a >> s) & 255)) * t end
  return (math.floor(ch(16)) << 16) | (math.floor(ch(8)) << 8) | math.floor(ch(0))
end
local function grad(t) return mix(PURPLE, GREEN, t) end   -- the Solana gradient

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
local function dur(sec)
  if sec >= 60 then return string.format("%dm%02ds", sec // 60, math.floor(sec % 60)) end
  return string.format("%.1fs", sec)
end

-- Objects that touch the screen only when something changes.
local function L(x, y, text, o)
  local l = ui.label(x, y, text, o)
  return { o = l, t = text,
    text = function(self, s) if self.t ~= s then self.o:text(s) self.t = s end end,
    color = function(self, c) if self.c ~= c then self.o:color(c) self.c = c end end,
    pos = function(self, px, py) if self.x ~= px or self.y ~= py then self.o:pos(px, py) self.x, self.y = px, py end end,
    show = function(self, b) self.o:show(b) end }
end
local function R(x, y, w, h, o)
  local r = ui.rect(x, y, w, h, o)
  return { o = r,
    color = function(self, c) if self.c ~= c then self.o:color(c) self.c = c end end,
    show = function(self, b) self.o:show(b) end }
end

---------------------------------------------------------------------------------
-- State from the relay

local info = nil
local est, sd = 0, 400           -- the relay's estimated slot, ms per slot
local pbase, pat = 0, 0          -- our slot clock: slots past `est` at time `pat` (a small float)
local disp = {}                  -- five windows, oldest first: {start, name, ours, cells, tx, per, fee, ms}
local hist = {}                  -- past windows, newest first (for the schedule)
local slide = 0                  -- px the carousel still has to slide
local live = false
local lastMsg, lastBle = -10000, -10000
local win = { on = false, tx = 0, fee = 0, skip = false }   -- Galaxy's window in progress
local blocks = {}                -- Galaxy's last 16 slots: {tx, skipped}
local slotTx = {}                -- slot -> {ok, fail, ours, skipped}, for the chart
local tickAt = -1000             -- when the cluster last moved to a new slot

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
ui.gradient(0, 0, ui.W, 2)
ui.label(8, 4, "GALAXY", { size = 20 })
local dot = R(92, 12, 6, 6, { color = "dim", radius = 3 })
ui.label(103, 9, "@" .. OWNER, { size = 12, color = "aqua" })
local tpsL = L(150, 3, "", { size = 20, w = 128, align = "right" })
ui.label(282, 10, "TPS", { size = 12, color = "dim" })

local views = { live = {}, schedule = {}, galaxy = {} }
local ORDER = { "live", "schedule", "galaxy" }
local function V(name, o) local t = views[name] t[#t + 1] = o return o end

---------------------------------------------------------------------------------
-- LIVE view

-- Leader carousel: one small canvas per card, so the screen redraws only the cards
-- that change (mostly the current one) instead of the whole strip.
local CAR_Y, PITCH, CW, CH = 27, 65, 60, 72
local cards = {}
for k = 1, 5 do
  local x = (k - 1) * PITCH
  local c = { cv = V("live", ui.canvas(x, CAR_Y, CW, CH, { color = "bg" })), x = x }
  c.name = V("live", L(x + 4, CAR_Y + 4, "", { size = 12, color = "dim", w = CW - 4 }))
  c.tx = V("live", L(x + 4, CAR_Y + 46, "", { size = 12, color = "dim", w = CW - 4 }))
  cards[k] = c
end

-- transactions per slot: one bar per slot, 5 px a slot, scrolling as slots are made
local CHART_Y, CHART_H, SLOT_W = 104, 54, 5
local chart = V("live", ui.canvas(0, CHART_Y, 320, CHART_H, { color = "bg" }))
local chartMax, chartKey = 1000, nil
V("live", L(6, CHART_Y + 1, "TX / SLOT", { size = 12, color = "dim" }))
local maxL = V("live", L(240, CHART_Y + 1, "", { size = 12, color = "dim", w = 74, align = "right" }))

-- Galaxy panel
local PY = 162
local frame = V("live", R(3, PY - 1, 314, 56, { color = PURPLE, radius = 7 }))
V("live", ui.rect(4, PY, 312, 54, { color = "panel", radius = 6 }))
V("live", ui.label(12, PY + 4, "ACTIVE STAKE", { size = 12, color = "dim" }))
local stakeL = V("live", L(12, PY + 16, "-", { size = 20, color = "green" }))
local subL = V("live", L(12, PY + 38, "", { size = 12, color = "dim", w = 126 }))
local RING = 44
local ring = V("live", ui.canvas(142, PY + 5, RING, RING, { color = "panel" }))
local pctL = V("live", L(142, PY + 20, "", { size = 12, w = RING, align = "center" }))
local capL = V("live", L(196, PY + 4, "NEXT LEADER", { size = 12, color = "dim" }))
local cdL = V("live", L(196, PY + 16, "", { size = 20, color = "lpurple", w = 116 }))
local cdSub = V("live", L(196, PY + 38, "", { size = 12, color = "dim", w = 116 }))

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
    ring:pixel(p[1], p[2], p[3] <= t and grad(p[3]) or BORDER)
  end
end

---------------------------------------------------------------------------------
-- SCHEDULE view: 2 next leaders, the current one, the last 6

local SROWS, SROW_Y, SROW_H = 9, 44, 19
local STATS = "%5s %6s %4s"
V("schedule", ui.label(8, 28, "LEADER", { size = 12, color = "lpurple" }))
V("schedule", ui.label(100, 28, "SLOTS", { size = 12, color = "lpurple" }))
V("schedule", ui.label(166, 28, string.format(STATS, "TX", "FEES", "MS"), { size = 12, color = "lpurple", w = 148, align = "right" }))
V("schedule", ui.rect(2, SROW_Y + 2 * SROW_H - 3, 316, SROW_H, { color = PANEL_HI, radius = 4 }))   -- the current leader
local srows = {}
for r = 1, SROWS do
  local y = SROW_Y + (r - 1) * SROW_H
  srows[r] = {
    name = V("schedule", L(8, y, "", { size = 12, color = "dim", w = 90 })),
    cv = V("schedule", ui.canvas(100, y + 1, 58, 12)),
    stat = V("schedule", L(166, y, "", { size = 12, color = "dim", w = 148, align = "right" })),
  }
end

---------------------------------------------------------------------------------
-- GALAXY view

V("galaxy", ui.label(8, 28, "GALAXY LEADER WINDOWS" .. DOT .. "NEXT 10 MIN", { size = 12, color = "lpurple" }))
local TL_Y = 44
local tl = V("galaxy", ui.canvas(0, TL_Y, 320, 40, { color = "bg" }))
local tlKey = nil
for m = 0, 10, 2 do
  V("galaxy", ui.label(m == 10 and 290 or (10 + m * 30 - 6), TL_Y + 42, m == 0 and "now" or (m .. "m"), { size = 12, color = "dim" }))
end
V("galaxy", ui.label(8, 104, "NEXT WINDOW", { size = 12, color = "dim" }))
local gCd = V("galaxy", L(8, 116, "", { size = 32, color = "lpurple", w = 180 }))
local gSlot = V("galaxy", L(190, 104, "", { size = 12, color = "dim", w = 122, align = "right" }))
local gStats = V("galaxy", L(190, 120, "", { size = 14, w = 122, align = "right" }))
local gStats2 = V("galaxy", L(190, 138, "", { size = 12, color = "dim", w = 122, align = "right" }))
V("galaxy", ui.label(8, 156, "LAST 16 BLOCKS" .. DOT .. "TRANSACTIONS", { size = 12, color = "lpurple" }))
local BAR_Y = 170
local bars = V("galaxy", ui.canvas(0, BAR_Y, 320, 46, { color = "bg" }))

local view = "live"
local function showView(v)
  view = v
  for name, list in pairs(views) do
    for _, o in ipairs(list) do o:show(name == v) end
  end
end
showView("live")

---------------------------------------------------------------------------------
-- Drawing

-- A slot's cell: its state's colour, or filling up while it is being made.
local function cell(c, px, py, pw, ph, st, s, live_s, f, now, up)
  if st >= 2 then
    c:rect(px, py, pw, ph, STATE[st])
    if st == 5 and ph > 14 then
      c:line(px + 2, py + 2, px + pw - 3, py + ph - 3, BG) c:line(px + pw - 3, py + 2, px + 2, py + ph - 3, BG)
    end
    return
  end
  c:rect(px, py, pw, ph, BORDER)
  c:rect(px + 1, py + 1, pw - 2, ph - 2, BG)
  if s == live_s then                          -- being made: fill up as the slot goes
    if up then
      local h = math.floor((ph - 2) * f)
      if h > 0 then c:rect(px + 1, py + ph - 1 - h, pw - 2, h, mix(AQUA, 0xFFFFFF, f)) end
    else
      local w = math.floor((pw - 2) * f)
      if w > 0 then c:rect(px + 1, py + 1, w, ph - 2, mix(AQUA, 0xFFFFFF, f)) end
    end
  elseif s < live_s and st == 1 then           -- made, waiting for the network's word
    c:rect(px + 1, py + 1, pw - 2, ph - 2, mix(0x1E3A40, AQUA, (math.sin(now / 80) + 1) * 0.3))
  end
end

-- Does this window have a cell that moves on its own (being made, or waiting)?
local function moving(d, live_s)
  return (live_s >= d[1] and live_s <= d[1] + 3) or (d[1] <= live_s and d[4]:find("1", 1, true) ~= nil)
end

local function drawCard(card, d, current, now, live_s, f)
  local c = card.cv
  local ours = d[3] == 1
  local fc = current and GREEN or (ours and PURPLE or BORDER)
  c:rect(0, 0, CW, CH, fc)
  c:rect(1, 1, CW - 2, CH - 2, ours and OURS_BG or PANEL)
  if ours then for k = 0, 5 do c:rect(1 + k * 10, 1, k == 5 and 8 or 10, 2, grad(k / 5)) end end
  for j = 0, 3 do
    cell(c, 4 + j * 13, 20, 11, 24, tonumber(d[4]:sub(j + 1, j + 1)) or 0, d[1] + j, live_s, f, now, true)
  end
  local w = math.floor((CW - 8) * math.min(d[5], 2400) / 2400)
  c:rect(4, CH - 6, CW - 8, 2, PANEL_HI)
  if w > 0 then c:rect(4, CH - 6, w, 2, ours and GREEN or AQUA) end
end

local function drawCarousel(now, live_s, f)
  if #disp < 5 then return end
  local off = math.floor(slide + 0.5)
  for k = 1, 5 do
    local card, d = cards[k], disp[k]
    local x = (k - 1) * PITCH + off
    if card.x ~= x then
      card.cv:pos(x, CAR_Y) card.x = x
      card.name:pos(x + 4, CAR_Y + 4) card.tx:pos(x + 4, CAR_Y + 46)
    end
    local sig = d[1] .. d[4] .. d[5] .. d[3] .. (k == 3 and "c" or "")
    if sig ~= card.sig or moving(d, live_s) then
      drawCard(card, d, k == 3, now, live_s, f)
      card.sig = sig
      card.name:text(d[2]:sub(1, 7))
      card.name:color(d[3] == 1 and "lime" or (k == 3 and "text" or "dim"))
      card.tx:text(d[5] > 0 and (big(d[5]) .. " tx") or (k > 3 and "next" or ""))
      card.tx:color(k == 3 and "text" or "dim")
    end
  end
end

local function drawChart(live_s, f)
  local shift = math.floor(f * SLOT_W)
  local key = live_s * 8 + shift               -- redraw only when the picture moves
  if key == chartKey then return end
  chartKey = key
  chart:clear(BG)
  local H = CHART_H
  for q = 1, 3 do chart:rect(0, H - (H * q) // 4, 320, 1, PANEL) end
  local scale = (H - 14) / chartMax
  local top = 0
  for k = 0, 320 // SLOT_W + 1 do
    local s = live_s - k
    local x = 320 - k * SLOT_W - shift
    local b = slotTx[s]
    if b then
      if b[3] then chart:rect(x, 12, SLOT_W, H - 12, 0x1A0C33) end
      if b[4] then
        chart:rect(x, H - 4, SLOT_W - 1, 4, PINK)
      else
        local oh = math.floor(b[1] * scale)
        local fh = math.floor(b[2] * scale)
        if b[3] then
          for yy = 0, oh + fh - 1, 2 do chart:rect(x, H - 2 - yy, SLOT_W - 1, 2, grad(yy / (H - 14))) end
        else
          if oh > 0 then chart:rect(x, H - oh, SLOT_W - 1, oh, 0x0C5A44) chart:rect(x, H - oh, SLOT_W - 1, 1, GREEN) end
          if fh > 0 then chart:rect(x, H - oh - fh, SLOT_W - 1, fh, 0x5A1E4A) chart:rect(x, H - oh - fh, SLOT_W - 1, 1, PINK) end
        end
        if b[1] + b[2] > top then top = b[1] + b[2] end
      end
    elseif s == live_s then
      chart:rect(x, H - 3, SLOT_W - 1, 3, AQUA)
    end
  end
  chartMax = math.max(500, ((top // 250) + 1) * 250)
  maxL:text(grouped(chartMax) .. " tx")
end

local function drawSchedule(now, live_s, f)
  if #disp < 5 then return end
  for r = 1, SROWS do
    local d = r <= 3 and disp[6 - r] or hist[r - 3]
    local row = srows[r]
    if d then
      local sig = d[1] .. d[4] .. d[5] .. "/" .. (d[7] or 0) .. "/" .. (d[8] or 0)
      local anim = moving(d, live_s)
      if sig ~= row.sig or anim then
        if sig ~= row.sig then
          local ours = d[3] == 1
          row.name:text((ours and "> " or "") .. d[2]:sub(1, 10))
          row.name:color(ours and "lime" or (r == 3 and "text" or "dim"))
          if r < 3 then
            row.stat:text(r == 1 and "" or "next")
          else
            local fee = (d[7] or 0) > 0 and string.format("%.4f", d[7] / 1000000000) or "-"
            row.stat:text(string.format(STATS, d[5] > 0 and big(d[5]) or "-", fee, (d[8] or 0) > 0 and tostring(d[8]) or "-"))
          end
          row.stat:color(ours and "lime" or (r == 3 and "text" or "dim"))
          row.sig = sig
        end
        row.cv:clear()
        for j = 0, 3 do
          cell(row.cv, j * 15, 0, 13, 12, tonumber(d[4]:sub(j + 1, j + 1)) or 0, d[1] + j, live_s, f, now, false)
        end
      end
    elseif row.sig ~= "" then
      row.name:text("") row.stat:text("") row.cv:clear() row.sig = ""
    end
  end
end

local function nextWindows()
  return info and type(info.next) == "table" and info.next or {}
end

local function drawTimeline(now, p)
  local key = est * 4 + (now // 250) % 4       -- 4 redraws a second is plenty here
  if key == tlKey then return end
  tlKey = key
  tl:clear(BG)
  tl:rect(10, 30, 300, 1, BORDER)
  for m = 0, 10 do tl:rect(10 + m * 30, 28, 1, 5, BORDER) end
  for _, w in ipairs(nextWindows()) do
    local t = ((w - est) - p) * sd / 1000
    if t >= -1 and t <= 600 then
      local x = 10 + math.floor(t / 2)          -- 600 s over 300 px
      for yy = 0, 23 do tl:rect(x, 4 + yy, 3, 1, grad(yy / 24)) end
    end
  end
  tl:rect(9, 0, 2, 34, mix(GREEN, LIME, (math.sin(now / 150) + 1) / 2))
end

local function drawBars()
  bars:clear(BG)
  local H = 44
  for i = 1, 16 do
    local b = blocks[17 - i]                       -- oldest on the left
    local x = 8 + (i - 1) * 19
    bars:rect(x, H - 1, 15, 1, BORDER)
    if b then
      if b[2] then
        bars:rect(x, H - 6, 15, 5, PINK)
      else
        local h = math.max(2, math.floor((H - 2) * math.min(b[1], 1200) / 1200))
        for yy = 0, h - 1 do bars:rect(x, H - 1 - yy, 15, 1, grad(yy / (H - 2))) end
      end
    end
  end
end

---------------------------------------------------------------------------------
-- Messages

local skipPct = 0
local function onInfo(m)
  info = m
  if type(m.sd) == "number" and m.sd > 50 then sd = m.sd end
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
  gStats:text(grouped(m.done or 0) .. " / " .. grouped(m.leader or 0))
  gStats2:text(string.format("E%d skip %.2f%%", m.epoch or 0, skipPct))
  if #blocks == 0 and type(m.last) == "table" then
    for i, b in ipairs(m.last) do
      if type(b) == "table" then blocks[i] = { b[1] or 0, b[2] == 1 } end
    end
    if view == "galaxy" then drawBars() end
  end
end

local function remember(d)       -- a past window, for the schedule: newest first, 6 kept
  for i = 1, #hist do
    if hist[i][1] == d[1] then hist[i] = d return end
    if hist[i][1] < d[1] then table.insert(hist, i, d) hist[7] = nil return end
  end
  if #hist < 6 then hist[#hist + 1] = d end
end

local function onFrame(m, now)
  if type(m.r) ~= "table" or #m.r < 5 or type(m.e) ~= "number" then return end
  local new = {}
  for k = 1, 5 do
    local d = m.r[6 - k]                     -- the relay sends the future first
    if type(d) ~= "table" or #d < 5 or type(d[4]) ~= "string" or type(d[2]) ~= "string" then return end
    new[k] = d
  end
  if disp[3] and new[3][1] ~= disp[3][1] then  -- the next leader took over: slide
    slide = slide + PITCH * ((new[3][1] - disp[3][1]) // 4)
    if slide > PITCH * 2 or slide < 0 then slide = 0 end
  end
  disp = new
  remember(new[1]) remember(new[2])
  for k = 1, 5 do
    local d = new[k]
    local per = d[6]
    for j = 0, 3 do
      local st = tonumber(d[4]:sub(j + 1, j + 1)) or 0
      if st >= 2 then
        local ok = type(per) == "table" and per[j * 2 + 1] or 0
        local fail = type(per) == "table" and per[j * 2 + 2] or 0
        slotTx[d[1] + j] = { ok, fail, d[3] == 1, st == 5 }
      end
    end
  end
  if m.e ~= est then
    newSlot(m.e, now)
    tickAt = now
    slotTx[est - 100] = nil                 -- the chart shows ~64 slots: forget older ones
    chartKey = nil
  end
  tpsL:text(grouped((m.ok or 0) + (m.fail or 0)))
  live = true
end

local ledSlot                    -- defined with the LEDs below

local function onSlot(m)
  local i = m.i + 1
  if i == 1 or not win.on then win = { on = true, tx = 0, fee = 0, skip = false } end
  local ok = m.st == "ok"
  if ok then win.tx = win.tx + (m.tx or 0) win.fee = win.fee + (m.fee or 0) else win.skip = true end
  table.insert(blocks, 1, { m.tx or 0, not ok })
  blocks[17] = nil
  if view == "galaxy" then drawBars() end
  ledSlot(i, ok)
  if i == 4 then win.on = false win.doneAt = sys.millis() end
end

---------------------------------------------------------------------------------
-- LEDs

local MODES = { "full", "galaxy", "off" }
local mode = 1
local level = {}
for n = 1, 6 do level[n] = { 0, 0, 0 } end
local fadeAt, FADE_MS = nil, 1200

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
    led.set(n, math.floor(c[1] * k), math.floor(c[2] * k), math.floor(c[3] * k))
  end
  if left and left < 10 then
    local speed = 1 + (10 - left) * 0.6
    local b = (math.sin(now / 1000 * speed * math.pi) + 1) / 2
    local p = math.floor(30 + 200 * b * (1 - left / 12))
    led.set(7, p // 2, p // 4, p) led.set(8, p // 2, p // 4, p)
  elseif MODES[mode] == "full" and now - tickAt < 60 then
    led.set(7, 20, 60, 50) led.set(8, 20, 60, 50)
  else
    led.set(7, 0, 0, 0) led.set(8, 0, 0, 0)
  end
end

---------------------------------------------------------------------------------
-- Connections. Two ways in, whichever delivers:
--   Wi-Fi: the relay's websocket. The badge server allows it only for an app that is
--     in the store or in a test run ("denied" otherwise).
--   Bluetooth: a phone runs the relay's /install page, which follows the relay and
--     writes the same messages, packed, to this badge. Needs nothing from the store.

local function dispatch(m, now)
  lastMsg = now
  if m.t == "f" then onFrame(m, now)
  elseif m.t == "info" then onInfo(m)
  elseif m.t == "slot" and type(m.i) == "number" and m.i >= 0 and m.i <= 3 then onSlot(m) end
end

-- Wi-Fi. Asking for a socket keeps the radio busy for a few seconds, which Bluetooth
-- shares: never ask while the phone is feeding us, and rarely once refused.
local retry = 1000
local connect
connect = function()
  if sys.millis() - lastBle < 10000 then timer.after(60000, connect) return end
  ws.open(RELAY, function(event, data)
    if event == "open" then
      retry = 1000
    elseif event == "message" then
      local m = json.decode(data)
      if type(m) == "table" then dispatch(m, sys.millis()) end
    else
      local refused = data == "denied" or data == "not linked" or data == "host not allowed"
      if not live then tpsL:text(refused and "phone?" or tostring(data)) end
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
  if k == "F" and #d == 184 then               -- frame: est, tps, 5 windows of 35 bytes
    local _, e, ok, fail = string.unpack("<c1I4I2I2", d)
    local cur, rows = e - e % 4, {}
    for j = 0, 4 do
      local ours, cells, a1, b1, a2, b2, a3, b3, a4, b4, fee, ms, name =
        string.unpack("<BI2I2I2I2I2I2I2I2I2I4I2c10", d, 10 + j * 35)
      local c = ""
      for n = 0, 3 do c = c .. ((cells >> (n * 4)) & 15) end
      name = name:gsub("[%z ]+$", "")
      rows[j + 1] = { cur + 8 - 4 * j, name, ours, c, a1 + b1 + a2 + b2 + a3 + b3 + a4 + b4,
        { a1, b1, a2, b2, a3, b3, a4, b4 }, fee, ms }
    end
    return { t = "f", e = e, ok = ok, fail = fail, r = rows }
  elseif k == "S" and #d == 13 then            -- one of our slots
    local _, s, i, ok, tx, fee = string.unpack("<c1I4BBI2I4", d)
    return { t = "slot", s = s, i = i, st = ok == 1 and "ok" or "skip", tx = tx, fee = fee }
  elseif k == "I" and #d >= 26 then            -- info
    local _, stake, share, rank, comm, delinq, epoch, pct, msd, leader, done, skip, up, nNext, nLast =
      string.unpack("<c1I4I2I2I2BI2BI2I2I2I2BBB", d)
    if #d ~= 26 + nNext * 4 + nLast * 2 then return nil end
    local m = { t = "info", stake = stake, share = share / 1000, rank = rank, delinq = delinq == 1, epoch = epoch,
      pct = pct, sd = msd, leader = leader, done = done, skip = skip, up = up == 1 and "live" or "reconnecting",
      next = {}, last = {} }
    if comm ~= 0xFFFF then m.comm = comm / 100 end
    local pos = 27
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
  local function advertise() ble.advertise({ name = "Galaxy", service = NUS, connectable = true }) end
  local served = ble.serve({ service = NUS, chars = { { uuid = RX, write = true } } }, function(event, a, b)
    if event == "open" then
      ui.toast("Phone connected")
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
  if slide > 0 then
    slide = slide * 0.6
    if slide < 0.5 then slide = 0 end
  end
  if live and now - lastMsg > 3000 then      -- nothing for 3 s: say so, don't just freeze
    live = false
    tpsL:text("no data")
  end
  dot:color(live and mix(0x0A5A40, GREEN, (math.sin(now / 200) + 1) / 2) or 0xFF754A)

  local p = live and phase(now) or 0
  local whole = math.floor(p)
  local live_s, f = est + whole, p - whole

  -- Galaxy's next window
  local w = nil
  for _, s in ipairs(nextWindows()) do if s + 3 >= est then w = s break end end
  local left = nil
  local leading = win.on or (w ~= nil and w <= live_s)
  if leading then
    capL:text("LEADER NOW") capL:color("lime")
    cdL:text("+" .. grouped(win.tx) .. " tx") cdL:color("lime")
    cdSub:text(string.format("%.4f SOL fees", win.fee / 1000000000)) cdSub:color("green")
    frame:color(mix(PURPLE, LIME, (math.sin(now / 60) + 1) / 2))
  elseif w then
    left = ((w - est) - p) * sd / 1000
    if left < 0 then left = 0 end
    capL:text("NEXT LEADER") capL:color("dim")
    cdL:text(dur(left)) cdL:color(left < 10 and "pink" or "lpurple")
    frame:color(left < 10 and mix(PURPLE, PINK, (math.sin(now / 100) + 1) / 2) or PURPLE)
    if info and info.delinq then
      cdSub:text("DELINQUENT") cdSub:color("pink")
    elseif win.doneAt and now - win.doneAt < 4000 then
      cdSub:text("last +" .. grouped(win.tx) .. " tx") cdSub:color("green")
    else
      cdSub:text(string.format("E%d skip %.1f%%", info and info.epoch or 0, skipPct))
      cdSub:color(skipPct > 0 and "orange" or "dim")
    end
  end

  if view == "live" then
    drawCarousel(now, live_s, f)
    drawChart(live_s, f)
  elseif view == "schedule" then
    drawSchedule(now, live_s, f)
  else
    drawTimeline(now, p)
    if leading then gCd:text("LEADER NOW") gCd:color("lime")
    elseif left then gCd:text(dur(left)) gCd:color(left < 10 and "pink" or "lpurple") end
    gSlot:text(w and ("slot " .. grouped(w)) or "")
  end
  leds(now, left)
end

function on_key(key)
  if key == "left" or key == "right" then
    local i = 1
    for n, v in ipairs(ORDER) do if v == view then i = n end end
    i = (i - 1 + (key == "right" and 1 or -1)) % #ORDER + 1
    showView(ORDER[i])
    -- what was drawn while hidden is stale: draw this view afresh
    for k = 1, 5 do cards[k].sig = nil end
    for r = 1, SROWS do srows[r].sig = nil end
    chartKey, tlKey = nil, nil
    if view == "galaxy" then drawBars() end
    return true
  elseif key == "select" then
    mode = mode % #MODES + 1
    if MODES[mode] == "off" then led.off() end
    ui.toast("LEDs: " .. MODES[mode])
    return true
  end
  return false
end
