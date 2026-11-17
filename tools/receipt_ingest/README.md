# receipt_ingest

A command-line tool that turns phone photos of paper receipts into a clean, numbered receipt set for
OCR evaluation. It groups the photos into receipts, gives every receipt a stable number, writes JPEG
copies without any metadata, reads the QR code (on a Ukrainian fiscal receipt it holds the total, the
date and time and the fiscal numbers, so it is free ground truth), crops the receipt out of the photo
and builds a contact sheet for checking the grouping.

It is a standalone tool: it does not talk to the Rails app or to the ML service. Its only link to the
app is the `fingerprint` value, which follows the app's rule (see "receipts.jsonl").

## Install

Python 3.12 and [uv](https://docs.astral.sh/uv/):

```sh
cd tools/receipt_ingest
uv sync
uv run receipt-ingest --help
```

`python -m receipt_ingest` works too. The lock file covers macOS on Apple silicon and Linux x86-64
only: `opencv-python-headless` 5.1.0.95 ships Windows wheels only, and limiting the lock to these two
platforms (`[tool.uv] environments` and `required-environments`) makes uv choose 5.0.0.93, which has
wheels for both.

## Usage

```sh
uv run receipt-ingest RAW_DIR OUT_DIR [--gap SECONDS] [--no-crop] [--redo-qr] [--redo-crop] [--jobs N]
```

- `RAW_DIR`: a folder of batch folders, `RAW_DIR/<batch>/…`. The batch is the name of the folder
  directly under `RAW_DIR`, whatever it is; inside a batch, folders are scanned recursively.
- `OUT_DIR`: where everything is written. It must be outside `RAW_DIR`, must not contain it, and
  must not be inside a git repository.
- `--gap SECONDS` (default 8): a pause between two photos that is longer than this starts a new
  receipt. Exactly 8 seconds keeps two photos together.
- `--no-crop`: make no new crops. Crops from earlier runs are kept while their receipt is unchanged.
- `--redo-qr`: decode the QR codes of every receipt again, not only of new or changed ones.
- `--redo-crop`: crop every receipt again.
- `--jobs N`: worker processes. The default is the CPU count minus two, between 1 and 8. `--jobs 1`
  runs everything in one process. The results do not depend on the number of jobs.

Exit codes: `0` success; `1` at least one receipt failed to process (the run still finishes and
writes everything else); `2` usage error, a refused output folder, an invalid
`groups_override.yaml` or an unusable `state.json`.

A second run over the same photos does almost nothing (about a second for 341 photos): it hashes the
raw files, finds every receipt unchanged and rewrites no file.

## What it does

1. **Scan.** Image files are `.heic .heif .jpg .jpeg` in any case. Everything else is counted as a
   skipped non-image: hidden files and folders, files directly in `RAW_DIR`, symlinks. An image that
   cannot be opened is skipped and named on stderr as `unreadable`. Each raw file gets the SHA-256
   of its bytes and its capture time from EXIF `DateTimeOriginal` + `SubSecTimeOriginal` +
   `OffsetTimeOriginal` (Kyiv time when the offset tag is missing).
2. **Duplicates and renames.** A file is identified by its SHA-256; the name is only a label. Of
   several files with the same bytes one is kept: the name recorded by the last run if that file is
   still there, otherwise the first in scan order; the others count as duplicates. A file that was
   renamed, or whose batch folder was renamed, keeps its receipt, number and images; only
   `raw_files` and `batch` change.
3. **Grouping.** Inside a batch, photos are ordered by capture time (then name); a gap longer than
   `--gap` starts a new receipt. Photos without a capture time come last, each as a receipt of its
   own. Groups never cross batches. A receipt with more than 3 photos gets `too_many_parts` but is
   written with all of them.
4. **Overrides** from `OUT_DIR/groups_override.yaml` (see below).
5. **Numbering** (see "Stable numbers").
6. **Convert** each photo to `images/rcpt_000123_N.jpg`.
7. **QR** decoding of the written JPEGs.
8. **Crop** of the written JPEGs.
9. **Write** `receipts.jsonl`, `groups_review.html`, `thumbs/` and `state.json`, and print a summary.

Converting, QR decoding and cropping run per receipt in a process pool.

## Output

All paths in the JSON files are relative to `OUT_DIR`. Folders get mode 700, files mode 600.

### images/

`rcpt_000123_1.jpg … rcpt_000123_N.jpg`, the photos of a receipt in capture order, at full
resolution, 8-bit RGB, JPEG quality 90. The orientation is applied exactly once (pillow-heif already
turns HEIC photos upright; JPEG photos are turned by their EXIF orientation). An embedded colour
profile (iPhone photos carry Display P3) is converted to sRGB; pixels without a profile are taken as
sRGB.

Then all metadata is removed: the JPEG is built from pixel data only, and the written bytes are
checked. Only the markers a bare JPEG needs are allowed (SOI, APP0/JFIF without a thumbnail, DQT,
SOF0-2, DHT, DRI, SOS, RST, EOI); there is no EXIF, GPS, XMP, ICC profile, MPF, Photoshop block or
comment, and nothing after the end of the image. A file must be smaller than 15 MB (the app's
`Receipt::MAX_IMAGE_BYTES`). A file that fails the check is never written, and its receipt fails.

`rcpt_000123_N_crop.jpg` is the crop of part N, written and checked the same way.

### receipts.jsonl

One line per receipt (raw-missing ones included), ordered by `receipt_id`, UTF-8, keys in this
order:

| Key | Meaning |
| --- | --- |
| `receipt_id` | `rcpt_000123` |
| `batch` | the batch folder name |
| `seq_in_batch` | 1-based position of the receipt in its batch, in capture order |
| `raw_files` | relative raw file names (`batch_02/IMG_0001.HEIC`), in capture order |
| `captured_at` | capture time of the first photo, ISO 8601 with offset and the recorded sub-seconds; `null` without a capture time |
| `images` | `[{file, sha256, width, height, bytes}]`, in part order |
| `fingerprint` | the app's `Receipt.fingerprint` of the images (below) |
| `qr_payload` | the chosen QR text, or `null` |
| `qr` | the raw query values `{date, time, id, sm, fn, mac}` of a tax-service URL (`null` for a missing key); `null` when the payload is not a tax-service URL |
| `qr_fields` | `{issued_at, total, fiscal_number, receipt_number}` read from `qr`; `null` when the payload is not a tax-service URL |
| `crop` | `[{file, sha256, width, height, bytes, part, quad}]`; present only when the receipt has crops. `quad` is the four corners in the full image (top left, top right, bottom right, bottom left) |
| `flags` | see below |

`fingerprint` equals the Rails app's `Receipt.fingerprint` (`app/models/receipt.rb`,
"Fingerprint" in `docs/domain.md`): with one image, the SHA-256 hex of its bytes; with several, the
SHA-256 of the per-image lower-case hex digests, sorted and joined with no separator. Crops are not
part of it. Uploading the `images` of a line to the app gives a receipt with the same `sha256`.

`qr_fields`:

- `issued_at`: `date` + `time` as Kyiv local time, ISO 8601 with offset; seconds are `00` when the
  time has none. Times come as `HHMM`, `HHMMSS`, `HH:MM` or `HH:MM:SS`.
- `total`: `sm` as a decimal string with exactly two places (`123` → `123.00`). Read with
  `decimal.Decimal`, never a float.
- `fiscal_number`: `fn`, 10 digits.
- `receipt_number`: `id`, digits on most receipts; letters, digits, `-` and `_` on some.

A field that cannot be read is `null`, and the receipt gets `qr_fields_partial`.

### Flags

| Flag | Meaning |
| --- | --- |
| `no_capture_time` | a photo has no EXIF capture time |
| `too_many_parts` | more than 3 photos; fix it with an override if it is wrong |
| `raw_missing` | none of the receipt's raw files is in `RAW_DIR` any more; its output is kept as it was |
| `processing_failed` | converting, decoding or cropping failed; the receipt has no images and is tried again on the next run |
| `no_qr` | no QR code was read from any photo |
| `qr_not_tax_url` | a QR code was read, but none is a tax-service URL |
| `qr_conflict` | two different tax-service URLs in one receipt, or (with no tax URL) two different other payloads |
| `qr_fields_partial` | some field of the tax-service URL could not be read |
| `crop_failed` | at least one photo of the receipt has no crop |

### groups_review.html and thumbs/

A static contact sheet: one section per batch, one card per receipt with its number, flags, a QR
status word (`tax`, `other` or `none`, never the payload), and under each thumbnail the relative raw
file name, which is what the override file needs. Excluded files are listed by name at the end of
their batch. Inline CSS only, no script and no external resource; light and dark mode follow the
system. `thumbs/rcpt_000123_N.jpg` are stripped JPEGs, 320 px on the long side.

### state.json

The memory between runs: `next_id`, the active receipts (with their key, part hashes, images,
thumbnails, the cached QR result with the strategy that found each code, the crop result, and the
tool and library versions that wrote the images) and the retired numbers with the reason. It holds
no run timestamps, so an identical run leaves it byte for byte the same. Do not edit it by hand.

`receipts.jsonl`, `groups_review.html` and `state.json` are replaced only when their content changes.

### Summary

The tool prints counts only: per batch and in total the receipts, images, receipts with a decoded QR
(count and share), receipts with a tax-service QR and the flags by kind; then the QR codes found by
each strategy and the seconds spent in it during this run; crops made and failed; files skipped as
duplicates, non-images and unreadable; and what the run did (receipts new, unchanged, rewritten,
restored, retired, raw missing, failed; images, crops, thumbnails and metadata files written; files
deleted).

## The override file

`OUT_DIR/groups_override.yaml` corrects the grouping. It is read on every run; a missing or empty
file means no overrides.

```yaml
merge:   [[batch_02/IMG_0012.HEIC, batch_02/IMG_0013.HEIC]]   # these files are one receipt
split:   [batch_02/IMG_0040.HEIC]                              # a new receipt starts at this file
exclude: [batch_03/IMG_0101.HEIC]                              # not a receipt
```

The names are the relative raw names shown in `groups_review.html`. Order of application:

1. group by the time gap;
2. `exclude` removes files from their groups. A group that becomes empty disappears; removing a
   photo from the middle does not split its group;
3. `split` starts a new receipt at each listed file (nothing happens at the first file of a group);
4. `merge` joins the whole groups that contain the listed files; the photos stay in capture order.
   Entries that share a group join into one receipt.

Errors stop the run with exit code 2 and a message that names the key and the entry: an unknown
top-level key, a wrong shape (a merge entry needs two or more names), a name that is not a scanned
raw file (a duplicate's name counts as unknown: use the kept one), a file that is both excluded and
used in `merge` or `split`, and a merge across batches.

## Stable numbers

A receipt's key is the SHA-256 of its earliest photo. Numbers are `rcpt_000001`, `rcpt_000002`, …;
`next_id` only grows.

- A group whose key is known keeps its number. That includes a retired key: a receipt that comes back
  (for example after a merge override is removed) gets its old number back. A number is never given
  to another key.
- New groups get the next free numbers in the order batch name, capture time, file name.
- A recorded receipt with no group this run is kept with `raw_missing` when none of its raw files is
  in the scan (output is never deleted because raw files are absent). Otherwise it is retired with a
  reason (`merged`, `excluded`, `regrouped`, or `failed` for a receipt that never got images and
  whose raw file is gone), and its images, crops and thumbnails are deleted.

What follows from this:

- after a merge, the earlier receipt keeps its number and the later one is retired (`merged`);
- after a split, the tail gets a new number;
- excluding the earliest photo of a receipt retires its number (`excluded`), and the remaining photos
  get a new number;
- removing an override brings the old numbers back;
- `seq_in_batch` of a raw-missing receipt is the one from the run that last saw it.

When the list of photo hashes of a receipt is unchanged, nothing of it is encoded again: its image
bytes and hashes stay the same across runs, and library upgrades do not change them. When the list
changed, only that receipt's images, crops, thumbnails and QR result are redone, and files that no
longer belong to it (a `_3` after a split) are removed. An image that is missing on disk or has a
different size is written again. Files in `images/` and `thumbs/` that match the tool's own naming
but belong to no receipt are deleted; other files there are left alone. Temporary files left by a
killed run are removed at the start.

## QR codes

Only QR codes count (receipts also carry linear barcodes). Each photo goes through a cascade of
strategies, cheapest and most productive first, and stops as soon as a tax-service URL is found;
other payloads (promo or payment codes) are kept as a fallback while the cascade goes on. Per
receipt, `qr_payload` is the tax-service URL if any photo has one, otherwise the first other payload
in part order.

The cascade works on the written JPEG in greyscale, so `--redo-qr` needs no raw file:

| Strategy | What it does |
| --- | --- |
| `clahe_half` | half size (`INTER_AREA`), local contrast enhancement (CLAHE, clip 2, 8×8 tiles), zxing-cpp |
| `clahe_full` | the same at full resolution |
| `region_rescue` | where zxing found a QR code but could not read it (checksum errors), a crop of that region: upscaled 2× with CLAHE and a 5×5 minimum filter (global binariser), then at 1× with 3×3 minimum filters and an opening at different CLAHE strengths |
| `clahe_strong_half` | half size with a stronger CLAHE (clip 4, 16×16 tiles) |

Thermal receipts fade; many codes are pale, low in contrast and small, with white holes in the dark
modules. That is why contrast enhancement and the minimum filter matter more than anything else.

Measured on the owner's 341 photos (300 receipts):

| | photos with a tax-service code | photos with any QR code |
| --- | --- | --- |
| plain greyscale at full, half and quarter size | 23 | 35 |
| this cascade | 62 | 87 |

| Strategy | codes found | CPU seconds for all photos |
| --- | --- | --- |
| `clahe_half` | 60 | 7.6 |
| `clahe_full` | 8 | 22.5 |
| `region_rescue` | 19 | 1.4 |
| `clahe_strong_half` | 1 | 6.4 |

Tried and left out because they found no tax-service code that the cascade misses: plain greyscale
at full, half, third, quarter and sixth size; zxing's `GlobalHistogram` binariser on the plain image;
Otsu and adaptive thresholds; unsharp masking; illumination flattening; overlapping tiles at full
resolution and upscaled 2×; OpenCV's `QRCodeDetector` and `QRCodeDetectorAruco`. Many photos have no
readable code at all (faded, cut off, or the code is on another photo of the same receipt), so most
receipts end with `no_qr`.

Some receipts from older cash registers carry their fiscal data in a multi-line text QR code instead
of a URL. The tool keeps such a payload and flags it `qr_not_tax_url`; it does not parse it.

### The tax-service URL

A tax-service URL has the scheme `http` or `https`, the host `cabinet.tax.gov.ua` (any case) and the
path `/cashregs/check` (a trailing slash is fine); the query keys can come in any order. The keys, as
the tax service describes its receipt check page:

- `id`: the fiscal number of the receipt;
- `fn`: the fiscal number of the cash register (RRO or software PRRO);
- `sm`: the amount, with a dot as the decimal separator;
- `date`: `yyyyMMdd`;
- `time`: `HHmm` (one official page says `HHmmss`);
- `mac`: a checksum, required only for offline software registers, so it can be missing.

So `fiscal_number` comes from `fn` and `receipt_number` from `id`. Sources:
<https://lv.tax.gov.ua/kampaniya-prro/907269.html> and
<https://tax.gov.ua/baneryi/programni-rro/povidomlennya-rozyasnennya/print-648574.html>.

## Crop

A deterministic OpenCV crop, on by default. On a copy 1000 px on the long side: blur, Otsu
threshold, then an opening that removes bright parts narrower than 6% of the frame (strips of tape
that stick out past the paper, thin bridges to a lamp reflection). The largest bright shape is
approximated by four corners, which must pass these checks: the shape covers at least 8% of the frame
and the four-sided outline at most 92% (more is practically the whole frame), the shape fills at
least 90% of the outline and the outline covers at least 90% of the shape, every corner is between
65° and 115°, and the inside is clearly brighter than the outside. When a check fails, stricter
masks are tried (a threshold above Otsu's, a wider opening). The four corners are then scaled to the
full image and warped to an upright rectangle.

No good shape means no crop file and `crop_failed`; the full image is always kept. The result is
cached in `state.json` and not retried unless `--redo-crop` is given or the receipt's photos change.
On the owner's photos 332 of 341 photos got a crop; the failures are crumpled or curled receipts.
A crop can still be wrong (for example only part of a receipt that a strip of tape cuts across), so
check them before trusting them.

## Privacy

- Raw files are opened read-only and never modified, moved, renamed or deleted; nothing is written
  inside `RAW_DIR`.
- `OUT_DIR` must be outside `RAW_DIR`, must not contain it and must not be inside a git repository
  (the tool looks for a `.git` folder or file in the output folder and every folder above it). Keep
  the output in a private folder outside any repository.
- Output folders get mode 700 and files mode 600, set explicitly. Every file is written atomically.
- Written JPEGs carry no metadata (checked after writing, see "images/").
- The console shows counts only. The only names it prints are batch names in the summary and, in an
  error line, the relative name of a raw file with the class name of the exception. It never prints
  an exception message, an EXIF value, a QR payload or a parsed QR field.
- `groups_review.html` shows no payload, only the status word.
- No image goes into git: the tests generate every image they need.

## Development

```sh
uv run ruff check .
uv run ruff format --check .
uv run pytest            # 80% line and branch coverage minimum
```

The tests use synthetic data only: small generated images, an invented tax-service URL, a hand-made
Display-P3-like ICC profile and hand-written EXIF with GPS and a thumbnail. The HEIC tests are skipped
when the local libheif has no HEIC encoder.
