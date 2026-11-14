-- Galaxy Live: the Solana cluster making blocks, live, with Galaxy front and centre.
-- A badge-sized take on the Firedancer dashboard.
--
-- LIVE view
--   Leader carousel: five leader windows, the past on the left, the future on the
--   right, the current one framed in green. Each card shows the leader and its four
--   slots: the slot being made fills up as it happens, then turns blue (completed),
--   light purple (notarized) and green (rooted), or pink if skipped. The cards
--   slide left when the next leader takes over. Galaxy's cards are purple.
--   TPS chart: successful and failed transactions a second, the last 16 s,
--   scrolling, shaded purple while Galaxy is leader.
--   Galaxy panel: active stake, rank, an epoch ring, the countdown to its next
--   window; while it is leader, its transactions and fees as they come.
-- GALAXY view (LEFT / RIGHT)
--   Galaxy's next windows on a 10-minute timeline, a big countdown, and its last
--   16 blocks as bars (transactions each).
--
-- LEDs: while Galaxy is leader the six top LEDs fill slot by slot (purple to
-- green, red for a skip), then flash and fade. The side LEDs breathe as its next
-- window comes and, in "full" mode, tick with every slot of the cluster.
-- Keys: LEFT/RIGHT view, SELECT LED mode (full / Galaxy / off), CANCEL exit.
--
-- Data: the relay (server.ts or worker/), about 10 messages a second, over Wi-Fi
-- (a WebSocket) or through a phone over Bluetooth (the relay's /install page).

local RELAY = "wss://galaxy-live-relay.theo-b59.workers.dev/live"   -- your relay; its host goes in app.json "hosts"
local OWNER = "ghosty"

---------------------------------------------------------------------------------
-- Colours and helpers

local BG, PANEL, PANEL_HI, BORDER = 0x000000, 0x111116, 0x1C1B26, 0x2A2935
local PURPLE, GREEN, PINK, LPURPLE, BLUE, AQUA, LIME = 0x9945FF, 0x14F195, 0xEB54BC, 0xB6B0FF, 0x64A8F2, 0x80ECFF, 0xACFF9B
local OURS_BG = 0x221040
local STATE = { [2] = BLUE, [3] = LPURPLE, [4] = GREEN, [5] = PINK }

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

-- labels: set text / colour only when they change
local function L(x, y, text, o)
  local l = ui.label(x, y, text, o)
  return { o = l, t = text, c = nil,
    text = function(self, s) if self.t ~= s then self.o:text(s) self.t = s end end,
    color = function(self, c) if self.c ~= c then self.o:color(c) self.c = c end end,
    pos = function(self, px, py) if self.x ~= px or self.y ~= py then self.o:pos(px, py) self.x, self.y = px, py end end,
    show = function(self, b) self.o:show(b) end }
end

---------------------------------------------------------------------------------
-- State from the relay

local info = nil
local est, estAt, sd = 0, 0, 400 -- estimated slot, when we heard it, ms per slot
local disp = {}                  -- carousel cards left to right: {s, name, ours, cells, tx}
local ghost = nil                -- the card that just slid off on the left
local slide = 0                  -- px the carousel still has to slide
local tpsOk, tpsFail = 0, 0
local live = false
local win = { on = false, tx = 0, fee = 0, skip = false }   -- Galaxy's window in progress
local blocks = {}                -- Galaxy's last 16 slots: {tx, skipped}

local function liveSlot(now)     -- the slot being made now, by our clock (at most one ahead)
  local s = est + (now - estAt) // sd
  return s > est + 1 and est + 1 or s
end

---------------------------------------------------------------------------------
-- Header

ui.bg("bg")
ui.gradient(0, 0, ui.W, 2)
ui.label(8, 4, "GALAXY", { size = 20 })
local dotR = ui.rect(92, 12, 6, 6, { color = "dim", radius = 3 })
local dotC = nil
local function dotColor(c) if c ~= dotC then dotR:color(c) dotC = c end end
ui.label(103, 9, "@" .. OWNER, { size = 12, color = "aqua" })
local tpsL = L(150, 3, "", { size = 20, w = 128, align = "right" })
ui.label(282, 10, "TPS", { size = 12, color = "dim" })

---------------------------------------------------------------------------------
-- LIVE view

local liveObjs = {}
local function V(o) liveObjs[#liveObjs + 1] = o return o end

-- leader carousel
local CAR_Y, CAR_H, PITCH, CW, CH = 26, 74, 65, 60, 70
local car = V(ui.canvas(0, CAR_Y, 320, CAR_H, { color = "bg" }))
local names, txs = {}, {}
for k = 1, 5 do
  names[k] = L(0, 0, "", { size = 12, color = "dim", w = CW - 6 })
  txs[k] = L(0, 0, "", { size = 12, color = "dim", w = CW - 6 })
  V(names[k]) V(txs[k])
end

-- transactions per slot: one bar per slot, 5 px a slot, scrolling as slots are made
local CHART_Y, CHART_H, SLOT_W = 104, 54, 5
local chart = V(ui.canvas(0, CHART_Y, 320, CHART_H, { color = "bg" }))
local slotTx = {}                -- slot -> {ok, fail, ours, skipped}
local chartMax = 1000
V(L(6, CHART_Y + 1, "TX / SLOT", { size = 12, color = "dim" }))
local maxL = V(L(240, CHART_Y + 1, "", { size = 12, color = "dim", w = 74, align = "right" }))

-- Galaxy panel
local PY = 162
local frameR = V(ui.rect(3, PY - 1, 314, 56, { color = PURPLE, radius = 7 }))
local frameC = PURPLE
local function frameColor(c) if c ~= frameC then frameR:color(c) frameC = c end end
V(ui.rect(4, PY, 312, 54, { color = "panel", radius = 6 }))
V(ui.label(12, PY + 4, "ACTIVE STAKE", { size = 12, color = "dim" }))
local stakeL = V(L(12, PY + 16, "-", { size = 20, color = "green" }))
local subL = V(L(12, PY + 38, "", { size = 12, color = "dim", w = 124 }))
local RING = 44
local ring = V(ui.canvas(140, PY + 5, RING, RING, { color = "panel" }))
local pctL = V(L(140, PY + 15, "", { size = 12, w = RING, align = "center" }))
local epL = V(L(140, PY + 27, "", { size = 12, color = "dim", w = RING, align = "center" }))
local capL = V(L(194, PY + 4, "NEXT LEADER", { size = 12, color = "dim" }))
local cdL = V(L(194, PY + 16, "", { size = 20, color = "lpurple", w = 118 }))
local cdSub = V(L(194, PY + 38, "", { size = 12, color = "dim", w = 118 }))

-- the ring's pixels, worked out once: {x, y, angle 0..1 from the top, clockwise}
local ringPx = {}
do
  local c, r1, r2 = (RING - 1) / 2, 15.5, 21.5
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
local function drawRing(pct)
  local t = pct / 100
  for _, p in ipairs(ringPx) do
    ring:pixel(p[1], p[2], p[3] <= t and grad(p[3]) or BORDER)
  end
end

---------------------------------------------------------------------------------
-- GALAXY view

local galObjs = {}
local function G(o) galObjs[#galObjs + 1] = o return o end
G(ui.label(8, 28, "GALAXY LEADER WINDOWS  ·  NEXT 10 MIN", { size = 12, color = "lpurple" }))
local TL_Y = 44
local tl = G(ui.canvas(0, TL_Y, 320, 40, { color = "bg" }))
for m = 0, 10, 2 do
  G(ui.label(10 + m * 30 - 6, TL_Y + 42, m == 0 and "now" or (m .. "m"), { size = 12, color = "dim" }))
end
G(ui.label(8, 104, "NEXT WINDOW", { size = 12, color = "dim" }))
local gCd = G(L(8, 116, "", { size = 32, color = "lpurple", w = 200 }))
local gSlot = G(L(170, 104, "", { size = 12, color = "dim", w = 142, align = "right" }))
local gStats = G(L(170, 122, "", { size = 14, w = 142, align = "right" }))
local gStats2 = G(L(170, 138, "", { size = 12, color = "dim", w = 142, align = "right" }))
G(ui.label(8, 156, "LAST 16 BLOCKS  ·  TRANSACTIONS", { size = 12, color = "lpurple" }))
local BAR_Y = 170
local bars = G(ui.canvas(0, BAR_Y, 320, 46, { color = "bg" }))

local view = "live"
local function showView(v)
  view = v
  for _, o in ipairs(liveObjs) do o:show(v == "live") end
  for _, o in ipairs(galObjs) do o:show(v == "galaxy") end
end
showView("live")

---------------------------------------------------------------------------------
-- Drawing

local function card(c, x, d, current, now, live_s)
  if x <= -CW or x >= 320 then return end
  local y = 2
  local ours = d[3] == 1
  c:rect(x, y, CW, CH, ours and OURS_BG or PANEL)
  -- frame
  local fc = current and GREEN or (ours and PURPLE or BORDER)
  c:rect(x, y, CW, 1, fc) c:rect(x, y + CH - 1, CW, 1, fc)
  c:rect(x, y, 1, CH, fc) c:rect(x + CW - 1, y, 1, CH, fc)
  if ours then for k = 0, 5 do c:rect(x + 1 + k * 10, y + 1, 10, 2, grad(k / 5)) end end
  -- the four slots
  local cells = d[4]
  for j = 0, 3 do
    local s = d[1] + j
    local st = tonumber(cells:sub(j + 1, j + 1)) or 0
    local px, py, pw, ph = x + 4 + j * 13, y + 20, 11, 24
    if st >= 2 then
      c:rect(px, py, pw, ph, STATE[st])
      if st == 5 then c:line(px + 2, py + 2, px + pw - 3, py + ph - 3, BG) c:line(px + pw - 3, py + 2, px + 2, py + ph - 3, BG) end
    else
      c:rect(px, py, pw, ph, BG)
      c:rect(px, py, pw, 1, BORDER) c:rect(px, py + ph - 1, pw, 1, BORDER)
      c:rect(px, py, 1, ph, BORDER) c:rect(px + pw - 1, py, 1, ph, BORDER)
      if s == live_s then                      -- being made: fill up as the slot goes
        local f = ((now - estAt) - (s - est) * sd) / sd
        f = f < 0 and 0 or (f > 1 and 1 or f)
        local h = math.floor((ph - 2) * f)
        if h > 0 then c:rect(px + 1, py + ph - 1 - h, pw - 2, h, mix(AQUA, 0xFFFFFF, f)) end
      elseif s < live_s and st == 1 then        -- made, waiting for the network's word
        local p = (math.sin(now / 80) + 1) / 2
        c:rect(px + 1, py + 1, pw - 2, ph - 2, mix(0x1E3A40, AQUA, p * 0.6))
      end
    end
  end
  -- transactions bar
  local w = math.floor((CW - 8) * math.min(d[5], 2400) / 2400)
  c:rect(x + 4, y + CH - 6, CW - 8, 2, PANEL_HI)
  if w > 0 then c:rect(x + 4, y + CH - 6, w, 2, ours and GREEN or AQUA) end
end

local function drawCarousel(now)
  car:clear(BG)
  if #disp < 5 then return end
  local live_s = liveSlot(now)
  local off = math.floor(slide + 0.5)
  if ghost then card(car, -PITCH + off, ghost, false, now, live_s) end
  for k = 1, 5 do
    local x = (k - 1) * PITCH + off
    local d = disp[k]
    card(car, x, d, k == 3, now, live_s)
    local n, t = names[k], txs[k]
    n:pos(x + 4, CAR_Y + 6)
    t:pos(x + 4, CAR_Y + 48)
    n:text(d[2]:sub(1, 10))
    n:color(d[3] == 1 and "lime" or (k == 3 and "text" or "dim"))
    t:text(d[5] > 0 and (big(d[5]) .. " tx") or (k > 3 and "next" or ""))
    t:color(k == 3 and "text" or "dim")
  end
end

local function drawChart(now)
  chart:clear(BG)
  local H = CHART_H
  for q = 1, 3 do chart:rect(0, H - (H * q) // 4, 320, 1, PANEL) end
  local live_s = liveSlot(now)
  -- how far into the live slot we are, so the bars glide instead of jumping
  local f = ((now - estAt) - (live_s - est) * sd) / sd
  f = f < 0 and 0 or (f > 1 and 1 or f)
  local shift = math.floor(f * SLOT_W)
  local scale = (H - 14) / chartMax
  local top = 0
  for k = 0, 320 // SLOT_W + 1 do
    local s = live_s - k
    local x = 320 - SLOT_W - k * SLOT_W - shift + SLOT_W
    local b = slotTx[s]
    if b then
      if b[3] then chart:rect(x, 12, SLOT_W, H - 12, 0x1A0C33) end
      if b[4] then
        chart:rect(x, H - 4, SLOT_W - 1, 4, PINK)
      else
        local oh = math.floor(b[1] * scale)
        local fh = math.floor(b[2] * scale)
        if b[3] then
          for yy = 0, oh + fh - 1, 2 do chart:rect(x, H - 1 - yy - 1, SLOT_W - 1, 2, grad(yy / (H - 14))) end
        else
          if oh > 0 then chart:rect(x, H - oh, SLOT_W - 1, oh, 0x0C5A44) chart:rect(x, H - oh, SLOT_W - 1, 1, GREEN) end
          if fh > 0 then chart:rect(x, H - oh - fh, SLOT_W - 1, fh, 0x5A1E4A) chart:rect(x, H - oh - fh, SLOT_W - 1, 1, PINK) end
        end
        if b[1] + b[2] > top then top = b[1] + b[2] end
      end
    elseif s == live_s then                     -- the slot being made
      local p = (math.sin(now / 80) + 1) / 2
      chart:rect(x, H - 3, SLOT_W - 1, 3, mix(0x1E3A40, AQUA, p))
    end
  end
  chartMax = math.max(500, ((top // 250) + 1) * 250)
end

local function drawTimeline(now)
  tl:clear(BG)
  tl:rect(10, 30, 300, 1, BORDER)
  for m = 0, 10 do tl:rect(10 + m * 30, 28, 1, 5, BORDER) end
  if info and type(info.next) == "table" then
    for _, w in ipairs(info.next) do
      local t = ((w - est) * sd - (now - estAt)) / 1000
      if t >= -1 and t <= 600 then
        local x = 10 + math.floor(t / 2)          -- 600 s over 300 px
        local h = 24
        for yy = 0, h - 1 do tl:rect(x, 28 - h + yy, 3, 1, grad(yy / h)) end
      end
    end
  end
  local p = (math.sin(now / 150) + 1) / 2
  tl:rect(9, 0, 2, 34, mix(GREEN, LIME, p))
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

local function onInfo(m)
  info = m
  if type(m.sd) == "number" and m.sd > 50 then sd = m.sd end
  stakeL:text(big(m.stake or 0) .. " SOL")
  local parts = {}
  if (m.rank or 0) > 0 then parts[#parts + 1] = "#" .. m.rank end
  if m.share then parts[#parts + 1] = string.format("%.2f%%", m.share) end
  if m.comm then parts[#parts + 1] = string.format("%g%%", m.comm) end
  subL:text(table.concat(parts, " · "))
  pctL:text((m.pct or 0) .. "%")
  epL:text("E" .. (m.epoch or ""))
  drawRing(m.pct or 0)
  local past = (m.done or 0) + (m.skip or 0)
  local skip = past > 0 and (m.skip or 0) * 100 / past or 0
  gStats:text(grouped(m.done or 0) .. " / " .. grouped(m.leader or 0))
  gStats2:text(string.format("this epoch · skip %.2f%%", skip))
  if #blocks == 0 and type(m.last) == "table" then
    for i, b in ipairs(m.last) do
      if type(b) == "table" then blocks[i] = { b[1] or 0, b[2] == 1 } end
    end
    if view == "galaxy" then drawBars() end
  end
  if not win.on then cdSub:text(string.format("skip %.2f%%", skip)) cdSub:color(skip > 0 and "orange" or "dim") end
  if m.delinq then cdSub:text("DELINQUENT") cdSub:color("pink") end
end

local function onFrame(m, now)
  if type(m.r) ~= "table" or #m.r < 5 then return end
  local new = {}
  for k = 1, 5 do
    local d = m.r[6 - k]                     -- the relay sends future first
    if type(d) ~= "table" or #d < 5 then return end
    new[k] = d
  end
  if disp[3] and new[3][1] ~= disp[3][1] then  -- the next leader took over: slide
    ghost = disp[1]
    slide = slide + PITCH * ((new[3][1] - disp[3][1]) // 4)
    if slide > PITCH * 2 then slide = 0 ghost = nil end
  end
  disp = new
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
    est, estAt = m.e, now
    slotTx[est - 100] = nil                 -- the chart shows ~64 slots: forget older ones
  end
  tpsOk, tpsFail = m.ok or 0, m.fail or 0
  tpsL:text(grouped(tpsOk + tpsFail))
  live = true
end

local ledSlot                    -- defined with the LEDs below

local function onSlot(m)
  local i = m.i + 1
  if i == 1 then win = { on = true, tx = 0, fee = 0, skip = false } end
  win.on = true
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
local tickAt = -1000

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

local lastMsg = -10000
local function dispatch(m, now)
  lastMsg = now
  if m.t == "f" then
    local before = est
    onFrame(m, now)
    if est ~= before then tickAt = now end
  elseif m.t == "info" then onInfo(m)
  elseif m.t == "slot" and type(m.i) == "number" and m.i >= 0 and m.i <= 3 then onSlot(m) end
end

-- Wi-Fi
local retry = 1000
local function connect()
  ws.open(RELAY, function(event, data)
    if event == "open" then
      retry = 1000
    elseif event == "message" then
      local m = json.decode(data)
      if type(m) == "table" then dispatch(m, sys.millis()) end
    else
      -- refused by the badge server: no point hammering, the phone can feed us
      local refused = data == "denied" or data == "not linked" or data == "host not allowed"
      if sys.millis() - lastMsg > 3000 then tpsL:text(refused and "phone?" or tostring(data)) end
      timer.after(refused and 60000 or retry, connect)
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
  if k == "F" and #d == 154 then               -- frame: est, tps, 5 windows of 29 bytes
    local _, e, ok, fail = string.unpack("<c1I4I2I2", d)
    local cur, rows = e - e % 4, {}
    for j = 0, 4 do
      local ours, cells, a1, b1, a2, b2, a3, b3, a4, b4, name = string.unpack("<BI2I2I2I2I2I2I2I2I2c10", d, 10 + j * 29)
      local c = ""
      for n = 0, 3 do c = c .. ((cells >> (n * 4)) & 15) end
      name = name:gsub("[%z ]+$", "")
      rows[j + 1] = { cur + 8 - 4 * j, name, ours, c, a1 + b1 + a2 + b2 + a3 + b3 + a4 + b4, { a1, b1, a2, b2, a3, b3, a4, b4 } }
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
      if ok and m then dispatch(m, sys.millis()) end
    elseif event == "close" then
      advertise()
    end
  end)
  if served then advertise() end
end

---------------------------------------------------------------------------------
-- Every tick (30 ms)

local function nextWindow()
  if not info or type(info.next) ~= "table" then return nil end
  for _, w in ipairs(info.next) do if w + 3 >= est then return w end end
  return nil
end

local tickN = 0
function on_tick(ms)
  local now = sys.millis()
  if slide > 0 then
    slide = slide * 0.55
    if slide < 0.5 then slide = 0 ghost = nil end
  end
  if live and now - lastMsg > 3000 then live = false end
  dotColor(live and mix(0x0A5A40, GREEN, (math.sin(now / 200) + 1) / 2) or 0xFF754A)

  -- countdown
  local w = nextWindow()
  local left = nil
  local leading = win.on or (w and w <= liveSlot(now))
  if leading then
    capL:text("LEADER NOW") capL:color("lime")
    cdL:text("+" .. grouped(win.tx) .. " tx") cdL:color("lime")
    cdSub:text(string.format("%.4f SOL fees", win.fee / 1000000000)) cdSub:color("green")
    frameColor(mix(PURPLE, LIME, (math.sin(now / 60) + 1) / 2))
  elseif w then
    left = ((w - est) * sd - (now - estAt)) / 1000
    if left < 0 then left = 0 end
    capL:text("NEXT LEADER") capL:color("dim")
    cdL:text(dur(left)) cdL:color(left < 10 and "pink" or "lpurple")
    frameColor(left < 10 and mix(PURPLE, PINK, (math.sin(now / 100) + 1) / 2) or PURPLE)
    if win.doneAt and now - win.doneAt < 4000 then
      cdSub:text(string.format("last +%s tx", grouped(win.tx))) cdSub:color("green")
    end
  end

  if view == "live" then
    drawCarousel(now)
    tickN = tickN + 1
    if tickN % 2 == 0 then
      drawChart(now)
      maxL:text(grouped(chartMax) .. " tx")
    end
  else
    drawTimeline(now)
    if leading then gCd:text("LEADER NOW") gCd:color("lime")
    elseif left then gCd:text(dur(left)) gCd:color(left < 10 and "pink" or "lpurple") end
    gSlot:text(w and ("slot " .. grouped(w)) or "")
  end
  leds(now, left)
end

function on_key(key)
  if key == "left" or key == "right" then
    showView(view == "live" and "galaxy" or "live")
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
