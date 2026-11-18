# 0010. Receipt ground truth: saved tax-service files, a store of its own, a tolerant reader

Status: accepted, with the ground-truth store, the import of saved receipt files, the export, and manual
ground truth with categories from the review form (labelling). The reader's format is implemented from
public documentation and not yet confirmed against a real file.

## Context

The capstone's main measurement is how well a local model reads receipt photos. The QR code on a
Ukrainian fiscal receipt already gives exact answers for the total, the date and time and the two fiscal
numbers, so those fields are scored without anyone typing. The items, which are most of what a receipt
says and what categorisation needs, have no such source on the paper.

The tax service keeps every fiscal receipt. Its receipt page, opened by a signed-in person, shows the
whole receipt, items included, and lets them save it as an XML file. The tax service's programmatic access
to receipts is suspended. A program could still imitate the page (call the endpoint the page uses, or
replay a browser session), but that would be scripting around a decision the tax service made, with the
owner's credentials, against a service that is not ours.

## Decision

### Item ground truth comes from files a person saves by hand

The owner opens the receipt page for a receipt and saves the file, about fifty receipts in all, one file
per receipt, named after the receipt's ingest number (`rcpt_000123.xml`), into a private folder outside the
repository (`~/Documents/money_bin_data/dps_xml/`). The app reads those local files and nothing else.

There is no request to any tax-service endpoint anywhere in this repository: no HTTP client for it, no
token, no setting or environment variable for one, no rate limit, nothing in the tests that fetches. The
files stay where the owner put them and are only read. Real files never enter git; the tests use invented
documents written by hand. The data is personal (shops, items, amounts, times), so the import prints counts
and receipt ids only, and the export refuses a folder inside a git repository.

Rejected: calling the documented interface (suspended); calling the page's own endpoint or driving a
browser from code (scripting around the suspension); typing the items in by hand for every receipt (that
is the manual path below, for receipts without a saved file).

### A store of its own: one record per receipt and source

`receipt_ground_truths` holds, per receipt and source, a JSON document in the shape of the OCR contract's
receipt, money and quantities as decimal strings, with a schema version. Two writers are planned: this
import (`dps_xml`) and "Save as ground truth" in the review form (`manual`), whose record
remembers which model pre-filled the form (`prefilled_by`), because a person correcting a model's answer
leans towards it, so that record cannot test that model. Whether the source gave item lines at all is a
column of its own (`items_known`), because "no items on the receipt" and "no item lines from the source"
are different facts. An imported record keeps the file's SHA-256 and the format variant that read it,
never the file's path or content, and can be checked against the print by a person; a checked record is
not replaced by a later import.

The store is separate from booking. The receipt's own columns and items are the ledger's working copy,
corrected at review and changed again later; if the evaluation's answers lived there, a model would be
scored against values it helped produce. So the import never writes a receipt, an item, a transaction or an
OCR or QR column, and none of those writers touch the store.

Rejected: ground-truth columns on `receipt_items` (they would move with every review, and a receipt has a
different number of items per source); one row per item (the evaluation always reads a receipt as a whole,
and two sources would need a join to compare); a JSON column on `receipts` (two sources, their own
provenance and check state).

### Cross-check against the QR code before anything is stored

A file saved under the wrong number would quietly teach the evaluation wrong items. Every file is compared
with the receipt's QR values where both have one (register number, receipt number, total, date and time
to the minute in Kyiv time); a disagreement keeps the file out and names the receipt and the fields. The
register number is shared by every receipt of a shop's register, so it proves nothing alone: a file must
also match on the receipt's own fiscal number, or on the total and the time together, to count as
verified. A file that cannot show this is imported as unverified, as a receipt without QR values is: only
a disagreement is evidence of a wrong file. When the QR code has those values and the file lacks them, the
import warns with the receipt's id, because the likeliest cause is a format the reader misreads. The export
repeats the check and writes its status (`agrees`, `disagrees`, `unverifiable`, `no_qr`), so the evaluation
can keep to verified records, and a record that later QR values contradict is marked rather than silently
kept.

### A tolerant reader, one class per format variant

The format of the saved file is not confirmed: the owner is trying three receipts by hand first. So the
reader is built to be corrected cheaply:

- the format knowledge sits in one small class per variant (`DpsXml::Check01`), chosen by looking at the
  document's root and structure; correcting it or adding a variant is a change to one class. A record
  remembers its variant's name and version, so a corrected variant reads the files again on the next run;
- unknown elements are ignored; a file without item lines gives a record without item ground truth, and so
  does a file with an item row the reader cannot keep (a shorter list would pass for a complete one); a
  value that is not an exact decimal is left out and counted, never rounded; a file that is not a receipt
  or not well-formed XML is skipped and counted; one bad file never stops the others;
- it is safe against hostile files: a size limit, no document type declaration (no entity expansion, no
  external entities), no network, a strict parse.

The first variant implements the publicly documented layout of a software cash register's receipt
document: a `CHECK` root; `CHECKHEAD` with the document type and subtype (sale or return), the seller and
the point of sale, `ORDERDATE` (`ddmmyyyy`) and `ORDERTIME` (`hhmmss`), the register's fiscal number
(`CASHREGISTERNUM`) and the receipt's (`ORDERTAXNUM`); `CHECKTOTAL` with `SUM`; `CHECKBODY` rows with
`NAME`, `AMOUNT` (the quantity), `PRICE`, `COST` and `DISCOUNTSUM`; payment and tax rows, which it does not
use. These parts are guesses until a real file confirms them:

- that the saved file is this document at all, rather than another rendering of the receipt;
- that money is in hryvnias with decimals (not kopecks), and therefore that the currency is UAH;
- that `COST` is before the discount and the item's amount is `COST - DISCOUNTSUM`; that a negative
  `DISCOUNTSUM` is a surcharge; that a receipt-level discount does not also appear as a row;
- that the seller (`ORGNM`, else `POINTNM`) is what OCR calls the merchant;
- the encodings (UTF-8 or Windows-1251 declared in the prolog, a byte-order mark tolerated) and the decimal
  separator (a comma is accepted).

### Manual ground truth: a snapshot from the review form, with categories

The owner labels receipts in the review form they already use for booking: correct, then "Save as ground
truth". The record is a snapshot of the receipt as stored after that save (the form is saved first, in the
same database transaction), so it holds exactly what the person saw saved, and nothing that happens to the
receipt or the ledger later reaches it. Labelling and booking stay apart: saving ground truth never books or
moves a status, and booking never writes ground truth. A booked receipt is snapshotted only as it stands
(changing it is "Accept again"). Replacing a record asks first, with a short count of what changes; the
confirmation is bound to the exact old and new content, so it cannot approve differences the person did not
see.

The record remembers what pre-filled the form (`prefilled_by`: a model's name, `source:hand`,
`source:dps_xml`), derived from the receipt: the model and prompt version that `Receipts::ApplyOcr` wrote
(a new column, `ocr_prompt_version`, because "Enter by hand" replaces `ocr_raw` while keeping a failed
receipt's earlier items), or `filled_from` when the person filled the form from the tax-service record. A
new OCR answer replaces fields and items and clears `filled_from`, so the record names whatever answer the
form really held; a form open during a re-read is refused as stale. The rule is the conservative one: any
version or prompt of a model counts as that model, and a form a model filled stays that model's even if the
person retyped everything.

Rejected: deriving `prefilled_by` from `ocr_raw` alone (lost on "Enter by hand"); a per-receipt history of
every answer the person ever saw (memory cannot be tracked anyway, and the stale-form refusal already
prevents the case that matters); storing ground truth when booking (a booked receipt is not necessarily
read right, and a labelled one need not be booked).

### Categories in the document, as slugs, in schema version 2

The item categoriser is evaluated against the categories a person chose, so the document carries them:
`category_slug` on each item and, for a card slip, on the receipt, the key the ML service's contract uses.
Slugs, not ids or names: a slug is stable across a rename and readable offline. `categories_known` is a
column, as `items_known` is: a person may save without categories, and then none is stored rather than a
half-finished set. The same pre-fill rule applies to the categoriser: `categories_prefilled_by` records
`receipts.categoriser_model_name` when suggestions were on the form (`source:unknown` when their source is
not recorded), so the evaluation can leave the record out for that categoriser.

Imported records have no categories. Both schema versions stay readable instead of rewriting stored rows:
a checked imported record is a person's judgement about that content, and the shape change adds nothing to
it. Readers go through one upgrade function, every writer writes version 2, and the export writes one shape
(version 2) with the stored version alongside. The import treats an unchanged file over a version 1 record as
unchanged, so a checked record never becomes a conflict through the version change.

Rejected: a data migration rewriting every record to version 2 (it would touch checked records and add
nothing); categories in a separate table (the evaluation reads a receipt as a whole, as for items).

## Consequences

- Item-level scores become possible for the receipts with a saved file, with exact answers that no model
  helped make. The set is small (about fifty receipts) and chosen by a person, so the report says how it was
  chosen.
- Ground truth from a person (`manual`) and from a file (`dps_xml`) sit side by side and can be compared,
  except where the person filled the form from the file (`prefilled_by` says so).
- Labelling is a review-form workflow: a receipt list filter for what is left, "Next receipt to label", and
  a keyboard shortcut. The categoriser can be evaluated once enough items are labelled with categories.
- After the owner's trial the reader will likely need a correction; the variant's version changes with it,
  and the next import replaces every unchecked record read by the old version.
- Deleting a receipt deletes its ground truth. A receipt with ground truth no longer counts as pristine, so
  the receipt load keeps it (and reports it) instead of deleting it or replacing its photos.
- A record whose file is refused later (a disagreement, too few values) stays until a person deals with
  it; the export marks it with the current check.
