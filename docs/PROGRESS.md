# EduVision recognition pipeline: progress

Branch `cloud/recognition-pipeline` (from `final-stage` 4033e03, with
`final-stage` 8210c24 merged for `sample_images/`). Living document; the
newest state is at the top of each section.

## Status at a glance

| Plan step | State | Verified by |
|---|---|---|
| 1. Template boxes + editor + local storage | Done | unit tests (JSON round-trip, store), widget build; editor not yet tried on a device |
| 2. Deskew / alignment | Done: printed-text anchors (ML Kit) + RANSAC homography, page-corner and whole-frame fallbacks, out-of-photo detection; ML Kit document scanner for capture | unit tests on synthetic perspective photos and a left-cropped synthetic photo; corner detection run on the 9 real photos; anchors on the real photos **not yet verified on a device** |
| 3. `OnnxSheetRecognizer` | Done; ships the v4 model (`assets/models/field_recognizer_v2.onnx`, 3.9 MB) | unit tests with stubbed model output; Python/Dart preprocessing parity test; synthetic eval and local real-sheet eval (below) |
| 4. Benchmark harness | Done: `integration_test/benchmark_test.dart`, `training/real_eval/eval_real.py`; PP-OCRv5 comparison run (custom model wins) | device benchmark **not yet run** (needs a phone/emulator) |
| 5. Validation | Done: range per template, reg-no mask/pattern/incomplete, per-question sum, written-total cross-check, roster import + fuzzy suggestion, duplicates | unit + widget tests for sample-sheet cases (a)–(f) |
| 6. Corrections stored as labelled crops | Done | unit test (files + JSONL index) |
| 7. Production readiness | Partly: `flutter analyze` clean, 68 tests pass, ProGuard rules for ONNX Runtime and androidx.window, model-load fallback to ML Kit, camera-permission denial offers the document scanner/gallery, review gates 0.90 (marks) / 0.95 (reg nos) | release build with the model verified (session 2); **not yet run on a device** |

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

- Session 2 (cloud, Flutter 3.47.7 / Dart 3.13.5): `flutter analyze` no
  issues (after adding the `assets/models/.gitkeep` placeholder);
  `flutter test`: 66 tests pass.
- Session 2, with the v4 model: release build succeeds; armeabi-v7a
  54.7 MB, arm64-v8a 69.5 MB, x86_64 77.6 MB (model 3.87 MB inside).
  `flutter test`: 68 pass; `flutter analyze`: no issues.
- Session 2: `flutter build apk --release --split-per-abi` **succeeds** (R8
  fix for androidx.window confirmed), without the model asset yet:
  armeabi-v7a 51.1 MB, arm64-v8a 65.9 MB, x86_64 74.0 MB. Largest parts of
  arm64 (uncompressed): `libonnxruntime.so` 28.6 MB, `libflutter.so` 11.7 MB,
  `libmlkit_google_ocr_pipeline.so` 11.1 MB, Dart code 8.1 MB. In the cloud
  sandbox Maven Central answered 429 to Gradle's parallel downloads; a local
  `~/.gradle/init.d` mirror (Google's Maven Central mirror) plus Gradle's
  429 retry worked around it. Nothing in the repo depends on that.
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

Credentials: session 1 authenticated through `~/.kaggle/kaggle.json`.
Session 2 uses `KAGGLE_API_TOKEN` (environment variable). The cloud
environment needs `api.kaggle.com`, `www.kaggle.com` and, for kernel
*outputs*, `www.kaggleusercontent.com` in its Allowed domains (dataset
downloads go through `storage.googleapis.com` and already work). All kernels are private.

| Kernel | Config | Outcome | GPU time |
|---|---|---|---|
| `eduvision-field-recognizer` (v1) | old generator, 15k steps, 150 min cap | stopped by the owner after ~1.5 h with empty logs (status ERROR); no output used | ~1.5 h (T4) |
| `eduvision-field-recognizer-v2` | new generator, old 150 min cap | ran a few minutes concurrently with v1, then deleted to respect one-GPU-kernel-at-a-time and the 60 min cap | < 0.3 h |
| `eduvision-field-recognizer-v3` | new generator (comb/cell layouts, partial reg nos, stray marks, motion blur), 60 min hard cap, validation every 1000 steps with patience 4, line-buffered logs | ran 08:05–08:57 UTC; trained to the wall-clock cap (step 12296, ~1065 samples/s, best synthetic val exact 0.7467, still rising slowly: 0.59 @1k, 0.675 @3k, 0.733 @8k, 0.747 @12k). Wrote `field_recognizer.pt`, `.onnx` and `eval_sets.npz`, then **ERROR**: `onnxruntime` is not in the Kaggle image, so int8 export and `results.json` never ran. Fixed in the script (installs it at start). The fp32 model is usable; int8 + eval can run offline from it | ~51 min (T4) |
| `eduvision-field-recognizer-v4` | v3 generator + printed text cut off at the crop edges; fine-tuned from v3 (private dataset `eduvision-field-recognizer-v3-output`); 60 min cap | ran 09:24–10:15 UTC, COMPLETE; wall-clock cap at step 11569, best val exact 0.770 (val now includes edge clutter). Shipped | ~50 min (T4) |
| `eduvision-ppocr-eval` (CPU) | PP-OCRv5 conversion + comparison | v1–v3 failed in setup, v4 COMPLETE | CPU only |

v3's outputs (`.pt`, `.onnx`, `eval_sets.npz`; synthetic, no student data)
are also a **private** dataset `sathwikchappala/eduvision-field-recognizer-v3-output`,
because an errored kernel cannot be attached as a kernel source. v4 and the
PP-OCR comparison attach it.

PP-OCRv5 comparison (`sathwikchappala/eduvision-ppocr-eval`, CPU only):
versions 1–3 failed in setup (no input; paddle2onnx has no Python 3.13 build;
paddle needs setuptools); version 4 completed. Results under "Model accuracy".

### How to check and fetch v3

```
kaggle kernels status sathwikchappala/eduvision-field-recognizer-v3
kaggle kernels logs   sathwikchappala/eduvision-field-recognizer-v3
kaggle kernels output sathwikchappala/eduvision-field-recognizer-v3 -p <dir>
```

Output files: `field_recognizer.onnx` (fp32, input `input` [1,1,32,W] ->
output `probs` [1,T,37]), `field_recognizer.int8.onnx` (LSTM/MatMul int8,
convs fp32), `field_recognizer.pt`, `eval_sets.npz`, `results.json`
(synthetic held-out metrics, size, stop reason, minutes).

## Template-free field detection (session 2)

After the first phone test (scans took 10-15 s and gave wrong values) it
turned out no template had been drawn, so every scan used the ML Kit
printed-text fallback: three full-image variants in pure Dart, then label
guessing; the handwriting model never ran. Teachers should not have to draw
boxes first, so `FieldLocator` now places the fields from the printed labels
the one ML Kit pass already reads ("Registered No." -> right of it;
"Part-A/B Total" -> the cell below; "GRAND"/"TOTAL" -> the cell right of
it), in label-size units so cropped or zoomed photos work. The model is the
default engine; a drawn template is used when one is active. "Total in
words" is not auto-detected (a digit model cannot read words).

Local eval (`training/real_eval/eval_auto_fields.py`, RapidOCR standing in
for ML Kit): fields found 34/34, read right 30/34 with the v4 model
(registration 7/9, all below the 0.95 gate so reviewed). Two Part-A cells
("10" read as "20" on the two left-cropped photos of one sheet) pass the
0.90 gate; on 12.13.31 the grand-total cross-check flags it, on 12.13.32 the
sheet goes to review for the missing Part-B but Part-A itself looks trusted.
Not yet run on a phone (ML Kit's line splitting may differ from RapidOCR's).

## Model accuracy and size

### v4 (shipped as `assets/models/field_recognizer_v2.onnx`, fp32)

Fine-tuned from v3 on the same generator plus printed text cut off at the
crop edges. fp32 3.87 MB, int8 2.66 MB (fp32 ships, as for v3).

Synthetic exact / silent@0.80, v3 vs v4. "v3 sets" have no edge clutter,
"v4 sets" do:

| Set | v3 sets: v3 | v3 sets: v4 | v4 sets: v3 | v4 sets: v4 |
|---|---|---|---|---|
| emnist_digit | 0.996 / 0.0020 | 0.996 / 0.0020 | 0.996 / 0.0020 | 0.996 / 0.0020 |
| marks_clean | 0.996 / 0.0025 | 0.996 / 0.0020 | 0.996 / 0.0025 | 0.996 / 0.0020 |
| marks_exam | 0.986 / 0.0055 | 0.982 / 0.0085 | 0.729 / 0.0640 | 0.980 / 0.0095 |
| marks_cell | 0.978 / 0.0070 | 0.975 / 0.0125 | 0.749 / 0.0640 | 0.974 / 0.0120 |
| reg_exam | 0.674 / 0.0790 | 0.681 / 0.0805 | 0.508 / 0.0885 | 0.688 / 0.0675 |
| reg_comb | 0.677 / 0.0725 | 0.676 / 0.0685 | 0.530 / 0.0835 | 0.671 / 0.0725 |

v4 with the app's rules on v4 sets (reg nos masked; wrong length = review),
auto-accept / silent at the shipped gates: marks_exam 0.880 / 0.0070,
marks_cell 0.860 / 0.0090, marks_clean 0.972 / 0.0010 (0.90 gate); reg_exam
0.235 / 0.0025, reg_comb 0.193 / 0.0025 (0.95 gate).

Real sheets, v4 (app padding 6%): exact 32/41 (v3 25/41), registration 6/9
(v3 0/9); with the box shifted 3% left or right: 33/41 and 36/41, reg 6/9
each time (v3 fell to 0/9 reg on the left shift). Wrong fields under the
app's rules: three "total in words" boxes and one Part-A on 12.13.31 are
caught by the written-total cross-check; Part-A on 12.13.32 ("10" read as
"20" at 0.88, no total in that photo) and the same misread on 12.13.31 were
the reason for raising the mark gate to 0.90, which sends both to review.
Three registration numbers are wrong at 0.52–0.68 and go to review.

**Gates (session 2):** marks 0.90 (`ExtractedField.trustedAbove`, was
0.80), registration numbers 0.95 (`ScanValidator.registrationTrustedAbove`).

### v3 (shipped as `field_recognizer_v1.onnx` until v4 replaced it)

~0.97M parameters. fp32 ONNX 3.87 MB, int8 (LSTM/MatMul only) 2.66 MB with
the same accuracy to within 0.3 points on every set. fp32 ships: int8 saves
1.2 MB of a ~66 MB APK and its LSTM speed on ARM is unmeasured. int8 and the
eval were produced offline in session 2 from v3's fp32 output (same code as
the kernel), since v3 crashed before them.

Synthetic held-out sets (2000 each, EMNIST *test* glyphs; **not real
handwriting**). Silent = wrong but auto-accepted. Desktop ms/crop, 1 thread.

| Set | Exact | CER | Auto-accept @0.80 | Silent @0.80 | ms/crop |
|---|---|---|---|---|---|
| emnist_digit | 0.996 | 0.004 | 0.988 | 0.0020 | 0.7 |
| marks_clean | 0.996 | 0.003 | 0.989 | 0.0025 | 0.9 |
| marks_exam | 0.986 | 0.009 | 0.917 | 0.0055 | 1.1 |
| marks_cell | 0.978 | 0.014 | 0.903 | 0.0070 | 1.4 |
| reg_exam | 0.675 | 0.043 | 0.563 | 0.0790 | 2.9 |
| reg_comb | 0.677 | 0.043 | 0.541 | 0.0725 | 2.9 |

Registration numbers decoded the way the app does (template mask; a
wrong-length read is "incomplete" and goes to review), gate swept:

| Set | Exact | @0.80 accept / silent | @0.90 | @0.95 | @0.98 |
|---|---|---|---|---|---|
| reg_exam | 0.825 | 0.506 / 0.0230 | 0.348 / 0.0070 | 0.205 / 0.0015 | 0.092 / 0.0005 |
| reg_comb | 0.807 | 0.436 / 0.0250 | 0.275 / 0.0050 | 0.134 / 0.0015 | 0.052 / 0.0005 |
| marks_exam | 0.986 | 0.916 / 0.0055 | 0.894 / 0.0030 | 0.842 / 0.0020 | 0.679 / 0.0005 |
| marks_cell | 0.978 | 0.903 / 0.0070 | 0.875 / 0.0050 | 0.824 / 0.0040 | 0.665 / 0.0025 |

Decision (session 2): registration numbers now need 0.95
(`ScanValidator.registrationTrustedAbove`); below that they go to review
with "Not certain enough for a registration number". A roster cannot catch a
one-digit roll-number misread, because that is usually another real student.
Marks were kept at 0.80 at first; raised to 0.90 after the v4 real-sheet
eval (see v4 above).

### PP-OCRv5 mobile rec vs custom v3 (same synthetic sets, same decoding)

Converted with paddle2onnx 2.0.1, 7.8 MB. Desktop ms/crop, 1 thread, Kaggle CPU.

| Set | PP-OCRv5 exact / silent | Custom v3 exact / silent | ms/crop PP-OCR / custom |
|---|---|---|---|
| emnist_digit | 0.974 / 0.0065 | 0.996 / 0.0020 | 45.6 / 1.4 |
| marks_clean | 0.959 / 0.0105 | 0.996 / 0.0025 | 45.2 / 2.0 |
| marks_exam | 0.891 / 0.0275 | 0.986 / 0.0055 | 45.3 / 2.4 |
| marks_cell | 0.853 / 0.0290 | 0.978 / 0.0070 | 45.1 / 3.1 |
| reg_exam | 0.421 / 0.0705 | 0.675 / 0.0790 | 47.4 / 7.3 |
| reg_comb | 0.297 / 0.0600 | 0.677 / 0.0725 | 48.6 / 7.6 |

Decision: keep the custom model (fewer silent errors on marks, higher
accuracy, ~15–30x faster, half the size). Caveat: the sets come from the same
generator the custom model trained on, which favours it; no real-sheet
comparison yet.

### Real sheets, v3 (`eval_real.py`, 9 photos, 41 hand-boxed fields)

A smoke test, not a statistic. Default 6% box padding: exact 25/41,
registration 0/9. **Every registration number and several totals were read
with an extra leading character** (e.g. a 10-character reg no read as 11,
"30" as "530"): the padding pulls the end of the printed label next to the
box into the crop. In the app these reg nos fail the length check and go to
review, so none is silently accepted, but none is read right either.
Without padding: exact 39/41, registration 8/9; but a 3% box shift to the
left (a realistic alignment residual) brings it back to 0/9 at any padding,
so padding is not the fix. v4 (below) trains on printed text cut off at the
crop edges.

## Real sample sheets (local only)

`sample_images/` (9 photos, 1 layout). Never uploaded anywhere; used for
template design, alignment checks and the local eval only.
`sample_images/annotations.json` holds hand-drawn field boxes and the README's
provisional labels.

- Page-corner detection on all 9 photos returns (almost) the whole frame:
  the sheet fills the frame or is cut off. This is why alignment uses printed
  anchors first.

## Next steps (priority order)

Done in session 2: model in the app (v4), synthetic and real-sheet numbers,
PP-OCRv5 comparison, release build with the model, review gates tightened.
What is left needs a device or more data:

1. **Device run of the benchmark.** On an emulator or phone:
   `python -I training/real_eval/export_bench.py <dir> --eval-sets eval_sets.npz`,
   `adb push <dir>/. /sdcard/Android/data/com.example.eduvision_0_1/files/bench/`,
   then `flutter test integration_test/benchmark_test.dart -d <device>`.
   It prints ONNX vs ML Kit accuracy and ms/crop per source (real vs
   synthetic sets) and the end-to-end result on the 9 photos (anchor
   alignment, per-field reads, timings), and writes `results_*.json` next to
   the data. Verify especially: anchors found on the left-cropped photos
   (12.13.30 PM (1), 12.13.31, 12.13.32) and the screenshot (12.13.30 PM).
2. **Latency on an entry-level phone** (the 2 s target): scan a few sheets,
   read `OnnxSheetRecognizer <alignment> timings (ms)` from logcat
   (decode / align / crop / inference / total). The ML Kit anchor pass is the
   likely largest stage; if it is too slow, run it on a downscaled page.
3. **Template editor on a device**: create the CAT template from a sample,
   check the teal anchor boxes cover the header and the marks slip, draw
   Registered No. (mask `DDADDADDXX`), Part-A/Part-B totals (max 40/80 for
   the 40/80 exam), Grand total and Total in words as written totals.
4. **More real sheets.** 9 photos of one layout is a smoke test. Re-run
   `eval_real.py` on new annotated sheets (and on the labelled crops the
   app collects) before trusting the gates; retrain (v5, bump the asset to
   `_v3`) with real crops once there are a few hundred.
5. **Registration numbers** still go to review most of the time (16–24%
   auto-accepted synthetic; 6/9 read right on real sheets). A per-box
   classifier for comb strips, or a class roster, would cut review work.

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
