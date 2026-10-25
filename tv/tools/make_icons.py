#!/usr/bin/env python3
"""Erzeugt App-Icon, großes Icon und Splash-Screen (reines Python, kein PIL).

Motiv: blaues, abgerundetes Quadrat mit Wellenform – dasselbe Logo wie in der App.
"""
import os, struct, sys, zlib

APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app")
ACCENT = (0x5B, 0x9D, 0xFF)
INK = (0x12, 0x12, 0x12)

# Wellenform-Balken in Einheitskoordinaten (0..1): (Mitte x, Höhe), vertikal zentriert
BARS = [(0.27, 0.21), (0.385, 0.375), (0.5, 0.54), (0.615, 0.335), (0.73, 0.19)]
BAR_W = 0.07
TILE_M, TILE_R = 0.04, 0.2   # Rand und Eckenradius des Quadrats


def in_bar(u, v):
    r = BAR_W / 2
    for cx, hgt in BARS:
        top, bot = 0.5 - hgt / 2, 0.5 + hgt / 2
        if abs(u - cx) > r or v < top or v > bot:
            continue
        if v < top + r and (u - cx) ** 2 + (v - (top + r)) ** 2 > r * r:
            continue
        if v > bot - r and (u - cx) ** 2 + (v - (bot - r)) ** 2 > r * r:
            continue
        return True
    return False


def in_tile(u, v):
    lo, hi, r = TILE_M, 1 - TILE_M, TILE_R
    if u < lo or u > hi or v < lo or v > hi:
        return False
    cx = min(max(u, lo + r), hi - r)
    cy = min(max(v, lo + r), hi - r)
    return (u - cx) ** 2 + (v - cy) ** 2 <= r * r


def sample(u, v):
    """Farbe des Logos an Einheitskoordinate u,v (None = transparent)."""
    if not in_tile(u, v):
        return None
    return INK if in_bar(u, v) else ACCENT


def render_logo(size, ss=4):
    """Liefert Pixelzeilen (RGBA) eines quadratischen Logos mit Kantenglättung."""
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    c = sample((x + (sx + .5) / ss) / size, (y + (sy + .5) / ss) / size)
                    if c:
                        acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; acc[3] += 255
            n = ss * ss
            a = acc[3] // n
            if a:
                cov = acc[3] / 255
                row += bytes((int(acc[0] / cov), int(acc[1] / cov), int(acc[2] / cov), a))
            else:
                row += b"\0\0\0\0"
        rows.append(bytes(row))
    return rows


def png(w, h, rows):
    raw = b"".join(b"\0" + r for r in rows)
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def splash(w=1920, h=1080, logo=300, bg=(0, 0, 0)):
    lrows = render_logo(logo)
    x0, y0 = (w - logo) // 2, (h - logo) // 2
    blank = bytes(bg + (255,)) * w
    rows = []
    for y in range(h):
        if y0 <= y < y0 + logo:
            row = bytearray(blank)
            lr = lrows[y - y0]
            for x in range(logo):
                r, g, b, a = lr[x * 4:x * 4 + 4]
                if a:
                    i = (x0 + x) * 4
                    row[i:i + 4] = bytes((
                        (r * a + bg[0] * (255 - a)) // 255,
                        (g * a + bg[1] * (255 - a)) // 255,
                        (b * a + bg[2] * (255 - a)) // 255, 255))
            rows.append(bytes(row))
        else:
            rows.append(blank)
    return png(w, h, rows)


# iOS-Icon-Varianten: Name -> (Hintergrund, Balken). Muss zu AppIconChoice in ios/Tonalo/Theme.swift passen.
IOS_VARIANTS = {
    "AppIcon": (ACCENT, INK),
    "AppIcon-Purple": ((0x9B, 0x7B, 0xFF), INK),
    "AppIcon-Pink": ((0xFF, 0x6F, 0xB5), INK),
    "AppIcon-Red": ((0xFF, 0x5A, 0x5F), INK),
    "AppIcon-Orange": ((0xFF, 0x9F, 0x43), INK),
    "AppIcon-Yellow": ((0xFF, 0xD2, 0x4A), INK),
    "AppIcon-Green": ((0x3D, 0xDC, 0x97), INK),
    "AppIcon-Dark": (INK, ACCENT),
    "AppIcon-Light": ((0xF2, 0xF2, 0xF2), INK),
}


def render_ios_icon(size=1024, ss=2, bg=ACCENT, fg=INK):
    """Randloses, deckendes Icon für iOS (Ecken rundet iOS selbst ab, Alpha ist nicht erlaubt)."""
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            acc = [0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    c = fg if in_bar((x + (sx + .5) / ss) / size, (y + (sy + .5) / ss) / size) else bg
                    acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]
            n = ss * ss
            row += bytes((acc[0] // n, acc[1] // n, acc[2] // n))
        rows.append(bytes(row))
    raw = b"".join(b"\0" + r for r in rows)
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    for name, size in (("icon.png", 80), ("largeIcon.png", 130)):
        with open(os.path.join(APP, name), "wb") as f:
            f.write(png(size, size, render_logo(size)))
    # Große Version nur als Vorschau / für die README, nicht im IPK
    assets = os.path.join(os.path.dirname(os.path.dirname(APP)), "assets")  # Repo-Wurzel, geteilt mit iOS
    os.makedirs(assets, exist_ok=True)
    with open(os.path.join(assets, "icon-512.png"), "wb") as f:
        f.write(png(512, 512, render_logo(512)))
    with open(os.path.join(APP, "splash.png"), "wb") as f:
        f.write(splash())
    assets = os.path.join(os.path.dirname(os.path.dirname(APP)), "ios", "Tonalo", "Assets.xcassets")
    if os.path.isdir(assets) and "--ios" in sys.argv:
        for name, (bg, fg) in IOS_VARIANTS.items():
            folder = os.path.join(assets, name + ".appiconset")
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, "icon-1024.png"), "wb") as f:
                f.write(render_ios_icon(bg=bg, fg=fg))
            with open(os.path.join(folder, "Contents.json"), "w") as f:
                f.write('{\n  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],\n'
                        '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
            print("iOS-Icon:", name)
    print("Icons + Splash erzeugt in", APP)


if __name__ == "__main__":
    main()
