#!/usr/bin/env python3
"""Genera un vídeo vertical de 15 s con música de suspense/emoción y una frase motivadora.

Uso:
    python3 crear_video.py "TU FRASE AQUÍ" [salida.mp4] [--mood suspense|emocion]
    python3 crear_video.py --lote frases.txt      # un vídeo por línea
"""
import argparse
import os
import subprocess
import tempfile
import textwrap
import wave

import numpy as np

SR = 44100
DUR = 15.0
W, H = 1080, 1920
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

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
    a, r = int(attack * SR), int(release * SR)
    e[:a] = np.linspace(0, 1, a)
    e[-r:] = np.linspace(1, 0, r)
    return e


def music(mood):
    n = int(DUR * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    rng = np.random.default_rng(7)

    # Pad: acordes con osciladores ligeramente desafinados (supersaw suave)
    seg = DUR / 4
    for i, chord in enumerate(CHORDS[mood]):
        s, e = int(i * seg * SR), int((i + 1) * seg * SR)
        tt = t[s:e]
        pad = np.zeros(e - s)
        for f in chord:
            for det in (-0.6, 0, 0.6):
                pad += np.sin(2 * np.pi * (f + det) * tt + rng.uniform(0, 6.28))
        out[s:e] += 0.035 * pad * env(e - s, 0.9, 0.9)

    # Drone grave continuo
    root = CHORDS[mood][0][0] / 2
    out += 0.12 * np.sin(2 * np.pi * root * t) * np.clip(t / 2, 0, 1)

    # Latido / tambor épico que acelera y crece
    beat_times, bt, gap = [], 0.5, 1.0
    while bt < DUR - 0.6:
        beat_times.append(bt)
        bt += gap
        gap = max(0.35, gap * 0.94)
    for k, b in enumerate(beat_times):
        s = int(b * SR)
        ln = int(0.45 * SR)
        tt = np.arange(ln) / SR
        freq = 55 * np.exp(-tt * 9) + 38
        kick = np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.exp(-tt * 7)
        vol = 0.25 + 0.45 * (b / DUR)
        out[s:s + ln] += vol * kick[: max(0, min(ln, n - s))]

    # Notas de piano (arpegio) en la segunda mitad
    for i, chord in enumerate(CHORDS[mood][2:], start=2):
        for j, f in enumerate(chord[1:] + [chord[1] * 2]):
            st = i * seg + j * seg / 4
            s = int(st * SR)
            ln = int(1.6 * SR)
            tt = np.arange(ln) / SR
            note = (np.sin(2 * np.pi * f * 2 * tt) + 0.4 * np.sin(2 * np.pi * f * 4 * tt)) * np.exp(-tt * 3)
            out[s:s + ln] += 0.09 * note[: max(0, min(ln, n - s))]

    # Riser de ruido al final + golpe final
    rs = int((DUR - 3.5) * SR)
    noise = rng.normal(0, 1, n - rs)
    noise = np.convolve(noise, np.ones(8) / 8, mode="same")
    out[rs:] += 0.10 * noise * np.linspace(0, 1, n - rs) ** 2
    hit = int((DUR - 0.9) * SR)
    tt = np.arange(n - hit) / SR
    out[hit:] += 0.6 * np.sin(2 * np.pi * (40 + 30 * np.exp(-tt * 5)) * tt) * np.exp(-tt * 2.5)

    # Reverb simple (ecos)
    rev = out.copy()
    for d, g in ((0.11, 0.35), (0.23, 0.25), (0.37, 0.18)):
        k = int(d * SR)
        rev[k:] += g * out[:-k]
    out = rev * env(n, 0.05, 0.4)
    out = np.tanh(out * 1.4)
    out /= np.max(np.abs(out)) * 1.05
    stereo = np.stack([out, np.roll(out, 220)], axis=1)
    return (stereo * 32767).astype(np.int16)


def write_wav(path, data):
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def esc(s):
    return s.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace("%", "\\%")


def render(frase, salida, mood):
    lines = textwrap.wrap(frase.upper(), width=14)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "m.wav")
        write_wav(wav, music(mood))

        c0, c1 = ("0x0b0f1a", "0x3a0d12") if mood == "suspense" else ("0x0a1024", "0x5a2a00")
        bg = (
            f"gradients=s={W}x{H}:c0={c0}:c1={c1}:x0=0:y0=0:x1={W}:y1={H}:speed=0.015:d={DUR}:r=30"
        )
        # Partículas: ruido muy oscuro que sube, para dar textura
        draws = []
        lh = 130
        y0 = H / 2 - len(lines) * lh / 2
        for i, ln in enumerate(lines):
            st = 1.2 + i * 0.9
            alpha = f"if(lt(t,{st}),0,if(lt(t,{st + 0.6}),(t-{st})/0.6,1))"
            draws.append(
                f"drawtext=fontfile={FONT}:text='{esc(ln)}':fontsize=92:fontcolor=white:"
                f"borderw=6:bordercolor=black@0.7:shadowx=0:shadowy=8:shadowcolor=black@0.6:"
                f"x=(w-text_w)/2:y={y0 + i * lh}+20*(1-min(1\\,max(0\\,(t-{st})/0.6))):alpha='{alpha}'"
            )
        vf = (
            f"[0:v]noise=alls=4:allf=t,"
            f"zoompan=z='1+0.0006*on':x='iw/2-iw/zoom/2':y='ih/2-ih/zoom/2':d=1:s={W}x{H}:fps=30,"
            f"vignette=PI/4,"
            + ",".join(draws)
            + f",fade=t=in:st=0:d=0.8,fade=t=out:st={DUR - 0.6}:d=0.6[v]"
        )
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", bg,
            "-i", wav,
            "-filter_complex", vf,
            "-map", "[v]", "-map", "1:a",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-maxrate", "8M", "-bufsize", "16M", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-t", str(DUR), "-movflags", "+faststart",
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
    a = p.parse_args()
    if a.lote:
        with open(a.lote, encoding="utf-8") as f:
            frases = [l.strip() for l in f if l.strip()]
        for i, fr in enumerate(frases, 1):
            render(fr, f"video_{i:02d}.mp4", "suspense" if i % 2 else "emocion")
    elif a.frase:
        render(a.frase, a.salida, a.mood)
    else:
        p.error("pon una frase o --lote archivo.txt")


if __name__ == "__main__":
    main()
