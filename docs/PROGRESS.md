# EduVision recognition pipeline: progress

Branch `cloud/recognition-pipeline` (from `final-stage` 4033e03, with
`final-stage` 8210c24 merged for `sample_images/`). Living document; the
newest state is at the top of each section.

## Status at a glance

| Plan step | State | Verified by |
|---|---|---|
| 1. Template boxes + editor + local storage | Done | unit tests (JSON round-trip, store), widget build; editor not yet tried on a device |
| 2. Deskew / alignment | Done: printed-text anchors (ML Kit) + RANSAC homography, page-corner and whole-frame fallbacks, out-of-photo detection; ML Kit document scanner for capture | unit tests on synthetic perspective photos and a left-cropped synthetic photo; corner detection run on the 9 real photos; anchors on the real photos **not yet verified on a device** |
| 3. `OnnxSheetRecognizer` | Done (code); model training in progress on Kaggle | unit tests with stubbed model output; Python/Dart preprocessing parity test |
| 4. Benchmark harness | Done (code): `integration_test/benchmark_test.dart`, `training/real_eval/eval_real.py`, Kaggle PP-OCRv5 comparison kernel | **not yet run on a device** (local emulator build failed: host out of memory) |
| 5. Validation | Done: range per template, reg-no mask/pattern/incomplete, per-question sum, written-total cross-check, roster import + fuzzy suggestion, duplicates | unit + widget tests for sample-sheet cases (a)–(f) |
| 6. Corrections stored as labelled crops | Done | unit test (files + JSONL index) |
| 7. Production readiness | Partly: `flutter analyze` clean, tests pass, ProGuard rule for ONNX Runtime, model-load fallback to ML Kit | release APK build and size check pending (host memory) |

## What was built

- `lib/models/sheet_template.dart`: `SheetTemplate` now carries `fields`
  (normalised boxes: registration, Part-A/B totals, per-question marks,
  written totals), `anchors`, `registrationMask` (`D`/`A`/`X` per position),
  per-template `partAMax`/`partBMax`, JSON serialisation.
- `lib/services/template_store.dart`: templates + active template in one JSON
  file in app storage (atomic write).
- `lib/pages/templates_page.dart`, `template_editor_page.dart`: choose the
  active template, draw boxes on a deskewed sample (document scanner, camera
  or gallery), set maxima and reg-no format; class roster import (.xlsx).
- `lib/services/template_builder.dart`: deskews the sample and records anchors.
- `lib/services/recognition/`
  - `page_loader.dart`: native image decode (downscaled to 2000 px).
  - `page_aligner.dart`: pure-Dart page detection, homography (from corners or
    least squares), per-box perspective sampling.
  - `anchor_aligner.dart`: ML Kit line reader (fed the gray page as NV21),
    anchor selection and RANSAC registration.
  - `crop_preprocessor.dart`: model input; mirror of the Python `prep()`.
  - `ctc_decoder.dart`: charset-constrained greedy CTC, min-char confidence
    from raw probabilities, positional mask decoding.
  - `onnx_recognizer.dart`: `OnnxSheetRecognizer implements SheetRecognizer`,
    `supportsHandwriting => true`, per-stage timings in every `ScanResult`.
- `lib/services/scan_validator.dart`, `roster_service.dart`,
  `correction_store.dart`.
- Scan screen: uses the active template; ONNX engine when the template has
  boxes, ML Kit otherwise or if the model fails to load; document-scanner
  button; validation before review.
- Review screen: shows each field's crop, the validation issue, a roster
  suggestion, a "Matches the sheet" confirm; re-validates on every edit;
  stores labelled crops on save; one row per student (the "Add anyway"
  duplicate option was removed).
- `training/recognizer/eduvision_recognizer.py` (Kaggle script kernel),
  `training/ppocr_eval/ppocr_eval.py` (PP-OCRv5 conversion and comparison),
  `training/real_eval/` (local-only real-sheet eval and device bench export).

## Verification log

- `flutter analyze`: no issues (last run after the benchmark harness commit).
- `flutter test`: 65 tests pass (`test/extraction_test.dart`,
  `recognition_pipeline_test.dart`, `validation_test.dart`,
  `ui_smoke_test.dart`, `real_samples_test.dart`).
- Preprocessing parity: Dart `CropPreprocessor` vs Python `prep()` on 8
  synthetic crops (including upscaling), max per-pixel difference < 0.06.
- Training pipeline smoke tests (local CPU/GPU, 60–200 steps on EMNIST test
  CSVs): train, export ONNX, int8 export, eval and early stopping all run.
  Numbers from these runs are meaningless and are not reported.

## Kaggle runs and GPU time

Credentials: `KAGGLE_API_TOKEN` is **not** visible in this session's
environment; the CLI authenticates through `~/.kaggle/kaggle.json`
(`kaggle kernels list --mine` works). All kernels are private.

| Kernel | Config | Outcome | GPU time |
|---|---|---|---|
| `eduvision-field-recognizer` (v1) | old generator, 15k steps, 150 min cap | stopped by the owner after ~1.5 h with empty logs (status ERROR); no output used | ~1.5 h (T4) |
| `eduvision-field-recognizer-v2` | new generator, old 150 min cap | ran a few minutes concurrently with v1, then deleted to respect one-GPU-kernel-at-a-time and the 60 min cap | < 0.3 h |
| `eduvision-field-recognizer-v3` | new generator (comb/cell layouts, partial reg nos, stray marks, motion blur), 60 min hard cap, validation every 1000 steps with patience 4, line-buffered logs | pushed 07:35 UTC, running | pending |

PP-OCRv5 comparison (`eduvision-ppocr-eval`, CPU only) runs after v3, on v3's
held-out sets.

## Model accuracy and size

Pending v3. Everything below the line will be filled from `results.json`
(synthetic held-out sets from EMNIST **test** glyphs) and from the real-sheet
eval (9 photos, 41 hand-boxed fields; a smoke test, not a statistic).

## Real sample sheets (local only)

`sample_images/` (9 photos, 1 layout). Never uploaded anywhere; used for
template design, alignment checks and the local eval only.
`sample_images/annotations.json` holds hand-drawn field boxes and the README's
provisional labels.

- Page-corner detection on all 9 photos returns (almost) the whole frame:
  the sheet fills the frame or is cut off. This is why alignment uses printed
  anchors first.

## Needs a real device or more sheets

- Anchor alignment on real photos, and end-to-end accuracy (the
  integration test does this; the local emulator run failed for lack of host
  memory).
- Latency on an entry-level phone. The app logs per-stage timings
  (`OnnxSheetRecognizer timings (ms)`) and shows them under "What the scanner
  read"; no phone numbers yet. Desktop single-thread ONNX timing is not a
  phone number.
- Document scanner behaviour (Play services module download on first use).
- Accuracy claims need ~200+ labelled real crops; the app now collects them
  locally (`labelled_crops/`).

## Open risks

- Synthetic EMNIST handwriting is not Indian exam handwriting; real accuracy
  may be lower. The review gate is the safety net.
- `H` written like `+1`/`#` (seen on the sheets) is not in the training data.
- "Total in words" written as English words cannot be read by a digit model;
  such a box will read as doubtful and go to review.
- Templates with few printed labels fall back to page corners, which need the
  whole page in the photo.
- Not addressed: `.gitignore` contains unresolved merge-conflict markers
  (pre-existing); `android/app/google-services.json` is tracked (pre-existing).
