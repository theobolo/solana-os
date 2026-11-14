-- Validators: public on-chain info about your Solana validators, read with `rpc`.
-- For each vote account: identity, commission, last voted slot (voting / delinquent),
-- and the SOL on the vote account and on the identity. SELECT refreshes, it also
-- refreshes every 2 minutes. The LEDs go green while every validator votes, red
-- as soon as one falls behind.
--
-- getVoteAccounts isn't among the badge's allowed rpc methods, so the app reads
-- each vote account's data itself (getAccountInfo with a dataSlice).

-- Your validators: a short name (shown on the badge) and the VOTE account address.
local VALIDATORS = {
  { name = "Mon validateur", vote = "REMPLACE_PAR_TON_VOTE_ACCOUNT" },
}

local REFRESH_MS = 120000
local DELINQUENT_SLOTS = 128      -- last vote further behind than this = delinquent

---------------------------------------------------------------------------------
-- Helpers

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64I = {}
for i = 1, 64 do B64I[B64:byte(i)] = i - 1 end

local function b64decode(s)
  local out, n, bits, acc = {}, 0, 0, 0
  for i = 1, #s do
    local v = B64I[s:byte(i)]
    if v then
      acc = (acc << 6) | v
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        n = n + 1
        out[n] = string.char((acc >> bits) & 0xFF)
      end
      acc = acc & ((1 << bits) - 1)
    end
  end
  return table.concat(out)
end

-- u32 / u16 little endian at a 0-based offset
local function u32(d, off) return (string.unpack("<I4", d, off + 1)) end
local function u16(d, off) return (string.unpack("<I2", d, off + 1)) end
-- a u64 that has to fit in 31 bits (slots, vector lengths); nil if it doesn't
local function u64small(d, off)
  local lo, hi = string.unpack("<I4I4", d, off + 1)
  if hi ~= 0 or lo > 0x7FFFFFFF then return nil end
  return lo
end

local function short(addr) return addr:sub(1, 4) .. ".." .. addr:sub(-4) end

-- lamports (number or decimal string) -> "12.34"
local function sol(lamports)
  local s = string.rep("0", 10) .. tostring(lamports)
  local whole = s:sub(1, -10):gsub("^0+", "")
  return (whole == "" and "0" or whole) .. "." .. s:sub(-9, -8)
end

-- Parse the start of a vote account's data (VoteStateVersions, bincode).
-- Returns { node, commission (text), votes_off (0-based offset of the vote
-- vector's length), entry, slot_in_entry } or nil, why.
local function parse_header(d)
  if #d < 77 then return nil, "data too short" end
  local tag = u32(d, 0)
  local h = { node = solana.encode(d:sub(5, 36)) }
  if tag == 1 or tag == 2 then
    -- 1 = V1_14_11 (Lockout: slot u64, confirmation u32)
    -- 2 = V3 (LandedVote: latency u8, then Lockout)
    h.commission = d:byte(69) .. "%"
    h.votes_off = 69
    h.entry = (tag == 2) and 13 or 12
    h.slot_in_entry = (tag == 2) and 1 or 0
  elseif tag == 3 then
    -- V4 (SIMD-0185): two collectors, commissions in basis points, pending
    -- delegator rewards, an optional BLS key, then the votes (LandedVote).
    if #d < 153 then return nil, "data too short" end
    local bps = u16(d, 132)
    h.commission = (bps % 100 == 0) and (bps // 100 .. "%") or string.format("%.2f%%", bps / 100)
    local bls = d:byte(145)                 -- Option tag at offset 144
    h.votes_off = (bls == 1) and (145 + 48) or 145
    h.entry = 13
    h.slot_in_entry = 1
  else
    return nil, "vote state v" .. tag .. "?"
  end
  return h
end

---------------------------------------------------------------------------------
-- UI

ui.bg("bg")
local title = ui.label(8, 6, "Validators", { size = 20 })
local status = ui.label(8, 34, "...", { size = 12, color = "dim", w = ui.W - 16 })
local list = ui.list(0, 52, ui.W, ui.H - 52 - 16, { "Loading..." }, {})
ui.hint("SELECT refresh   CANCEL exit")

local rows = {}
local state = {}       -- per validator: { h, last_vote, vote_bal, id_bal, err }
local current_slot

local function render()
  local bad, good = 0, 0
  for i, v in ipairs(VALIDATORS) do
    local s = state[i] or {}
    local sub, right
    if s.err then
      sub, right = s.err, "?"
    elseif s.h then
      local parts = { short(s.h.node), "comm " .. s.h.commission }
      if s.vote_bal then parts[#parts + 1] = "vote " .. sol(s.vote_bal) end
      if s.id_bal then parts[#parts + 1] = "id " .. sol(s.id_bal) end
      sub = table.concat(parts, " · ")
      if s.last_vote and current_slot then
        local behind = current_slot - s.last_vote
        if behind > DELINQUENT_SLOTS then
          right = "DELINQ"
          bad = bad + 1
        else
          right = "OK"
          good = good + 1
        end
      else
        right = "..."
      end
    else
      sub, right = short(v.vote), "..."
    end
    rows[i] = { title = v.name, sub = sub, right = right }
  end
  list:items(rows)
  if bad > 0 then
    led.fill(255, 0, 0)
  elseif good == #VALIDATORS and good > 0 then
    led.fill(0, 120, 40)
  end
end

---------------------------------------------------------------------------------
-- Calls, one at a time (30 rpc calls a minute per badge)

local queue, busy = {}, false

local function pump()
  if busy or #queue == 0 then return end
  busy = true
  local job = table.remove(queue, 1)
  rpc.call(job.method, job.params, function(ok, r)
    busy = false
    job.cb(ok, r)
    render()
    pump()
  end)
end

local function add(method, params, cb)
  queue[#queue + 1] = { method = method, params = params, cb = cb }
end

local function slice(addr, off, len)
  return { addr, { encoding = "base64", dataSlice = { offset = off, length = len } } }
end

local function refresh()
  if #queue > 0 or busy then return end
  status:text("Refreshing...")
  add("getSlot", { { commitment = "confirmed" } }, function(ok, r)
    if ok then current_slot = r end
  end)
  for i, v in ipairs(VALIDATORS) do
    state[i] = state[i] or {}
    local s = state[i]
    add("getAccountInfo", slice(v.vote, 0, 208), function(ok, r)
      if not ok then s.err = tostring(r) return end
      if not r.value then s.err = "no such account" return end
      local d = b64decode(r.value.data[1])
      local h, why = parse_header(d)
      if not h then s.err = why return end
      s.err, s.h = nil, h
      -- the vote vector's length, then its last entry's slot
      local n = u64small(d, h.votes_off)
      if not n or n == 0 then s.last_vote = nil return end
      local off = h.votes_off + 8 + h.entry * (n - 1) + h.slot_in_entry
      table.insert(queue, 1, { method = "getAccountInfo", params = slice(v.vote, off, 8),
        cb = function(ok2, r2)
          if ok2 and r2.value then
            s.last_vote = u64small(b64decode(r2.value.data[1]), 0)
          end
        end })
      -- and the identity's balance, now that we know it
      add("getBalance", { h.node }, function(ok2, r2)
        if ok2 then s.id_bal = r2.value end
      end)
    end)
    add("getBalance", { v.vote }, function(ok, r)
      if ok then s.vote_bal = r.value end
    end)
  end
  add("getEpochInfo", nil, function(ok, r)
    if ok then
      local pct = r.slotsInEpoch > 0 and (r.slotIndex * 100 // r.slotsInEpoch) or 0
      status:text("Epoch " .. r.epoch .. " (" .. pct .. "%)  slot " .. tostring(current_slot or r.absoluteSlot))
    else
      status:text(tostring(r))
    end
  end)
  pump()
end

render()
refresh()
timer.every(REFRESH_MS, refresh)

function on_key(k)
  if k == "select" then refresh() return true end
  return false
end
