# Bundled models

| File | What | Source | License |
|---|---|---|---|
| `field_recognizer_v3.onnx` | Handwriting CRNN for marks and registration numbers (training run v5: v4 fine-tuned with single comb-box crops) | trained by `training/recognizer/` | project's own |
| `ppocr_v3_det.onnx` | PP-OCRv3 text detection, used once per new sheet layout to find printed labels | PaddleOCR `ch_PP-OCRv3_det_infer`, ONNX from RapidOCR 1.2.3 | Apache-2.0 |
| `ppocr_v3_rec.onnx` | PP-OCRv3 text recognition (character list in the model metadata) | PaddleOCR `ch_PP-OCRv3_rec_infer`, ONNX from RapidOCR 1.2.3 | Apache-2.0 |
| `ppocr_v5_rec.onnx` | PP-OCRv5 mobile text recognition, reads handwritten text fields (names, courses); character list added to the model metadata from its `inference.yml` | Hugging Face `PaddlePaddle/PP-OCRv5_mobile_rec_onnx` (sha256 of the original `inference.onnx`: da72dc72ca4dc220df0dfde68c1dedc31c58d3e76a25871122e5056227d50092) | Apache-2.0 |

PaddleOCR: https://github.com/PaddlePaddle/PaddleOCR (Apache License 2.0).
RapidOCR: https://github.com/RapidAI/RapidOCR (Apache License 2.0).
