# Offline recognition pipeline — research (2026-10-22)

Goal from README: scan exam sheet on an entry-level Android phone, extract
registration number and handwritten marks offline, validate, export to Excel,
~2 s per page, never silently trust an uncertain mark.

Decisions taken with the user:

- Primary target: **Android phone** (current Flutter app). Windows is out of scope for now.
- Sheet layouts **vary by college**, so the pipeline must be template-driven.
- Only **1–5 real sample sheets** available, so accuracy cannot yet be measured statistically.

## Where the app is today

- `SheetRecognizer` interface (`lib/services/recognition/sheet_recognizer.dart`) keeps the UI independent of the engine.
- Only implementation: `MlKitSheetRecognizer`. ML Kit Latin text model reads **printed** text only (`supportsHandwriting => false`).
- `SheetTemplate` holds label synonyms and max marks, but no field positions.
- `ScanResult` / `ExtractedField` already carry confidence, and `needsReview` gates saving (threshold 0.80). The total is derived, never read. Keep this.

## Findings

### Large OCR models are the wrong tool here

HF official leaderboards (olmOCR-bench, Real5-OmniDocBench) are led by VLMs:
LightOnOCR-3 (0.8B–4B), PaddleOCR-VL-1.6, MinerU2.5 (1.2B), GLM-OCR.
The smallest is still ~0.8B parameters and decodes token by token. On an
entry-level phone CPU that is many seconds per page, and the benchmarks
measure printed PDF parsing, not handwritten digits. Rejected for the main path.

### Compact candidates that fit the phone

| Model | Size | License | Use | Notes |
|---|---|---|---|---|
| [PaddlePaddle/en_PP-OCRv5_mobile_rec](https://huggingface.co/PaddlePaddle/en_PP-OCRv5_mobile_rec) | ~8 MB | Apache-2.0 | Text-line recognition (CTC) | Vendor claims improved handwriting in v5. Paddle format; convert with `paddle2onnx`. CTC output gives per-character probabilities, which become confidence. |
| [PaddlePaddle/PP-OCRv5_mobile_det_onnx](https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_det_onnx) | ~4.8 MB | Apache-2.0 | Text detection | Already ONNX. Only needed if a template does not give field boxes. |
| Custom digit CNN (EMNIST/MNIST-style) | ~0.1–1 MB | own | Single-digit classification | Best for marks written in printed boxes. Train once and export to TFLite/ONNX. |
| [microsoft/trocr-small-handwritten](https://huggingface.co/microsoft/trocr-small-handwritten) | ~62M params | MIT (per model card) | Handwritten line recognition | Autoregressive and slower. Use as a benchmark baseline only. |
| [PP-DocLayoutV3](https://huggingface.co/PaddlePaddle/PP-DocLayoutV3_safetensors) / table-transformer | 100+ MB | Apache-2.0 / MIT | Layout and table detection | Too heavy for every scan. Templates replace it. |

### Flutter packages (checked on pub.dev 2026-10-22)

- `flutter_onnxruntime` 1.9.0 (2026-10-06): runs ONNX models on Android CPU (XNNPACK/NNAPI). Recommended runtime.
- `tflite_flutter` 0.12.1 (2025-10-28): alternative if the digit CNN ships as TFLite.
- `opencv_dart` 2.2.2: perspective warp, thresholding, contour and box detection, ORB alignment.
- `google_mlkit_document_scanner` 0.6.1: on-device edge detection plus deskew UI. Needs Google Play services, and its module downloads once. Use `opencv_dart` warp as a fallback for devices without Play services.

## Proposed pipeline

```
capture ─► page crop + deskew ─► align to college template ─► crop field ROIs
        ─► printed fields: ML Kit (existing)
        ─► handwritten fields: PP-OCRv5 rec (digit-only CTC decode) or digit CNN for boxed cells
        ─► validate (range, regex, roster match, confidence) ─► review screen ─► Excel
```

1. **Template per college.** On one sample sheet the teacher draws a box around each field: reg no, Part-A, Part-B, optional per-question marks. Store boxes as normalized coordinates of the deskewed page, kept locally, one template per college or exam. This handles layouts that vary by college with only one sample each.
2. **Alignment.** After deskew, refine with ORB feature matching against the template image (`opencv_dart`) to absorb small shifts. Pad each ROI by a few percent.
3. **Recognition.** For handwritten fields, restrict CTC decoding to the expected charset (digits for marks, the reg-no pattern for IDs). A constrained charset is the largest cheap accuracy gain. For boxed digit cells, segment by box and classify each digit with the CNN.
4. **Confidence.** Field confidence = minimum per-character probability, not the mean. Agreement across the existing preprocessing variants can raise it. Anything below the threshold goes to review.
5. **Validation.** Keep the existing checks: range check against `partAMax`/`partBMax`, derived total, reg-no regex. Add two: if per-question marks exist, check that they sum to the part total; optionally import a class roster (Excel) and fuzzy-match reg numbers, flagging unknown or duplicate IDs.
6. **Learning from corrections.** Each correction on the review screen yields a labeled crop. Store these locally only. They grow the evaluation set, and later a fine-tuning set, without new privacy exposure.

Latency estimate (unverified): no detection pass is needed, because templates give the ROIs. That leaves recognition of about 3–15 small crops at ~10–40 ms each on CPU, plus ~100–300 ms for warp and alignment. This is well under 2 s. Measure on a real low-end device before claiming it.

## Plan with verification

1. Add `SheetTemplate` field boxes, plus a template editor screen. Verify: boxes drawn on a sample sheet reproduce the same crops after a re-scan.
2. Add page deskew and ORB alignment. Verify: on the 1–5 samples photographed at different angles, ROI crops contain the full field.
3. Convert `en_PP-OCRv5_mobile_rec` to ONNX and add `OnnxSheetRecognizer implements SheetRecognizer` with digit-constrained decoding. Verify: unit tests with saved crops; latency logged per field.
4. Benchmark harness (`test/` or a debug screen): run ML Kit, PP-OCRv5 and TrOCR-small on the same labeled crops, and report accuracy and ms per crop. Verify: table output on the samples. With fewer than 5 sheets, treat results as a smoke test, not as accuracy.
5. Add the roster import and the extra validation rules. Verify: unit tests for duplicates, unknown IDs and over-range marks.
6. Capture corrections as labeled crops. Verify: the corrected crop and its label persist locally.

## Open risks

- PP-OCRv5's handwriting claim comes from the vendor. It is untested on Indian exam handwriting, so step 4 decides.
- 1–5 samples are too few to measure accuracy. Real numbers need roughly 200 or more labeled mark crops, which step 6 collects.
- `google_mlkit_document_scanner` depends on Play services. Keep the OpenCV fallback.

## Update after implementation (2026-10-22, branch `cloud/recognition-pipeline`)

What the first real sample sheets (`sample_images/`, 9 photos of one college's
CAT answer book) changed in the plan:

- **Alignment: printed-text anchors replace ORB and the OpenCV fallback.**
  Most real photos fill the frame or cut off the left edge, so page-corner
  detection finds nothing useful (it returns roughly the whole frame on all 9).
  Instead, when the teacher creates a template, ML Kit (already in the app)
  reads the printed lines on the sample ("Registered No.", "Part-A Total",
  "GRAND TOTAL", ...), and those that occur once are stored as anchors. At scan
  time the same lines are found again, matched by text, and a RANSAC homography
  is fitted over their corner points (`AnchorAligner`). This works on cropped
  photos, needs no new native library, and costs one ML Kit pass. Corner
  detection (pure Dart, `PageAligner.detectPage`) and then the whole frame are
  the fallbacks. `opencv_dart` was not added: it would add native libraries to
  the APK for a fallback that the anchors make unnecessary, and pure-Dart
  geometry is unit-testable on the host.
- **Warp only the boxes.** Each template box is resampled straight from the
  photo through the homography; the full page is never warped at scan time.
- **Decode with the native decoder.** `package:image` JPEG decoding is slow in
  Dart; `PageLoader` uses the engine's decoder (downscaled, EXIF-aware).
- **Model: a custom CRNN-CTC (~1M params, ~3.9 MB fp32)** trained on EMNIST
  glyphs composed into exam-style crops, including one-character-per-box
  registration strips and digits floating in wide marks-table cells. Results
  and the PP-OCRv5 comparison are in `docs/PROGRESS.md`.
- **Confidence uses raw probabilities.** Decoding is restricted to the field's
  charset, but the confidence is the model's own probability for the chosen
  character (not renormalised over the allowed set), and is capped when a
  disallowed character was the model's clear favourite. Constraining can pick
  the right digit; it must not make a doubtful one look certain.
- **Registration mask** (`D`/`A`/`X` per position, e.g. `DDADDADDXX`) both
  repairs letter/digit swaps from the model's own per-frame second choice and
  flags incomplete numbers ("read 2 of 10").
- **Written totals are cross-checked, never used.** A grand-total cell or a
  "total in words" box is read as digits and compared with Part-A + Part-B; a
  mismatch forces review. Blank question and total cells are normal
  (examiners often fill only the part totals) and only need review when the
  model is unsure they are blank.
- **Boxes outside the photo** (slip cut off) are reported as such, not read.

## PP-OCRv5 comparison result (2026-10-22, session 2)

`en_PP-OCRv5_mobile_rec` (converted to ONNX, 7.8 MB) against the custom CRNN
v3 (3.9 MB) on the same synthetic held-out sets with the same charset-constrained
decoding and 0.80 gate: PP-OCRv5 marks exact 0.85–0.97 with 0.65–2.9% silent
errors; custom 0.98–0.996 with 0.2–0.7%. Registration numbers: 0.30–0.42 vs
0.68. ~45 ms vs 1.4–7.6 ms per crop (desktop, one thread). The vendor's
handwriting claim does not carry over to isolated exam digits; the custom
model stays. These sets come from the custom model's own generator, so real
sheets remain the deciding test (`docs/PROGRESS.md`).
