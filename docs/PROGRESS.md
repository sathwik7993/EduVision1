# EduVision: progress

Branch `cloud/recognition-pipeline`. Living document; newest state first.
The Flutter app and its history are in git before commit 2aaf45c.

## Status at a glance (session 3)

| Deliverable | State | Verified by |
|---|---|---|
| Native Android app (Kotlin, Compose) replacing Flutter | Done | debug + release builds; Robolectric tests; device run in Test Lab (below) |
| Sign-in (Firebase email/password, Google) | Done | builds; **not tried on a phone** (Google sign-in needs the APK signed with a key whose SHA-1 is in the Firebase project) |
| Capture: ML Kit document scanner, camera app, gallery | Done | not tried on a phone |
| Any paper layout: suggested fields + tap-to-select, custom fields as columns | Done | `NewLayoutTest`, `TapSelectTest`, `LayoutSetupUiTest` (device) |
| Recognition pipeline (align, snap to cell, read) | Done | `RealSheetsTest`: 33/34 fields, 9/9 registration numbers, 0 silent errors |
| Validation (ranges, sums, written total, roster, duplicates, 0/D alternatives) | Done | `ValidationTest` |
| Review screen, results, .xlsx export, roster import, layout editor | Done | Robolectric (`DataTest`, `FieldCardTest`); editor not tried on a phone |
| Labelled crops kept for retraining | Done | code path only |
| Latency on entry-level phones | See "Device runs" | Firebase Test Lab |

## Any paper layout (session 3, second part)

A new layout needs one sample sheet and, at most, a few taps:

1. Home → "Set up a new paper layout" (or just scan: a sheet that matches no
   saved layout is detected as new).
2. The app reads the printed text once and suggests fields from labels in
   many wordings (`FieldSuggester`: Registered No., Roll Number, Hall Ticket
   No., Section A, Total Marks, Marks Obtained...), each paired with the
   empty printed box right of or below its label.
3. The teacher taps any other box they want (`CellFinder.boxAt` snaps to the
   printed border; a row of equal boxes can be read as one value, one
   character per box), says what it is (registration, part totals, grand
   total, question, any named number or text) and saves.
4. Every later sheet of that layout is matched and read automatically; custom
   fields become their own Excel columns.

No anchors are set by hand: sheets are registered by matching the whole
printed page (ORB features), which tolerates tilt, perspective and cropping.

Verified: sample photos 34/34 fields with the suggested layout; a second,
made-up layout with different wording and structure (registration boxes under
the label, totals as table column headings) 12/12 with suggested fields plus
one tapped custom field (`NewLayoutTest`); taps snap to the printed box on
three real photos (`TapSelectTest`); the editor flow on a device
(`LayoutSetupUiTest`, Test Lab).

## Every field on the sheet (0.4.0)

`FormFinder` also finds, from the same sample sheet: each cell of a marks
table (named by its heading: question number, Part-A/B Total, GRAND TOTAL;
struck columns skipped), every "label : writing" line (Name, Branch,
Section, Course, Date, or any colon label; read with the printed-text
model), and tick choices ("B.Tech / M.Tech / MBA", "I / II / III / IV";
the option under the tick). Handwritten words and ticks are shown for
checking but do not block saving; every field is an Excel column. On the
owner's Assignment Booklet photo (kept out of the repo) all 17 fields were
found and 13 read right on the first scan, the other 4 flagged.

## Architecture

```
core/   plain Kotlin/JVM: model, validation, recognition (OpenCV + ONNX Runtime)
app/    Android app (Compose UI, Firebase, document scanner, stores)
assets/models/   field_recognizer_v3.onnx, ppocr_v3_det.onnx, ppocr_v3_rec.onnx
training/        recognizer (Kaggle), synthetic sheet generator, real-sheet eval
```

The core runs unchanged on the desktop (OpenCV from `org.openpnp:opencv`,
ONNX Runtime JVM) and on Android (`org.opencv:opencv`,
`onnxruntime-android`): the same code is tested against the real photos on a
desktop and benchmarked on phones.

### Pipeline (`core/.../recog/SheetReader.kt`)

1. **First scan of a layout**: PP-OCRv3 (ONNX) reads the printed text once;
   `LayoutFinder` places Registered No. / Part-A Total / Part-B Total / GRAND
   TOTAL boxes relative to their labels; the comb's box count is measured.
   The photo becomes the template's reference image. The teacher confirms the
   registration format (prefilled from the reading) and the maximum marks.
2. **Every later scan**: `Aligner` matches ORB features to the reference
   (global homography + regional ones around each field). No OCR runs.
3. For each field the homography whose printed surroundings best correlate
   with the reference is used (one print run of the CAT booklet has the marks
   slip a full row higher than another; the global fit put Part-A in the
   Part-B cell). Below 0.5 correlation the field is flagged.
4. `CellFinder` snaps the box to its printed cell (connected components of
   the non-line area) or splits a comb into its boxes (separators must span
   the strip's height, so a handwritten "1" or "H" is not a separator).
5. The handwriting model reads the inside of the cell: digits only for marks;
   one character per comb box with the class its position allows.
6. 0/D, 1/I, 5/S... in an X position produce an alternative reading; a roster
   settles it, otherwise it goes to review with a one-tap suggestion.
7. A field that is cut off, whose box was not found, or whose context does not
   match is flagged whatever the model says.

A photo that matches no saved layout creates a new one, so a teacher with
sheets from two colleges never has to pick a template.

## Accuracy

Real photos: `sample_images/` (9 photos, 1 layout, 34 labelled fields), full
pipeline, auto template from the clean photo 12.13.33, mask `DDADDADDXX`.
LOCAL ONLY: never uploaded.

| Version | Fields right | Registration | Wrong but accepted |
|---|---|---|---|
| Flutter app, v4 model, label boxes + padding (session 2) | 30/34 | 7/9 | 2 |
| Native pipeline, v4 model | 28/34 | 5/9 | 0 |
| Native pipeline, v5 model (shipped as `field_recognizer_v3.onnx`) | 33/34 | 9/9 | 0 |
| + box-based field suggestion (current) | **34/34** | **9/9** | **0** |

The one miss is Part-A on 12.13.32, where the photo cuts the marks slip off;
it is flagged ("Could not find the printed box"). Registration numbers still
go to review without a roster: 0/D in the roll suffix is a real ambiguity, and
the alternative is offered. Caveat: 9 photos of one layout; the v5 training
change (single comb boxes, confusable characters over-sampled) was chosen
after looking at these photos, though training used only synthetic EMNIST
data. More real sheets are needed before trusting the numbers.

Synthetic sheets of a different, made-up layout
(`training/synthetic/make_sheet.py`, used for the device runs): 12/12.

### v5 recognizer (Kaggle `eduvision-field-recognizer-v5`, T4, 20 min)

v4 fine-tuned with a new "box" layout: the inside of one printed comb box as
the app cuts it (border slivers, letters running past the box), 30% of
samples, confusable characters over-sampled. Early stop at step 1000 of 5000.
Synthetic held-out (exact / silent at 0.90): emnist_digit 0.994 / 0.001,
marks_exam 0.970 / 0.0065, marks_cell 0.961 / 0.0105, reg_comb 0.629 / 0.018,
reg_box 0.823 / 0.0075. Slightly below v4 on the synthetic marks sets
(0.980 / 0.974), clearly better on the real photos (above). 3.87 MB fp32.

## Speed

Desktop (1 model thread): ~90 ms per sheet after the template exists (align
~40 ms, 4 fields ~50 ms); first scan of a new layout ~0.5-1.5 s (OCR).
The Flutter app took 10-15 s per scan on the phone. Phones: see below.

## Device runs (Firebase Test Lab, project edusignin-c3d6f)

`app/src/androidTest/.../DeviceBenchmarkTest.kt` on synthetic sheets only.

| Device | Scan (median, after layout exists) | First scan of a new layout | Read right |
|---|---|---|---|
| Samsung Galaxy A03s (SM-A037U, API 33, entry level) | 1647 ms (1.1-1.7 s) | 15.2 s | 12/12 |
| TECNO POP 7 (API 31) | Test Lab infrastructure error, no result | | |
| Samsung Galaxy A14 (API 34) | no device available during the run | | |
| Virtual Arm phone (MediumPhone.arm, API 34), 0.3.0, 4 fields | 142 ms | 4.2 s | 12/12 |
| Virtual Arm phone, 0.4.0, all 21 fields of the synthetic sheet | 422 ms | 8.0 s | 12/12 |
| Samsung Galaxy A03s, 0.4.1 (fields in parallel), 21 fields | 846-1005 ms (0.4.0 way: 1581-1779 ms) | 14.9 s | 12/12 |
| Virtual Arm phone, 0.4.1, 21 fields | 210-224 ms (0.4.0 way: 247-277 ms) | 5.8 s | 12/12 |

### Speed (0.4.1)

The fields of a sheet are read on up to 4 threads, each model call on one
core, and all boxes of a comb go through the model in one call (the model's
batch size is now declared dynamic; weights and outputs unchanged). On the
Galaxy A03s (8 slow cores) that is ~1.8x faster. Measured on both phones in
two alternating rounds (`DeviceBenchmarkTest`), all 12/12 read right:

| A03s, median ms per sheet | round 1 | round 2 |
|---|---|---|
| one field at a time (0.4.0) | 1779 | 1581 |
| fields in parallel (0.4.1, shipped) | 1005 | 846 |
| + int8 LSTM/head weights | 1021 | 853 |
| + XNNPACK kernels | 848 | 875 |
| + int8 + XNNPACK | 884 | 830 |

int8 and XNNPACK are within the noise, so the app keeps the plain fp32
model. Fully int8 (convolutions too) was rejected on the desktop tests:
synthetic 11/12, layout B 10/12.

0.4.0 reads every field (questions, text lines, ticks), not just four, and
looks for printed text at a larger working size; both cost time. Still well
under the 2 s target on this device; the entry-level Galaxy A03s has not been
re-measured with 0.4.0.

`LayoutSetupUiTest` (tap a box, name it, save) passes on the virtual phone.
It caught a bug fixed in the same session: a tapped marks cell that sits in
a row of equal cells was saved as the whole row; whole-row reading is now
the default only for registration/text fields.

The 2 s target is met on an entry-level phone. The one-time layout set-up
(printed-text OCR on the whole page) is slow on that phone: next to optimise.

## APK

Release, per CPU type: arm64-v8a 61.6 MB, armeabi-v7a 50.2 MB, x86_64 99.4 MB
(Flutter: 69.5 / 54.7 / 77.6). Largest parts (arm64): OpenCV 20.9 MB,
ONNX Runtime 18.2 MB, PP-OCR rec 10.7 MB, field model 3.9 MB, PP-OCR det 2.4 MB.

## How to build and test

```
./gradlew :core:test                 # pipeline on the real + synthetic sheets
./gradlew :app:testDebugUnitTest     # Robolectric
./gradlew :app:assembleRelease       # APKs in app/build/outputs/apk/release
```

Device benchmark on a connected phone:
`./gradlew :app:connectedDebugAndroidTest`, results in logcat tag `EduBench`.
On Test Lab: see `docs/testlab.md`.

## Next steps

1. Try the app on a real phone end to end: sign-in (email; Google needs the
   release key's SHA-1 added in Firebase), document scanner, first scan,
   review, export.
2. Collect real sheets. The app keeps every confirmed field in
   `files/labelled_crops/`; a few hundred real crops allow an honest accuracy
   number and a retrain on real handwriting.
3. Import a class roster: it settles the 0/D-type doubts that currently send
   every registration number to review.
4. Speed up the one-time layout set-up on slow phones (OCR on a smaller page,
   or only around candidate boxes).
5. Shrink the APK: an OpenCV build with only core/imgproc/features2d/calib3d
   would save ~15 MB; PP-OCR rec could be swapped for an English-only model.

## Open risks

- EMNIST is not Indian exam handwriting; the review gate is the safety net.
- `H` written like `+1`/`#` is read correctly on these photos but is not in
  the training data.
- "Total in words" is not read (a digit model cannot read words).
- Labels in wording the suggester does not know are not suggested; the
  teacher taps those boxes (one tap each).
- Writing on a line (no printed box) cannot be snapped; the teacher draws it.
- `app/google-services.json` is tracked (as before).
