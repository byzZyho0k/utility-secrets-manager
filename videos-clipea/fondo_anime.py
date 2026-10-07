"""Fondo animado estilo anime (100% generado, sin copyright).

Escena: cielo nocturno/atardecer, luna enorme, ciudad en dos capas con parallax,
protagonista de espaldas en una azotea con bufanda al viento, lluvia o pétalos,
y relámpagos / pulsos de luz sincronizados con los golpes de la música.
"""
import math
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W, H, FPS = 1080, 1920, 30

PALETAS = {
    "suspense": dict(top=(6, 8, 22), mid=(30, 10, 40), hor=(120, 20, 35), moon=(255, 225, 215),
                     glow=(255, 60, 60), city=(10, 6, 16), city2=(22, 12, 30), win=(255, 190, 120)),
    "emocion": dict(top=(18, 10, 50), mid=(110, 40, 110), hor=(255, 140, 70), moon=(255, 240, 210),
                    glow=(255, 170, 90), city=(20, 10, 35), city2=(55, 25, 70), win=(255, 220, 150)),
}


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _cielo(p, rng):
    y = np.linspace(0, 1, H)[:, None]
    top, mid, hor = (np.array(p[k], np.float32) for k in ("top", "mid", "hor"))
    a = np.clip(y / 0.55, 0, 1)
    b = np.clip((y - 0.55) / 0.3, 0, 1)
    col = top * (1 - a) + mid * a
    col = col * (1 - b) + hor * b
    img = np.repeat(col[:, None, :], W, axis=1)
    return img.astype(np.float32)


def _luna(p, cx, cy, r):
    glow = Image.new("RGB", (W, H), 0)
    d = ImageDraw.Draw(glow)
    d.ellipse([cx - r * 2.2, cy - r * 2.2, cx + r * 2.2, cy + r * 2.2], fill=p["glow"])
    glow = glow.filter(ImageFilter.GaussianBlur(r * 0.9))
    disc = Image.new("RGB", (W, H), 0)
    d = ImageDraw.Draw(disc)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=p["moon"])
    # cráteres suaves
    rng = np.random.default_rng(3)
    for _ in range(9):
        a, rr = rng.uniform(0, 6.28), rng.uniform(0, r * 0.7)
        cr = rng.uniform(r * 0.06, r * 0.18)
        x, y = cx + rr * math.cos(a), cy + rr * math.sin(a)
        d.ellipse([x - cr, y - cr, x + cr, y + cr], fill=_lerp(p["moon"], p["glow"], 0.25))
    disc = disc.filter(ImageFilter.GaussianBlur(2))
    return np.asarray(glow, np.float32) * 0.85 + np.asarray(disc, np.float32)


def _ciudad(p, rng, base_y, hmin, hmax, color, ventanas, ancho_extra):
    w = W + ancho_extra
    img = Image.new("RGBA", (w, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = -20
    while x < w:
        bw = int(rng.integers(70, 190))
        bh = int(rng.integers(hmin, hmax))
        top = base_y - bh
        d.rectangle([x, top, x + bw, H], fill=color + (255,))
        if rng.random() < 0.3:  # antena
            ax = x + bw // 2
            d.rectangle([ax - 3, top - rng.integers(40, 120), ax + 3, top], fill=color + (255,))
        if ventanas:
            for wy in range(top + 20, base_y - 10, 34):
                for wx in range(x + 12, x + bw - 16, 26):
                    if rng.random() < 0.22:
                        c = _lerp(ventanas, (255, 255, 255), rng.uniform(0, 0.3))
                        d.rectangle([wx, wy, wx + 11, wy + 16], fill=c + (int(rng.integers(140, 255)),))
        x += bw + int(rng.integers(0, 14))
    return np.asarray(img, np.float32)


def _personaje(p, fase):
    """Silueta de espaldas sobre la azotea, con pelo de punta y bufanda al viento."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    col = (4, 3, 8, 255)
    # azotea
    d.rectangle([0, 1640, W, H], fill=col)
    d.rectangle([0, 1625, W, 1645], fill=(14, 10, 20, 255))
    cx, pies = 540, 1630
    # piernas
    d.polygon([(cx - 70, pies), (cx - 40, pies - 300), (cx - 5, pies - 300), (cx - 25, pies)], fill=col)
    d.polygon([(cx + 25, pies), (cx + 5, pies - 300), (cx + 40, pies - 300), (cx + 70, pies)], fill=col)
    # abrigo con cola que ondea
    ola = 25 * math.sin(fase)
    ola2 = 18 * math.sin(fase + 1.3)
    d.polygon([
        (cx - 105, pies - 520), (cx + 105, pies - 520),
        (cx + 130 + ola2, pies - 150), (cx + 170 + ola, pies - 110),
        (cx + 60, pies - 170), (cx - 60, pies - 170),
        (cx - 135, pies - 140 + ola2 * 0.4),
    ], fill=col)
    # hombros y cuello
    d.ellipse([cx - 120, pies - 560, cx + 120, pies - 470], fill=col)
    d.rectangle([cx - 28, pies - 600, cx + 28, pies - 530], fill=col)
    # cabeza
    hy = pies - 660
    d.ellipse([cx - 62, hy - 70, cx + 62, hy + 75], fill=col)
    # pelo de punta estilo anime
    puntas = [(-75, -10, -150, -60), (-55, -55, -110, -140), (-20, -70, -40, -175), (15, -72, 30, -185),
              (50, -55, 115, -150), (70, -15, 150, -70), (72, 25, 140, 40), (-72, 25, -135, 50)]
    for bx, by, tx, ty in puntas:
        s = 6 * math.sin(fase * 1.4 + bx)
        d.polygon([(cx + bx - 30, hy + by + 25), (cx + bx + 30, hy + by + 10), (cx + tx + s, hy + ty)], fill=col)
    # bufanda: tira larga que ondea a la derecha
    pts_up, pts_dn = [], []
    for i in range(26):
        t = i / 25
        x = cx + 30 + t * 520
        y = pies - 560 + t * 60 + 45 * math.sin(fase * 1.8 - t * 6) * t
        g = 34 * (1 - t * 0.6)
        pts_up.append((x, y - g / 2))
        pts_dn.append((x, y + g / 2))
    d.polygon(pts_up + pts_dn[::-1], fill=(150, 15, 25, 255))
    d.ellipse([cx - 70, pies - 600, cx + 70, pies - 540], fill=(150, 15, 25, 255))
    return np.asarray(img, np.float32)


def _sobre(base, capa, dx=0):
    if dx:
        capa = np.roll(capa, dx, axis=1)
    capa = capa[:, :W]
    a = capa[..., 3:4] / 255.0
    return base * (1 - a) + capa[..., :3] * a


def generar(salida, mood, golpes, dur, seed=0):
    p = PALETAS[mood]
    rng = np.random.default_rng(seed)
    sky = _cielo(p, rng)
    sky += _luna(p, 540, 1010, 240)
    stars_xy = rng.integers(0, [W, int(H * 0.5)], size=(260, 2))
    stars_ph = rng.uniform(0, 6.28, 260)
    lejos = _ciudad(p, rng, 1500, 200, 520, p["city2"], None, 400)
    cerca = _ciudad(p, rng, 1680, 120, 420, p["city"], p["win"], 600)
    # halo del personaje
    pj0 = _personaje(p, 0)
    halo = Image.fromarray(pj0[..., 3].astype(np.uint8)).filter(ImageFilter.GaussianBlur(28))
    halo = np.asarray(halo, np.float32)[..., None] / 255.0 * np.array(p["glow"], np.float32) * 0.9
    pj_frames = [_personaje(p, 2 * math.pi * k / 16) for k in range(16)]

    n_rain = 380 if mood == "suspense" else 0
    rain = np.c_[rng.uniform(0, W, n_rain), rng.uniform(0, H, n_rain), rng.uniform(40, 75, n_rain)]
    n_pet = 0 if mood == "suspense" else 90
    pet = np.c_[rng.uniform(0, W, n_pet), rng.uniform(0, H, n_pet), rng.uniform(1.5, 4, n_pet),
                rng.uniform(0, 6.28, n_pet)]

    golpes = np.array(golpes)
    proc = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
         "-pix_fmt", "yuv420p", salida],
        stdin=subprocess.PIPE,
    )
    total = int(dur * FPS)
    for f in range(total):
        t = f / FPS
        fr = sky.copy()
        # estrellas titilando
        tw = (0.5 + 0.5 * np.sin(stars_ph + t * 3)) * 200
        fr[stars_xy[:, 1], stars_xy[:, 0]] += tw[:, None]
        fr = _sobre(fr, lejos, -int(t * 6))
        fr = _sobre(fr, cerca, -int(t * 16))
        fr += halo * (0.6 + 0.4 * math.sin(t * 2))
        fr = _sobre(fr, pj_frames[f % 16 if mood == "emocion" else (f // 2) % 16])

        # golpe reciente -> relámpago / pulso de luz
        dt = t - golpes[golpes <= t].max() if (golpes <= t).any() else 9
        if mood == "suspense":
            fl = max(0.0, 1 - dt / 0.18) * (0.35 if t > dur * 0.4 else 0.2)
            if fl > 0:
                fr = fr * (1 - fl) + np.array([200, 205, 255], np.float32) * fl
            # lluvia
            rain[:, 1] = (rain[:, 1] + rain[:, 2]) % H
            rain[:, 0] = (rain[:, 0] - rain[:, 2] * 0.15) % W
            for x, y, ln in rain:
                x0, y0 = int(x), int(y)
                y1 = min(H, y0 + int(ln))
                fr[y0:y1, x0:x0 + 2] = fr[y0:y1, x0:x0 + 2] * 0.5 + 110
        else:
            fl = max(0.0, 1 - dt / 0.3) * 0.18
            fr *= 1 + fl
            pet[:, 1] = (pet[:, 1] + pet[:, 2]) % H
            pet[:, 0] = (pet[:, 0] + 1.2 + np.sin(t * 2 + pet[:, 3]) * 1.5) % W
            for x, y, s, ph in pet:
                x0, y0 = int(x), int(y)
                r = int(5 + 3 * math.sin(t * 4 + ph))
                fr[y0:y0 + r, x0:x0 + r * 2] = fr[y0:y0 + r, x0:x0 + r * 2] * 0.3 + np.array([255, 170, 190]) * 0.7
        proc.stdin.write(np.clip(fr, 0, 255).astype(np.uint8).tobytes())
    proc.stdin.close()
    proc.wait()
