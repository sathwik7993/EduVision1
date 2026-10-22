# %% [markdown]
# # PP-OCRv5 mobile rec vs. the EduVision field recognizer
#
# Converts `PaddlePaddle/en_PP-OCRv5_mobile_rec` (Apache-2.0) to ONNX with
# paddle2onnx, then scores it and the custom recognizer on the *same*
# held-out crops (`eval_sets.npz`, produced from EMNIST test glyphs by the
# `eduvision-field-recognizer` kernel, attached as a kernel source).
#
# Both models are decoded the way the app would: greedy CTC restricted to the
# field's charset (digits for marks, 0-9A-Z for registration numbers), with
# confidence = minimum per-character probability, gated at 0.80.

# %%
import subprocess
import sys

subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q", "onnxruntime", "huggingface_hub", "pyyaml", "uv"],
    check=True,
)
# paddle2onnx has no Python 3.13 build (the Kaggle image's Python); convert
# in a separate 3.12 environment.
P2O = "/tmp/p2o"
subprocess.run([sys.executable, "-m", "uv", "venv", "-q", "--python", "3.12", P2O], check=True)
subprocess.run(
    [sys.executable, "-m", "uv", "pip", "install", "-q", "--python", f"{P2O}/bin/python",
     "paddlepaddle==3.0.0", "paddle2onnx==2.0.1"],
    check=True,
)

# %%
import glob
import json
import os
import time

import cv2
import numpy as np
import onnxruntime as ort
import yaml
from huggingface_hub import snapshot_download

CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
DIGITS = CHARSET[:10]
TRUSTED_ABOVE = 0.80


def find(name):
    hits = glob.glob(f"/kaggle/input/**/{name}", recursive=True)
    if not hits:
        raise FileNotFoundError(name)
    return hits[0]


# %% [markdown]
# ## Held-out sets and metrics (same definitions as the training script)

# %%
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


def allowed_for(name):
    return CHARSET if name.startswith("reg") else DIGITS


def _edits(a, b):
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
    edits = sum(_edits(p, l) for (p, _), l in zip(preds, labels))
    chars = max(1, sum(len(l) for l in labels))
    accepted = [(p, l) for (p, c), l in zip(preds, labels) if c >= TRUSTED_ABOVE and p]
    silent = sum(p != l for p, l in accepted)
    return {
        "n": n,
        "exact_acc": round(exact / n, 4),
        "cer": round(edits / chars, 4),
        "auto_accept_rate": round(len(accepted) / n, 4),
        "silent_error_rate": round(silent / n, 4),
        "acc_when_accepted": round(1 - silent / max(1, len(accepted)), 4),
    }


def ctc_decode(probs, class_chars, allowed):
    """Same rule as the app: greedy CTC over the allowed classes, confidence =
    min raw per-character probability, capped by the strongest dropped
    disallowed class. class_chars[i] is the character of class i (0 = blank)."""
    keep = [0] + [i for i, c in enumerate(class_chars) if i > 0 and c in allowed]
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
            text.append(class_chars[keep[k]])
            confs.append(p[t, k])
        elif k == prev and k != 0:
            confs[-1] = max(confs[-1], p[t, k])
        prev = k
    if not text:
        return "", min(float(p[:, 0].min()), 1 - dropped) if len(p) else 0.0
    return "".join(text), min(float(min(confs)), 1 - dropped)


def run(sess, sets, preprocess, class_chars):
    out = {}
    for name, items in sets.items():
        preds, start = [], time.perf_counter()
        for g, _ in items:
            probs = sess.run(None, {sess.get_inputs()[0].name: preprocess(g)})[0][0]
            preds.append(ctc_decode(probs, class_chars, allowed_for(name)))
        ms = (time.perf_counter() - start) * 1000 / len(items)
        out[name] = {**score(preds, [t for _, t in items]), "ms_per_crop_1thread": round(ms, 3)}
        print(name, out[name], flush=True)
    return out


def session(path):
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 1
    return ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])


# %% [markdown]
# ## Convert PP-OCRv5

# %%
model_dir = snapshot_download("PaddlePaddle/en_PP-OCRv5_mobile_rec")
subprocess.run(
    [f"{P2O}/bin/paddle2onnx", "--model_dir", model_dir, "--model_filename", "inference.json",
     "--params_filename", "inference.pdiparams", "--save_file", "en_PP-OCRv5_mobile_rec.onnx",
     "--opset_version", "14"],
    check=True,
)
with open(os.path.join(model_dir, "inference.yml")) as f:
    cfg = yaml.safe_load(f)
post = cfg["PostProcess"]
ppocr_chars = ["<blank>"] + list(post["character_dict"]) + [" "]  # use_space_char


def ppocr_prep(gray):
    # PaddleOCR RecResizeImg for PP-OCRv5 rec: 3x48xW, W >= 320, (x/255-0.5)/0.5.
    h, w = gray.shape
    img_h, ratio = 48, max(320 / 48, w / h)
    img_w = int(img_h * ratio)
    rw = min(img_w, int(np.ceil(img_h * w / h)))
    rgb = cv2.cvtColor(cv2.resize(gray, (rw, img_h)), cv2.COLOR_GRAY2RGB).astype(np.float32)
    x = np.zeros((3, img_h, img_w), np.float32)
    x[:, :, :rw] = ((rgb / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)
    return x[None]


# %% [markdown]
# ## Custom recognizer preprocessing (mirrors crop_preprocessor.dart)

# %%
def custom_prep(gray):
    h, w = gray.shape
    width = max(16, min(512, int(round(w * 32 / max(h, 1)))))
    shrink = width <= w and 32 <= h
    x = 1.0 - cv2.resize(gray, (width, 32), interpolation=cv2.INTER_AREA if shrink else cv2.INTER_LINEAR).astype(np.float32) / 255.0
    lo, hi = float(x.min()), float(x.max())
    x = (x - lo) / (hi - lo + 1e-3)
    pad = (-width) % 4
    if pad:
        x = np.pad(x, ((0, 0), (0, pad)))
    return x[None, None]


# %% [markdown]
# ## Compare

# %%
sets = load_eval_sets(find("eval_sets.npz"))
custom_chars = ["<blank>"] + list(CHARSET)
results = {
    "ppocr_size_bytes": os.path.getsize("en_PP-OCRv5_mobile_rec.onnx"),
    "ppocr": run(session("en_PP-OCRv5_mobile_rec.onnx"), sets, ppocr_prep, ppocr_chars),
    "custom_fp32": run(session(find("field_recognizer.onnx")), sets, custom_prep, custom_chars),
}
with open("comparison.json", "w") as f:
    json.dump(results, f, indent=2)
print(json.dumps(results, indent=2))
