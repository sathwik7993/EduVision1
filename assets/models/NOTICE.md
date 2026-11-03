# Bundled models

| File | What | Source | License |
|---|---|---|---|
| `field_recognizer_v2.onnx` | Handwriting CRNN for marks and registration numbers (v4) | trained by `training/recognizer/` | project's own |
| `ppocr_v3_det.onnx` | PP-OCRv3 text detection, used once per new sheet layout to find printed labels | PaddleOCR `ch_PP-OCRv3_det_infer`, ONNX from RapidOCR 1.2.3 | Apache-2.0 |
| `ppocr_v3_rec.onnx` | PP-OCRv3 text recognition (character list in the model metadata) | PaddleOCR `ch_PP-OCRv3_rec_infer`, ONNX from RapidOCR 1.2.3 | Apache-2.0 |

PaddleOCR: https://github.com/PaddlePaddle/PaddleOCR (Apache License 2.0).
RapidOCR: https://github.com/RapidAI/RapidOCR (Apache License 2.0).
