"""Draws a synthetic exam answer-book cover (no real student data) and
phone-photo-like variants of it, for device tests that run on remote phones
(Firebase Test Lab). The layout imitates the structure of the CAT cover in
sample_images/ (labels, a 10-box registration comb, a marks slip) but is drawn
from scratch; the handwriting is OpenCV's Hershey script font.

Usage: python -I training/synthetic/make_sheet.py OUT_DIR
Writes sheet_clean.png, photo_1.jpg ... photo_4.jpg and truth.json.
"""
import json, os, sys
import cv2
import numpy as np

W, H = 1240, 1754  # A4 at 150 dpi
F, FB = cv2.FONT_HERSHEY_SIMPLEX, cv2.FONT_HERSHEY_DUPLEX
HAND = cv2.FONT_HERSHEY_SCRIPT_SIMPLEX
INK = (40, 30, 120)  # dark red print, BGR
PEN = (120, 40, 20)  # blue pen


def text(img, s, x, y, scale=0.8, font=F, color=INK, th=2):
    cv2.putText(img, s, (x, y), font, scale, color, th, cv2.LINE_AA)


def hand(img, s, x, y, scale, rng):
    for ch in s:
        sc = scale * rng.uniform(0.9, 1.1)
        cv2.putText(img, ch, (x, y + int(rng.integers(-3, 4))), HAND, sc, PEN, 3, cv2.LINE_AA)
        (w, _), _ = cv2.getTextSize(ch, HAND, sc, 3)
        x += w + int(rng.integers(0, 6))


def sheet(reg, part_a, part_b, seed=1):
    rng = np.random.default_rng(seed)
    img = np.full((H, W, 3), 250, np.uint8)
    text(img, "BOOKLET NUMBER :", 110, 110, 0.7, FB)
    cv2.rectangle(img, (100, 70), (520, 170), INK, 2)
    cv2.rectangle(img, (760, 70), (1140, 170), INK, 2)
    text(img, "College Stamp", 880, 150, 0.7, FB)
    text(img, "SPRINGFIELD INSTITUTE OF TECHNOLOGY", 110, 250, 1.3, FB, th=3)
    text(img, "(AUTONOMOUS)", 500, 295, 0.9, FB)
    text(img, "CONTINUOUS ASSESSMENT TEST ANSWER BOOK", 230, 350, 1.0, FB, th=2)
    # Registration comb: label, then 10 boxes.
    text(img, "Registered No.", 520, 410, 0.85)
    x0, y0, bw, bh = 735, 375, 42, 50
    for i in range(11):
        cv2.line(img, (x0 + i * bw, y0), (x0 + i * bw, y0 + bh), INK, 2)
    cv2.rectangle(img, (x0, y0), (x0 + 10 * bw, y0 + bh), INK, 2)
    for i, ch in enumerate(reg):
        hand(img, ch, x0 + i * bw + 9, y0 + 38, 1.1, rng)
    text(img, "FIRST / SECOND CONTINUOUS ASSESSMENT TEST B.Tech", 90, 480, 0.75)
    text(img, "Subject :", 90, 540, 0.8)
    text(img, "Date :", 90, 600, 0.8)
    text(img, "INSTRUCTIONS TO THE CANDIDATES", 400, 680, 0.9, FB)
    lines = ["This booklet contains 16 pages. Check it before writing.",
             "Fill in the registered number before you begin.",
             "Write the question number in the margin only.",
             "Use only black or blue ink. Rough work must be separated.",
             "No additional answer books will be supplied."]
    for i, l in enumerate(lines):
        text(img, f"{i + 1}.  {l}", 80, 740 + i * 42, 0.65, color=(60, 60, 60), th=1)
    # Marks slip.
    text(img, "To be filled in by the Examiner only", 420, 1080, 0.8, FB)
    top, left, right = 1110, 70, 1150
    cw = 92
    rows = [top, top + 60, top + 130, top + 190, top + 260, top + 360]
    for y in rows:
        cv2.line(img, (left, y), (right, y), INK, 2)
    cv2.line(img, (left, top), (left, rows[-1]), INK, 2)
    cv2.line(img, (right, top), (right, rows[-1]), INK, 2)
    colx = [left + 100, left + 200] + [left + 200 + cw * (i + 1) for i in range(7)]
    tot_x = colx[-1]
    for x in colx:
        cv2.line(img, (x, top), (x, rows[4]), INK, 2)
    cv2.line(img, (tot_x - 2 * cw, rows[4]), (tot_x - 2 * cw, rows[5]), INK, 2)
    cv2.line(img, (tot_x, rows[4]), (tot_x, rows[5]), INK, 2)
    text(img, "PART-A", left + 10, top + 100, 0.7)
    text(img, "PART-B", left + 10, top + 230, 0.7)
    for r, (label, base) in enumerate([("Q.No.", 1), ("Marks", None), ("Q.No.", 11), ("Marks", None)]):
        text(img, label, left + 110, rows[r] + 42, 0.65)
        if base:
            for i in range(7):
                text(img, str(base + i), colx[1] + cw * i + 30, rows[r] + 42, 0.65, color=(60, 60, 60))
    text(img, "Part-A Total", tot_x + 20, rows[0] + 40, 0.75, FB)
    text(img, "Part-B Total", tot_x + 20, rows[2] + 40, 0.75, FB)
    text(img, "GRAND", tot_x - 2 * cw + 30, rows[4] + 45, 0.75, FB)
    text(img, "TOTAL", tot_x - 2 * cw + 32, rows[4] + 80, 0.75, FB)
    text(img, "Grand Total in Words :", left + 10, rows[5] - 20, 0.7, FB)
    hand(img, part_a, tot_x + 60, rows[1] + 52, 1.6, rng)
    hand(img, part_b, tot_x + 60, rows[3] + 52, 1.6, rng)
    hand(img, str(int(part_a) + int(part_b)), tot_x + 60, rows[4] + 70, 1.6, rng)
    text(img, "Signature of the Examiner with Date", 700, 1650, 0.7, color=(60, 60, 60), th=1)
    return img


def sheet_b(reg, sec_a, sec_b, internal, seed=1):
    """A second, different layout: the number goes in boxes UNDER its label,
    the marks in a table whose column headings are the labels, other wording."""
    rng = np.random.default_rng(seed)
    img = np.full((H, W, 3), 248, np.uint8)
    ink = (90, 60, 20)  # dark blue print
    text(img, "GREENFIELD UNIVERSITY", 330, 120, 1.4, FB, ink, 3)
    text(img, "Semester End Examination - Answer Script", 300, 175, 0.9, F, ink, 2)
    cv2.rectangle(img, (60, 220), (1180, 520), ink, 2)
    text(img, "Hall Ticket No.", 90, 280, 0.85, FB, ink)
    x0, y0, bw, bh = 90, 300, 54, 62
    for i in range(11):
        cv2.line(img, (x0 + i * bw, y0), (x0 + i * bw, y0 + bh), ink, 2)
    cv2.rectangle(img, (x0, y0), (x0 + 10 * bw, y0 + bh), ink, 2)
    for i, ch in enumerate(reg):
        hand(img, ch, x0 + i * bw + 13, y0 + 47, 1.3, rng)
    text(img, "Course Code :", 720, 280, 0.8, F, ink)
    text(img, "Name of the Course :", 90, 430, 0.8, F, ink)
    text(img, "Date of Exam :", 720, 430, 0.8, F, ink)
    for i, l in enumerate(["Answer all questions in the space provided.",
                           "Do not write your name anywhere in the script.",
                           "Mobile phones are strictly prohibited."]):
        text(img, l, 90, 620 + i * 40, 0.65, F, (70, 70, 70), 1)
    text(img, "FOR OFFICE USE", 470, 1180, 0.8, FB, ink)
    heads = ["Section A", "Section B", "Internal", "Total Marks"]
    left, top, cw, hh, vh = 140, 1210, 240, 60, 110
    for i in range(len(heads) + 1):
        cv2.line(img, (left + i * cw, top), (left + i * cw, top + hh + vh), ink, 2)
    for y in (top, top + hh, top + hh + vh):
        cv2.line(img, (left, y), (left + len(heads) * cw, y), ink, 2)
    for i, h_ in enumerate(heads):
        text(img, h_, left + i * cw + 30, top + 40, 0.8, FB, ink)
    vals = [sec_a, sec_b, internal, str(int(sec_a) + int(sec_b))]
    for i, v in enumerate(vals):
        hand(img, v, left + i * cw + 80, top + hh + 75, 1.7, rng)
    text(img, "Examiner's Signature", 800, 1560, 0.7, F, (70, 70, 70), 1)
    return img


def photo(img, seed):
    """Perspective, rotation, uneven light, blur and JPEG, like a phone shot."""
    rng = np.random.default_rng(seed)
    h, w = img.shape[:2]
    j = lambda: rng.uniform(-0.06, 0.06)
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    dst = np.float32([[w * (0.05 + j()), h * (0.04 + j())], [w * (0.95 + j()), h * (0.03 + j())],
                      [w * (0.97 + j()), h * (0.96 + j())], [w * (0.03 + j()), h * (0.97 + j())]])
    out_w, out_h = 1200, 1600
    dst *= np.float32([out_w / w, out_h / h])
    m = cv2.getPerspectiveTransform(src, dst)
    bg = np.array(rng.integers(40, 200, 3), np.uint8)
    p = cv2.warpPerspective(img, m, (out_w, out_h), borderValue=tuple(int(v) for v in bg))
    g = np.linspace(rng.uniform(0.75, 1.0), rng.uniform(0.85, 1.05), out_w)[None, :, None]
    p = np.clip(p * g, 0, 255).astype(np.uint8)
    p = cv2.GaussianBlur(p, (0, 0), rng.uniform(0.5, 1.2))
    ok, buf = cv2.imencode(".jpg", p, [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(70, 92))])
    return cv2.imdecode(buf, cv2.IMREAD_COLOR)


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    students = [("21B81A0512", "34", "52"), ("21B81A0577", "18", "47"), ("21B81A05C3", "40", "60"), ("21B81A0590", "27", "39")]
    cv2.imwrite(os.path.join(out, "sheet_clean.png"), sheet(*students[0], seed=0))
    truth = {}
    for i, (reg, a, b) in enumerate(students, 1):
        name = f"photo_{i}.jpg"
        cv2.imwrite(os.path.join(out, name), photo(sheet(reg, a, b, seed=i), seed=100 + i))
        truth[name] = {"registration": reg, "partA": a, "partB": b}
    json.dump(truth, open(os.path.join(out, "truth.json"), "w"), indent=2)
    # Layout B
    b_students = [("19K41A0233", "22", "45", "18"), ("19K41A0251", "30", "38", "20"), ("19K41A02D7", "15", "50", "16")]
    cv2.imwrite(os.path.join(out, "b_sheet_clean.png"), sheet_b(*b_students[0], seed=0))
    truth_b = {}
    for i, (reg, a, b, internal) in enumerate(b_students, 1):
        name = f"b_photo_{i}.jpg"
        cv2.imwrite(os.path.join(out, name), photo(sheet_b(reg, a, b, internal, seed=10 + i), seed=200 + i))
        truth_b[name] = {"registration": reg, "partA": a, "partB": b, "internal": internal}
    json.dump(truth_b, open(os.path.join(out, "truth_b.json"), "w"), indent=2)
    print("wrote", out)
