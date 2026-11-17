# 0004. Receipt ingest: a separate command-line tool for the OCR evaluation set

Status: accepted, after phase 2.

## Context

The OCR part of the project needs a test set: real receipts with known answers. The owner photographs
paper receipts with an iPhone, in batches, one to three photos per receipt. The photos are HEIC files
with EXIF data and a Display P3 colour profile. They are personal data.

A Ukrainian fiscal receipt carries a QR code that links to the tax service's receipt check page. The
link holds the total, the date and time, the fiscal number of the receipt and the fiscal number of the
cash register. A decoded code is therefore ground truth that costs nothing: OCR results can be compared
with it without anyone typing the answers.

Before any OCR model can be measured, the photos have to become a stable set: grouped into receipts,
numbered, converted to a format the app accepts, cleaned of metadata, and paired with whatever the QR
code gives.

## Decision

### A separate tool, not part of the app or of the ML service

`tools/receipt_ingest/` is a Python command-line program with its own `pyproject.toml`, lock file, tests
and CI job. It does not talk to the Rails app or to the ML service.

- Building an evaluation set is offline batch work on a folder. It needs no database, no web request and
  no background job.
- The ML service (`ml/`) stays small: it serves `/ocr` and `/categorise` and nothing else. The image
  libraries the tool needs (OpenCV, a QR decoder) are not dependencies of the service.
- The set must exist before the OCR backends do, so that they can be measured from their first version.

The one link to the app is the `fingerprint` field in `receipts.jsonl`. It follows `Receipt.fingerprint`
(`docs/domain.md`), and the images fit the app's limits (JPEG, 1 to 3 per receipt, under 15 MB each), so
the set can be uploaded later without conversion. The one exception is a receipt flagged `too_many_parts`:
it has more than three photos and has to be fixed in the override file first.

### Privacy rules

- Raw photos are opened read-only. The tool never modifies, moves, renames or deletes them and writes
  nothing inside the raw folder.
- The tool refuses an output folder that is inside the raw folder, contains it, or is inside any git
  repository. Folders are compared by what they are on disk, not by their names, so another spelling of
  the same folder (a symlink, other letter case on a Mac) is refused too. The output lives in a private folder outside the repository, with folder mode 700 and file
  mode 600.
- Every written JPEG is built from the pixels only. After writing, the tool opens the file again and
  fails if anything but the picture is left (EXIF, GPS, XMP, an ICC profile, a thumbnail, a comment). The
  capture time is read before the metadata is dropped.
- The console shows counts only. An error line may name a raw file by its relative name and the class of
  the exception, never the exception's message, an EXIF value or a QR payload.
- The tests generate every image they need. No image file is committed, and `.gitignore` refuses
  `*.heic`, `*.heif` and `rcpt_*.jpg` as a second line of defence.

### Stable numbering

A receipt set is only useful for comparing models if `rcpt_000123` means the same receipt every time.

- A receipt is identified by the SHA-256 of its earliest photo. The file name is only a label: a renamed
  file or batch folder keeps its receipt and number.
- A group whose earliest photo is already known keeps its number. New groups get the next free numbers.
  A number is never given to another receipt; a receipt that disappears (merged into another one,
  excluded) is recorded as retired, and gets its old number back if it returns.
- A receipt whose photos did not change is not encoded again, so its image hashes stay the same across
  runs. `state.json` in the output folder holds what this needs, together with the versions of the
  libraries that wrote each image. An upgrade of a library does not rewrite existing images.
- Output is never deleted because a raw photo is absent. A receipt that has lost a raw photo (a folder
  was moved, a file was deleted) is frozen: it keeps its number and its images and is flagged
  `raw_missing` until the photo is back. Only the override file, or a real regrouping with every photo
  present, changes or retires a receipt.
- A step that fails (a QR decode, a crop) never removes images that were already written. The receipt is
  flagged and the step is tried again on the next run.
- `state.json` is written before anything is deleted, so a run that is killed half way can be repeated.
- Grouping is by the pause between photos (more than 8 seconds starts a new receipt). Mistakes are fixed
  by the owner in `groups_override.yaml` (merge, split, exclude), which is applied on every run. A name
  in that file that matches no photo is an error.

The cost of identifying a receipt by its earliest photo: excluding that photo, or splitting a receipt,
gives the remaining photos a new number. This is accepted, because the alternative (an identity that
depends on the whole group) would renumber a receipt whenever a part is added to it.

### Libraries

- **Pillow + pillow-heif** decode the photos and write the JPEGs. They need no system library, so the
  tool behaves the same on the owner's Mac and in CI. The first plan was pyvips on Homebrew's libvips. It
  was dropped: the PyPI package cannot find the Homebrew library without a library path set before
  Python starts, and the package with its own bundled libvips cannot decode these photos (it has no HEVC
  decoder).
- **zxing-cpp** decodes QR codes. A plain decode found a code in few photos: thermal paper fades, and
  the codes are small and low in contrast. The tool therefore runs a short cascade of strategies
  (contrast enhancement at two sizes, then a second look at regions where the decoder saw a code but
  could not read it) and reports how many codes each strategy found and how long it took, so a strategy
  that does not pay for itself can be seen and removed. Strategies that found nothing extra on the
  owner's photos were removed (`tools/receipt_ingest/README.md` lists them).
- **OpenCV** (headless) does the image processing for the cascade and the receipt crop. The lock file is
  limited to macOS on Apple silicon and Linux x86-64, because the newest release on PyPI had Windows
  wheels only.

### What the QR fields mean

The tax service describes the parameters of the check link: `id` is the fiscal number of the receipt,
`fn` is the fiscal number of the cash register, `sm` is the amount, `date` and `time` are the moment of
the sale, and `mac` is required only for software registers working offline. So the tool maps `fn` to
the app's `fiscal_number` and `id` to `receipt_number`. The raw values are kept next to the cleaned ones.

Many receipts have no readable code, and a few carry other QR codes (promotions, payment). A
tax-service link always wins over another payload. A receipt without one is flagged, not dropped: it is
still a valid OCR test image, only without free answers.

## Consequences

- The repository has a second Python project. CI has a job for it, `bin/ci` runs its three checks, and
  Dependabot watches its lock file.
- The evaluation set and its state live only on the owner's machine. Losing `state.json` loses the
  numbering: a new run would number the receipts again from 1.
- The QR ground truth covers only part of the set. Receipts from older cash registers carry their fiscal
  data as plain text in the code; the tool keeps that payload but does not parse it yet.
- The crop is a convenience, not a guarantee. The full image is always kept, and a crop can be wrong.
