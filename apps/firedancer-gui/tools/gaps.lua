-- Measures the picture's smoothness on the badge: the gaps between ticks and each tick's
-- own Lua time, printed every 5 s. Append it to a copy of main.lua, send and run that:
--   cat main.lua tools/gaps.lua > /tmp/m.lua
--   python3 tools/badgeput.py firedancer-gui /tmp/m.lua main.lua
--   python3 tools/badgerun.py "lua run firedancer-gui" 70
-- then put the real main.lua back. A gap over ~65 ms shows as a freeze (CLAUDE.md).
do
  local f, last, t0 = on_tick, nil, sys.millis()
  local g, l, n, gmax, lmax, lsum = { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0 }, 0, 0, 0, 0
  on_tick = function(ms)
    local now = sys.millis()
    if last then
      local d = now - last
      local i = d <= 35 and 1 or d <= 45 and 2 or d <= 65 and 3 or d <= 100 and 4 or d <= 200 and 5 or 6
      g[i] = g[i] + 1
      if d > gmax then gmax = d end
    end
    last = now
    f(ms)
    local d = sys.millis() - now
    local i = d <= 5 and 1 or d <= 10 and 2 or d <= 20 and 3 or 4
    l[i], lsum, n = l[i] + 1, lsum + d, n + 1
    if d > lmax then lmax = d end
    if now - t0 >= 5000 then
      print(string.format("GAP %d ticks/5s gaps <=35:%d <=45:%d <=65:%d <=100:%d <=200:%d >200:%d max %d | lua %d ms/s <=5:%d <=10:%d <=20:%d >20:%d max %d",
        n, g[1], g[2], g[3], g[4], g[5], g[6], gmax, lsum // 5, l[1], l[2], l[3], l[4], lmax))
      g, l, n, gmax, lmax, lsum, t0 = { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0 }, 0, 0, 0, 0, now
    end
  end
end
