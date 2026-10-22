# Sample exam sheets

Real photos of one college's answer-book cover (CMR College of Engineering &
Technology, Continuous Assessment Test). Use them as a **reference and as test
fixtures only**. Other colleges use different layouts, so nothing may be
hard-coded to this sheet. It should become one saved template among many.

These photos contain real student registration numbers. Keep them in this
private repo only. Never upload them to Kaggle, Hugging Face or any other
external service. They must not be used as training data on remote machines.

## Layout (this college)

- **Registered No.**: 10 printed boxes, one handwritten character per box,
  top-right under the title.
  Format follows the JNTU-H style: `YY` + college code (`H5`) + entry type
  (`1` regular, `3`/`5` lateral) + `A` + branch (`66`) + 2-char roll (`09`, `D9`, `K1`).
  Regex candidate: `^\d{2}[A-Z]\d[0-9][A-Z]\d{2}[A-Z0-9]{2}$`.
  Positional repair is possible: `H` written like `+1`, `1` like `|`, `A` like `^`, `D` vs `0`.
- **Marks slip** at the bottom, labelled "To be filled in by the Examiner only":
  - PART-A row: Q.No 1–10 marks cells, then a **Part-A Total** cell.
  - PART-B row: Q.No 11–17 marks cells (3 struck cells), then a **Part-B Total** cell.
  - **GRAND TOTAL** cell, plus a "Grand Total in Words" line.
  - Examiners often fill **only the totals**, leaving per-question cells empty.
- Other fields (Subject, Date, Semester, Booklet number) are mostly blank or optional.

## Observed capture conditions

Full page, page cropped on the left, slight rotation and perspective, a red
patterned background, a phone screenshot that includes the old app UI, faint
pencil-like strokes, and stray marks in empty cells.

## Ground truth (my reading — owner should verify)

| File (WhatsApp Image 2026-10-22 at …) | Reg No | Part-A | Part-B | Grand total | Notes |
|---|---|---|---|---|---|
| 12.13.28 PM | 23H51A66K1 | — | — | — | marks slip empty |
| 12.13.29 PM | 23H53A66D9 | 40 | 80 | (blank, stray mark) | subject EDC; "in words" says 30 → **inconsistent**, must flag |
| 12.13.29 PM (1) | 23H53A66D9 | 40 | 80 | (blank) | same sheet, second photo |
| 12.13.30 PM | 23H53A66D9 | 40 | 80 | (blank) | screenshot of old app; old app output total 120 |
| 12.13.30 PM (1) | 23H53A66D9 | 40 | 80 | (blank) | left side cropped, red background |
| 12.13.31 PM | 23H51A66D9 | 10 | 20 | 30 | left side cropped |
| 12.13.32 PM | 23H51A66D9 | 10 | 20 | — | heavily cropped, slip partly cut off |
| 12.13.33 PM | 23H51A66D9 | 10 | 20 | 30 | clean full page |
| 12.13.34 PM | 23 (rest empty) | — | — | — | incomplete reg no, must flag |

Validation cases these photos show:
- Part-B 80 exceeds the default `partBMax` 60.
- The grand total and the total in words disagree with Part-A + Part-B.
- Reg no is incomplete.
- Empty slip.
- Duplicate scans of the same student, which must not create duplicate rows.
