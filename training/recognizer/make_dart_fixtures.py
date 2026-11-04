"""Writes test/fixtures/prep_parity.json: grayscale crops and the model input
`prep()` produces for them, so the Dart port (crop_preprocessor.dart) is
checked against the exact preprocessing the model was trained with.

Usage: python training/recognizer/make_dart_fixtures.py <emnist csv dir>
"""
import base64
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eduvision_recognizer as er  # noqa: E402


def main():
    bank = er.load_bank(sys.argv[1], "test", limit=2000)
    rng = np.random.default_rng(7)
    cases = []
    for i in range(8):
        text = er.random_text(rng, "reg" if i % 2 else "mark") or "7"
        gray = er.render_field(text, bank, rng)
        if i == 6:  # field smaller than the model input: upscaling path
            gray = gray[: max(4, gray.shape[0] // 3), :]
            import cv2

            gray = cv2.resize(gray, (max(8, gray.shape[1] // 3), max(8, gray.shape[0])), interpolation=cv2.INTER_AREA)
        x = er.prep(gray)
        cases.append({
            "width": int(gray.shape[1]),
            "height": int(gray.shape[0]),
            "pixels": base64.b64encode(gray.tobytes()).decode(),
            "outWidth": int(x.shape[1]),
            "expected": base64.b64encode(x.astype("<f4").tobytes()).decode(),
        })
    root = os.path.join(os.path.dirname(__file__), "..", "..", "test", "fixtures")
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "prep_parity.json"), "w") as f:
        json.dump(cases, f)
    print("wrote", len(cases), "cases")


if __name__ == "__main__":
    main()
