# 0010. Receipt ground truth: saved tax-service files, a store of its own, a tolerant reader

Status: accepted, with the ground-truth store, the import of saved receipt files and the export. The
reader's format is implemented from public documentation and not yet confirmed against a real file.

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
is the later "save as gold" path, for receipts without a saved file).

### A store of its own: one record per receipt and source

`receipt_ground_truths` holds, per receipt and source, a JSON document in the shape of the OCR contract's
receipt, money and quantities as decimal strings, with a schema version. Two writers are planned: this
import (`dps_xml`) and, later, a "save as gold" action in the review form (`manual`), whose record
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
to the minute in Kyiv time); a disagreement keeps the file out and names the receipt and the fields. A
receipt without a QR value is imported and counted as unverified.

### A tolerant reader, one class per format variant

The format of the saved file is not confirmed: the owner is trying three receipts by hand first. So the
reader is built to be corrected cheaply:

- the format knowledge sits in one small class per variant (`DpsXml::Check01`), chosen by looking at the
  document's root and structure; correcting it or adding a variant is a change to one class. A record
  remembers its variant's name and version, so a corrected variant reads the files again on the next run;
- unknown elements are ignored; a file without item lines gives a record without item ground truth; a
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

## Consequences

- Item-level scores become possible for the receipts with a saved file, with exact answers that no model
  helped make. The set is small (about fifty receipts) and chosen by a person, so the report says how it was
  chosen.
- Ground truth from a person (`manual`) and from a file (`dps_xml`) sit side by side and can be compared.
- After the owner's trial the reader will likely need a correction; the variant's version changes with it,
  and the next import replaces every unchecked record read by the old version.
- Deleting a receipt deletes its ground truth. The receipt load deletes only pristine receipts that left the
  ingest set; the import recreates a record from its file on the next run, but a person's check is lost.
