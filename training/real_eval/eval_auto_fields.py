"""Local eval of template-free field detection (lib/.../field_locator.dart).

Finds the printed labels with an offline OCR (RapidOCR, models bundled in the
pip wheel; a stand-in for ML Kit on the phone), places the field boxes with
the same rules as FieldLocator, and reads them with the field model.

LOCAL ONLY. The photos contain real registration numbers: never upload them,
their crops or this script's output.

Usage:
  pip install rapidocr_onnxruntime
  python -I training/real_eval/eval_auto_fields.py MODEL.onnx
"""
import json, os, re, sys, cv2, onnxruntime as ort
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "training", "recognizer"))
sys.path.insert(0, os.path.join(ROOT, "training", "real_eval"))
import eduvision_recognizer as er, eval_real as ev  # noqa: E402
from rapidocr_onnxruntime import RapidOCR  # noqa: E402
norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())

def locate(lines):
    """Mirror of FieldLocator.locate. lines: [(text, x0, y0, x1, y1)] in
    pixels -> {field: (x0, y0, x1, y1)}."""
    out = {}
    def find(pred):
        hits = [l for l in lines if pred(norm(l[0]))]
        return min(hits, key=lambda l: (len(norm(l[0])), l[2])) if hits else None
    reg = find(lambda t: t.startswith("registeredno"))
    if reg:
        _, x0, y0, x1, y1 = reg; w, h = x1 - x0, y1 - y0; c = (y0 + y1) / 2
        out["registration"] = (x1, c - 0.9 * h, x1 + 2.9 * w, c + 0.7 * h)
    for key, field in (("partatotal", "partA"), ("partbtotal", "partB")):
        l = find(lambda t, k=key: t.startswith(k) and len(t) <= len(k) + 3)
        if l:
            _, x0, y0, x1, y1 = l; w, h = x1 - x0, y1 - y0
            out[field] = (x0 - 0.1 * w, y1, x1 + 0.05 * w, y1 + 2.6 * h)
    g = find(lambda t: t in ("grand", "grandtotal"))
    if g:
        parts = [g] + [l for l in lines if norm(l[0]) == "total" and l[2] >= g[2] and l[2] - g[4] < (g[4] - g[2]) and min(l[3], g[3]) > max(l[1], g[1])]
        x0 = min(p[1] for p in parts); y0 = min(p[2] for p in parts); x1 = max(p[3] for p in parts); y1 = max(p[4] for p in parts)
        w, h = x1 - x0, y1 - y0
        out["grandTotal"] = (x1 + 0.35 * w, y0 - 0.35 * h, x1 + 2.2 * w, y1 + 0.35 * h)
    return out

def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy; u = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter
    return inter / u if u else 0

if __name__ == "__main__":
    ocr = RapidOCR()
    sess = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
    ann = json.load(open(f"{ROOT}/sample_images/annotations.json"))
    tot = ok = found = 0; silent = 0
    for name, fields in ann.items():
        if name.startswith("_"): continue
        img = cv2.imread(f"{ROOT}/sample_images/{name}"); g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY); H, W = g.shape
        res, _ = ocr(img)
        lines = [(t, min(p[0] for p in b), min(p[1] for p in b), max(p[0] for p in b), max(p[1] for p in b)) for b, t, _ in res or []]
        boxes = locate(lines)
        row = []
        for f, (abox, label) in fields.items():
            if f == "totalInWords": continue
            tot += 1
            b = boxes.get(f)
            if b is None: row.append(f"{f}:MISSING"); continue
            found += 1
            dx, dy = (b[2]-b[0]) * ev.PAD, (b[3]-b[1]) * ev.PAD
            x0, y0 = int(max(0, b[0]-dx)), int(max(0, b[1]-dy)); x1, y1 = int(min(W, b[2]+dx)), int(min(H, b[3]+dy))
            outside = b[0] < -0.01*W or b[1] < -0.01*H or b[2] > 1.01*W or b[3] > 1.01*H
            probs = sess.run(None, {"input": er.prep(g[y0:y1, x0:x1])[None, None]})[0][0]
            text, conf = er.ctc_decode(probs, er.CHARSET if f == "registration" else er.DIGITS)
            right = text == label; ok += right
            gate = 0.95 if f == "registration" else 0.90
            accepted = not outside and conf >= gate and text != ""
            silent += accepted and not right
            row.append(f"{f}:iou{iou(b, abox):.2f}{'' if right else ' WRONG'}{' ACCEPTED' if accepted and not right else ''}{' outside' if outside else ''}")
        print(name[-16:], " | ".join(row), flush=True)
    print(f"found {found}/{tot}, read right {ok}/{tot}, wrong-but-accepted (before cross-checks) {silent}")
