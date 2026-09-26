"""Dessine l'icône de l'app d'après le logo des maquettes : œuf orange, goutte
sombre au centre, sur fond blanc. Même dessin que MpLogo (lib/widgets/brand.dart).

    python tool/make_icon.py
    dart run flutter_launcher_icons

Produit assets/icon/icon.png (iOS, anciens Android) et
assets/icon/icon_foreground.png (icône adaptative Android, fond blanc).
Pour une autre icône, remplacer ces deux PNG (1024 × 1024) et relancer
seulement la seconde commande.
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

WHITE = (255, 255, 255, 255)
RIM = (0x5A, 0x32, 0x08, 255)
CORE = (0x11, 0x11, 0x11, 255)
# Dégradé de l'œuf, du haut gauche au bas droit.
GRADIENT = [(0xFF, 0xBE, 0x55), (0xFF, 0x9F, 0x1C), (0xF0, 0x8A, 0x00)]
SUPERSAMPLE = 4
OUT = Path(__file__).resolve().parent.parent / 'assets' / 'icon'


def egg_points(left, top, w, h):
    cx, cy, a, b = left + w / 2, top + h / 2, w / 2 / 1.06, h / 2
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        s = math.sin(t)
        pts.append((cx + a * math.cos(t) * (1 - 0.12 * s), cy - b * s))
    return pts


def cubic(p0, p1, p2, p3, n=60):
    return [
        tuple(
            (1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t ** 2 * c + t ** 3 * d
            for a, b, c, d in zip(p0, p1, p2, p3)
        )
        for t in (i / n for i in range(n + 1))
    ]


def drop_points(left, top, right, bottom):
    w, h, cx = (right - left) / 2, bottom - top, (left + right) / 2
    belly = top + h * 0.62
    pts = cubic((cx, top), (cx + w * 0.55, top + h * 0.28), (cx + w, top + h * 0.42), (cx + w, belly))
    pts += cubic((cx + w, belly), (cx + w, bottom - h * 0.1), (cx + w * 0.55, bottom), (cx, bottom))
    pts += cubic((cx, bottom), (cx - w * 0.55, bottom), (cx - w, bottom - h * 0.1), (cx - w, belly))
    pts += cubic((cx - w, belly), (cx - w, top + h * 0.42), (cx - w * 0.55, top + h * 0.28), (cx, top))
    return pts


def gradient_fill(n):
    # Calculé petit puis agrandi : le dégradé est doux, rien ne se perd.
    m = 256
    grad = Image.new('RGBA', (m, m))
    px = grad.load()
    for y in range(m):
        for x in range(m):
            t = (x + y) / (2 * (m - 1))
            i = 0 if t < 0.5 else 1
            u = t * 2 - i
            c = [round(GRADIENT[i][k] + (GRADIENT[i + 1][k] - GRADIENT[i][k]) * u) for k in range(3)]
            px[x, y] = (*c, 255)
    return grad.resize((n, n), Image.BILINEAR)


def mark(size, background):
    n = size * SUPERSAMPLE
    im = Image.new('RGBA', (n, n), background or (0, 0, 0, 0))
    h = n * 0.66
    w = h * 0.8
    left, top = (n - w) / 2, (n - h) / 2
    mask = Image.new('L', (n, n), 0)
    ImageDraw.Draw(mask).polygon(egg_points(left, top, w, h), fill=255)
    im.paste(gradient_fill(n), (0, 0), mask)
    draw = ImageDraw.Draw(im)
    dw, dh = w * 0.42, h * 0.5
    dl, dt = left + (w - dw) / 2, top + h * 0.55 - dh / 2
    draw.polygon(drop_points(dl, dt, dl + dw, dt + dh), fill=RIM)
    draw.polygon(
        drop_points(dl + dw * 0.12, dt + dh * 0.2, dl + dw * 0.88, dt + dh * 0.94),
        fill=CORE,
    )
    return im.resize((size, size), Image.LANCZOS)


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    mark(1024, WHITE).save(OUT / 'icon.png')
    # Même dessin, fond transparent : flutter_launcher_icons ajoute lui-même
    # la marge de 16 % de l'icône adaptative.
    mark(1024, None).save(OUT / 'icon_foreground.png')
