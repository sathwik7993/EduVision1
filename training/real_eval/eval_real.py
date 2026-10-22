"""Local eval of field models on the real sample sheets.

Crops each hand-annotated field box from sample_images/ and decodes it the
way the app does (digit-only for marks, optional registration mask, min-char
confidence, 0.80 review gate). This measures the recognizer alone; alignment
is measured on the device (integration_test/).

LOCAL ONLY. The photos contain real registration numbers: never upload them,
their crops or this script's output to Kaggle, Hugging Face or elsewhere.

Usage:
  python -I training/real_eval/eval_real.py MODEL.onnx [MODEL2.onnx ...]
      [--mask DDADDADDXX] [--mosaic out.png]
"""
import argparse
import json
import os
import sys
import time

import cv2
import numpy as np
import onnxruntime as ort

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "training", "recognizer"))
import eduvision_recognizer as er  # noqa: E402

PAD = 0.06  # PageAligner.pad


def crops():
    with open(os.path.join(ROOT, "sample_images", "annotations.json")) as f:
        ann = json.load(f)
    for name, fields in ann.items():
        if name.startswith("_"):
            continue
        image = cv2.imread(os.path.join(ROOT, "sample_images", name))
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        for field, ((x0, y0, x1, y1), label) in fields.items():
            dx, dy = (x1 - x0) * PAD, (y1 - y0) * PAD
            x0, y0 = int(max(0, x0 - dx)), int(max(0, y0 - dy))
            x1, y1 = int(min(gray.shape[1], x1 + dx)), int(min(gray.shape[0], y1 + dy))
            yield name.split(" at ")[1].replace(".jpeg", ""), field, gray[y0:y1, x0:x1], label


def decode_masked(probs, mask):
    """Mirror of CtcDecoder.decodeMasked."""
    text, conf = er.ctc_decode(probs, er.CHARSET)
    best = probs.argmax(axis=1)
    spans, prev = [], 0
    for t, k in enumerate(best):
        if k != 0 and k != prev:
            spans.append([t])
        elif k != 0:
            spans[-1].append(t)
        prev = k
    if len(text) != len(mask) or len(spans) != len(mask):
        return text, conf
    out, conf = [], 1.0
    for m, span in zip(mask, spans):
        allowed = {"D": er.DIGITS, "A": er.CHARSET[10:]}.get(m, er.CHARSET)
        idx = [er.CHARSET.index(c) + 1 for c in allowed]
        sub = probs[span][:, idx]
        t, j = np.unravel_index(sub.argmax(), sub.shape)
        out.append(allowed[j])
        conf = min(conf, float(sub[t, j]))
    return "".join(out), conf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="+")
    ap.add_argument("--mask", default="DDADDADDXX")
    ap.add_argument("--mosaic")
    args = ap.parse_args()

    items = list(crops())
    if args.mosaic:
        rows = []
        for photo, field, g, label in items:
            x = cv2.resize(g, (max(8, int(g.shape[1] * 48 / g.shape[0])), 48))[:, :700]
            row = np.full((52, 1000), 255, np.uint8)
            row[2:50, : x.shape[1]] = x
            cv2.putText(row, f"{photo} {field} [{label}]", (705, 32), cv2.FONT_HERSHEY_PLAIN, 1, 0)
            rows.append(row)
        cv2.imwrite(args.mosaic, np.vstack(rows))

    for path in args.models:
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        sess = ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])
        print(f"\n== {os.path.basename(path)} ({os.path.getsize(path) / 1e6:.2f} MB)")
        print(f"{'photo':<16}{'field':<14}{'label':<12}{'read':<12}{'conf':>6}  verdict")
        n = ok = accepted = silent = 0
        ms = 0.0
        for photo, field, g, label in items:
            start = time.perf_counter()
            probs = sess.run(None, {"input": er.prep(g)[None, None]})[0][0]
            ms += (time.perf_counter() - start) * 1000
            if field == "registration":
                text, conf = decode_masked(probs, args.mask) if args.mask else er.ctc_decode(probs)
            else:
                text, conf = er.ctc_decode(probs, er.DIGITS)
                text = str(int(text)) if text else text
            right = text == label
            gate = conf >= er.TRUSTED_ABOVE
            n += 1
            ok += right
            accepted += gate
            silent += gate and not right
            verdict = ("ok" if right else "WRONG") + (" auto" if gate else " review")
            print(f"{photo:<16}{field:<14}{label!r:<12}{text!r:<12}{conf:>6.2f}  {verdict}")
        print(f"exact {ok}/{n}  auto-accepted {accepted}/{n}  silent errors {silent}/{n}  "
              f"{ms / n:.1f} ms/crop (1 thread, desktop)")


if __name__ == "__main__":
    main()
