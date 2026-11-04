"""Builds the on-device benchmark folder for integration_test/benchmark_test.dart.

  python -I training/real_eval/export_bench.py OUT_DIR [--eval-sets eval_sets.npz] [--per-set 50]

OUT_DIR gets:
  photos/        the real sample photos + annotations.json (end-to-end run)
  crops/*.png    real field crops (hand boxes) and synthetic held-out crops
  labels.json    [{file, kind: "reg"|"mark", label, source}]

Then push it to the emulator or a USB-connected phone (local transfer only):
  adb push OUT_DIR /sdcard/Android/data/com.example.eduvision_0_1/files/bench

LOCAL ONLY: the real photos contain registration numbers. Never upload.
"""
import argparse
import json
import os
import shutil
import sys

import cv2

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "training", "recognizer"))
import eduvision_recognizer as er  # noqa: E402
from eval_real import crops  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--eval-sets")
    ap.add_argument("--per-set", type=int, default=50)
    args = ap.parse_args()

    photos = os.path.join(args.out, "photos")
    crop_dir = os.path.join(args.out, "crops")
    os.makedirs(photos, exist_ok=True)
    os.makedirs(crop_dir, exist_ok=True)

    src = os.path.join(ROOT, "sample_images")
    for name in os.listdir(src):
        if name.endswith(".jpeg") or name == "annotations.json":
            shutil.copy(os.path.join(src, name), photos)

    labels = []
    for i, (photo, field, gray, label) in enumerate(crops()):
        name = f"real_{i:03d}.png"
        cv2.imwrite(os.path.join(crop_dir, name), gray)
        labels.append({"file": name, "kind": "reg" if field == "registration" else "mark",
                       "label": label, "source": "real"})

    if args.eval_sets:
        for set_name, items in er.load_eval_sets(args.eval_sets).items():
            for i, (gray, label) in enumerate(items[: args.per_set]):
                name = f"syn_{set_name}_{i:03d}.png"
                cv2.imwrite(os.path.join(crop_dir, name), gray)
                labels.append({"file": name, "kind": "reg" if set_name.startswith("reg") else "mark",
                               "label": label, "source": f"synthetic:{set_name}"})

    with open(os.path.join(args.out, "labels.json"), "w") as f:
        json.dump(labels, f, indent=1)
    print(f"{len(labels)} crops -> {args.out}")


if __name__ == "__main__":
    main()
