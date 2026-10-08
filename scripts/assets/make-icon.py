#!/usr/bin/env python3
"""Regenerate Resources/AppIcon.icns and docs/icon.png (requires Pillow).

The mark is GrokGauge's own glyph (open ring + slash) inside a gauge arc.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
S = 1024 * 4  # supersample


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m


def arc_points(cx, cy, r, a0, a1, step=0.25):
    pts = []
    a = a0
    while a <= a1:
        rad = math.radians(a)
        pts.append((cx + r * math.cos(rad), cy + r * math.sin(rad)))
        a += step
    return pts


def thick_arc(draw, cx, cy, r, a0, a1, width, fill, caps=True):
    w = int(width)
    draw.arc([cx - r - w / 2, cy - r - w / 2, cx + r + w / 2, cy + r + w / 2], a0, a1, fill=fill, width=w)
    if caps:
        for a in (a0, a1):
            x, y = cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))
            draw.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=fill)


def thick_polyline(draw, pts, width, fill):
    draw.line(pts, fill=fill, width=int(width), joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def main():
    inset = int(S * 0.098)  # macOS icon grid: ~824/1024 body
    body = S - 2 * inset
    radius = int(body * 0.225)

    # Background: deep graphite vertical gradient.
    bg = Image.new("RGBA", (S, S))
    top, bottom = (44, 46, 54, 255), (10, 11, 14, 255)
    px = ImageDraw.Draw(bg)
    for y in range(S):
        px.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S))
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), squircle_mask(S, inset, radius))

    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx = cy = S / 2

    # Gauge track + colored progress arc (green -> orange -> red).
    gr = body * 0.40
    gw = body * 0.055
    thick_arc(d, cx, cy, gr, 135, 405, gw, (255, 255, 255, 34))
    stops = [(52, 199, 89), (255, 159, 10), (255, 69, 58)]
    a0, a1 = 135.0, 135.0 + 270 * 0.72
    seg = 1.0
    a = a0
    while a < a1:
        t = (a - a0) / 270
        c = lerp(stops[0], stops[1], t / 0.5) if t < 0.5 else lerp(stops[1], stops[2], (t - 0.5) / 0.5)
        thick_arc(d, cx, cy, gr, a, min(a1, a + seg + 0.3), gw, c + (255,), caps=False)
        a += seg
    for ang, col in ((a0, stops[0]),):
        x, y = cx + gr * math.cos(math.radians(ang)), cy + gr * math.sin(math.radians(ang))
        d.ellipse([x - gw / 2, y - gw / 2, x + gw / 2, y + gw / 2], fill=col + (255,))
    t_end = (a1 - a0) / 270
    end_col = lerp(stops[1], stops[2], (t_end - 0.5) / 0.5)
    x, y = cx + gr * math.cos(math.radians(a1)), cy + gr * math.sin(math.radians(a1))
    d.ellipse([x - gw / 2, y - gw / 2, x + gw / 2, y + gw / 2], fill=end_col + (255,))

    # The mark (same geometry as GrokMarkGeometry in Swift), white.
    ms = body * 0.50
    ox, oy = cx - ms / 2, cy - ms / 2
    lw = ms * 0.105
    white = (245, 246, 248, 255)
    thick_arc(d, ox + 0.5 * ms, oy + 0.5 * ms, 0.33 * ms, -15, 285, lw, white)
    thick_polyline(d, [(ox + 0.30 * ms, oy + 0.70 * ms), (ox + 0.87 * ms, oy + 0.13 * ms)], lw, white)

    glow = layer.filter(ImageFilter.GaussianBlur(S * 0.012))
    icon.alpha_composite(glow)
    icon.alpha_composite(layer)

    # Subtle top highlight edge.
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle([inset, inset, S - inset, S - inset], radius=radius,
                                         outline=(255, 255, 255, 40), width=int(S * 0.004))
    icon.alpha_composite(hl)

    out = icon.resize((1024, 1024), Image.LANCZOS)
    (ROOT / "docs").mkdir(exist_ok=True)
    out.save(ROOT / "docs" / "icon.png")
    out.save(ROOT / "Resources" / "AppIcon.icns",
             sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote docs/icon.png and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
