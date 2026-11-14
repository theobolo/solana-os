-- Galaxy Live: the Galaxy validator, live on the badge.
--
-- Screen: active stake, stake rank and share, commission, epoch progress, blocks
-- produced and skip rate this epoch, a countdown to the next leader window and
-- the last block it produced (transactions, fees).
--
-- LEDs: while Galaxy is leader, the six top LEDs fill up slot by slot (4 slots
-- a window, purple to green; red for a skipped slot), then flash and fade. The
-- two side LEDs breathe as the next window gets close.
--
-- Data: one WebSocket to your relay (server.ts), which follows the Firedancer
-- dashboard and sends only what concerns Galaxy.

local RELAY = "wss://galaxy.example.com/live"   -- your relay; its host goes in app.json "hosts"
local OWNER = "ghosty"

---------------------------------------------------------------------------------
-- Formatting

local function big(n)            -- 6706820 -> "6.71M"
  if n >= 1000000 then return string.format("%.2fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fK", n / 1000) end
  return tostring(n)
end

local function sol(lamports)     -- 24626206 -> "0.0246"
  return string.format("%.4f", lamports / 1000000000)
end

local function grouped(n)        -- 469347723 -> "469 347 723"
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
  return (out:gsub("^ ", ""))
end

---------------------------------------------------------------------------------
-- Screen

ui.bg("bg")
ui.gradient(0, 0, ui.W, 3)
ui.label(8, 4, "GALAXY", { size = 32 })
ui.label(150, 6, "@" .. OWNER, { size = 14, color = "aqua", w = 162, align = "right" })
local live = ui.label(150, 24, "connecting", { size = 12, color = "dim", w = 162, align = "right" })

local stake = ui.label(8, 42, "-", { size = 32, color = "green" })
local stakeSub = ui.label(8, 78, "active stake", { size = 12, color = "dim", w = 304 })

local epochL = ui.label(8, 96, "Epoch -", { size = 14 })
local epochR = ui.label(160, 96, "", { size = 14, color = "dim", w = 152, align = "right" })
local bar = ui.bar(8, 116, 304, 6, 0)

local blocks = ui.label(8, 128, "Blocks -", { size = 14 })
local skipL = ui.label(160, 128, "", { size = 14, color = "dim", w = 152, align = "right" })

-- the current leader window: 4 slots
local squares = {}
for n = 1, 4 do
  squares[n] = ui.rect(8 + (n - 1) * 30, 152, 26, 22, { color = "panel", radius = 4, border = "border" })
end
local leader = ui.label(132, 152, "", { size = 20, color = "lpurple", w = 180, align = "right" })
local last = ui.label(8, 182, "", { size = 12, color = "dim", w = 304 })
ui.hint("SELECT LEDs on/off   CANCEL exit")

---------------------------------------------------------------------------------
-- LEDs: levels we fade on every tick

local leds = true
local level = {}                -- 1..8 -> {r, g, b} target colour, faded by `fade`
for n = 1, 8 do level[n] = { 0, 0, 0 } end
local fadeAt = nil              -- sys.millis() when the window's LEDs start fading
local FADE_MS = 1200

-- purple (9945FF) to green (14F195) across the top six
local function grad(n)
  local t = (n - 1) / 5
  return math.floor(0x99 + (0x14 - 0x99) * t), math.floor(0x45 + (0xF1 - 0x45) * t), math.floor(0xFF + (0x95 - 0xFF) * t)
end

local function setTop(upto, skippedFrom)
  for n = 1, 6 do
    if n <= upto then
      if skippedFrom and n > skippedFrom then level[n] = { 255, 30, 30 }
      else level[n] = { grad(n) } end
    end
  end
end

---------------------------------------------------------------------------------
-- State from the relay

local nextIn, nextAt = nil, 0   -- seconds to the next window when we heard, and when
local inWindow = false
local winSkip = false

local function onInfo(m)
  stake:text(big(m.stake or 0) .. " SOL")
  local parts = {}
  if (m.rank or 0) > 0 then parts[#parts + 1] = "#" .. m.rank .. " by stake" end
  if m.share then parts[#parts + 1] = string.format("%.2f%% of network", m.share) end
  if m.comm then parts[#parts + 1] = string.format("%g%% comm", m.comm) end
  stakeSub:text(table.concat(parts, "  ·  "))
  epochL:text("Epoch " .. (m.epoch or "-"))
  epochR:text((m.pct or 0) .. "%")
  bar:set(m.pct or 0)
  blocks:text("Blocks " .. grouped(m.done or 0) .. " / " .. grouped(m.leader or 0))
  local past = (m.done or 0) + (m.skip or 0)
  skipL:text(string.format("skip %.2f%%", past > 0 and (m.skip or 0) * 100 / past or 0))
  skipL:color((m.skip or 0) > 0 and "orange" or "dim")
  if m.delinq then
    live:text("DELINQUENT") live:color("pink")
  else
    live:text(m.up == "live" and "LIVE" or (m.up or "?")) live:color(m.up == "live" and "green" or "orange")
  end
  if m.nextIn then nextIn, nextAt = m.nextIn, sys.millis() end
end

local function onSlot(m)
  local i = m.i + 1                       -- 1..4 in the window
  if i == 1 then                          -- a new window
    for n = 1, 4 do squares[n]:color("panel") end
    for n = 1, 6 do level[n] = { 0, 0, 0 } end
    fadeAt, winSkip = nil, false
  end
  inWindow = true
  local ok = m.st == "ok"
  squares[i]:color(ok and "green" or "pink")
  if not ok then winSkip = true end
  -- 4 slots over 6 LEDs: 2, 3, 5, 6
  local upto = math.ceil(i * 6 / 4)
  local from = math.ceil((i - 1) * 6 / 4)
  setTop(upto, (not ok) and from or nil)
  if ok then
    last:text("Block " .. grouped(m.s) .. "  ·  " .. (m.tx or 0) .. " tx  ·  " .. sol(m.fee or 0) .. " SOL fees")
    last:color("text")
  else
    last:text("Slot " .. grouped(m.s) .. " skipped") last:color("pink")
  end
  if i == 4 then
    -- the window is done: a flash, then fade
    if not winSkip then for n = 1, 6 do level[n] = { 200, 255, 220 } end end
    fadeAt = sys.millis() + 250
    inWindow = false
    nextIn = nil
  end
end

---------------------------------------------------------------------------------
-- Connection

local sock, retry = nil, 2000

local function connect()
  live:text("connecting") live:color("dim")
  sock = ws.open(RELAY, function(event, data)
    if event == "open" then
      retry = 2000
    elseif event == "message" then
      local m = json.decode(data)
      if type(m) ~= "table" then return end
      if m.t == "info" then onInfo(m)
      elseif m.t == "slot" and type(m.i) == "number" and m.i >= 0 and m.i <= 3 then onSlot(m) end
    else
      live:text(tostring(data)) live:color("orange")
      timer.after(retry, connect)
      retry = math.min(retry * 2, 30000)
    end
  end)
end
connect()

---------------------------------------------------------------------------------
-- Every tick: countdown and LEDs

local lastShown = ""
function on_tick(ms)
  local now = sys.millis()
  -- countdown
  local text, left = "", nil
  if inWindow then
    text = "LEADER NOW"
  elseif nextIn then
    left = nextIn - (now - nextAt) / 1000
    if left < 0 then left = 0 end
    text = string.format("leader in %.1fs", left)
  end
  if text ~= lastShown then leader:text(text) lastShown = text leader:color(inWindow and "green" or "lpurple") end

  if not leds then return end
  -- top six: fade after a window
  local k = 1
  if fadeAt and now > fadeAt then
    k = 1 - (now - fadeAt) / FADE_MS
    if k <= 0 then
      k = 0
      for n = 1, 6 do level[n] = { 0, 0, 0 } end
      fadeAt = nil
      for n = 1, 4 do squares[n]:color("panel") end
    end
  end
  for n = 1, 6 do
    local c = level[n]
    led.set(n, math.floor(c[1] * k), math.floor(c[2] * k), math.floor(c[3] * k))
  end
  -- side two: breathe faster as the next window comes (last 10 s)
  if left and left < 10 and not inWindow then
    local speed = 1 + (10 - left) * 0.6                  -- breaths a second, roughly
    local b = (math.sin(now / 1000 * speed * math.pi) + 1) / 2
    local v = math.floor(30 + 200 * b * (1 - left / 12))
    led.set(7, v // 2, v // 4, v) led.set(8, v // 2, v // 4, v)
  else
    led.set(7, 0, 0, 0) led.set(8, 0, 0, 0)
  end
end

function on_key(k)
  if k == "select" then
    leds = not leds
    if not leds then led.off() end
    ui.toast(leds and "LEDs on" or "LEDs off")
    return true
  end
  return false
end
