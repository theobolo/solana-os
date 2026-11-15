"""Simulate the badge's screen for a Lua app: runs main.lua in Lua 5.5 with the badge's
ui / led / ws / storage / timer imitated, draws the screen with PIL in the badge's
own fonts and theme colours, charges each tick what LVGL would redraw, and saves frames.

python3 bench.py main.lua ws  rec.ws  OUTDIR      a recording of the relay's JSON messages
python3 bench.py main.lua live ws://localhost:8090/live OUTDIR   a running relay (SECONDS)

Env: KEYS="ms:key,...", SHOT_MS, STORE (the app's storage, JSON), EXTRA (ws mode: more
"ms {json}" messages), SECONDS (live mode). See CLAUDE.md, "Testing without a badge".
"""
import json, math, os, sys, threading, time, queue
import lupa
from PIL import Image, ImageDraw

SRC, MODE, REC, OUT = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(OUT, exist_ok=True)

THEME = {"text": 0xFFFFFF, "dim": 0x8E8C9E, "bg": 0x000000, "panel": 0x111116, "border": 0x2A2935,
         "purple": 0x9945FF, "green": 0x14F195, "pink": 0xEB54BC, "lpurple": 0xB6B0FF, "blue": 0x64A8F2,
         "aqua": 0x80ECFF, "lime": 0xACFF9B, "yellow": 0xE8F180, "orange": 0xFF754A}
def rgb(c):
    if isinstance(c, bytes): c = c.decode()
    if isinstance(c, str): c = THEME[c]
    c = int(c)
    # RGB565 like the badge
    r, g, b = (c >> 16) & 255, (c >> 8) & 255, c & 255
    return ((r >> 3) << 3, (g >> 2) << 2, (b >> 3) << 3)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from badgefont import Font
BFONT = {12: Font("sol_mono_12"), 14: Font("sol_font_14"), 20: Font("sol_font_20"), 32: Font("sol_font_32")}   # the badge's own
LINE = {k: f.line_height for k, f in BFONT.items()}
STATUS_H = 22

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
clock = [0]
millis = lambda: clock[0]

objs = []
charge = [0]          # pixel work, in badge instructions (1 per 16 px)

def opt(o, k, d=None):
    if o is None: return d
    v = o[k]
    return d if v is None else v

DIRTY = []
WRAPS = {}         # labels whose text the badge would wrap onto more lines than it has: (x, y) -> text
def check_wrap(o):
    if o.kind == "label" and o.w and len(BFONT[o.size].lines(o.text, o.w)) > o.text.count("\n") + 1:
        WRAPS.setdefault((o.x, o.y), (clock[0], o.text))
WHO = []
WHOT = []          # areas LVGL would redraw this tick: (x1, y1, x2, y2), screen coordinates
class Obj:
    def __init__(self, kind, x, y, **kw):
        self.kind, self.x, self.y, self.vis = kind, int(x), int(y), True
        self.__dict__.update(kw)
        objs.append(self)
        self.inv()
    def box(self):
        if self.kind == "label":
            f = BFONT[self.size]
            lines = f.lines(self.text, self.w)
            w = self.w if self.w else max([f.width(t) for t in lines] + [1])
            return (self.x, self.y + STATUS_H, self.x + w, self.y + STATUS_H + LINE[self.size] * len(lines))
        return (self.x, self.y + STATUS_H, self.x + getattr(self, "w", 1), self.y + STATUS_H + getattr(self, "h", 1))
    def inv(self):
        if self.vis:
            DIRTY.append(self.box())
            b = self.box()
            WHO.append((self.kind, b[2] - b[0], b[3] - b[1], self.x, self.y, (getattr(self, "text", "") or "")[:12]))

def methods(o):
    t = L.table()
    def pos(self, x, y):
        if (o.x, o.y) == (int(x), int(y)): return
        o.inv(); o.x, o.y = int(x), int(y); o.inv()
    def show(self, b):
        b = bool(b)
        if o.vis == b: return
        if o.vis: o.inv()
        o.vis = b
        o.inv()
    def text(self, s):
        s = s.decode() if isinstance(s, bytes) else str(s)
        if s == o.text: return
        o.inv(); o.text = s; o.inv()
        check_wrap(o)
    def color(self, c):
        o.color = c; o.inv()
    def setv(self, v):
        o.value = v; o.inv()
    def size(self, w, h):
        o.inv(); o.w, o.h = int(w), int(h); o.inv()
    t["pos"], t["show"], t["text"], t["color"], t["set"], t["size"] = pos, show, text, color, setv, size
    t["remove"] = lambda self: objs.remove(o)
    if o.kind == "canvas":
        def clear(self, c=None):
            o.inv()
            charge[0] += o.w * o.h // 16
            o.img.paste((0, 0, 0, 0) if c is None else rgb(c) + (255,), (0, 0, o.w, o.h))
        def pixel(self, x, y, c):
            o.inv()
            if 0 <= x < o.w and 0 <= y < o.h: o.img.putpixel((int(x), int(y)), rgb(c) + (255,))
        def rect(self, x, y, w, h, c):
            o.inv()
            x, y, w, h = int(x), int(y), int(w), int(h)
            x2, y2 = min(o.w, x + w), min(o.h, y + h)
            x, y = max(0, x), max(0, y)
            if x < x2 and y < y2:
                charge[0] += (x2 - x) * (y2 - y) // 16
                o.draw.rectangle([x, y, x2 - 1, y2 - 1], fill=rgb(c) + (255,))
        def line(self, x1, y1, x2, y2, c):
            o.inv()
            o.draw.line([int(x1), int(y1), int(x2), int(y2)], fill=rgb(c) + (255,))
        def image(self, img, x, y):
            o.inv()
            im = IMAGES[int(img["__img"])]
            charge[0] += im.width * im.height // 16
            o.img.paste(im, (int(x), int(y)), im)
        t["clear"], t["pixel"], t["rect"], t["line"], t["image"] = clear, pixel, rect, line, image
    return t

def label(x, y, text, o=None):
    ob = Obj("label", x, y, text=(text.decode() if isinstance(text, bytes) else str(text)),
             size=int(opt(o, "size", 14)), color=opt(o, "color", "text"), w=opt(o, "w"), align=opt(o, "align", "left"))
    if isinstance(ob.align, bytes): ob.align = ob.align.decode()
    check_wrap(ob)
    return methods(ob)
def rect(x, y, w, h, o=None):
    return methods(Obj("rect", x, y, w=int(w), h=int(h), color=opt(o, "color", "panel"), radius=int(opt(o, "radius", 0)), border=opt(o, "border")))
def gradient(x, y, w, h): return methods(Obj("grad", x, y, w=int(w), h=int(h)))
def bar(x, y, w, h, v): return methods(Obj("bar", x, y, w=int(w), h=int(h), value=v))
def canvas(x, y, w, h, o=None):
    img = Image.new("RGBA", (int(w), int(h)), (0, 0, 0, 0))
    c = opt(o, "color")
    if c is not None: img.paste(rgb(c) + (255,), (0, 0, int(w), int(h)))
    ob = Obj("canvas", x, y, w=int(w), h=int(h), img=img)
    ob.draw = ImageDraw.Draw(img)
    return methods(ob)

L.execute("ui = { W = 320, H = 218 }  function ui.bg() end function ui.hint() end")
IMAGES = []
BASEPAL = {"k": 0x000000, "w": 0xFFFFFF, "p": 0x9945FF, "g": 0x14F195, "m": 0xEB54BC, "v": 0xB6B0FF, "b": 0x64A8F2,
           "a": 0x80ECFF, "l": 0xACFF9B, "y": 0xE8F180, "o": 0xFF754A, "#": 0xFFFFFF}
def load(rows, o=None):
    pal = dict(BASEPAL)
    if o is not None and o["palette"] is not None:
        for k, v in o["palette"].items():
            pal[k.decode() if isinstance(k, bytes) else k] = v
    rs = [rows[i + 1] for i in range(len(rows))]
    rs = [r.decode() if isinstance(r, bytes) else r for r in rs]
    w, h = max(len(r) for r in rs), len(rs)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for y, r in enumerate(rs):
        for x, ch in enumerate(r):
            if ch in ".  ": continue
            im.putpixel((x, y), rgb(pal[ch]) + (255,))
    IMAGES.append(im)
    t = L.table(); t["__img"] = len(IMAGES) - 1
    return t
toasts = []
def image(x, y, rows, o=None):
    t = load(rows, o); im = IMAGES[int(t["__img"])]
    ob = Obj("canvas", x, y, w=im.width, h=im.height, img=im); ob.draw = ImageDraw.Draw(im)
    return methods(ob)
for k, f in dict(label=label, rect=rect, gradient=gradient, bar=bar, canvas=canvas, load=load, image=image,
                 toast=lambda s: toasts.append((millis(), s))).items():
    g.ui[k] = f

leds = [(0, 0, 0)] * 9
g.led = L.table()
LEDW = [0]
def led_set(i, r, gg, b):
    LEDW[0] += 1
    leds[int(i)] = (int(r), int(gg), int(b))
g.led["set"] = led_set
g.led["off"] = lambda: [leds.__setitem__(i, (0, 0, 0)) for i in range(9)]
g.sys = L.table(); g.sys["millis"] = millis
timers = []
def after(ms, fn): timers.append([millis() + int(ms), fn, None]); return len(timers)
def every(ms, fn): timers.append([millis() + int(ms), fn, int(ms)]); return len(timers)
g.timer = L.table(); g.timer["after"] = after; g.timer["every"] = every
L.execute("json = {}")
def to_lua(v):
    if isinstance(v, dict):
        t = L.table()
        for k, x in v.items(): t[k] = to_lua(x)
        return t
    if isinstance(v, list):
        t = L.table()
        for i, x in enumerate(v): t[i + 1] = to_lua(x)
        return t
    return v
g.json["decode"] = lambda s: to_lua(json.loads(s))

cb = {}
SENT = []                    # what the app sent on its socket: (ms, text)
LIVEQ, LIVEC = queue.Queue(), []
def ws_open(url, f):
    cb["ws"] = f
    cb["url"] = url
    if MODE == "live":
        from websockets.sync.client import connect
        u = url.decode() if isinstance(url, bytes) else str(url)
        c = connect(REC + (u[u.index("?"):] if "?" in u else ""), max_size=None)
        LIVEC[:] = [c]
        def pump():
            try:
                for m in c: LIVEQ.put(m)
            except Exception: pass
        threading.Thread(target=pump, daemon=True).start()
    t = L.table()
    def send(self, m):
        text = m.decode() if isinstance(m, bytes) else m if isinstance(m, str) else json.dumps({k: v for k, v in m.items()})
        SENT.append((millis(), text))
        if LIVEC: LIVEC[0].send(text)
        return True
    t["send"] = send
    t["state"] = lambda self: "open"
    return t
g.ws = L.table(); g.ws["open"] = ws_open
STORE = json.loads(os.environ.get("STORE", "{}"))   # the app's storage at launch, e.g. '{"follow": "..."}' 
g.storage = L.table()
g.storage["get"] = lambda k: to_lua(STORE.get(k.decode() if isinstance(k, bytes) else k))
def store_set(k, v): STORE[k.decode() if isinstance(k, bytes) else k] = v
g.storage["set"] = store_set
g.storage["remove"] = lambda k: STORE.pop(k.decode() if isinstance(k, bytes) else k, None)
L.execute("pcall_ok = pcall")

# instruction counting: a count hook every 100 VM instructions
L.execute("""
__count = 0
function __hook() __count = __count + 100 end
debug.sethook(__hook, "", 100)
""")
worst = {}
TICKS, TICK_INS = [], [0]
def run_cb(name, fn, *args):
    g.__count = 0; charge[0] = 0
    r = fn(*args)
    n = g.__count + charge[0]
    worst[name] = max(worst.get(name, 0), n)
    TICK_INS[0] += n
    return r

L.execute(open(SRC).read())
L.execute("collectgarbage('collect') collectgarbage('stop')")
ALLOC = []

def render():
    im = Image.new("RGB", (320, 240), (0, 0, 0))
    d = ImageDraw.Draw(im)
    # status bar, roughly as the badge draws it
    d.rectangle([0, 0, 319, STATUS_H - 1], fill=(10, 14, 28))
    BFONT[14].draw(im, 24, 4, "Solana OS", (255, 255, 255))
    for x in range(320):
        t = x / 319
        d.line([x, STATUS_H - 2, x, STATUS_H - 1], fill=(int(0x99 + (0x14 - 0x99) * t), int(0x45 + (0xF1 - 0x45) * t), int(0xFF + (0x95 - 0xFF) * t)))
    for o in objs:
        if not o.vis: continue
        x, y = o.x, o.y + STATUS_H
        if o.kind == "rect":
            d.rounded_rectangle([x, y, x + o.w - 1, y + o.h - 1], radius=o.radius, fill=rgb(o.color),
                                outline=rgb(o.border) if o.border is not None else None)
        elif o.kind == "grad":
            for i in range(o.w):
                t = i / max(1, o.w - 1)
                d.line([x + i, y, x + i, y + o.h - 1], fill=(int(0x99 + (0x14 - 0x99) * t), int(0x45 + (0xF1 - 0x45) * t), int(0xFF + (0x95 - 0xFF) * t)))
        elif o.kind == "bar":
            d.rounded_rectangle([x, y, x + o.w - 1, y + o.h - 1], radius=o.h // 2, fill=rgb("border"))
        elif o.kind == "canvas":
            im.paste(o.img, (x, y), o.img)
        elif o.kind == "label":   # as LVGL: wrapped at w, not clipped
            BFONT[o.size].draw(im, x, y, o.text, rgb(o.color), o.w, o.align, (0, STATUS_H, 320, 240))
    for at, text in toasts:      # roughly the badge's toast: a light pill near the bottom, ~2 s
        if at <= clock[0] < at + 2000:
            f = BFONT[14]; tw = min(f.width(text), 280)
            d.rounded_rectangle([160 - tw // 2 - 10, 206, 160 + tw // 2 + 10, 230], radius=12, fill=(230, 230, 236))
            f.draw(im, 160 - tw // 2, 211, text, (0, 0, 0), 280 if f.width(text) > 280 else None)
    # the LEDs, drawn around the screen like on the board
    big = Image.new("RGB", (360, 300), (12, 12, 14))
    big.paste(im, (10, 50))
    bd = ImageDraw.Draw(big)
    for n in range(1, 7):
        cx = 30 + (n - 1) * 52
        c = leds[n]; k = max(c) / 255
        col = tuple(min(255, int(v * 1.0 + 40 * k)) for v in c) if max(c) else (40, 40, 44)
        bd.ellipse([cx - 9, 14, cx + 9, 32], fill=col)
    for n, cy in ((7, 110), (8, 230)):
        c = leds[n]
        col = c if max(c) else (40, 40, 44)
        bd.ellipse([338, cy - 9, 356, cy + 9], fill=col)
    return big

rec = []
for line in ([] if MODE == "live" else open(REC)):
    at, payload = line.split(" ", 1)
    rec.append((int(at), payload.strip()))
if os.environ.get("EXTRA") and MODE == "ws":   # more messages ("ms {json}" lines), e.g. a relay's answers
    for line in open(os.environ["EXTRA"]):
        if line.strip():
            at, payload = line.split(" ", 1)
            rec.append((int(at), json.dumps({"m": json.loads(payload)})))
    rec.sort(key=lambda r: r[0])
shots = {}
i = 0
run_cb("ws", cb["ws"], "open")
END = int(os.environ.get("SECONDS", "45")) * 1000 if MODE == "live" else rec[-1][0] + 500
T0 = time.time()
while clock[0] < END:
    if MODE == "live":         # real time: what came by now
        while time.time() - T0 < clock[0] / 1000: time.sleep(0.005)
        while not LIVEQ.empty():
            run_cb("ws", cb["ws"], "message", LIVEQ.get())
    while i < len(rec) and rec[i][0] <= clock[0]:
        run_cb("ws", cb["ws"], "message", json.dumps(json.loads(rec[i][1])["m"], separators=(",", ":")))   # as the relay writes it
        i += 1
    for t in list(timers):
        if clock[0] >= t[0]:
            run_cb("timer", t[1])
            if t[2]: t[0] += t[2]
            else: timers.remove(t)
    for kk in os.environ.get("KEYS", "").split(","):
        if kk and int(kk.split(":")[0]) == clock[0]: run_cb("on_key", g.on_key, kk.split(":")[1])
    run_cb("on_tick", g.on_tick, 30)
    # what this tick costs the screen: LVGL joins overlapping areas (when the union is smaller
    # than the parts), then each area costs ~0.8 ms plus ~1.4 us a pixel. That is measured on
    # the badge with this app (console top: taskLVGL's CPU over the pixels flushed, 1.0 to
    # 1.7 us by view, 2026-11-14); CHANGELOG 2.1.0's ~0.45 us came from full-screen redraws.
    areas = []
    for a in DIRTY:
        x1, y1, x2, y2 = max(0, a[0]), max(STATUS_H, a[1]), min(320, a[2]), min(240, a[3])
        if x2 > x1 and y2 > y1: areas.append([x1, y1, x2, y2])
    joined = True
    while joined:
        joined = False
        for ia in range(len(areas)):
            for ja in range(ia + 1, len(areas)):
                A, B = areas[ia], areas[ja]
                u = [min(A[0], B[0]), min(A[1], B[1]), max(A[2], B[2]), max(A[3], B[3])]
                ua = (u[2] - u[0]) * (u[3] - u[1])
                if ua <= (A[2] - A[0]) * (A[3] - A[1]) + (B[2] - B[0]) * (B[3] - B[1]):
                    areas[ia] = u; del areas[ja]; joined = True; break
            if joined: break
    px = sum((a[2] - a[0]) * (a[3] - a[1]) for a in areas)
    TICKS.append((clock[0], len(areas), px, 0.8 * len(areas) + px * 0.0014, TICK_INS[0], LEDW[0]))
    WHOT.append((clock[0], list(WHO))); WHO.clear()
    DIRTY.clear(); TICK_INS[0] = 0; LEDW[0] = 0
    if clock[0] % 1000 == 0:
        ALLOC.append((clock[0], L.eval("collectgarbage('count')")))
        L.execute("collectgarbage('collect') collectgarbage('stop')")
        ALLOC.append((clock[0], L.eval("collectgarbage('count')")))
    if clock[0] % int(os.environ.get("SHOT_MS", "3000")) == 0: shots[clock[0]] = render()
    clock[0] += 30
print(MODE, "worst instructions per callback:", worst)
import pickle, statistics
pickle.dump(TICKS, open(os.path.join(OUT, MODE + "_ticks.pkl"), "wb"))
pickle.dump(WHOT, open(os.path.join(OUT, MODE + "_who.pkl"), "wb"))
kb = [ALLOC[i + 2][1] - ALLOC[i + 1][1] for i in range(0, len(ALLOC) - 2, 2)]   # KB allocated in each second
pickle.dump(kb, open(os.path.join(OUT, MODE + "_alloc.pkl"), "wb"))
print("messages fed:", i, "of", len(rec))
pickle.dump({t: im.tobytes() for t, im in shots.items()}, open(os.path.join(OUT, MODE + ".pkl"), "wb"))
[im.resize((720, 600), Image.NEAREST).save(os.path.join(OUT, f"{MODE}_{t//1000:02d}.png")) for t, im in shots.items()]
print("ui objects:", len(objs))
for at, m in SENT: print("sent at", at, m)
for at, m in toasts: print("toast at", at, m)
for (x, y), (at, text) in WRAPS.items(): print(f"WRAPS on the badge: label at {x},{y} ({at} ms): {text!r}")
if STORE: print("storage:", json.dumps({k: (dict(v) if hasattr(v, "items") else v) for k, v in STORE.items()}, default=lambda x: dict(x)))
