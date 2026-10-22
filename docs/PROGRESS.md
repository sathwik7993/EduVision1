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
| 7. Production readiness | Partly: `flutter analyze` clean, tests pass, ProGuard rules for ONNX Runtime and androidx.window, model-load fallback to ML Kit, camera-permission denial offers the document scanner/gallery | release build failed once in R8 (missing androidx.window classes); fix added, rebuild and APK size **not yet verified** |

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
  `flutter test`: 66 tests pass. `flutter build apk` not possible here: the
  session's network policy blocks `dl.google.com` (Android SDK).
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
Session 2 had `KAGGLE_API_TOKEN` set as an environment variable, but the
environment's network policy rejected `api.kaggle.com` and `www.kaggle.com`
(proxy 403), so v3 could not be polled or fetched and no GPU time was used.
Add both hosts to the environment's Allowed domains (and `dl.google.com` for
release builds), then start a new session. All kernels are private.

| Kernel | Config | Outcome | GPU time |
|---|---|---|---|
| `eduvision-field-recognizer` (v1) | old generator, 15k steps, 150 min cap | stopped by the owner after ~1.5 h with empty logs (status ERROR); no output used | ~1.5 h (T4) |
| `eduvision-field-recognizer-v2` | new generator, old 150 min cap | ran a few minutes concurrently with v1, then deleted to respect one-GPU-kernel-at-a-time and the 60 min cap | < 0.3 h |
| `eduvision-field-recognizer-v3` | new generator (comb/cell layouts, partial reg nos, stray marks, motion blur), 60 min hard cap, validation every 1000 steps with patience 4, line-buffered logs | pushed 07:35 UTC; **QUEUED** when this session ended (handover) | ≤ 60 min when it runs |

PP-OCRv5 comparison (`training/ppocr_eval/`, kernel id
`sathwikchappala/eduvision-ppocr-eval`, CPU only) has **not been pushed yet**.
Its metadata already points at v3's output.

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

## Model accuracy and size

**No trained model yet; no accuracy numbers exist.** Size of the architecture
(from the smoke export): ~0.97M parameters, fp32 ONNX 3.9 MB, int8
(LSTM/MatMul only) 2.7 MB. In the smoke test fully int8 ONNX (convs too) was
~15x slower on desktop CPU, so convs stay fp32. Desktop single-thread time per
crop was 1–5 ms for the smoke model (not a phone number).

When v3 finishes, report from `results.json` per set (`emnist_digit`,
`marks_clean`, `marks_exam`, `marks_cell`, `reg_exam`, `reg_comb`; all
**synthetic**, from EMNIST *test* glyphs): exact accuracy, CER,
auto-accept rate, silent-error rate (wrong but above the 0.80 gate), and
accuracy when accepted. Report the real-sheet eval separately (9 photos, 41
hand-boxed fields; a smoke test, not a statistic).

`assets/models/` holds only a `.gitkeep` placeholder until step 1 below is
done. A clean checkout builds; the ONNX model fails to load and scanning falls
back to ML Kit (printed text only, so handwritten marks go to review).

## Real sample sheets (local only)

`sample_images/` (9 photos, 1 layout). Never uploaded anywhere; used for
template design, alignment checks and the local eval only.
`sample_images/annotations.json` holds hand-drawn field boxes and the README's
provisional labels.

- Page-corner detection on all 9 photos returns (almost) the whole frame:
  the sheet fills the frame or is cut off. This is why alignment uses printed
  anchors first.

## Next steps (priority order)

1. **Get the model in.** When v3 is COMPLETE, fetch its output (commands
   above) and copy `field_recognizer.onnx` to
   `assets/models/field_recognizer_v1.onnx` (the versioned name in
   `OrtFieldModel.asset`; bump the suffix for any later retrain, because
   flutter_onnxruntime caches the extracted asset by file name). Pick fp32 vs
   int8 from `results.json` (accuracy and ms). Commit it. If v3 failed, read
   `kaggle kernels logs`, fix, and push once more (keep the 60 min cap, one
   GPU kernel at a time, record GPU minutes here).
2. **Fill in the numbers.** Paste the synthetic metrics from `results.json`
   into this file. Run the local real-sheet eval (never upload its inputs or
   outputs):
   `python -I training/real_eval/eval_real.py <model.onnx> --mask DDADDADDXX`
   and record exact / auto-accepted / silent errors separately from the
   synthetic numbers.
3. **PP-OCRv5 comparison.** `kaggle kernels push -p training/ppocr_eval`
   (CPU; converts `PaddlePaddle/en_PP-OCRv5_mobile_rec` with paddle2onnx and
   scores it and the custom model on v3's `eval_sets.npz` with the same
   decoding rules). paddle2onnx does not install on local Python 3.13, hence
   Kaggle. Choose the model by silent-error rate first, then exact accuracy,
   then ms/crop and size; update the research doc. Also run
   `eval_real.py` on the converted PP-OCR model only if its preprocessing is
   ported there (it is not yet: `eval_real.py` uses the custom `prep`).
4. **Release build.** `flutter build apk --release --split-per-abi`. The last
   attempt failed in R8 on missing `androidx.window.extensions/sidecar`
   classes; `-dontwarn` rules for them were added to
   `android/app/proguard-rules.pro` but the build has **not been re-run**.
   Record per-ABI APK sizes here (`build/app/outputs/flutter-apk/`).
5. **Device run of the benchmark.** On an emulator or phone:
   `python -I training/real_eval/export_bench.py <dir> --eval-sets eval_sets.npz`,
   `adb push <dir>/. /sdcard/Android/data/com.example.eduvision_0_1/files/bench/`,
   then `flutter test integration_test/benchmark_test.dart -d <device>`.
   It prints ONNX vs ML Kit accuracy and ms/crop per source (real vs
   synthetic sets) and the end-to-end result on the 9 photos (anchor
   alignment, per-field reads, timings), and writes `results_*.json` next to
   the data. The local attempt failed only because the host ran out of
   memory during the Gradle build. Verify especially: anchors found on the
   left-cropped photos (12.13.30 PM (1), 12.13.31, 12.13.32) and the
   screenshot (12.13.30 PM).
6. **Latency on an entry-level phone** (the 2 s target): scan a few sheets,
   read `OnnxSheetRecognizer <alignment> timings (ms)` from logcat
   (decode / align / crop / inference / total). The ML Kit anchor pass is the
   likely largest stage; if it is too slow, run it on a downscaled page.
7. **Template editor on a device**: create the CAT template from a sample,
   check the teal anchor boxes cover the header and the marks slip, draw
   Registered No. (mask `DDADDADDXX`), Part-A/Part-B totals (max 40/80 for
   the 40/80 exam), Grand total and Total in words as written totals.

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
