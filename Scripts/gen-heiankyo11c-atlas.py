#!/usr/bin/env python3
"""Generates the heiankyo11c map atlas (Resources/heiankyo11c/patterns.png + tiles.json).

Pixel art of 11th-century Heian-kyo, drawn procedurally so it can be regenerated:
- commercial blocks: compounds behind tile-capped earthen walls (築地塀) with one-storey
  houses (平屋) under cypress-bark or tile roofs, small gardens and ponds;
- urban forest: temple precincts (corridor ring, main hall, pagoda, white gravel, trees);
- building: compounds under construction (timber frames, lumber, earth);
- river canal: a river with stone/sand banks; firebreak boulevard: a great avenue (大路)
  lined with willows and ditches.

Uses only the Python standard library and a fixed random seed, so output is deterministic.
Run from the repository root, then run Scripts/embed-resources.sh.
"""
import json
import os
import random
import struct
import zlib

OUT_DIR = os.path.join("Resources", "heiankyo11c")


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), 255)


# Palette
ROOF_TILE = [hexc("4F545B"), hexc("6E747C"), hexc("8F959C"), hexc("B3B8BD")]   # dark..light
ROOF_BARK = [hexc("5A3A26"), hexc("744D33"), hexc("916242"), hexc("AE7D57")]
WALL_CAP = hexc("5E636A")
WALL_WHITE = hexc("EFE9DC")   # white plaster face of the earthen walls
WALL_BODY = hexc("E3D6B8")
GROUND = hexc("D8C49C")
GROUND_DOT = hexc("CBB58A")
GRAVEL = hexc("E7E2D6")
GRAVEL_DOT = hexc("D3CCBD")
GREEN = [hexc("3A5126"), hexc("4F6B33"), hexc("6A8743"), hexc("86A257")]
WATER = [hexc("3F5F74"), hexc("4E7186"), hexc("6A8DA0"), hexc("8FB0BF")]
STONE = [hexc("8A857B"), hexc("A7A194"), hexc("C4BDAE")]
SAND = hexc("D9C9A2")
VERMILION = hexc("B8432F")
WOOD = hexc("8B5A2B")
LUMBER = hexc("C49A6C")
EARTH = hexc("B98A5A")
ROAD = hexc("BF763A")
ROAD_LIGHT = hexc("CB8749")
ROAD_DARK = hexc("A9652F")
DITCH = hexc("7A4E2A")
TRANSPARENT = (0, 0, 0, 0)
# Grey tile roofs dominate (as in reconstructions of Heian-kyo); cypress bark is the minority.
ROOFS = [ROOF_TILE, ROOF_TILE, ROOF_TILE, ROOF_BARK]


class Img:
    def __init__(self, w, h, fill=TRANSPARENT):
        self.w, self.h = w, h
        self.px = [fill] * (w * h)

    def set(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = c

    def get(self, x, y):
        return self.px[y * self.w + x]

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.set(xx, yy, c)

    def outline(self, x, y, w, h, c):
        for xx in range(x, x + w):
            self.set(xx, y, c)
            self.set(xx, y + h - 1, c)
        for yy in range(y, y + h):
            self.set(x, yy, c)
            self.set(x + w - 1, yy, c)

    def blit(self, other, dx, dy):
        for y in range(other.h):
            for x in range(other.w):
                c = other.get(x, y)
                if c[3]:
                    self.set(dx + x, dy + y, c)

    def png(self):
        raw = b"".join(b"\x00" + bytes(v for p in self.px[y * self.w:(y + 1) * self.w] for v in p)
                       for y in range(self.h))

        def chunk(t, body):
            return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)

        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


# --- Building blocks ---------------------------------------------------------------

def speckle(img, x, y, w, h, base, dot, rnd, density=0.12):
    img.rect(x, y, w, h, base)
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            if rnd.random() < density:
                img.set(xx, yy, dot)


def roof(img, x, y, w, h, pal, hip=True):
    """Top view of a hipped/gabled roof: lit upper slope, shaded lower slope, ridge, eaves outline."""
    img.rect(x, y, w, h, pal[1])
    horizontal = w >= h
    if horizontal:
        mid = y + h // 2
        img.rect(x, y, w, mid - y, pal[2])          # upper slope catches the light
        inset = min(h // 2, (w - 1) // 2) if hip else 0
        for xx in range(x + inset, x + w - inset):
            img.set(xx, mid if h % 2 else mid - 1, pal[3])  # ridge
    else:
        mid = x + w // 2
        img.rect(x, y, mid - x, h, pal[2])
        inset = min(w // 2, (h - 1) // 2) if hip else 0
        for yy in range(y + inset, y + h - inset):
            img.set(mid if w % 2 else mid - 1, yy, pal[3])
    # eaves: darker bottom/right edge reads as overhang shadow
    for xx in range(x, x + w):
        img.set(xx, y + h - 1, pal[0])
    for yy in range(y, y + h):
        img.set(x + w - 1, yy, pal[0])


def tree(img, cx, cy, rnd, r=1):
    shades = GREEN
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy <= r * r + (1 if r > 1 else 0):
                img.set(cx + dx, cy + dy, shades[rnd.choice([1, 2, 2, 3])])
    img.set(cx + r, cy + r, shades[0])  # shadow


def wall_ring(img, x, y, w, h, gates, rnd):
    """Earthen wall with a tile cap; `gates` is a list of 'N','S','E','W' sides with a gate."""
    img.outline(x, y, w, h, WALL_CAP)
    for side in gates:
        if side in "NS":
            gx = x + w // 2 - 1 + rnd.choice([-2, 0, 2]) * (w > 12)
            gy = y if side == "N" else y + h - 1
            img.set(gx, gy, VERMILION if rnd.random() < 0.3 else WOOD)
            img.set(gx + 1, gy, WOOD)
        else:
            gy = y + h // 2 - 1
            gx = x if side == "W" else x + w - 1
            img.set(gx, gy, WOOD)
            img.set(gx, gy + 1, WOOD)


def pond(img, x, y, w, h, rnd):
    img.rect(x, y, w, h, WATER[1])
    img.set(x, y, GREEN[2]); img.set(x + w - 1, y + h - 1, GREEN[1])
    for _ in range(max(1, w * h // 8)):
        img.set(x + rnd.randrange(w), y + rnd.randrange(h), WATER[2])
    img.set(x + rnd.randrange(w), y + rnd.randrange(h), STONE[2])


def place_buildings(img, x, y, w, h, rnd, count, sizes, pals):
    """Places up to `count` non-overlapping roofs (with a 1 px margin) inside the rect."""
    occupied = []
    placed = 0
    for _ in range(count * 30):
        if placed >= count:
            break
        bw, bh = rnd.choice(sizes)
        if bw > w or bh > h:
            continue
        bx, by = x + rnd.randrange(w - bw + 1), y + rnd.randrange(h - bh + 1)
        if any(bx < ox + ow + 1 and ox < bx + bw + 1 and by < oy + oh + 1 and oy < by + bh + 1
               for ox, oy, ow, oh in occupied):
            continue
        roof(img, bx, by, bw, bh, rnd.choice(pals), hip=rnd.random() < 0.6)
        occupied.append((bx, by, bw, bh))
        placed += 1
    return occupied


def compound(w, h, seed, walls="NSEW", style=None):
    """A residential compound (commercial zone) of w x h px."""
    rnd = random.Random(seed)
    img = Img(w, h)
    speckle(img, 0, 0, w, h, GROUND, GROUND_DOT, rnd, 0.08)
    style = style or rnd.choice(["shinden", "machiya", "garden", "mixed"])
    # Walls are two pixels: tile cap outside, white plaster inside.
    x0 = 2 if "W" in walls else 0
    y0 = 2 if "N" in walls else 0
    x1 = w - (2 if "E" in walls else 0)
    y1 = h - (2 if "S" in walls else 0)
    iw, ih = x1 - x0, y1 - y0
    if style == "shinden" and iw >= 13 and ih >= 13:
        # 寝殿造: main hall to the north, side halls, corridors, pond garden to the south.
        # Proportions, roofing and garden vary per seed so no two variants match.
        main_pal = rnd.choice(ROOFS)
        side_pal = rnd.choice(ROOFS)
        mw, mh = rnd.choice([(7, 4), (7, 5), (5, 4)])
        sw, sh = rnd.choice([(3, 5), (3, 4), (4, 4)])
        mx = x0 + (iw - mw) // 2 + rnd.choice([-1, 0, 0, 1])
        roof(img, mx, y0, mw, mh, main_pal)
        sides = rnd.choice([(True, True), (True, True), (True, False), (False, True)])
        if sides[0]:
            roof(img, x0, y0 + 3, sw, sh, side_pal)
            for xx in range(x0 + sw, mx):
                img.set(xx, y0 + 2, side_pal[0])         # 渡殿 corridor
        if sides[1]:
            roof(img, x1 - sw, y0 + 3, sw, sh, side_pal)
            for xx in range(mx + mw, x1 - sw):
                img.set(xx, y0 + 2, side_pal[0])
        pw = rnd.randrange(max(3, iw // 3), iw - 5)
        pond(img, x0 + 2 + rnd.randrange(iw - pw - 3), y1 - 4, pw, 2, rnd)
        for _ in range(rnd.choice([2, 3, 4])):
            tree(img, x0 + 1 + rnd.randrange(iw - 2), y1 - 1, rnd, rnd.choice([0, 1]))
    elif style == "machiya":
        place_buildings(img, x0, y0, iw, ih, rnd, 8, [(4, 3), (5, 3), (3, 3), (3, 4)], ROOFS)
        for _ in range(3):
            tree(img, x0 + 1 + rnd.randrange(max(1, iw - 2)), y0 + 1 + rnd.randrange(max(1, ih - 2)), rnd, 0)
    elif style == "garden":
        occ = place_buildings(img, x0, y0, iw, max(4, ih // 2), rnd, 3, [(6, 4), (5, 3), (3, 3)], ROOFS)
        if ih >= 8 and iw >= 6:
            pond(img, x0 + 2, y0 + ih // 2 + 1, max(2, iw - 5), max(2, ih // 2 - 3), rnd)
        for _ in range(4):
            tree(img, x0 + 1 + rnd.randrange(max(1, iw - 2)), y1 - 2, rnd, 1 if iw > 8 else 0)
    else:
        place_buildings(img, x0, y0, iw, ih, rnd, 6, [(6, 4), (4, 3), (3, 5), (5, 3), (3, 3)], ROOFS)
        for _ in range(2):
            tree(img, x0 + rnd.randrange(max(1, iw)), y0 + rnd.randrange(max(1, ih)), rnd, 0)
    # Walls last so they stay crisp: white plaster inside, tile cap outside.
    for layer, color in ((1, WALL_WHITE), (0, WALL_CAP)):
        lo_x = layer if "W" in walls else 0
        hi_x = w - 1 - (layer if "E" in walls else 0)
        lo_y = layer if "N" in walls else 0
        hi_y = h - 1 - (layer if "S" in walls else 0)
        if "N" in walls:
            for xx in range(lo_x, hi_x + 1): img.set(xx, layer, color)
        if "S" in walls:
            for xx in range(lo_x, hi_x + 1): img.set(xx, h - 1 - layer, color)
        if "W" in walls:
            for yy in range(lo_y, hi_y + 1): img.set(layer, yy, color)
        if "E" in walls:
            for yy in range(lo_y, hi_y + 1): img.set(w - 1 - layer, yy, color)
    gate_side = rnd.choice([s for s in walls if s in "NS"] or list(walls) or ["N"])
    if gate_side in walls:
        if gate_side in "NS":
            gx = w // 2 - 1 + rnd.choice([-3, 0, 3]) * (w > 12)
            gy = 0 if gate_side == "N" else h - 1
            inner = 1 if gate_side == "N" else h - 2
            img.set(gx, gy, WOOD); img.set(gx + 1, gy, WOOD)
            img.set(gx, inner, GROUND); img.set(gx + 1, inner, GROUND)   # opening through the wall
        else:
            gy = h // 2 - 1
            gx = 0 if gate_side == "W" else w - 1
            inner = 1 if gate_side == "W" else w - 2
            img.set(gx, gy, WOOD); img.set(gx, gy + 1, WOOD)
            img.set(inner, gy, GROUND); img.set(inner, gy + 1, GROUND)
    return img


def construction(w, h, seed):
    """A compound under construction: partial walls, timber frames, lumber and earth."""
    rnd = random.Random(seed)
    img = Img(w, h)
    speckle(img, 0, 0, w, h, EARTH, GROUND_DOT, rnd, 0.2)
    # Walls with gaps where they are still being built.
    for xx in range(w):
        if rnd.random() < 0.7: img.set(xx, 0, WALL_CAP)
        if rnd.random() < 0.7: img.set(xx, h - 1, WALL_CAP)
    for yy in range(h):
        if rnd.random() < 0.7: img.set(0, yy, WALL_CAP)
        if rnd.random() < 0.7: img.set(w - 1, yy, WALL_CAP)
    # Timber frame of a hall: posts on a grid joined by beams.
    fx, fy, fw, fh = 3, 3, w - 7, h - 9
    for xx in range(fx, fx + fw):
        img.set(xx, fy, WOOD); img.set(xx, fy + fh - 1, WOOD)
    for yy in range(fy, fy + fh):
        img.set(fx, yy, WOOD); img.set(fx + fw - 1, yy, WOOD)
    for xx in range(fx, fx + fw, 3):
        for yy in range(fy, fy + fh, 3):
            img.set(xx, yy, ROOF_BARK[0])
    if seed % 2:
        roof(img, fx + 1, fy + 1, fw // 2, fh - 2, ROOF_TILE)   # half-tiled roof
    # Lumber stacks and earth mounds near the south wall.
    for k in range(3):
        lx = 2 + k * 5
        img.rect(lx, h - 5, 3, 1, LUMBER); img.rect(lx, h - 4, 3, 1, WOOD)
    img.rect(w - 5, h - 4, 3, 2, ROOF_BARK[2]); img.set(w - 4, h - 5, ROOF_BARK[3])
    return img


def pagoda(img, cx, cy, size):
    """五重塔 seen from above: tiers as concentric squares, finial in the middle."""
    half = size // 2
    for k in range(half + 1):
        c = ROOF_TILE[0] if k % 2 == 0 else ROOF_TILE[2]
        img.outline(cx - half + k, cy - half + k, size - 2 * k, size - 2 * k, c)
    img.set(cx, cy, hexc("C9A23F"))  # gilt finial (相輪)


def temple(w, h, seed):
    """Temple precinct: outer wall with south gate, corridor ring, main hall, pagoda, trees."""
    rnd = random.Random(seed)
    img = Img(w, h)
    speckle(img, 0, 0, w, h, GROUND, GROUND_DOT, rnd, 0.08)
    img.outline(0, 0, w, h, WALL_CAP)
    # South gate (南大門).
    gx = w // 2
    roof(img, gx - 2, h - 3, 5, 3, ROOF_TILE)
    img.set(gx - 1, h - 1, VERMILION); img.set(gx + 1, h - 1, VERMILION)
    if w >= 30 and h >= 30:
        # Corridor (回廊) around a gravel court with pagoda and main hall; halls to the north.
        cx0, cy0 = w // 6, h // 5
        cw, ch = w - 2 * cx0, h // 2
        speckle(img, cx0, cy0, cw, ch, GRAVEL, GRAVEL_DOT, rnd, 0.15)
        img.outline(cx0, cy0, cw, ch, ROOF_TILE[1])
        img.outline(cx0 + 1, cy0 + 1, cw - 2, ch - 2, ROOF_TILE[0])
        # Vermilion pillars along the inner side of the corridor.
        for xx in range(cx0 + 2, cx0 + cw - 2, 3):
            img.set(xx, cy0 + 2, VERMILION); img.set(xx, cy0 + ch - 3, VERMILION)
        for yy in range(cy0 + 2, cy0 + ch - 2, 3):
            img.set(cx0 + 2, yy, VERMILION); img.set(cx0 + cw - 3, yy, VERMILION)
        roof(img, cx0 + cw // 2 - 2, cy0 + ch - 2, 5, 3, ROOF_TILE)       # middle gate (中門)
        img.set(cx0 + cw // 2, cy0 + ch - 1, VERMILION)
        ps = 7 if w < 50 else 9
        pagoda(img, cx0 + cw // 4 + 1, cy0 + ch // 2, ps)
        hx, hy, hw = cx0 + cw // 2 + 1, cy0 + ch // 2 - 3, cw // 2 - 4
        roof(img, hx, hy, hw, 6, ROOF_TILE)                                    # 金堂
        for xx in range(hx, hx + hw, 2):
            img.set(xx, hy + 6, VERMILION)                                     # pillars under the eaves
        roof(img, cx0, cy0 - 5 if cy0 >= 6 else 1, cw, 4, ROOF_TILE)            # 講堂
        # Pond garden (like Shinsen-en) in the largest precinct, monks' quarters otherwise.
        if w >= 50:
            pw, ph = cx0 + cw // 3, h - cy0 - ch - 8
            pond(img, 3, cy0 + ch + 3, pw, ph, rnd)
            for k in range(0, pw, 3):
                tree(img, 3 + k, cy0 + ch + 2, rnd, 0)
            roof(img, 3 + pw // 2 - 2, cy0 + ch + 3 + ph // 2 - 1, 4, 3, ROOF_TILE)  # pavilion on the island
        else:
            place_buildings(img, 2, cy0 + ch + 1, cx0 - 3, h - cy0 - ch - 5, rnd, 2, [(4, 3), (3, 4)], ROOFS)
        place_buildings(img, cx0 + cw + 1, cy0 + ch + 1, w - cx0 - cw - 3, h - cy0 - ch - 5, rnd, 2,
                        [(4, 3), (3, 4)], ROOFS)
        trees = 10 if w < 50 else 22
    elif h > w:
        # Narrow precinct: pagoda in front of the hall.
        speckle(img, 2, 2, w - 4, h - 6, GRAVEL, GRAVEL_DOT, rnd, 0.15)
        roof(img, 3, 3, w - 6, 8, ROOF_TILE)                     # 本堂
        for xx in range(3, w - 3, 3):
            img.set(xx, 11, VERMILION)                           # pillars under the eaves
        pagoda(img, w // 2, h // 2 + 3, 7)
        roof(img, 3, h // 2 + 10, 5, 3, ROOF_BARK)
        trees = 6
    else:
        # Small temple: one hall on a gravel court.
        speckle(img, 2, 2, w - 4, h - 6, GRAVEL, GRAVEL_DOT, rnd, 0.15)
        roof(img, 4, 4, w - 8, 7, ROOF_TILE)
        for xx in range(4, w - 4, 3):
            img.set(xx, 11, VERMILION)
        trees = 4
    # Trees inside the outer wall.
    for _ in range(trees):
        side = rnd.randrange(4)
        if side == 0: tx, ty = rnd.randrange(2, w - 2), 2
        elif side == 1: tx, ty = 2, rnd.randrange(2, h - 4)
        elif side == 2: tx, ty = w - 3, rnd.randrange(2, h - 4)
        else: tx, ty = rnd.randrange(2, w - 2), h - 5
        if img.get(tx, ty) in (GROUND, GROUND_DOT):
            tree(img, tx, ty, rnd, 1)
    img.outline(0, 0, w, h, WALL_CAP)
    img.set(gx - 1, h - 1, VERMILION); img.set(gx + 1, h - 1, VERMILION)
    return img


def river(w, h, seed):
    """River segment that tiles vertically: stone/sand banks, water with ripples."""
    rnd = random.Random(seed)
    img = Img(w, h)
    for y in range(h):
        for x in range(w):
            if x in (0, w - 1):
                c = rnd.choice([SAND, STONE[1], STONE[2], SAND])
            else:
                c = WATER[1] if (x + y // 3) % 5 else WATER[2]
                if rnd.random() < 0.06: c = WATER[3]
                if x in (1, w - 2) and rnd.random() < 0.3: c = WATER[0]
            img.set(x, y, c)
        if rnd.random() < 0.08:
            img.set(rnd.choice([0, w - 1]), y, GREEN[2])  # reeds
    return img


def river_cap(w, h, top):
    """Closed river end: the bank curves across; water only reaches the inner edge."""
    img = Img(w, h)
    for y in range(h):
        depth = y if top else h - 1 - y          # distance from the closed end
        for x in range(w):
            inner = abs(x - (w - 1) / 2) <= depth - 0.5
            img.set(x, y, WATER[1] if inner and 0 < x < w - 1 else (STONE[1] if (x + y) % 3 == 0 else SAND))
    return img


def short_stream(w, h, seed):
    """A short stream/pond closed at both ends (single-tile waterway)."""
    rnd = random.Random(seed)
    img = Img(w, h)
    for y in range(h):
        for x in range(w):
            edge = y < 2 or y >= h - 2 or x in (0, w - 1)
            img.set(x, y, (STONE[1] if rnd.random() < 0.4 else SAND) if edge else WATER[1 if (x + y) % 4 else 2])
    img.set(w // 2, h // 2, STONE[2])
    return img


def avenue(w, h, seed):
    """Great avenue (大路), tiles horizontally: dense tree rows, ditches, packed earth with ruts."""
    rnd = random.Random(seed)
    img = Img(w, h)
    for y in range(h):
        for x in range(w):
            if y in (3, h - 4):
                c = DITCH
            elif y < 3 or y > h - 4:
                c = GROUND if rnd.random() < 0.7 else GROUND_DOT
            else:
                c = ROAD_LIGHT if rnd.random() < 0.15 else ROAD
                if y in (5, h - 6) and rnd.random() < 0.6:
                    c = ROAD_DARK                      # cart ruts
            img.set(x, y, c)

    def wset(x, y, c):
        img.set(x % w, y, c)                           # wrap so the strip tiles seamlessly

    # Overlapping canopies every 4 px (240 is a multiple of 4), offset between the two rows.
    for row, offset in ((1, 0), (h - 2, 2)):
        for x in range(offset, w, 4):
            for dx in range(-2, 3):
                for dy in (-1, 0, 1):
                    if abs(dx) + abs(dy) <= 2:
                        wset(x + dx, row + dy, GREEN[rnd.choice([1, 2, 2, 3])])
            wset(x + 1, row + 1, GREEN[0])             # shadow on the south-east side
    return img


# --- Atlas layout ------------------------------------------------------------------

def main():
    pieces = []
    sprites = []  # (img, piece dict)

    def add(img, **meta):
        sprites.append((img, meta))

    styles = ["shinden", "machiya", "garden", "mixed"]
    for i in range(16):
        add(compound(19, 19, 100 + i, style=styles[i % 4]), id=f"hk_c{i}", kind="block", zone="commercial_zone")
    # Halves: walls on the outer sides only; sizes match the renderer's half rectangles.
    for i in range(4):
        add(compound(10, 19, 200 + i, walls="NSW"), id=f"hk_l{i}", kind="block_part", zone="commercial_zone",
            split="v", local_rect=[0, 0, 10, 19])
        add(compound(9, 19, 210 + i, walls="NSE"), id=f"hk_r{i}", kind="block_part", zone="commercial_zone",
            split="v", local_rect=[10, 0, 9, 19])
        add(compound(19, 10, 220 + i, walls="NEW"), id=f"hk_t{i}", kind="block_part", zone="commercial_zone",
            split="h", local_rect=[0, 0, 19, 10])
        add(compound(19, 9, 230 + i, walls="SEW"), id=f"hk_b{i}", kind="block_part", zone="commercial_zone",
            split="h", local_rect=[0, 10, 19, 9])
    for i in range(2):
        add(construction(19, 19, 300 + i), id=f"hk_building{i}", kind="building")
    # Temples: sizes equal the rendered spans with 1 px roads (n*19 + (n-1)), so no rescaling.
    add(temple(19, 19, 401), id="park_D", kind="urban_forest")
    add(temple(19, 39, 402), id="park_B", kind="urban_forest")
    add(temple(39, 39, 403), id="park_C", kind="urban_forest")
    add(temple(59, 59, 404), id="park_A", kind="urban_forest")
    add(river(6, 95, 501), id="canal_N", kind="river_canal", zone="waterway")
    add(short_stream(5, 19, 502), id="canal_S", kind="river_canal", zone="waterway")
    add(river_cap(6, 3, True), id="canal_cap_top", kind="river_canal", zone="waterway")
    add(river_cap(6, 4, False), id="canal_cap_bottom", kind="river_canal", zone="waterway")
    add(avenue(240, 14, 601), id="boulevard", kind="firebreak_boulevard")

    # Shelf packing into a 256-wide atlas with 1 px gaps.
    width, x, y, row_h = 256, 0, 0, 0
    placed = []
    for img, meta in sprites:
        if x + img.w > width:
            x, y, row_h = 0, y + row_h + 1, 0
        placed.append((img, meta, x, y))
        x += img.w + 1
        row_h = max(row_h, img.h)
    height = y + row_h
    atlas = Img(width, height)
    for img, meta, px, py in placed:
        atlas.blit(img, px, py)
        piece = dict(meta)
        piece.update(atlas_x=px, atlas_y=py, atlas_w=img.w, atlas_h=img.h)
        pieces.append(piece)

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "patterns.png"), "wb") as f:
        f.write(atlas.png())
    with open(os.path.join(OUT_DIR, "tiles.json"), "w") as f:
        json.dump({"atlas": {"file": "patterns.png", "width": width, "height": height,
                             "note": "generated by Scripts/gen-heiankyo11c-atlas.py"},
                   "pieces": pieces}, f, indent=1, ensure_ascii=False)
    print(f"wrote {OUT_DIR}/patterns.png ({width}x{height}) and tiles.json ({len(pieces)} pieces)")


if __name__ == "__main__":
    main()
