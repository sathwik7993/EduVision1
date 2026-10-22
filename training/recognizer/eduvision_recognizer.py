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
# Outputs (in the working dir):
# - `field_recognizer.onnx`        fp32 model, input [1,1,32,W] -> probs [1,T,37]
# - `field_recognizer.int8.onnx`   dynamic-int8 variant
# - `eval_sets.npz`                held-out crops (EMNIST *test* glyphs only)
# - `results.json`                 accuracy, confidence-gate metrics, size

# %%
import argparse
import glob
import json
import math
import os
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
TRUSTED_ABOVE = 0.80  # ExtractedField.trustedAbove

# Registration-number shapes seen on Indian exam sheets. D = digit, A = letter.
REG_SHAPES = [
    "DDADDADDDD",  # 21B01A0512
    "DDADDADDDD",
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
    resized = cv2.resize(gray, (width, INPUT_HEIGHT), interpolation=cv2.INTER_AREA)
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


def random_text(rng, kind=None) -> str:
    kind = kind or rng.choice(["mark", "reg", "free"], p=[0.45, 0.35, 0.20])
    if kind == "mark":
        r = rng.random()
        if r < 0.03:
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
        return "".join(
            DIGITS[rng.integers(10)] if s == "D" else CHARSET[10 + rng.integers(26)]
            for s in shape
        )
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


def render_field(text: str, bank: dict, rng, exam_style: bool = True) -> np.ndarray:
    """Grayscale uint8 crop as the app would cut it from an aligned page."""
    if not text:
        ink = np.zeros((RENDER_H // 2, RENDER_H), np.float32)
    elif rng.random() < 0.15:
        ink = _printed_ink(text, rng)
    else:
        ink = _handwritten_ink(text, bank, rng)

    if not exam_style:
        pad = RENDER_H // 4
        ink = np.pad(ink, pad)
        return (255 - ink * 230).clip(0, 255).astype(np.uint8)

    # ROI margins: the teacher's box is never tight around the writing.
    ih, iw = ink.shape
    top = int(RENDER_H * rng.uniform(0.08, 0.6))
    bottom = int(RENDER_H * rng.uniform(0.08, 0.6))
    left = int(RENDER_H * rng.uniform(0.1, 1.2))
    right = int(RENDER_H * rng.uniform(0.1, 1.2))
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
    if rng.random() < 0.5:  # cell or box border, slightly inside the ROI
        j = lambda: int(rng.integers(0, max(2, RENDER_H // 6)))
        cv2.rectangle(lines, (j(), j()), (w - 1 - j(), h - 1 - j()), line_level, t)
    else:
        if rng.random() < 0.35:  # ruled line or underline
            y = top + ih + int(rng.integers(-RENDER_H // 8, max(1, bottom)))
            cv2.line(lines, (0, y), (w, y), line_level, t)
        if rng.random() < 0.25:  # table column at one side
            x = int(rng.integers(0, max(1, left))) if rng.random() < 0.5 else w - 1 - int(rng.integers(0, max(1, right)))
            cv2.line(lines, (x, 0), (x, h), line_level, t)
    if 0 < len(text) <= 3 and rng.random() < 0.15:  # examiner circles the total
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
    if rng.random() < 0.7:
        m = cv2.getRotationMatrix2D((w / 2, h / 2), rng.uniform(-3, 3), 1.0)
        m[:, 2] += rng.uniform(-0.06, 0.06, size=2) * np.array([w, h])
        gray = cv2.warpAffine(gray, m, (w, h), borderMode=cv2.BORDER_REPLICATE)

    if rng.random() < 0.6:
        gray = cv2.GaussianBlur(gray, (0, 0), rng.uniform(0.3, 1.4))

    gray = np.clip(gray, 0, 255).astype(np.uint8)
    # Camera resolution: a field is often only 15-40 px tall in the photo.
    scale = rng.uniform(18, 48) / h if rng.random() < 0.8 else 1.0
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
    probability, the same rule the app uses to gate review."""
    keep = [0] + [CHARSET.index(c) + 1 for c in allowed]
    p = probs[:, keep]
    p = p / np.maximum(p.sum(axis=1, keepdims=True), 1e-9)
    best = p.argmax(axis=1)
    text, confs, prev, run = [], [], 0, 0.0
    for t, k in enumerate(best):
        if k != prev and k != 0:
            text.append(allowed[k - 1])
            confs.append(p[t, k])
        elif k == prev and k != 0:
            confs[-1] = max(confs[-1], p[t, k])
        prev = k
    if not text:
        # An empty read is only as trustworthy as the blank frames.
        return "", float(p[:, 0].min()) if len(p) else 0.0
    return "".join(text), float(min(confs))


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
    def __init__(self, bank, seed):
        self.bank, self.seed = bank, seed

    def __iter__(self):
        info = torch.utils.data.get_worker_info()
        rng = np.random.default_rng(self.seed + (info.id if info else 0) * 7919 + int(time.time()))
        while True:
            text = random_text(rng)
            x = prep(render_field(text, self.bank, rng, exam_style=rng.random() < 0.85))
            yield x, text


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
    sets["marks_exam"] = [(render_field(t, bank, rng), t) for t in (random_text(rng, "mark") for _ in range(n))]
    sets["reg_exam"] = [(render_field(t, bank, rng), t) for t in (random_text(rng, "reg") for _ in range(n))]
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
    return DIGITS if name in ("emnist_digit", "marks_clean", "marks_exam") else CHARSET


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="/kaggle/input")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--steps", type=int, default=15000)
    ap.add_argument("--max-minutes", type=float, default=150, help="safety stop for the GPU quota")
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--eval-n", type=int, default=2000)
    ap.add_argument("--smoke", action="store_true", help="tiny run on test CSVs to check the pipeline")
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

    model = FieldRecognizer().to(device)
    params = sum(p.numel() for p in model.parameters())
    print("params", params, flush=True)
    loader = torch.utils.data.DataLoader(
        FieldStream(train_bank, seed=1), batch_size=args.batch, num_workers=args.workers,
        collate_fn=collate, persistent_workers=args.workers > 0,
    )
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=args.steps, pct_start=0.05)
    ctc = nn.CTCLoss(blank=0, zero_infinity=True)

    model.train()
    start, step = time.time(), 0
    for xs, lengths, targets, target_lengths in loader:
        xs = xs.to(device, non_blocking=True)
        logits = model.train_logits(xs, lengths)
        log_probs = logits.log_softmax(-1).transpose(0, 1)  # [T, N, C]
        loss = ctc(log_probs, targets, lengths, target_lengths)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        opt.step()
        sched.step()
        step += 1
        if step % 500 == 0 or step == args.steps or args.smoke and step % 50 == 0:
            rate = step * args.batch / (time.time() - start)
            print(f"step {step} loss {loss.item():.4f} samples/s {rate:.0f}", flush=True)
        if step >= args.steps:
            break
        if time.time() - start > args.max_minutes * 60:
            print("stopping early: time budget", flush=True)
            break
    train_minutes = (time.time() - start) / 60

    model.eval().cpu()
    torch.save(model.state_dict(), os.path.join(args.out_dir, "field_recognizer.pt"))
    onnx_path = os.path.join(args.out_dir, "field_recognizer.onnx")
    torch.onnx.export(
        model, torch.zeros(1, 1, INPUT_HEIGHT, 64), onnx_path,
        input_names=["input"], output_names=["probs"],
        dynamic_axes={"input": {3: "width"}, "probs": {1: "frames"}},
        opset_version=17, dynamo=False,
    )
    from onnxruntime.quantization import QuantType, quantize_dynamic

    int8_path = os.path.join(args.out_dir, "field_recognizer.int8.onnx")
    # Convs stay fp32: dynamic ConvInteger ran ~15x slower than fp32 Conv on CPU
    # in the smoke test. Only the LSTM and the classifier are quantized.
    quantize_dynamic(
        onnx_path, int8_path, weight_type=QuantType.QInt8,
        op_types_to_quantize=["LSTM", "MatMul", "Gemm"],
    )

    results = {
        "params": params,
        "steps": step,
        "batch": args.batch,
        "train_minutes": round(train_minutes, 1),
        "smoke": args.smoke,
        "size_bytes": {p: os.path.getsize(os.path.join(args.out_dir, p)) for p in ("field_recognizer.onnx", "field_recognizer.int8.onnx")},
        "fp32": evaluate_onnx(onnx_path, sets),
        "int8": evaluate_onnx(int8_path, sets),
    }
    with open(os.path.join(args.out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
