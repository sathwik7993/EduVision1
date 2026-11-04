# %% [markdown]
# # EduVision field recognizer
#
# Trains the compact on-device recognizer used by `OnnxSheetRecognizer` in the
# app: a small CRNN (CNN + BiLSTM, CTC) that reads one template field crop --
# a handwritten mark such as "38", or a registration number such as
# "21B01A0512" -- and emits per-frame character probabilities.
#
# Data is public only: EMNIST glyphs (Kaggle dataset `crawford/emnist`) are
# composed into strings and rendered onto synthetic exam-sheet backgrounds
# (box borders, ruled lines, circled totals, shadows, blur, JPEG). No student
# data is used.
#
# Runs as a Kaggle script kernel (`python eduvision_recognizer.py`) and locally
# (`python eduvision_recognizer.py --smoke --data-dir <csv dir>`).
#
# v6 trains two models from the v5 weights (`--task both`): one for
# registration numbers, one for marks. Each is a soup (weight average) of
# `--seeds` fine-tuning runs, each run keeping an EMA of its weights; the soup
# is then interpolated with the starting model (WiSE-FT) and the best on a
# second validation set is kept. Its confidence is calibrated by a
# temperature folded into the classifier weights.
#
# Outputs (in the working dir):
# - `field_recognizer_reg.onnx`, `field_recognizer_marks.onnx`
#                                  fp32, input [N,1,32,W] -> probs [N,T,37]
# - `eval_sets.npz`                held-out crops (EMNIST *test* glyphs only)
# - `results.json`                 per task: every candidate on validation, the
#                                  pick, held-out metrics vs the starting model

# %%
import argparse
import glob
import json
import math
import os
import sys
import time

import cv2
import numpy as np

# The app depends on these exact values; keep in sync with
# lib/services/recognition/crop_preprocessor.dart.
CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"  # class i+1; 0 is CTC blank
DIGITS = CHARSET[:10]
INPUT_HEIGHT = 32
MIN_WIDTH = 16
MAX_WIDTH = 512
TRUSTED_ABOVE = 0.90  # ExtractedField.trustedAbove

# Registration-number shapes seen on Indian exam sheets. D = digit, A = letter.
REG_SHAPES = [
    "DDADDADDDD",  # 21B01A0512
    "DDADDADDXX",  # 23H51A05K3: YY, college code, entry, A, branch, roll
    "DDADDADDXX",
    "DDDDDDDDDD",
    "DDDDDDDD",
    "DDDDDDDDDDDD",
    "AADDDDDDD",
    "DDAAADDDD",
    "DDDDADDDDDD",
]


# %% [markdown]
# ## Preprocessing shared with the app
#
# `prep` is the contract with Dart. Grayscale crop in, float32 [32, W] out:
# resize to height 32 keeping aspect (area interpolation), invert so ink is
# high, min-max stretch, pad width to a multiple of 4.


# %%
def prep(gray: np.ndarray) -> np.ndarray:
    h, w = gray.shape[:2]
    width = int(round(w * INPUT_HEIGHT / max(h, 1)))
    width = max(MIN_WIDTH, min(MAX_WIDTH, width))
    # Area when shrinking, bilinear otherwise. Explicit, because OpenCV's
    # INTER_AREA has its own non-bilinear rule when enlarging, which the Dart
    # port would have to copy.
    shrink = width <= w and INPUT_HEIGHT <= h
    resized = cv2.resize(gray, (width, INPUT_HEIGHT), interpolation=cv2.INTER_AREA if shrink else cv2.INTER_LINEAR)
    x = 1.0 - resized.astype(np.float32) / 255.0
    lo, hi = float(x.min()), float(x.max())
    x = (x - lo) / (hi - lo + 1e-3)
    pad = (-width) % 4
    if pad:
        x = np.pad(x, ((0, 0), (0, pad)))
    return x


# %% [markdown]
# ## Glyph bank


# %%
def _read_csv(path: str, limit=None) -> np.ndarray:
    import pandas as pd

    return pd.read_csv(path, header=None, dtype=np.uint8, nrows=limit).to_numpy()


def _find(data_dir: str, name: str) -> str:
    hits = glob.glob(os.path.join(data_dir, "**", name), recursive=True)
    if not hits:
        raise FileNotFoundError(f"{name} not found under {data_dir}")
    return hits[0]


def load_bank(data_dir: str, split: str, limit=None) -> dict:
    """char -> uint8 array [N, 28, 28], ink high. Digits from emnist-digits
    (240k train), letters from emnist-balanced (its letter classes already merge
    the look-alike lowercase shapes)."""
    bank = {c: [] for c in CHARSET}

    digits = _read_csv(_find(data_dir, f"emnist-digits-{split}.csv"), limit)
    images = digits[:, 1:].reshape(-1, 28, 28).transpose(0, 2, 1)
    for d in range(10):
        bank[str(d)] = images[digits[:, 0] == d]

    mapping = {}
    with open(_find(data_dir, "emnist-balanced-mapping.txt")) as f:
        for line in f:
            label, code = line.split()
            mapping[int(label)] = chr(int(code))
    balanced = _read_csv(_find(data_dir, f"emnist-balanced-{split}.csv"), limit)
    images = balanced[:, 1:].reshape(-1, 28, 28).transpose(0, 2, 1)
    for label, ch in mapping.items():
        if ch.isalpha() and ch.isupper():
            bank[ch] = images[balanced[:, 0] == label]

    missing = [c for c, v in bank.items() if len(v) == 0]
    if missing:
        raise ValueError(f"no glyphs for {missing}")
    return bank


# %% [markdown]
# ## Synthetic exam-field renderer

# %%
HERSHEY = [
    cv2.FONT_HERSHEY_SIMPLEX,
    cv2.FONT_HERSHEY_DUPLEX,
    cv2.FONT_HERSHEY_COMPLEX,
    cv2.FONT_HERSHEY_TRIPLEX,
    cv2.FONT_HERSHEY_PLAIN,
    cv2.FONT_HERSHEY_SCRIPT_SIMPLEX,
    cv2.FONT_HERSHEY_SCRIPT_COMPLEX,
]
RENDER_H = 40  # render scale; the model sees height 32


# Characters handwriting mixes up; over-sampled in single boxes, where the
# app has no neighbouring characters to lean on (v4 read a "D" as "0" on 3 of
# the 9 real sheets).
CONFUSABLE = "0DOQ1IL7T5S2Z8B6G4AH9"


def random_text(rng, kind=None) -> str:
    kind = kind or rng.choice(["mark", "reg", "free"], p=[0.45, 0.35, 0.20])
    if kind == "char":
        r = rng.random()
        if r < 0.08:
            return ""  # unfilled box
        pool = CONFUSABLE if r < 0.45 else CHARSET
        return pool[rng.integers(len(pool))]
    if kind == "mark":
        r = rng.random()
        if r < 0.06:
            return ""  # empty box: absent student / no mark entered
        if r < 0.28:
            return str(rng.integers(0, 10))
        if r < 0.38:
            return f"0{rng.integers(0, 10)}"
        if r < 0.92:
            return str(rng.integers(10, 100))
        return str(rng.integers(100, 201))
    if kind == "reg":
        shape = REG_SHAPES[rng.integers(len(REG_SHAPES))]
        pick = {
            "D": lambda: DIGITS[rng.integers(10)],
            "A": lambda: CHARSET[10 + rng.integers(26)],
            "X": lambda: CHARSET[rng.integers(36)],
        }
        return "".join(pick[s]() for s in shape)
    n = int(rng.integers(1, 11))
    return "".join(
        DIGITS[rng.integers(10)] if rng.random() < 0.6 else CHARSET[10 + rng.integers(26)]
        for _ in range(n)
    )


def _glyph_ink(g: np.ndarray, rng, height: int) -> np.ndarray:
    ys, xs = np.nonzero(g > 40)
    if len(ys) == 0:
        return np.zeros((height, 4), np.float32)
    g = g[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1].astype(np.float32) / 255.0
    h = max(8, int(height * rng.uniform(0.55, 0.85)))
    w = max(3, int(g.shape[1] * h / g.shape[0] * rng.uniform(0.8, 1.25)))
    g = cv2.resize(g, (w, h), interpolation=cv2.INTER_LINEAR)
    # Slant and rotation, the main difference between writers.
    shear = rng.uniform(-0.3, 0.3)
    angle = math.radians(rng.uniform(-7, 7))
    c, s = math.cos(angle), math.sin(angle)
    m = np.array([[c, -s + shear, 0], [s, c, 0]], np.float32)
    corners = np.array([[0, 0, 1], [w, 0, 1], [0, h, 1], [w, h, 1]], np.float32) @ m.T
    m[:, 2] = -corners.min(axis=0)
    size = np.ceil(corners.max(axis=0) - corners.min(axis=0)).astype(int) + 1
    g = cv2.warpAffine(g, m, (int(size[0]), int(size[1])))
    # Pen thickness.
    k = rng.choice([-1, 0, 0, 1, 1, 2])
    if k > 0:
        g = cv2.dilate(g, np.ones((k + 1, k + 1), np.uint8))
    elif k < 0 and h > 30:
        g = cv2.erode(g, np.ones((2, 2), np.uint8))
    return np.clip(g, 0, 1)


def _handwritten_ink(text: str, bank: dict, rng) -> np.ndarray:
    pieces = []
    for ch in text:
        pool = bank[ch]
        g = _glyph_ink(pool[rng.integers(len(pool))], rng, RENDER_H)
        pieces.append(g)
    width = sum(p.shape[1] for p in pieces) + RENDER_H * len(pieces)
    canvas = np.zeros((RENDER_H * 2, width + 8), np.float32)
    x = 4
    for p in pieces:
        y = int(RENDER_H * 0.5 + RENDER_H * rng.uniform(-0.06, 0.06) - p.shape[0] / 2 + RENDER_H / 2)
        y = max(0, min(canvas.shape[0] - p.shape[0], y))
        region = canvas[y : y + p.shape[0], x : x + p.shape[1]]
        np.maximum(region, p[: region.shape[0], : region.shape[1]], out=region)
        x += p.shape[1] + int(RENDER_H * rng.uniform(-0.04, 0.35))
        x = max(4, x)
    return _trim(canvas)


def _printed_ink(text: str, rng) -> np.ndarray:
    font = HERSHEY[rng.integers(len(HERSHEY))]
    if rng.random() < 0.3:
        font |= cv2.FONT_ITALIC
    thickness = int(rng.integers(1, 4))
    (tw, th), _ = cv2.getTextSize(text, font, 1.0, thickness)
    scale = RENDER_H * rng.uniform(0.5, 0.8) / max(th, 1)
    canvas = np.zeros((RENDER_H * 2, int(tw * scale) + RENDER_H), np.uint8)
    cv2.putText(
        canvas, text, (RENDER_H // 4, int(RENDER_H * 1.3)), font, scale, 255,
        max(1, int(thickness * scale)), cv2.LINE_AA,
    )
    return _trim(canvas.astype(np.float32) / 255.0)


def _trim(ink: np.ndarray) -> np.ndarray:
    ys, xs = np.nonzero(ink > 0.05)
    if len(ys) == 0:
        return np.zeros((RENDER_H // 2, RENDER_H // 2), np.float32)
    return ink[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]


def _comb_ink(text: str, cells: int, bank: dict, rng):
    """One character per printed box, like the 10-box Registered No. strip.
    Returns (ink, grid); boxes past len(text) stay empty (partly filled)."""
    cw = int(RENDER_H * rng.uniform(0.8, 1.15))
    ch = int(RENDER_H * rng.uniform(1.0, 1.3))
    ink = np.zeros((ch, cw * cells), np.float32)
    grid = np.zeros_like(ink)
    printed = rng.random() < 0.1
    for i, c in enumerate(text):
        if printed:
            g = _printed_ink(c, rng)
        else:
            pool = bank[c]
            g = _glyph_ink(pool[rng.integers(len(pool))], rng, ch)
        scale = min(1.0, (cw - 4) / g.shape[1], (ch - 4) / g.shape[0])
        if scale < 1.0:
            g = cv2.resize(g, (max(2, int(g.shape[1] * scale)), max(2, int(g.shape[0] * scale))))
        y = max(0, (ch - g.shape[0]) // 2 + int(rng.integers(-3, 4)))
        x = max(0, i * cw + (cw - g.shape[1]) // 2 + int(rng.integers(-3, 4)))
        region = ink[y : y + g.shape[0], x : x + g.shape[1]]
        np.maximum(region, g[: region.shape[0], : region.shape[1]], out=region)
    level, t = rng.uniform(0.4, 0.9), int(rng.integers(1, 3))
    cv2.rectangle(grid, (0, 0), (grid.shape[1] - 1, ch - 1), level, t)
    for i in range(1, cells):
        cv2.line(grid, (i * cw, 0), (i * cw, ch), level, t)
    return ink, grid


def _box_crop(text: str, bank: dict, rng):
    """The inside of one printed box of a registration comb, cut out the way
    the app does after finding the box borders: the crop may keep a sliver of
    border at an edge, and a big letter can run past the box and be cut."""
    ch = int(RENDER_H * rng.uniform(1.0, 1.3))
    cw = int(ch * rng.uniform(0.75, 1.2))
    b = max(4, ch // 4)
    ink = np.zeros((ch + 2 * b, cw + 2 * b), np.float32)
    grid = np.zeros_like(ink)
    if text:
        pool = bank[text]
        g = _printed_ink(text, rng) if rng.random() < 0.08 else _glyph_ink(pool[rng.integers(len(pool))], rng, ch)
        target = ch * rng.uniform(0.55, 1.15)
        scale = target / g.shape[0]
        g = cv2.resize(g, (max(2, int(g.shape[1] * scale)), max(2, int(g.shape[0] * scale))))
        y = b + (ch - g.shape[0]) // 2 + int(rng.integers(-ch // 8, ch // 8 + 1))
        x = b + (cw - g.shape[1]) // 2 + int(rng.integers(-cw // 8, cw // 8 + 1))
        y0, x0 = max(0, y), max(0, x)
        y1, x1 = min(ink.shape[0], y + g.shape[0]), min(ink.shape[1], x + g.shape[1])
        if y1 > y0 and x1 > x0:
            np.maximum(ink[y0:y1, x0:x1], g[y0 - y : y1 - y, x0 - x : x1 - x], out=ink[y0:y1, x0:x1])
    elif rng.random() < 0.4:
        inner = np.ascontiguousarray(ink[b:-b, b:-b])
        _stray_marks(inner, rng)
        ink[b:-b, b:-b] = inner
    level, t = rng.uniform(0.4, 0.9), int(rng.integers(1, 3))
    cv2.rectangle(grid, (b, b), (b + cw, b + ch), level, t)
    # The app trims ~6% + 1 px inside the found borders; residuals either way.
    ins = [int(round(rng.uniform(-0.06, 0.1) * ch)) + 1 for _ in range(4)]
    sl = (slice(b + ins[0], b + ch - ins[1]), slice(b + ins[2], b + cw - ins[3]))
    return ink[sl], grid[sl]


def _stray_marks(ink: np.ndarray, rng):
    """Dots and short ticks examiners leave in otherwise empty cells."""
    h, w = ink.shape
    for _ in range(int(rng.integers(1, 4))):
        x, y = int(rng.integers(0, w)), int(rng.integers(0, h))
        if rng.random() < 0.5:
            cv2.circle(ink, (x, y), int(rng.integers(1, 3)), 1.0, -1)
        else:
            dx, dy = rng.integers(-6, 7, size=2)
            cv2.line(ink, (x, y), (x + int(dx), y + int(dy)), 1.0, int(rng.integers(1, 3)))


def render_field(text: str, bank: dict, rng, exam_style: bool = True, layout: str = "free", cells: int = 0) -> np.ndarray:
    """Grayscale uint8 crop as the app would cut it from an aligned page.

    layout: "free" (writing in a box or on a line), "cell" (a large marks-table
    cell with the digits floating in it), or "comb" (one character per printed
    box; `cells` boxes, of which the first len(text) are filled)."""
    grid = None
    if layout == "box":
        ink, grid = _box_crop(text, bank, rng)
    elif layout == "comb":
        ink, grid = _comb_ink(text, max(cells, len(text), 1), bank, rng)
    elif not text:
        ink = np.zeros((RENDER_H // 2, RENDER_H), np.float32)
        if exam_style and rng.random() < 0.5:
            _stray_marks(ink, rng)
    elif rng.random() < 0.15:
        ink = _printed_ink(text, rng)
    else:
        ink = _handwritten_ink(text, bank, rng)

    if not exam_style:
        pad = RENDER_H // 4
        ink = np.pad(ink, pad)
        return (255 - ink * 230).clip(0, 255).astype(np.uint8)

    # ROI margins: the teacher's box is never tight around the writing. A
    # marks-table cell can be several times wider than the digits in it.
    ih, iw = ink.shape
    if layout == "box":
        top = bottom = left = right = 0  # already cut at the box
    elif layout == "comb":
        top, bottom, left, right = (int(RENDER_H * rng.uniform(0.05, 0.4)) for _ in range(4))
    else:
        wide = 2.5 if layout == "cell" else 1.2
        top = int(RENDER_H * rng.uniform(0.08, 0.8 if layout == "cell" else 0.6))
        bottom = int(RENDER_H * rng.uniform(0.08, 0.8 if layout == "cell" else 0.6))
        left = int(RENDER_H * rng.uniform(0.1, wide))
        right = int(RENDER_H * rng.uniform(0.1, wide))
    h, w = ih + top + bottom, iw + left + right
    ink_full = np.zeros((h, w), np.float32)
    ink_full[top : top + ih, left : left + iw] = ink

    # Paper, with a lighting gradient and sensor noise.
    paper = np.full((h, w), rng.uniform(165, 250), np.float32)
    if rng.random() < 0.6:
        gx, gy = rng.uniform(-1, 1, size=2)
        grad = (np.arange(w, dtype=np.float32)[None, :] / w - 0.5) * gx + (np.arange(h, dtype=np.float32)[:, None] / h - 0.5) * gy
        paper += grad * rng.uniform(0, 70)
    paper += rng.standard_normal((h, w), dtype=np.float32) * rng.uniform(0, 7)

    # Printed sheet furniture that leaks into the crop.
    lines = np.zeros((h, w), np.float32)
    line_level = rng.uniform(0.35, 0.85)
    t = int(rng.integers(1, 4))
    if grid is not None:
        lines[top : top + ih, left : left + iw] = grid
    elif layout == "cell" or rng.random() < 0.5:  # cell or box border, slightly inside the ROI
        j = lambda: int(rng.integers(0, max(2, RENDER_H // 6)))
        cv2.rectangle(lines, (j(), j()), (w - 1 - j(), h - 1 - j()), line_level, t)
    else:
        if rng.random() < 0.35:  # ruled line or underline
            y = top + ih + int(rng.integers(-RENDER_H // 8, max(1, bottom)))
            cv2.line(lines, (0, y), (w, y), line_level, t)
        if rng.random() < 0.25:  # table column at one side
            x = int(rng.integers(0, max(1, left))) if rng.random() < 0.5 else w - 1 - int(rng.integers(0, max(1, right)))
            cv2.line(lines, (x, 0), (x, h), line_level, t)
    # Printed text cut off by the crop edge: the end of a label such as
    # "Registered No.:" right before the comb, or a neighbouring cell. v3 read
    # these as a leading digit on every real sheet; they are never part of the
    # field.
    for margin, at_left in ((left, True), (right, False)):
        if layout == "box" or margin < 4 or rng.random() > 0.35:
            continue
        frag = _printed_ink("".join(rng.choice(list(CHARSET + ".:-"), size=int(rng.integers(1, 4)))), rng)
        fh = min(h, max(4, int(ih * rng.uniform(0.5, 1.1))))
        frag = cv2.resize(frag, (max(2, int(frag.shape[1] * fh / frag.shape[0])), fh))
        # Always cut: a whole printed string in the margin would be ambiguous.
        vis = max(2, min(int(frag.shape[1] * rng.uniform(0.2, 0.7)), int(margin * 0.9)))
        frag = frag[:, -vis:] if at_left else frag[:, :vis]
        y = int(rng.integers(0, h - fh + 1))
        x = 0 if at_left else w - vis
        np.maximum(lines[y : y + fh, x : x + vis], frag * rng.uniform(0.6, 1.0), out=lines[y : y + fh, x : x + vis])
    if layout != "box" and 0 < len(text) <= 3 and rng.random() < 0.15:  # examiner circles the total
        cv2.ellipse(
            lines, (left + iw // 2, top + ih // 2),
            (int(iw * rng.uniform(0.55, 0.8)) + 6, int(ih * rng.uniform(0.6, 0.9)) + 6),
            rng.uniform(-10, 10), 0, 360, rng.uniform(0.5, 1.0), int(rng.integers(2, 5)),
        )

    # Ink: pen most of the time, faint pencil sometimes.
    ink_level = rng.uniform(100, 165) if rng.random() < 0.15 else rng.uniform(0, 100)
    gray = paper.copy()
    gray -= np.maximum(lines, 0) * (paper - rng.uniform(20, 90))
    gray = gray * (1 - ink_full) + ink_level * ink_full

    # Small alignment residual: rotation and shift of the whole crop.
    if layout != "box" and rng.random() < 0.7:
        m = cv2.getRotationMatrix2D((w / 2, h / 2), rng.uniform(-3, 3), 1.0)
        m[:, 2] += rng.uniform(-0.06, 0.06, size=2) * np.array([w, h])
        gray = cv2.warpAffine(gray, m, (w, h), borderMode=cv2.BORDER_REPLICATE)

    if rng.random() < 0.6:
        gray = cv2.GaussianBlur(gray, (0, 0), rng.uniform(0.3, 1.4))
    if rng.random() < 0.15:  # hand shake during a phone capture
        k = int(rng.integers(3, 8))
        kernel = np.zeros((k, k), np.float32)
        kernel[k // 2, :] = 1.0 / k
        rot = cv2.getRotationMatrix2D(((k - 1) / 2, (k - 1) / 2), rng.uniform(0, 180), 1.0)
        kernel = cv2.warpAffine(kernel, rot, (k, k))
        gray = cv2.filter2D(gray, -1, kernel / max(kernel.sum(), 1e-6))

    gray = np.clip(gray, 0, 255).astype(np.uint8)
    # Camera resolution: a field is often only 15-40 px tall in the photo
    # (a comb box 12-35 px).
    lo_px, hi_px = (12, 35) if layout == "box" else (18, 48)
    scale = rng.uniform(lo_px, hi_px) / h if rng.random() < 0.8 else 1.0
    if scale < 1.0:
        gray = cv2.resize(gray, (max(4, int(w * scale)), max(4, int(h * scale))), interpolation=cv2.INTER_AREA)
    if rng.random() < 0.5:
        ok, buf = cv2.imencode(".jpg", gray, [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(35, 95))])
        gray = cv2.imdecode(buf, cv2.IMREAD_GRAYSCALE)
    return gray


# %% [markdown]
# ## Model

# %%
import torch
import torch.nn as nn
import torch.nn.functional as F


def _block(cin, cout, k=3, p=1):
    return nn.Sequential(nn.Conv2d(cin, cout, k, padding=p, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True))


class FieldRecognizer(nn.Module):
    """~1M parameters. Width is downsampled 4x, so a 10-character
    registration crop (~300 px at height 32) gets ~75 CTC frames."""

    def __init__(self, classes=len(CHARSET) + 1, hidden=128):
        super().__init__()
        self.cnn = nn.Sequential(
            _block(1, 32), nn.MaxPool2d(2, 2),          # 16 x W/2
            _block(32, 64), nn.MaxPool2d(2, 2),         # 8 x W/4
            _block(64, 128), _block(128, 128), nn.MaxPool2d((2, 1)),  # 4
            _block(128, 192), nn.MaxPool2d((2, 1)),     # 2
            _block(192, 256, k=(2, 1), p=0),            # 1
            nn.Dropout(0.1),
        )
        self.rnn = nn.LSTM(256, hidden, batch_first=True, bidirectional=True)
        self.head = nn.Linear(hidden * 2, classes)

    def features(self, x):
        return self.cnn(x).squeeze(2).transpose(1, 2)  # [N, T, 256]

    def forward(self, x):
        y, _ = self.rnn(self.features(x))
        return F.softmax(self.head(y), dim=-1)  # export path: probabilities

    def train_logits(self, x, lengths):
        f = self.features(x)
        packed = nn.utils.rnn.pack_padded_sequence(f, lengths.cpu(), batch_first=True, enforce_sorted=False)
        y, _ = self.rnn(packed)
        y, _ = nn.utils.rnn.pad_packed_sequence(y, batch_first=True, total_length=f.shape[1])
        return self.head(y)


# %% [markdown]
# ## Decoding and metrics (mirrors lib/services/recognition/ctc_decoder.dart)

# %%
def ctc_decode(probs: np.ndarray, allowed: str = CHARSET):
    """Greedy CTC over the allowed charset. Confidence = minimum per-character
    raw probability (not renormalised over the allowed set), capped by the
    strongest dropped disallowed character -- the same rule
    lib/services/recognition/ctc_decoder.dart uses to gate review."""
    keep = [0] + [CHARSET.index(c) + 1 for c in allowed]
    p = probs[:, keep]
    best = p.argmax(axis=1)
    best_p = p[np.arange(len(p)), best]
    other = probs.copy()
    other[:, keep] = 0
    other[:, 0] = 0
    over = other.max(axis=1) if len(p) else np.zeros(0)
    dropped = float(over[over > best_p].max()) if (over > best_p).any() else 0.0
    text, confs, prev = [], [], 0
    for t, k in enumerate(best):
        if k != prev and k != 0:
            text.append(allowed[k - 1])
            confs.append(p[t, k])
        elif k == prev and k != 0:
            confs[-1] = max(confs[-1], p[t, k])
        prev = k
    if not text:
        # An empty read is only as trustworthy as the blank frames.
        return "", min(float(p[:, 0].min()), 1 - dropped) if len(p) else 0.0
    return "".join(text), min(float(min(confs)), 1 - dropped)


def _cer(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a):
        cur = [i + 1]
        for j, cb in enumerate(b):
            cur.append(min(cur[j] + 1, prev[j + 1] + 1, prev[j] + (ca != cb)))
        prev = cur
    return prev[-1]


def score(preds, labels) -> dict:
    n = len(labels)
    exact = sum(p == l for (p, _), l in zip(preds, labels))
    edits = sum(_cer(p, l) for (p, _), l in zip(preds, labels))
    chars = max(1, sum(len(l) for l in labels))
    accepted = [(p, l) for (p, c), l in zip(preds, labels) if c >= TRUSTED_ABOVE and p]
    silent = sum(p != l for p, l in accepted)
    return {
        "n": n,
        "exact_acc": round(exact / n, 4),
        "cer": round(edits / chars, 4),
        # Fraction the app would auto-accept without forcing review.
        "auto_accept_rate": round(len(accepted) / n, 4),
        # Wrong readings that would pass the review gate: the number that matters.
        "silent_error_rate": round(silent / n, 4),
        "acc_when_accepted": round(1 - silent / max(1, len(accepted)), 4),
    }


# %% [markdown]
# ## Data pipeline

# %%
class FieldStream(torch.utils.data.IterableDataset):
    def __init__(self, bank, seed, task="all"):
        self.bank, self.seed, self.task = bank, seed, task

    def __iter__(self):
        info = torch.utils.data.get_worker_info()
        rng = np.random.default_rng(self.seed + (info.id if info else 0) * 7919 + int(time.time()))
        while True:
            gray, text = sample_task(self.bank, rng, self.task)
            yield prep(gray), text


def sample_task(bank, rng, task="all"):
    """Training data for one of the app's two models.

    reg:   registration numbers, mostly one comb box at a time as the app
           reads them, plus whole combs and free-written numbers.
    marks: marks only (digits), in the cells and boxes they are written in.
    all:   the single general model of v5.
    """
    if task == "reg":
        r = rng.random()
        if r < 0.6:
            return sample_field(bank, rng, "char", "box")
        return sample_field(bank, rng, "reg", "comb" if r < 0.8 else "free")
    if task == "marks":
        r = rng.random()
        if r < 0.12:
            d = DIGITS[rng.integers(10)]
            return render_field(d, bank, rng, layout="box", cells=1), d
        return sample_field(bank, rng, "mark", "cell" if r < 0.55 else "free")
    return sample_field(bank, rng)


def sample_field(bank, rng, kind=None, layout=None):
    """One training/eval example: (grayscale crop, label)."""
    if kind is None and layout is None and rng.random() < 0.3:
        kind, layout = "char", "box"  # the app reads a comb box by box
    if kind == "char":
        layout = "box"
    text = random_text(rng, kind)
    if layout is None:
        if len(text) >= 6 and rng.random() < 0.45:
            layout = "comb"
        elif len(text) <= 3 and rng.random() < 0.4:
            layout = "cell"
        else:
            layout = "free"
    cells = len(text)
    if layout == "comb" and rng.random() < 0.1:
        text = text[: int(rng.integers(1, len(text)))]  # only "23" filled in
    exam_style = layout != "free" or rng.random() < 0.85
    return render_field(text, bank, rng, exam_style=exam_style, layout=layout, cells=cells), text


def collate(batch):
    width = max(x.shape[1] for x, _ in batch)
    xs = np.zeros((len(batch), 1, INPUT_HEIGHT, width), np.float32)
    for i, (x, _) in enumerate(batch):
        xs[i, 0, :, : x.shape[1]] = x
    lengths = torch.tensor([x.shape[1] // 4 for x, _ in batch])
    targets = torch.tensor([CHARSET.index(c) + 1 for _, t in batch for c in t], dtype=torch.long)
    target_lengths = torch.tensor([len(t) for _, t in batch])
    return torch.from_numpy(xs), lengths, targets, target_lengths


def build_eval_sets(bank, n, seed=12345):
    """Fixed held-out sets from EMNIST *test* glyphs."""
    rng = np.random.default_rng(seed)
    sets = {}
    # Classic single-digit check: test glyphs as-is, padded like a tight crop.
    digits = []
    for i in range(n):
        d = str(i % 10)
        g = bank[d][rng.integers(len(bank[d]))]
        digits.append(((255 - np.pad(g, 6)).astype(np.uint8), d))
    sets["emnist_digit"] = digits
    sets["marks_clean"] = [(render_field(t, bank, rng, exam_style=False), t) for t in (random_text(rng, "mark") or "0" for _ in range(n))]
    sets["marks_exam"] = [sample_field(bank, rng, "mark", "free") for _ in range(n)]
    # Totals floating in a wide marks-table cell, ruled lines around them.
    sets["marks_cell"] = [sample_field(bank, rng, "mark", "cell") for _ in range(n)]
    sets["reg_exam"] = [sample_field(bank, rng, "reg", "free") for _ in range(n)]
    # One character per printed box; ~10% only partly filled in.
    sets["reg_comb"] = [sample_field(bank, rng, "reg", "comb") for _ in range(n)]
    # One comb box at a time, as the app reads registration numbers.
    sets["reg_box"] = [sample_field(bank, rng, "char", "box") for _ in range(n)]
    return sets


def save_eval_sets(sets, path):
    arrays = {}
    for name, items in sets.items():
        arrays[f"{name}_pixels"] = np.concatenate([g.ravel() for g, _ in items])
        arrays[f"{name}_shapes"] = np.array([g.shape for g, _ in items], np.int32)
        arrays[f"{name}_labels"] = np.array([t for _, t in items])
    np.savez_compressed(path, **arrays)


def load_eval_sets(path):
    data = np.load(path)
    sets = {}
    for key in data.files:
        if not key.endswith("_labels"):
            continue
        name = key[: -len("_labels")]
        pixels, shapes, labels = data[f"{name}_pixels"], data[f"{name}_shapes"], data[key]
        items, offset = [], 0
        for (h, w), label in zip(shapes, labels):
            items.append((pixels[offset : offset + h * w].reshape(h, w), str(label)))
            offset += h * w
        sets[name] = items
    return sets


def allowed_for(name: str) -> str:
    return CHARSET if name.startswith("reg") else DIGITS


TASK_SETS = {
    "reg": ("reg_box", "reg_comb", "reg_exam"),
    "marks": ("emnist_digit", "marks_clean", "marks_exam", "marks_cell"),
}


def task_val(bank, task, n, seed):
    """Fixed validation set from *train* glyphs (the test glyphs stay for the final eval)."""
    rng = np.random.default_rng(seed)
    out = []
    for _ in range(n):
        g, t = sample_task(bank, rng, task)
        out.append((prep(g), t, CHARSET if task == "reg" else DIGITS))
    return out


# %% [markdown]
# ## Train, export, evaluate

# %%
def evaluate_onnx(path, sets) -> dict:
    import onnxruntime as ort

    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 1  # closest desktop proxy for one phone core
    sess = ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])
    out = {}
    for name, items in sets.items():
        preds, start = [], time.perf_counter()
        for g, _ in items:
            x = prep(g)[None, None]
            probs = sess.run(None, {"input": x})[0][0]
            preds.append(ctc_decode(probs, allowed_for(name)))
        ms = (time.perf_counter() - start) * 1000 / len(items)
        out[name] = {**score(preds, [t for _, t in items]), "ms_per_crop_1thread": round(ms, 3)}
    return out


def val_metrics(model, val, device, temperature=1.0) -> dict:
    """Exact match and the app's review-gate numbers on [val]: the fraction
    read wrong yet trusted (confidence >= 0.90) is what must stay near 0."""
    model.eval()
    hits = silent = accepted = 0
    with torch.no_grad():
        for x, text, allowed in val:
            f = model.features(torch.from_numpy(x)[None, None].to(device))
            y, _ = model.rnn(f)
            probs = F.softmax(model.head(y) / temperature, dim=-1)[0].cpu().numpy()
            pred, conf = ctc_decode(probs, allowed)
            hits += pred == text
            if conf >= TRUSTED_ABOVE and pred:
                accepted += 1
                silent += pred != text
    model.train()
    n = len(val)
    return {"exact": hits / n, "silent": silent / n, "accepted": accepted / n}


def main():
    # Kaggle shows a script's log only as it is flushed.
    sys.stdout.reconfigure(line_buffering=True)
    script_start = time.time()
    # The Kaggle image lacks onnxruntime (v3 crashed on it after training).
    # Install it before training, not after.
    try:
        import onnxruntime  # noqa: F401
    except ImportError:
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "onnxruntime"], check=True)
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="/kaggle/input")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--steps", type=int, default=4000)
    ap.add_argument("--max-minutes", type=float, default=200,
                    help="hard wall-clock cap for the whole run (GPU quota); training stops early enough to export")
    ap.add_argument("--export-minutes", type=float, default=10, help="time reserved for export + eval")
    ap.add_argument("--val-every", type=int, default=500)
    ap.add_argument("--patience", type=int, default=3, help="validations without improvement before stopping")
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--eval-n", type=int, default=2000)
    ap.add_argument("--smoke", action="store_true", help="tiny run on test CSVs to check the pipeline")
    ap.add_argument("--task", default="both", choices=["all", "reg", "marks", "both"],
                    help="both: a registration model and a marks model")
    ap.add_argument("--seeds", type=int, default=3, help="runs per task, averaged into a model soup")
    ap.add_argument("--ema", type=float, default=0.999, help="EMA decay of the weights")
    ap.add_argument("--lr", type=float, default=5e-4, help="peak learning rate (fine-tuning)")
    ap.add_argument("--val-n", type=int, default=1500)
    ap.add_argument("--init", default="field_recognizer.pt",
                    help="state dict to fine-tune from (a path, or a file name found under --data-dir, "
                         "e.g. an attached earlier kernel's output); trains from scratch if not found")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print("device", device, "cpus", os.cpu_count(), flush=True)

    test_bank = load_bank(args.data_dir, "test")
    # The smoke run has only the test CSVs locally. It checks the plumbing; its
    # numbers are meaningless because train and eval glyphs overlap.
    train_bank = test_bank if args.smoke else load_bank(args.data_dir, "train")
    if args.smoke:
        args.steps, args.eval_n = min(args.steps, 200), min(args.eval_n, 200)

    sets = build_eval_sets(test_bank, args.eval_n)
    save_eval_sets(sets, os.path.join(args.out_dir, "eval_sets.npz"))
    print(f"data ready after {(time.time() - script_start) / 60:.1f} min", flush=True)

    init_hits = [args.init] if os.path.exists(args.init) else glob.glob(os.path.join(args.data_dir, "**", args.init), recursive=True)
    init_state = torch.load(init_hits[0], map_location="cpu") if init_hits else None
    print("init", init_hits[0] if init_hits else "scratch", flush=True)
    params = sum(p.numel() for p in FieldRecognizer().parameters())
    print("params", params, flush=True)

    tasks = ["all"] if args.task == "all" else ["reg", "marks"] if args.task == "both" else [args.task]
    results = {"params": params, "smoke": args.smoke, "batch": args.batch, "tasks": {}}
    # Time is shared out evenly: every run of every task gets the same budget.
    runs_left = len(tasks) * args.seeds

    def train_run(task, seed, val, budget_s):
        """One fine-tuning run with an EMA of the weights; returns the best EMA state."""
        torch.manual_seed(seed)
        model = FieldRecognizer().to(device)
        if init_state is not None:
            model.load_state_dict(init_state)
        ema = torch.optim.swa_utils.AveragedModel(
            model, multi_avg_fn=torch.optim.swa_utils.get_ema_multi_avg_fn(args.ema), use_buffers=True)
        loader = torch.utils.data.DataLoader(
            FieldStream(train_bank, seed=1000 * seed + 1, task=task), batch_size=args.batch,
            num_workers=args.workers, collate_fn=collate, persistent_workers=False,
        )
        opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
        sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=args.steps, pct_start=0.05)
        ctc = nn.CTCLoss(blank=0, zero_infinity=True)
        model.train()
        t0, step = time.time(), 0
        best, best_state, stale, why = -1.0, None, 0, "steps"
        for xs, lengths, targets, target_lengths in loader:
            xs = xs.to(device, non_blocking=True)
            log_probs = model.train_logits(xs, lengths).log_softmax(-1).transpose(0, 1)
            loss = ctc(log_probs, targets, lengths, target_lengths)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            sched.step()
            ema.update_parameters(model)
            step += 1
            if step % 500 == 0:
                print(f"  [{task} s{seed}] step {step} loss {loss.item():.4f}", flush=True)
            if step % args.val_every == 0 or step >= args.steps:
                m = val_metrics(ema.module, val, device)
                # Exact match, with a trusted-but-wrong reading costing 5x a miss.
                key = m["exact"] - 5 * m["silent"]
                print(f"  [{task} s{seed}] step {step} ema {m}", flush=True)
                if key > best:
                    best, stale = key, 0
                    best_state = {k: v.detach().cpu().clone() for k, v in ema.module.state_dict().items()}
                else:
                    stale += 1
                    if stale >= args.patience:
                        why = "early stop"
                        break
            if step >= args.steps:
                break
            if time.time() - t0 > budget_s:
                why = "time budget"
                break
        print(f"  [{task} s{seed}] stopped ({why}) at step {step}, best {best:.4f}", flush=True)
        return best_state

    def as_model(state):
        m = FieldRecognizer().to(device)
        m.load_state_dict(state)
        return m.eval()

    def mix(states, weights):
        out = {}
        for k in states[0]:
            if states[0][k].dtype.is_floating_point:
                out[k] = sum(w * st[k].float() for st, w in zip(states, weights))
            else:
                out[k] = states[0][k].clone()  # BatchNorm batch counter
        return out

    def fit_temperature(model, val):
        """The temperature that keeps the most readings trusted while cutting
        trusted-but-wrong readings: folded into the head, so the app's
        confidence numbers mean what the review gate assumes."""
        best_t, best_key = 1.0, None
        for t in (0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0):
            m = val_metrics(model, val, device, temperature=t)
            key = m["accepted"] - 10 * m["silent"]
            if best_key is None or key > best_key:
                best_t, best_key = t, key
        return best_t

    for task in tasks:
        val = task_val(train_bank, task, 200 if args.smoke else args.val_n, seed=999)
        val_pick = task_val(train_bank, task, 200 if args.smoke else args.val_n, seed=4242)
        states = []
        for seed in range(args.seeds):
            budget = (script_start + (args.max_minutes - args.export_minutes) * 60 - time.time()) / runs_left
            runs_left -= 1
            st = train_run(task, seed, val, budget)
            if st is not None:
                states.append(st)
        report = {}
        # Candidates, judged on a second validation set the runs never saw.
        cands = {f"seed{i}": st for i, st in enumerate(states)}
        cands["soup"] = mix(states, [1 / len(states)] * len(states))
        if init_state is not None:
            cands["init"] = {k: v.float() if v.dtype.is_floating_point else v for k, v in init_state.items()}
            # WiSE-FT: interpolate the starting model and the soup.
            for a in (0.25, 0.5, 0.75):
                cands[f"wise{a}"] = mix([init_state, cands["soup"]], [1 - a, a])
        for name, st in cands.items():
            m = val_metrics(as_model(st), val_pick, device)
            report[name] = m
            print(f"[{task}] {name} {m}", flush=True)
        pick = max((n for n in cands if n != "init"), key=lambda n: report[n]["exact"] - 5 * report[n]["silent"])
        model = as_model(cands[pick])
        temp = fit_temperature(model, val_pick)
        print(f"[{task}] picked {pick}, temperature {temp}", flush=True)
        with torch.no_grad():
            model.head.weight.div_(temp)
            model.head.bias.div_(temp)
        model = model.cpu()
        suffix = "" if task == "all" else f"_{task}"
        torch.save(model.state_dict(), os.path.join(args.out_dir, f"field_recognizer{suffix}.pt"))
        onnx_path = os.path.join(args.out_dir, f"field_recognizer{suffix}.onnx")
        torch.onnx.export(
            model, torch.zeros(1, 1, INPUT_HEIGHT, 64), onnx_path,
            input_names=["input"], output_names=["probs"],
            dynamic_axes={"input": {0: "batch", 3: "width"}, "probs": {0: "batch", 1: "frames"}},
            opset_version=17, dynamo=False,
        )
        task_sets = {k: v for k, v in sets.items() if task == "all" or k in TASK_SETS[task]}
        entry = {"picked": pick, "temperature": temp, "candidates": report,
                 "heldout": evaluate_onnx(onnx_path, task_sets)}
        if init_state is not None:
            # The starting model on the same held-out sets, for comparison.
            base = as_model(cands["init"]).cpu()
            base_path = os.path.join(args.out_dir, "baseline.onnx")
            torch.onnx.export(base, torch.zeros(1, 1, INPUT_HEIGHT, 64), base_path, input_names=["input"],
                              output_names=["probs"], dynamic_axes={"input": {0: "batch", 3: "width"}, "probs": {0: "batch", 1: "frames"}},
                              opset_version=17, dynamo=False)
            entry["baseline_heldout"] = evaluate_onnx(base_path, task_sets)
        results["tasks"][task] = entry
        with open(os.path.join(args.out_dir, "results.json"), "w") as f:
            json.dump(results, f, indent=2)

    results["total_minutes"] = round((time.time() - script_start) / 60, 1)
    with open(os.path.join(args.out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
