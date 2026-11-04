# %% [markdown]
# # EduVision handwritten-word recognizer
#
# Reads the written fields of a sheet that are words, not marks: names,
# course names, sections, branches, course codes, dates. The same CRNN as
# training/recognizer (CNN + BiLSTM, CTC, input height 32, same `prep`), with
# a larger character set, fine-tuned from the v5 marks/registration weights.
#
# Data, all public, no student data:
# - Kaggle `landlord/handwriting-recognition`: ~410k handwritten names on
#   forms, block capitals (CC0).
# - GNHK, Kaggle `thejashwinima/gnhk-handwriting-dataset`: real-world English
#   handwriting from Europe, North America, Africa and Asia, word boxes
#   (GoodNotes, CC BY 4.0). Words are also joined into short phrases so the
#   model learns spaces.
# - Synthetic dates, sections, course codes and branches drawn from EMNIST
#   glyphs (Kaggle `crawford/emnist`).
#
# PP-OCRv5 mobile (the app's current word reader) is scored on the same
# held-out sets, alone and when it agrees with this model.
#
# Outputs: `word_recognizer.onnx` (charset in the metadata, key
# "charset"), `word_recognizer.pt`, `results.json`.

# %%
import argparse
import glob
import json
import os
import sys
import time

import cv2
import numpy as np

CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz .,-/:()&'"
DIGIT_CHARS = "0123456789"
INPUT_HEIGHT = 32
MIN_WIDTH = 16
MAX_WIDTH = 512
TRUSTED_ABOVE = 0.90


def prep(gray: np.ndarray) -> np.ndarray:
    """Same contract as training/recognizer and FieldModel.prepare in the app."""
    h, w = gray.shape[:2]
    width = int(round(w * INPUT_HEIGHT / max(h, 1)))
    width = max(MIN_WIDTH, min(MAX_WIDTH, width))
    shrink = width <= w and INPUT_HEIGHT <= h
    resized = cv2.resize(gray, (width, INPUT_HEIGHT), interpolation=cv2.INTER_AREA if shrink else cv2.INTER_LINEAR)
    x = 1.0 - resized.astype(np.float32) / 255.0
    lo, hi = float(x.min()), float(x.max())
    x = (x - lo) / (hi - lo + 1e-3)
    pad = (-width) % 4
    if pad:
        x = np.pad(x, ((0, 0), (0, pad)))
    return x


def _find(root, pattern):
    hits = sorted(glob.glob(os.path.join(root, "**", pattern), recursive=True))
    if not hits:
        raise FileNotFoundError(f"{pattern} not found under {root}")
    return hits


def clean(text) -> str:
    if not isinstance(text, str):
        return ""
    t = " ".join(text.split())
    return t if t and all(c in CHARSET for c in t) else ""


# %% [markdown]
# ## Sources

# %%
def load_names(root, split, limit=None):
    """(path, label) of the handwritten names; unreadable/empty ones dropped."""
    import pandas as pd

    csv = _find(root, f"written_name_{split}_v2.csv")[0]
    df = pd.read_csv(csv, nrows=limit)
    images = {os.path.basename(p): p for p in glob.glob(os.path.join(root, "**", f"{split}_v2", "**", "*.jpg"), recursive=True)}
    out = []
    for fn, ident in zip(df.FILENAME, df.IDENTITY):
        t = clean(ident)
        if t and t not in ("UNREADABLE", "EMPTY") and fn in images:
            out.append((images[fn], t))
    return out


def load_gnhk(root, split, limit=None):
    """Word crops (gray uint8, height ~48) with their line index, per page."""
    pages = []
    jsons = [p for p in _find(root, "*.json") if f"{os.sep}{split}{os.sep}" in p]
    for jp in jsons[:limit]:
        img = cv2.imread(jp[:-5] + ".jpg", cv2.IMREAD_GRAYSCALE)
        if img is None:
            continue
        words = []
        for w in json.load(open(jp)):
            t = clean(w.get("text"))
            if not t or t.startswith("%"):
                continue
            p = w["polygon"]
            xs = [p[f"x{i}"] for i in range(4)]
            ys = [p[f"y{i}"] for i in range(4)]
            x0, x1, y0, y1 = max(0, min(xs)), min(img.shape[1], max(xs)), max(0, min(ys)), min(img.shape[0], max(ys))
            if x1 - x0 < 4 or y1 - y0 < 4:
                continue
            crop = img[y0:y1, x0:x1]
            s = 48.0 / crop.shape[0]
            crop = cv2.resize(crop, (max(4, int(crop.shape[1] * s)), 48), interpolation=cv2.INTER_AREA)
            words.append((crop, t, w.get("line_idx", 0)))
        if words:
            pages.append(words)
    return pages


def load_emnist(root, split):
    import pandas as pd

    bank = {}
    d = pd.read_csv(_find(root, f"emnist-digits-{split}.csv")[0], header=None, dtype=np.uint8).to_numpy()
    imgs = d[:, 1:].reshape(-1, 28, 28).transpose(0, 2, 1)
    for k in range(10):
        bank[str(k)] = imgs[d[:, 0] == k]
    mapping = {}
    for line in open(_find(root, "emnist-balanced-mapping.txt")[0]):
        a, b = line.split()
        mapping[int(a)] = chr(int(b))
    d = pd.read_csv(_find(root, f"emnist-balanced-{split}.csv")[0], header=None, dtype=np.uint8).to_numpy()
    imgs = d[:, 1:].reshape(-1, 28, 28).transpose(0, 2, 1)
    for k, ch in mapping.items():
        if ch.isalpha() and ch.isupper():
            bank[ch] = imgs[d[:, 0] == k]
    return bank


# %% [markdown]
# ## Synthetic dates, sections and codes

# %%
BRANCHES = ["CSE", "CSM", "CSD", "ECE", "EEE", "MECH", "CIVIL", "IT", "AIDS", "AIML", "CSC", "CSO"]


def random_field(rng) -> str:
    r = rng.random()
    if r < 0.45:  # date
        d, m, y = int(rng.integers(1, 29)), int(rng.integers(1, 13)), int(rng.integers(2019, 2028))
        sep = rng.choice(["/", "-", ".", "/"])
        yy = str(y) if rng.random() < 0.6 else str(y)[2:]
        dd = f"{d:02d}" if rng.random() < 0.7 else str(d)
        mm = f"{m:02d}" if rng.random() < 0.7 else str(m)
        return f"{dd}{sep}{mm}{sep}{yy}"
    if r < 0.65:  # section: CSM-04, A, B2
        b = BRANCHES[rng.integers(len(BRANCHES))]
        return f"{b}-{int(rng.integers(1, 9)):02d}" if rng.random() < 0.6 else b
    if r < 0.85:  # course code: CS501PC, 22A05501
        letters = "".join(chr(65 + int(rng.integers(26))) for _ in range(int(rng.integers(2, 4))))
        digits = "".join(str(int(rng.integers(10))) for _ in range(int(rng.integers(3, 6))))
        tail = "".join(chr(65 + int(rng.integers(26))) for _ in range(int(rng.integers(0, 3))))
        return letters + digits + tail
    return rng.choice(["B.Tech", "M.Tech", "MBA", "MCA", "B.Sc", "I", "II", "III", "IV", "I-I", "II-II", "III-I", "IV-II"])


def render_glyphs(text, bank, rng) -> np.ndarray:
    """EMNIST glyphs for letters and digits, pen strokes for separators."""
    h = 40
    parts = []
    for c in text:
        if c in bank:
            g = bank[c][rng.integers(len(bank[c]))]
            ys, xs = np.nonzero(g > 40)
            g = g[ys.min():ys.max() + 1, xs.min():xs.max() + 1] if len(ys) else g
            gh = int(h * rng.uniform(0.75, 1.0))
            g = cv2.resize(g, (max(3, int(g.shape[1] * gh / g.shape[0])), gh))
            cell = np.zeros((h, g.shape[1] + int(rng.integers(2, 8))), np.uint8)
            top = int(rng.integers(0, h - gh + 1))
            cell[top:top + gh, : g.shape[1]] = g
        else:
            w = {"/": 14, "-": 14, ".": 8, " ": 16}.get(c, 10)
            cell = np.zeros((h, w), np.uint8)
            t = int(rng.integers(2, 4))
            if c == "/":
                cv2.line(cell, (w - 3, 4), (2, h - 4), 255, t)
            elif c == "-":
                y = h // 2 + int(rng.integers(-3, 4))
                cv2.line(cell, (2, y), (w - 3, y), 255, t)
            elif c == ".":
                cv2.circle(cell, (w // 2, h - 6), t, 255, -1)
        parts.append(cell)
    ink = np.concatenate(parts, axis=1)
    return 255 - ink


# %% [markdown]
# ## Making crops look like a phone photo of a form

# %%
def form_noise(gray, rng) -> np.ndarray:
    g = gray.astype(np.float32)
    h, w = g.shape
    pad = int(h * rng.uniform(0.05, 0.4))
    g = cv2.copyMakeBorder(g, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=float(np.median(g)))
    h, w = g.shape
    if rng.random() < 0.5:  # the printed line the writing sits on, solid or dotted
        y = int(h - pad * rng.uniform(0.3, 1.0))
        level = rng.uniform(40, 140)
        if rng.random() < 0.5:
            cv2.line(g, (0, y), (w, y), level, int(rng.integers(1, 3)))
        else:
            for x in range(0, w, int(rng.integers(5, 10))):
                cv2.circle(g, (x, y), 1, level, -1)
    if rng.random() < 0.3:  # a box border cut into the crop
        cv2.rectangle(g, (0, 0), (w - 1, h - 1), rng.uniform(40, 140), int(rng.integers(1, 3)))
    a = rng.uniform(-3, 3)
    m = cv2.getRotationMatrix2D((w / 2, h / 2), a, 1.0)
    g = cv2.warpAffine(g, m, (w, h), borderMode=cv2.BORDER_REPLICATE)
    lo, hi = rng.uniform(0, 70), rng.uniform(170, 255)
    g = lo + (g / 255.0) * (hi - lo)
    if rng.random() < 0.5:
        g = cv2.GaussianBlur(g, (0, 0), rng.uniform(0.3, 1.2))
    g += rng.normal(0, rng.uniform(0, 10), g.shape)
    g = np.clip(g, 0, 255).astype(np.uint8)
    if rng.random() < 0.5:
        ok, buf = cv2.imencode(".jpg", g, [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(35, 90))])
        g = cv2.imdecode(buf, cv2.IMREAD_GRAYSCALE)
    return g


def gnhk_phrase(pages, rng):
    """1-3 neighbouring words of one line, joined with a gap: a phrase with spaces."""
    words = pages[rng.integers(len(pages))]
    i = int(rng.integers(len(words)))
    n = int(rng.choice([1, 1, 2, 3]))
    run = [words[i]]
    for w in words[i + 1:]:
        if len(run) >= n or w[2] != run[-1][2]:
            break
        run.append(w)
    # The gap takes the paper's colour, so it is no cue a real line lacks.
    paper = int(np.percentile(np.concatenate([c.ravel() for c, _, _ in run]), 90))
    parts = []
    for k, (crop, _, _) in enumerate(run):
        if k:
            parts.append(np.full((48, int(rng.integers(14, 30))), paper, np.uint8))
        parts.append(crop)
    img = np.concatenate(parts, axis=1)
    return img, " ".join(t for _, t, _ in run)


# %% [markdown]
# ## Model (as training/recognizer, more classes)

# %%
import torch
import torch.nn as nn
import torch.nn.functional as F


def _block(cin, cout, k=3, p=1):
    return nn.Sequential(nn.Conv2d(cin, cout, k, padding=p, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True))


class WordRecognizer(nn.Module):
    def __init__(self, classes=len(CHARSET) + 1, hidden=128):
        super().__init__()
        self.cnn = nn.Sequential(
            _block(1, 32), nn.MaxPool2d(2, 2),
            _block(32, 64), nn.MaxPool2d(2, 2),
            _block(64, 128), _block(128, 128), nn.MaxPool2d((2, 1)),
            _block(128, 192), nn.MaxPool2d((2, 1)),
            _block(192, 256, k=(2, 1), p=0),
            nn.Dropout(0.1),
        )
        self.rnn = nn.LSTM(256, hidden, batch_first=True, bidirectional=True)
        self.head = nn.Linear(hidden * 2, classes)

    def features(self, x):
        return self.cnn(x).squeeze(2).transpose(1, 2)

    def forward(self, x):
        y, _ = self.rnn(self.features(x))
        return F.softmax(self.head(y), dim=-1)

    def train_logits(self, x, lengths):
        f = self.features(x)
        packed = nn.utils.rnn.pack_padded_sequence(f, lengths.cpu(), batch_first=True, enforce_sorted=False)
        y, _ = self.rnn(packed)
        y, _ = nn.utils.rnn.pad_packed_sequence(y, batch_first=True, total_length=f.shape[1])
        return self.head(y)


def ctc_decode(probs, charset=CHARSET):
    best = probs.argmax(-1)
    out, confs, prev = [], [], 0
    for t, c in enumerate(best):
        if c != 0 and c != prev:
            out.append(charset[c - 1])
            confs.append(float(probs[t, c]))
        prev = c
    return "".join(out).strip(), (min(confs) if confs else 0.0)


def key(s: str) -> str:
    """What a teacher would call the same reading: case and spacing ignored."""
    return "".join(c for c in s.lower() if c.isalnum())


def cer(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a):
        cur = [i + 1]
        for j, cb in enumerate(b):
            cur.append(min(cur[j] + 1, prev[j + 1] + 1, prev[j] + (ca != cb)))
        prev = cur
    return prev[-1]


def score(preds, labels):
    n = len(labels)
    exact = sum(p == l for (p, _), l in zip(preds, labels))
    same = sum(key(p) == key(l) for (p, _), l in zip(preds, labels))
    edits = sum(cer(key(p), key(l)) for (p, _), l in zip(preds, labels))
    chars = max(1, sum(len(key(l)) for l in labels))
    acc = [(p, l) for (p, c), l in zip(preds, labels) if c >= TRUSTED_ABOVE and p]
    silent = sum(key(p) != key(l) for p, l in acc)
    return {"n": n, "exact": round(exact / n, 4), "same_ignoring_case": round(same / n, 4),
            "cer": round(edits / chars, 4), "auto_accept": round(len(acc) / n, 4),
            "silent": round(silent / n, 4)}


# %% [markdown]
# ## PP-OCRv5 mobile on the same crops

# %%
class PPOCRv5:
    def __init__(self, onnx_path, yml_path):
        import onnxruntime as ort
        import yaml

        self.s = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
        self.chars = yaml.safe_load(open(yml_path))["PostProcess"]["character_dict"] + [" "]

    def read(self, gray):
        h, w = gray.shape
        nw = max(16, min(3200, int(np.ceil(48 * w / max(h, 1)))))
        img = cv2.resize(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), (nw, 48)).astype(np.float32)
        img = (img / 255.0 - 0.5) / 0.5
        p = self.s.run(None, {self.s.get_inputs()[0].name: img.transpose(2, 0, 1)[None]})[0][0]
        return ctc_decode(p, self.chars)


# %% [markdown]
# ## Training

# %%
class Stream(torch.utils.data.IterableDataset):
    def __init__(self, names, pages, bank, seed):
        self.names, self.pages, self.bank, self.seed = names, pages, bank, seed

    def __iter__(self):
        info = torch.utils.data.get_worker_info()
        rng = np.random.default_rng(self.seed + (info.id if info else 0) * 7919 + int(time.time()))
        while True:
            img, t = sample(self.names, self.pages, self.bank, rng)
            if img is None:
                continue
            x = prep(form_noise(img, rng))
            if x.shape[1] // 4 < len(t) + 1:
                continue  # too narrow for CTC
            yield x, t


def sample(names, pages, bank, rng):
    r = rng.random()
    if r < 0.45 and names:
        p, t = names[rng.integers(len(names))]
        return cv2.imread(p, cv2.IMREAD_GRAYSCALE), t
    if r < 0.75 and pages:
        return gnhk_phrase(pages, rng)
    t = random_field(rng)
    if bank is None:
        return None, t
    return render_glyphs(t, bank, rng), t


def collate(batch):
    width = max(x.shape[1] for x, _ in batch)
    xs = np.zeros((len(batch), 1, INPUT_HEIGHT, width), np.float32)
    for i, (x, _) in enumerate(batch):
        xs[i, 0, :, : x.shape[1]] = x
    lengths = torch.tensor([x.shape[1] // 4 for x, _ in batch])
    targets = torch.tensor([CHARSET.index(c) + 1 for _, t in batch for c in t], dtype=torch.long)
    return torch.from_numpy(xs), lengths, targets, torch.tensor([len(t) for _, t in batch])


def evaluate(model, sets, device, pp=None):
    out = {}
    model.eval()
    with torch.no_grad():
        for name, items in sets.items():
            ours, theirs, both = [], [], []
            for g, _ in items:
                x = torch.from_numpy(prep(g))[None, None].to(device)
                o = ctc_decode(model(x)[0].cpu().numpy())
                ours.append(o)
                if pp is not None:
                    t = pp.read(g)
                    theirs.append(t)
                    # Agreement: PP-OCRv5's text, trusted only when both read it.
                    both.append((t[0], min(t[1], o[1])) if key(t[0]) == key(o[0]) else (t[0], min(t[1], 0.5)))
            labels = [t for _, t in items]
            out[name] = {"ours": score(ours, labels)}
            if pp is not None:
                out[name]["ppocrv5"] = score(theirs, labels)
                out[name]["ppocrv5_checked_by_ours"] = score(both, labels)
            print(name, json.dumps(out[name]), flush=True)
    model.train()
    return out


def main():
    sys.stdout.reconfigure(line_buffering=True)
    t0 = time.time()
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="/kaggle/input")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--steps", type=int, default=30000)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--max-minutes", type=float, default=210)
    ap.add_argument("--eval-n", type=int, default=2000)
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--smoke", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    for mod in ("onnxruntime", "yaml"):
        try:
            __import__(mod)
        except ImportError:
            import subprocess
            subprocess.run([sys.executable, "-m", "pip", "install", "-q", "onnxruntime", "pyyaml"], check=True)
    lim = 400 if args.smoke else None

    names_train = load_names(args.data_dir, "train", lim) if not args.smoke else load_names(args.data_dir, "test", lim)
    names_test = load_names(args.data_dir, "test")[: args.eval_n] if not args.smoke else names_train[:100]
    pages_train = load_gnhk(args.data_dir, "train", 10 if args.smoke else None) if not args.smoke else []
    pages_test = load_gnhk(args.data_dir, "test")
    try:
        bank = load_emnist(args.data_dir, "train" if not args.smoke else "test")
        bank_test = load_emnist(args.data_dir, "test")
    except FileNotFoundError:
        bank = bank_test = None
    print(f"names {len(names_train)}, gnhk pages {len(pages_train)}/{len(pages_test)}, "
          f"data ready after {(time.time() - t0) / 60:.1f} min", flush=True)

    rng = np.random.default_rng(12345)
    sets = {
        "names": [(form_noise(cv2.imread(p, cv2.IMREAD_GRAYSCALE), rng), t) for p, t in names_test],
        "gnhk_words": [(c, t) for words in pages_test for c, t, _ in words][: args.eval_n],
    }
    gp = [gnhk_phrase(pages_test, rng) for _ in range(min(args.eval_n, 1000))]
    sets["gnhk_phrases"] = [(form_noise(g, rng), t) for g, t in gp]
    if bank_test is not None:
        fields = [random_field(rng) for _ in range(args.eval_n)]
        sets["dates_codes"] = [(form_noise(render_glyphs(t, bank_test, rng), rng), t) for t in fields]

    model = WordRecognizer().to(device)
    init = glob.glob(os.path.join(args.data_dir, "**", "field_recognizer.pt"), recursive=True)
    if init:
        st = torch.load(init[0], map_location=device)
        st = {k: v for k, v in st.items() if not k.startswith("head.")}
        model.load_state_dict(st, strict=False)
        print("CNN+LSTM from", init[0], flush=True)
    ema = torch.optim.swa_utils.AveragedModel(model, multi_avg_fn=torch.optim.swa_utils.get_ema_multi_avg_fn(0.999), use_buffers=True)
    steps = 60 if args.smoke else args.steps
    loader = torch.utils.data.DataLoader(Stream(names_train, pages_train, bank, 1), batch_size=32 if args.smoke else args.batch,
                                         num_workers=args.workers, collate_fn=collate)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps, pct_start=0.05)
    ctc = nn.CTCLoss(blank=0, zero_infinity=True)
    deadline = t0 + (args.max_minutes - 25) * 60
    step = 0
    for xs, lengths, targets, tl in loader:
        xs = xs.to(device, non_blocking=True)
        loss = ctc(model.train_logits(xs, lengths).log_softmax(-1).transpose(0, 1), targets, lengths, tl)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        opt.step()
        sched.step()
        ema.update_parameters(model)
        step += 1
        if step % 500 == 0 or args.smoke and step % 20 == 0:
            print(f"step {step} loss {loss.item():.4f} {(time.time() - t0) / 60:.1f} min", flush=True)
        if step >= steps or time.time() > deadline:
            break
    print(f"trained {step} steps", flush=True)

    best = ema.module.eval().cpu()
    torch.save(best.state_dict(), os.path.join(args.out_dir, "word_recognizer.pt"))
    path = os.path.join(args.out_dir, "word_recognizer.onnx")
    torch.onnx.export(best, torch.zeros(1, 1, INPUT_HEIGHT, 128), path, input_names=["input"], output_names=["probs"],
                      dynamic_axes={"input": {0: "batch", 3: "width"}, "probs": {0: "batch", 1: "frames"}},
                      opset_version=17, dynamo=False)
    import onnx

    m = onnx.load(path)
    e = m.metadata_props.add()
    e.key, e.value = "charset", CHARSET
    onnx.save(m, path)

    pp = None
    onnx_hits = glob.glob(os.path.join(args.data_dir, "**", "PP-OCRv5_mobile_rec_inference.onnx"), recursive=True)
    if onnx_hits:
        pp = PPOCRv5(onnx_hits[0], onnx_hits[0].replace(".onnx", ".yml"))
    results = {"steps": step, "minutes": round((time.time() - t0) / 60, 1), "eval": evaluate(best, sets, "cpu", pp)}
    json.dump(results, open(os.path.join(args.out_dir, "results.json"), "w"), indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
