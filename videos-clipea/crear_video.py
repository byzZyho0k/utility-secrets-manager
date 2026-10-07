#!/usr/bin/env python3
"""Genera un vídeo vertical de 15 s con música de suspense/emoción y una frase motivadora.

Uso:
    python3 crear_video.py "TU FRASE AQUÍ" [salida.mp4] [--mood suspense|emocion]
    python3 crear_video.py --lote frases.txt      # un vídeo por línea
    python3 crear_video.py "FRASE" --fondo clip.mp4   # usar tu propio vídeo de fondo
"""
import argparse
import os
import subprocess
import tempfile
import textwrap
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import fondo_anime

SR = 44100
DUR = 15.0
W, H = 1080, 1920
FONT = "/usr/share/fonts/opentype/inter/Inter-Black.otf"
FONT_RESERVA = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# Acordes (frecuencias en Hz) — progresión menor cinematográfica
CHORDS = {
    "emocion": [  # Am - F - C - G
        [110.00, 220.00, 261.63, 329.63],
        [87.31, 174.61, 220.00, 261.63],
        [130.81, 196.00, 261.63, 329.63],
        [98.00, 196.00, 246.94, 293.66],
    ],
    "suspense": [  # Dm - Bb - Gm - A
        [73.42, 146.83, 174.61, 220.00],
        [58.27, 116.54, 146.83, 174.61],
        [98.00, 146.83, 196.00, 233.08],
        [110.00, 164.81, 220.00, 277.18],
    ],
}


def env(n, attack, release):
    e = np.ones(n)
    a, r = max(1, int(attack * SR)), max(1, int(release * SR))
    e[:a] = np.linspace(0, 1, a)
    e[-r:] = np.minimum(e[-r:], np.linspace(1, 0, r))
    return e


def golpes():
    beat_times, bt, gap = [], 0.5, 1.0
    while bt < DUR - 1.4:
        beat_times.append(bt)
        bt += gap
        gap = max(0.4, gap * 0.94)
    return beat_times + [DUR - 0.9]


def _filtro(x, lo=None, hi=None):
    """Filtro paso-banda suave en frecuencia (sin chasquidos)."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    g = np.ones_like(f)
    if hi:
        g *= 1 / (1 + (f / hi) ** 4)
    if lo:
        g *= 1 / (1 + (lo / np.maximum(f, 1e-3)) ** 4)
    return np.fft.irfft(X * g, len(x))


def _saw(freq, t, maxf=4000):
    """Diente de sierra limitado en banda (cuerdas cálidas)."""
    out = np.zeros_like(t)
    k = 1
    while k * freq < maxf and k <= 10:
        out += np.sin(2 * np.pi * k * freq * t) / k
        k += 1
    return out


def _poner(out, s, x):
    if s >= len(out):
        return
    x = x[: len(out) - s]
    out[s:s + len(x)] += x


def music(mood):
    n = int(DUR * SR)
    t = np.arange(n) / SR
    rng = np.random.default_rng(7)
    chords = CHORDS[mood]
    seg = DUR / 4
    pad = np.zeros(n)
    bajo = np.zeros(n)
    piano = np.zeros(n)
    perc = np.zeros(n)

    # Cuerdas: acordes una octava arriba, vibrato lento y fundido entre acordes
    for i, chord in enumerate(chords):
        s = int(max(0, i * seg - 0.5) * SR)
        e = int(min(DUR, (i + 1) * seg + 0.5) * SR)
        tt = t[s:e]
        vib = 1 + 0.003 * np.sin(2 * np.pi * 5 * tt)
        x = np.zeros(e - s)
        for f in chord[1:]:
            f2 = f * 2 if f < 200 else f
            for det in (0.997, 1.003):
                x += _saw(f2 * det * vib.mean(), tt + rng.uniform(0, 1))
        x *= env(e - s, 0.8, 0.8)
        pad[s:e] += x
        # bajo: fundamental + armónicos audibles en móvil
        r = chord[0]
        bajo[s:e] += (np.sin(2 * np.pi * r * tt) + 0.6 * np.sin(4 * np.pi * r * tt)
                      + 0.3 * np.sin(6 * np.pi * r * tt)) * env(e - s, 0.4, 0.6)
    pad = _filtro(pad, lo=180, hi=2600)
    pad *= 0.10 * np.clip(0.4 + t / DUR, 0, 1)
    bajo *= 0.16 * np.clip(t / 1.5, 0, 1)

    # Piano: motivo que se repite en cada acorde (se oye bien en el móvil)
    patron = [0, 2, 1, 3, 2, 1] if mood == "emocion" else [0, 1, 0, 2, 0, 3]
    paso = seg / len(patron)
    for i, chord in enumerate(chords):
        notas = sorted(f * 4 if f < 150 else f * 2 for f in chord)
        for j, idx in enumerate(patron):
            f = notas[idx % len(notas)]
            ln = int(1.8 * SR)
            tt = np.arange(ln) / SR
            x = (np.sin(2 * np.pi * f * tt) + 0.35 * np.sin(4 * np.pi * f * tt)
                 + 0.12 * np.sin(6 * np.pi * f * tt)) * np.exp(-tt * 2.6)
            x *= env(ln, 0.008, 0.3)
            vel = 0.6 + 0.4 * rng.random()
            _poner(piano, int((i * seg + j * paso) * SR), x * vel)
    piano *= 0.13

    # Golpes épicos: cuerpo grave + "click" para que se sienta en el móvil
    for b in golpes()[:-1]:
        ln = int(0.5 * SR)
        tt = np.arange(ln) / SR
        fr = 45 + 110 * np.exp(-tt * 25)
        cuerpo = np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-tt * 6)
        cuerpo = np.tanh(cuerpo * 2.2) / np.tanh(2.2)
        clk = _filtro(rng.normal(0, 1, ln), lo=1500, hi=5000) * np.exp(-tt * 180) * 0.6
        x = (cuerpo + clk) * env(ln, 0.003, 0.08)
        _poner(perc, int(b * SR), x * (0.45 + 0.55 * b / DUR))
    perc *= 0.55

    # Tensión extra
    extra = np.zeros(n)
    if mood == "suspense":  # tic-tac de reloj
        for k in np.arange(0.25, DUR - 1.2, 0.5):
            ln = int(0.03 * SR)
            tt = np.arange(ln) / SR
            f = 2400 if int(k * 2) % 2 else 1800
            _poner(extra, int(k * SR), np.sin(2 * np.pi * f * tt) * np.exp(-tt * 250) * env(ln, 0.002, 0.005))
        extra *= 0.06
    else:  # campanitas suaves en los cambios de acorde
        for i, chord in enumerate(chords):
            ln = int(2.5 * SR)
            tt = np.arange(ln) / SR
            f = chord[-1] * 4
            _poner(extra, int(i * seg * SR), np.sin(2 * np.pi * f * tt) * np.exp(-tt * 1.5) * env(ln, 0.003, 0.2))
        extra *= 0.05

    # Subida final (sin siseo): ruido filtrado + tono que sube
    sub = np.zeros(n)
    rs = int((DUR - 3.2) * SR)
    m = int((DUR - 0.9) * SR) - rs
    tt = np.arange(m) / SR
    curva = (tt / tt[-1]) ** 2
    ruido = _filtro(rng.normal(0, 1, m), lo=400, hi=2500) * curva * 0.12
    barrido = np.sin(2 * np.pi * np.cumsum(220 + 600 * curva) / SR) * curva * 0.06
    sub[rs:rs + m] = (ruido + barrido) * env(m, 0.3, 0.01)
    # Impacto final
    hit = int((DUR - 0.9) * SR)
    tt = np.arange(n - hit) / SR
    boom = np.sin(2 * np.pi * np.cumsum(40 + 90 * np.exp(-tt * 8)) / SR) * np.exp(-tt * 2.2)
    boom = np.tanh(boom * 2) * 0.6
    boom += _filtro(rng.normal(0, 1, n - hit), hi=1200) * np.exp(-tt * 5) * 0.25
    sub[hit:] += boom

    seco = pad + bajo + piano + perc + extra + sub
    # Reverb difusa por convolución (sin ecos sueltos)
    ir_n = int(1.8 * SR)
    ir_t = np.arange(ir_n) / SR
    ir = _filtro(rng.normal(0, 1, ir_n), hi=4000) * np.exp(-ir_t * 3.2)
    ir /= np.sqrt(np.sum(ir ** 2))
    L = 1 << int(np.ceil(np.log2(n + ir_n)))
    wet = np.fft.irfft(np.fft.rfft(pad + piano + extra, L) * np.fft.rfft(ir, L), L)[:n]
    mezcla = seco + 0.35 * wet
    mezcla = _filtro(mezcla, lo=35, hi=12000)
    mezcla *= env(n, 0.02, 0.5)
    mezcla /= np.max(np.abs(mezcla)) + 1e-9
    mezcla = np.tanh(mezcla * 1.2) / np.tanh(1.2) * 0.89
    mezcla = _filtro(mezcla, hi=9000)
    # estéreo: piano y cuerdas un poco abiertos
    ancho = _filtro(wet, lo=300) * 0.08
    ancho /= np.max(np.abs(mezcla)) + 1e-9
    stereo = np.stack([mezcla + ancho, mezcla - ancho], axis=1)
    stereo /= max(1.0, np.max(np.abs(stereo)) / 0.95)
    return (stereo * 32767).astype(np.int16)


def write_wav(path, data):
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def _fuente(tam):
    try:
        return ImageFont.truetype(FONT, tam)
    except OSError:
        return ImageFont.truetype(FONT_RESERVA, tam)


def _partir(texto, fuente, ancho_max):
    lineas, actual = [], ""
    for palabra in texto.split():
        prueba = (actual + " " + palabra).strip()
        if fuente.getlength(prueba) <= ancho_max or not actual:
            actual = prueba
        else:
            lineas.append(actual)
            actual = palabra
    if actual:
        lineas.append(actual)
    return lineas


def _maquetar(frase):
    """Elige el tamaño más grande que deja la frase en <= 4 líneas dentro de márgenes."""
    texto = frase.upper()
    for tam in (104, 94, 86, 78, 70, 62):
        f = _fuente(tam)
        lineas = _partir(texto, f, W - 150)
        if len(lineas) <= 4 and all(f.getlength(l) <= W - 150 for l in lineas):
            return tam, lineas
    return tam, lineas


def _png_linea(texto, tam, color, ruta):
    """Una línea de texto con contorno y sombra, con la línea base siempre en el mismo sitio."""
    f = _fuente(tam)
    alto = int(tam * 1.7)
    base = int(tam * 1.15)
    capa = Image.new("RGBA", (W, alto), (0, 0, 0, 0))
    sombra = Image.new("RGBA", (W, alto), (0, 0, 0, 0))
    ImageDraw.Draw(sombra).text((W // 2, base + 8), texto, font=f, anchor="ms", fill=(0, 0, 0, 200),
                                stroke_width=max(4, tam // 12), stroke_fill=(0, 0, 0, 200))
    sombra = sombra.filter(ImageFilter.GaussianBlur(10))
    ImageDraw.Draw(capa).text((W // 2, base), texto, font=f, anchor="ms", fill=color,
                              stroke_width=max(4, tam // 14), stroke_fill=(0, 0, 0, 255))
    Image.alpha_composite(sombra, capa).save(ruta)
    return alto, base


def _png_velo(ruta, hasta):
    """Degradado oscuro arriba para que el texto se lea siempre."""
    y = np.arange(H)[:, None]
    a = np.clip(1 - y / hasta, 0, 1) ** 1.3 * 170
    rgba = np.zeros((H, W, 4), np.uint8)
    rgba[..., 3] = np.repeat(a, W, axis=1).astype(np.uint8)
    Image.fromarray(rgba).save(ruta)


def render(frase, salida, mood, fondo=None, seed=0, gancho="ESCUCHA ESTO..."):
    tam, lines = _maquetar(frase)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "m.wav")
        write_wav(wav, music(mood))

        if fondo:
            entrada = ["-stream_loop", "-1", "-i", fondo]
            prep = (f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},fps=30,"
                    f"eq=brightness=-0.12:saturation=1.15,")
        else:
            bg = os.path.join(tmp, "bg.mp4")
            fondo_anime.generar(bg, mood, golpes(), DUR, seed)
            entrada = ["-i", bg]
            prep = ""

        # Capas PNG: velo + gancho + una por línea
        pngs, overlays = [], []
        lh = int(tam * 1.18)
        y_top = 300
        velo = os.path.join(tmp, "velo.png")
        _png_velo(velo, y_top + len(lines) * lh + 260)
        pngs.append(velo)
        overlays.append("overlay=0:0")
        if gancho:
            ruta = os.path.join(tmp, "gancho.png")
            alto, base = _png_linea(gancho, 62, (255, 213, 74, 255), ruta)
            pngs.append(ruta)
            overlays.append(f"overlay=0:{170 - base}:enable='lt(t,1.6)'")
        for i, ln in enumerate(lines):
            ruta = os.path.join(tmp, f"l{i}.png")
            alto, base = _png_linea(ln, tam, (255, 255, 255, 255), ruta)
            st = 1.5 + i * 0.7
            y = y_top + i * lh + tam - base
            pngs.append(ruta)
            overlays.append(("fade", st, f"overlay=0:'{y}+30*max(0\\,1-(t-{st})/0.45)':eval=frame"))

        cad = [f"[0:v]{prep}zoompan=z='1+0.0003*on':x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':d=1:s={W}x{H}:fps=30,"
               f"vignette=PI/5[v0]"]
        ult = "v0"
        for k, ov in enumerate(overlays):
            idx = k + 2  # 0 = fondo, 1 = audio
            if isinstance(ov, tuple):
                _, st, expr = ov
                cad.append(f"[{idx}:v]format=rgba,fade=t=in:st={st}:d=0.45:alpha=1[p{k}]")
                cad.append(f"[{ult}][p{k}]{expr}[v{k + 1}]")
            else:
                cad.append(f"[{ult}][{idx}:v]{ov}[v{k + 1}]")
            ult = f"v{k + 1}"
        cad.append(f"[{ult}]fade=t=in:st=0:d=0.3,fade=t=out:st={DUR - 0.5}:d=0.5,format=yuv420p[v]")
        cad.append("[1:a]loudnorm=I=-14:TP=-1.5:LRA=11,aresample=44100[a]")

        img_in = []
        for pth in pngs:
            img_in += ["-loop", "1", "-t", str(DUR), "-i", pth]
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            *entrada,
            "-i", wav,
            *img_in,
            "-filter_complex", ";".join(cad),
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-maxrate", "10M", "-bufsize", "20M",
            "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-t", str(DUR), "-movflags", "+faststart",
            salida,
        ]
        subprocess.run(cmd, check=True)
    print("OK ->", salida)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("frase", nargs="?")
    p.add_argument("salida", nargs="?", default="video.mp4")
    p.add_argument("--mood", choices=["suspense", "emocion"], default="emocion")
    p.add_argument("--lote", help="archivo con una frase por línea")
    p.add_argument("--fondo", help="vídeo propio para usar de fondo (si no, se genera uno estilo anime)")
    p.add_argument("--gancho", default="ESCUCHA ESTO...", help="texto gancho del primer segundo ('' para quitarlo)")
    a = p.parse_args()
    if a.lote:
        with open(a.lote, encoding="utf-8") as f:
            frases = [l.strip() for l in f if l.strip()]
        for i, fr in enumerate(frases, 1):
            render(fr, f"video_{i:02d}.mp4", "suspense" if i % 2 else "emocion", a.fondo, i, a.gancho)
    elif a.frase:
        render(a.frase, a.salida, a.mood, a.fondo, 0, a.gancho)
    else:
        p.error("pon una frase o --lote archivo.txt")


if __name__ == "__main__":
    main()
