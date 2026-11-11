# EduVision: summary of the work so far

EduVision reads photographed exam sheets on an Android phone: the
registration (hall ticket) number, the marks, and the other written fields,
and saves them to a results sheet that exports to Excel. This file sums up
what was built, what was measured, and what is still open. Detailed
measurements and decisions are in [PROGRESS.md](PROGRESS.md).

Latest version: **0.4.4** (versionCode 8), branch `cloud/recognition-pipeline`.

## 1. Where it started

- A Flutter app that took 10-15 s per scan on a phone and read sheets from
  fixed box positions.
- Sample sheets in `sample_images/` (9 photos of the college's booklets,
  private: never uploaded or used for training).

## 2. What was built

### Native Android app (replaced Flutter, 0.2.0)

- Kotlin + Jetpack Compose (`app/`), with a plain-Kotlin recognition core
  (`core/`). The same core runs on the phone and in the desktop tests.
- Firebase login (email and Google), the ML Kit document scanner, the camera
  or the gallery for photos.
- Screens:
  - Home: scan, or set up a new paper layout.
  - Check before saving: each value with its crop, confidence and issues;
    one-tap suggestions.
  - Results, with Excel export.
  - Paper layouts (templates), and the class list (roster).
  - Layout editor: tap a printed box to add a field.
- Data stays on the phone: results, layouts, class list, and the confirmed
  field crops that can later train the models.

### Any paper layout (0.3.0 - 0.4.0)

- **First scan of a new layout:** printed-text OCR (PP-OCRv3) finds the labels
  ("Hall Ticket No.", "Part-A", "Marks", "Name", "Date"...). From them, the app
  finds:
  - the registration comb;
  - marks tables, with question numbers and Part-A/Part-B;
  - totals;
  - written lines (name, course, section, date);
  - tick-box choices (Year I/II/III/IV, Mid I/II).
- The teacher checks the layout once and can tap any printed box to add a
  field. Every later sheet of that layout is read automatically.
- **Later scans:** ORB feature matching lines the photo up with the layout's
  reference image (global and regional homographies, to cope with bent paper).
  Each box is snapped to its printed cell.

### Reading the values

| Field | How it is read |
|---|---|
| Registration number | Own handwriting model (CRNN), one box at a time, with the characters each position allows (e.g. `DDADDADDXX`) |
| Marks, question cells, totals | Own handwriting model, digits only |
| Names, course, section, dates | PP-OCRv5 mobile (handwriting-capable), PP-OCRv3 as a fallback when it reads nothing |
| Tick choices | Finds the tick mark above the printed options |

Own models: `training/recognizer/`, trained on Kaggle GPUs from public EMNIST
handwriting rendered into synthetic exam boxes. No student data is used.

| Version | What changed |
|---|---|
| v3 / v4 | First models; v4 adds printed and cut-off text |
| v5 | Fine-tuned on single comb boxes, confusable characters over-sampled |
| v6 (0.4.3) | Separate marks and registration models (EMA, seed soup, WiSE-FT tried) |

Since 0.4.3 each box is read 4 times with tiny crop changes and the readings
vote (test-time augmentation). The older v5 model must agree with the v6
reading, or the box goes to review.

### Reliability: wrong values never saved silently

- Every value has a confidence. Below 0.90 for marks, or 0.95 for a
  registration number, it goes to the teacher.
- Cross-checks:
  - question marks must add up to the part total;
  - Part-A + Part-B must equal the written total;
  - marks cannot exceed the maximum;
  - the registration number's format and the class list are checked;
  - duplicate registration numbers are flagged;
  - dates must be real calendar dates.
- Look-alike characters (0/D, 1/I, 5/S) are offered as "Could also be ...",
  and the class list settles them.
- Values teachers confirm on 2 or more sheets (e.g. a course name) are offered
  as one-tap suggestions on later sheets. They are never filled in silently.
- Ink that the reader cannot read goes to review, not through as "blank".

### Speed

- Fields are read in parallel on up to 4 cores, and all boxes of a comb go
  through the model in one call.
- Galaxy A03s (entry-level phone): about 1.6-1.8 s per sheet before, about
  0.8-1.1 s after.
- Tried and not used:
  - int8 models: no gain on the phone; the fully int8 model lost accuracy;
  - XNNPACK: crashed ONNX Runtime for the printed-text models.

### Fixes

- **Black screen after a scan (0.4.1):** the review screen closed twice and
  removed the home screen too. Fixed, and covered by a device test.
- **Setup screen reopening:** the phone's back button on the layout setup
  screen now cancels the setup.

## 3. Results

| Test | Result |
|---|---|
| 9 real sample photos | 34/34 values right, 9/9 registration numbers, 0 wrong-but-unflagged |
| Assignment booklet (real) | 15/17 right, both misses flagged (was 13/17 before PP-OCRv5) |
| CAT answer book (real) | 6/6 right |
| Synthetic sheets, two layouts | 11/12 and 12/12; the miss is flagged |
| Held-out synthetic marks (1,000 each) | 97.5-97.9% right, 0.5% wrong-but-trusted (was 95.8-96.5% and 0.7-1.1%) |
| Held-out synthetic registration boxes | 84.9% right, 0.4% wrong-but-trusted (was 80.6% and 1.1%) |

Device tests run on Firebase Test Lab with synthetic sheets only: a benchmark,
the tap-a-box layout setup, and navigation. They pass on a virtual Arm phone
(Android 14) and on a Galaxy A03s (Android 13).

## 4. Still open

- **Handwritten words** (names, course names, sections, dates) are the weakest
  fields.
  - A handwritten-word model trained on public data was prepared
    (`training/words/`): 410k handwritten names (CC0), GNHK real-world words
    (CC BY 4.0), and synthetic dates and codes.
  - Its training run was stopped on request and has not been run since.
- **Real handwriting for training.** The app stores confirmed field crops on
  the phone. Using them to train needs the college's consent.
- **Proof that it works on any paper.** A fresh set of 20-30 sheets from other
  colleges and layouts, measured once and never tuned on, would show it.
  `LayoutFinder` still holds fixed offsets measured on the CAT answer book, as
  a fallback.
- **Google sign-in** needs the release key's SHA-1 and SHA-256 fingerprints
  added in the Firebase console.
- **Setting up a new layout** takes about 15 s on an entry-level phone (once
  per layout).

## 5. Where things are

| Path | What |
|---|---|
| `app/` | Android app (Compose UI, data stores, scanner) |
| `core/` | Recognition core: alignment, cell finding, reading, validation |
| `assets/models/` | Bundled ONNX models and their licences (`NOTICE.md`) |
| `training/recognizer/` | Marks and registration model training (Kaggle) |
| `training/words/` | Handwritten-word model training (prepared, not run) |
| `training/synthetic/` | Synthetic sheet generator for the tests |
| `docs/PROGRESS.md` | Detailed measurements and decisions |
| `docs/testlab.md` | How to run the device tests on Firebase Test Lab |
