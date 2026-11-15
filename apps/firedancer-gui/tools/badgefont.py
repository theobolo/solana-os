"""The badge's own fonts (main/assets/sol_*.c, LVGL 4 bpp, not compressed), for the
simulator: widths, wrapping and pixels as the badge has them. The Mac's fonts are
narrower, so a label that fits in a simulator screenshot could wrap on the badge.

    f = Font("sol_mono_12")
    f.width("TX / SLOT"); f.lines("some long text", 120); f.draw(img, x, y, text, (r, g, b))
"""
import os, re

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "main", "assets")
BREAK = " ,.;:-_)]}"          # LV_TXT_BREAK_CHARS: a line may end after one of these


class Font:
    def __init__(self, name):
        src = open(os.path.join(ASSETS, name + ".c")).read()
        bm = src[src.index("glyph_bitmap[] = {"):]
        bm = bm[:bm.index("};")]
        bm = re.sub(r"/\*.*?\*/", "", bm, flags=re.S)
        self.bitmap = bytes(int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", bm))
        self.glyphs = [tuple(int(v) for v in m) for m in re.findall(
            r"\.bitmap_index = (\d+), \.adv_w = (\d+), \.box_w = (\d+), \.box_h = (\d+), \.ofs_x = (-?\d+), \.ofs_y = (-?\d+)", src)]
        self.line_height = int(re.search(r"\.line_height = (\d+)", src).group(1))
        self.base_line = int(re.search(r"\.base_line = (\d+)", src).group(1))
        ul = re.search(r"unicode_list_1\[\] = \{([^}]*)\}", src)
        extra = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", ul.group(1))] if ul else []
        self.ids = {c: c - 32 + 1 for c in range(32, 127)}
        for n, ofs in enumerate(extra): self.ids[176 + ofs] = 96 + n

    def glyph(self, ch):
        return self.glyphs[self.ids.get(ord(ch), self.ids[ord("?")])]

    def adv(self, ch):            # LVGL rounds each glyph's advance to whole pixels
        return (self.glyph(ch)[1] + 8) >> 4

    def width(self, text):
        return sum(self.adv(c) for c in text)

    def lines(self, text, w=None):
        """The lines LVGL shows: split at newlines, wrapped at w after a break character,
        a word longer than the line cut where it reaches the edge."""
        out = []
        for para in text.split("\n"):
            if not w:
                out.append(para)
                continue
            while self.width(para) > w:
                cut, x, brk = 0, 0, -1
                for i, c in enumerate(para):
                    x += self.adv(c)
                    if x > w: break
                    cut = i + 1
                    if c in BREAK: brk = i + 1
                n = brk if brk > 0 else max(cut, 1)
                out.append(para[:n].rstrip(" "))
                para = para[n:].lstrip(" ")
            out.append(para)
        return out

    def draw(self, img, x, y, text, color, w=None, align="left", clip=None):
        """Draw onto an RGB PIL image; clip = (x1, y1, x2, y2) the area pixels may land in."""
        px = img.load()
        W, H = img.size
        cx1, cy1, cx2, cy2 = clip or (0, 0, W, H)
        for n, line in enumerate(self.lines(text, w)):
            lw = self.width(line)
            pen = x
            if w and align == "right": pen = x + w - lw
            elif w and align == "center": pen = x + (w - lw) // 2
            top = y + n * self.line_height
            for c in line:
                bi, adv, bw, bh, ox, oy = self.glyph(c)
                gy = top + self.line_height - self.base_line - bh - oy
                for r in range(bh):
                    for k in range(bw):
                        bit = (r * bw + k) * 4
                        a = (self.bitmap[bi + bit // 8] >> (4 - bit % 8)) & 15
                        if not a: continue
                        sx, sy = pen + ox + k, gy + r
                        if cx1 <= sx < cx2 and cy1 <= sy < cy2:
                            o = px[sx, sy]
                            px[sx, sy] = tuple(o[i] + (color[i] - o[i]) * a // 15 for i in range(3))
                pen += (adv + 8) >> 4
        return len(self.lines(text, w))
