# 0018. Booking a receipt onto a ledger transaction the person chooses

Status: accepted. The undo of a booking (below, "Undo") came in a second change on the same decision.

## Context

The ledger holds the history of the bank accounts, imported row by row: about 24,800 transactions, of which
about 3,860 are `needs_review` (no category yet). Receipts are photographed, read by OCR, corrected in the
review form and accepted with `Receipts::Accept`. Until now "Accept" always created a new expense on the
account the form pre-selected, although the bank's transaction for the same purchase is almost always in
the ledger already: every accepted receipt counted the purchase twice.

`Receipts::Accept` could already rebook a receipt that had a transaction (it replaces the lines with the
items summed per category). What was missing was choosing that transaction. A check on the real data
(counts only): of 13 read receipts with a date, 12 had exactly one ledger expense of the same amount on the
same day and one had none; all 12 were `needs_review`, single-line, with a legacy category path and a
stored suggestion on the line; in 2 of the 12 the items did not sum to the bank amount.

The owner's requirements: show the candidate transactions on the review page; the person picks one or books
a new expense; never link without the person's choice; keep the transaction's old state so a rebook can be
undone; accepting a linked receipt never creates a second transaction.

## Decision

### The search is a query, the choice is the person's, the rules are Accept's

`ReceiptLinkCandidates` (a query object) lists expenses whose amount is minus one of the receipt's amounts
(the printed total, the items' sum or a slip's total, the QR total), not transfer legs, within two days of
the receipt's Kyiv date (`issued_at`, else the QR time; no date means no search, never "today"), on an
account in the receipt's currency (archived accounts and every status included), and reports apart the
ones another receipt is booked on. It ranks in Ruby (days, then the time gap, then whether the merchant
name matches, then the id) and shows twenty.

The window and the extra amounts are a **search filter, not a rule**. They decide what is worth showing; they
are not what makes a link correct. A bank can post a purchase days later, a receipt can be dated wrong by
OCR, and a person who knows better may link outside the window. So `Receipts::Accept` never searches: it
books onto the transaction it is given (`link:`), after checking only what must hold for any link: the row
still exists, it is at the version the person saw (`lock_version`), it is an expense and not a transfer leg,
no other receipt is booked on it, its account is in the receipt's currency. The form refuses only what is
stale: when the person accepts, `Receipts::Review` computes the list again from the values it has just saved,
in the same database transaction, and books nothing when the ids differ from those the page showed. That is
what makes a "new expense" chosen before a correction of the date or the total safe: a match that the
correction brings in cannot be passed over unseen.

Nothing is pre-selected while there is any match (a candidate, or one booked from another receipt); "a new
expense" is pre-selected only when there is none. Ctrl/Cmd+Enter without a choice is refused with a message.

An unknown receipt currency searches every account and links to any, as `Accept` already books an unknown
currency on any account: the amount still has to match exactly, and the person chooses.

### Items that do not sum to the bank amount are refused

When the items do not sum to the chosen transaction's amount, Accept refuses (`TotalMismatch`, the rule it
already had for "Accept again"); nothing is added to make them fit. A remainder line would book money under
a category nobody chose and hide an OCR error (a skipped line, a misread amount) that the person can fix in
the form. The candidate shows a danger badge, so the person sees it before accepting.

### The record of the booking is a table tied to the transaction

`receipt_bookings` (`ReceiptBooking`) holds one row per booked receipt, written by Accept on both paths:
`mode` (`linked` or `created`), `previous` (for `linked`: the transaction as it was before the first rebook,
a versioned JSON document with the amount and every line column, money as decimal strings, times to the
microsecond), what Accept left (a digest of the lines it wrote, with their comments and origins, and the
transaction's `lock_version` right after; both refreshed by every "Accept again"), the transaction's
`import_digest` at the first link, and which payee Accept assigned and whether it created it.

The version and the digest together are how an undo tells that somebody changed the transaction after the
booking: every writer of the row moves its version, except a line saved on its own with only a new comment
or category, which the digest sees. The suggestion job's refresh of a line's stored suggestion moves neither,
on purpose: a suggestion is nobody's choice and can be filled again.

Why a table and not columns on the receipt:

- the state belongs to the pair, and to the transaction most of all: a foreign key to the transaction with
  `ON DELETE CASCADE` makes the record disappear with the row it describes (the history import replaces a
  row by destroying and recreating it). Columns on the receipt would outlive the transaction and describe a
  row that no longer exists;
- unique indexes on both `receipt_id` and `transaction_id` restate "one receipt per transaction" where the
  undo will read it;
- the receipt row is the review form's record (`lock_version`, every form field); the booking record changes
  at other moments and must not move the form's version.

`previous` and the import digest are written at the first link only: "Accept again" rebooks the receipt's own
transaction, and the state to go back to is still the one from before the receipt touched it. The lines
digest is refreshed each time, so an undo can tell whether somebody changed the lines after the last
acceptance. The column list of a line in `previous` is fixed in the model (`ReceiptBooking::LINE_COLUMNS`), and
a test compares it with the table, so a new column cannot slip in or out of the document unversioned.

### Concurrency

Accept locks the receipt row, then the chosen transaction row, then its lines in id order (the suggestion job
writes lines without moving the transaction's version, as for `Transactions::Categorise`), and reads them
again. Two receipts choosing one transaction: the second waits for the first's row lock and then sees the
link (checked before the version, which the first booking also moved). The unique indexes are the backstop;
a violation is refused as `AlreadyLinked`, inside a savepoint so that PostgreSQL's aborted transaction does
not leak into the caller's. The history import destroys a row's lines before the row, the opposite order,
so the two can deadlock; that is rare, PostgreSQL breaks it, and the form says to try again (the importer is
not changed here).

### The migration does not roll back over records

Rolling the migration back would drop the only copy of the earlier state of every linked transaction while
the receipts' lines stay in the ledger. The rollback refuses while the table has a row.

## Undo

The owner's requirement: undo an acceptance so that the ledger is what it was, the receipt is back before the
acceptance, and nothing else is lost (items, their categories, ground truth). `Receipts::UndoAccept`, from
"Undo the acceptance" on the receipt's page.

### It undoes only what the acceptance left

The undo overwrites a transaction with a state recorded earlier. That is only right while nobody changed the
transaction since, so it refuses unless all of these still hold: the transaction's `lock_version` is the
record's `booked_lock_version`, its lines digest is the record's, and for a linked booking its `import_digest`
is the recorded one and its amount the one in `previous`. The version catches every writer of the row, the
digest a line saved on its own, the import digest an importer that rewrote the row (the export wins, as the
import contract says), and the amount is a backstop for a writer past the models. A refreshed stored suggestion
is in none of them on purpose: it is nobody's choice, and the undo restores the earlier suggestion anyway.
The alternative, merging a later change into the restored state, would need rules for every column and would
guess; a refusal that says what changed lets the person decide (put it back by hand, or keep the booking).

The button also carries the receipt's and the transaction's versions as the page showed them, so a tab opened
before an "Accept again" cannot undo the newer booking unseen. The service locks in Accept's order (receipt,
transaction, lines in id order), so the two cannot deadlock.

### The restored lines are new lines with the old values

The earlier lines are rebuilt as new line objects through the transaction (nested attributes without ids), so
the model's rules run: the lines sum to the amount, a category is a category and not a group. Their ids are
new; passing the old ids would make Rails look for rows that no longer exist. "Exact" means the values: every
recorded column but the ids, money from its decimal string (never a float), times to the microsecond, the
line's own `created_at` and `updated_at` as recorded (the old line put back; the transaction's own timestamp
and version show the undo).

A reference that no longer resolves is dropped, not guessed: a deleted category, or one turned into a group,
leaves the line without a category, which also clears the category's origin, probability and artefact (the
check constraints require a category for them); a missing suggested category drops the whole stored
suggestion, a missing runner-up only the runner-up. A `confirmed` transaction that thereby gets an
uncategorised line becomes `needs_review`, Accept's own rule. The page says what was dropped.

### Status, payee, created rows

The status comes back from `previous`. The payee comes back when the transaction's payee is still the one
Accept assigned, the earlier one, or none: a payee a person set between two acceptances (which the version
check cannot see, since "Accept again" refreshes it) is the person's and stays. A `created` booking's
transaction is destroyed with its lines; a transaction of source `receipt` without a record (from before
records existed) the same way, with its payee kept, since nothing says the acceptance created it; any other
transaction without a record is refused, since its earlier state is not known. The unrecorded `receipt` row is
deleted without the "unchanged since" check, for want of a baseline: a deliberate exception for a case only test
data has (the real data had no receipt booked without a record when the undo came); "Accept again" first writes a
record, after which the undo checks it.

A payee the acceptance created is deleted when no transaction, no other booking record and no linked booking's
`previous` names it any more, in a savepoint: if the delete is refused anyway, the payee stays and the undo
commits. An unused payee is harmless; a lost undo is not. Its row is locked with `SKIP LOCKED`: a writer about to
refer to it holds a key-share lock (the foreign key of a transaction it inserts, and
`Payee.find_or_create_by_name!` reads with one), and the payee is then kept rather than deleted under that
writer. When the payee is kept because another booking assigned it too, that booking inherits "Accept created
it", so the payee goes with whichever of the two is undone last, in either order.

A refusal for an edit made in the app (a category set from the transaction list, a comment) says that "Accept
again" makes the undo possible: it overwrites the lines anyway and records the transaction as it leaves it. A
later import or another amount cannot be got past that way.

### The receipt

The receipt goes back to `extracted` with no transaction and no record, through the same step a destroyed
transaction takes (`Receipt#release_from_ledger!`, `update_columns` that also move its `lock_version`). Its
items, categories, ground truth, OCR and QR columns, photos and OCR request are untouched. It is not pristine,
so the receipt load keeps it, and nothing queues OCR for it unless a person asks.

## The importer limit

The history import is not changed. Its contract is "the export wins": a row whose export row changed is
rewritten. For a linked transaction that means either the lines are rewritten in place (the receipt stays
linked and `reviewed`, and the stored digests no longer match: the undo can see it and must refuse), or the
row is destroyed and recreated (the record cascades away and the receipt returns to `extracted` through
`Transaction#release_receipt`, to be booked again). A re-import of an unchanged export keeps the receipt's
lines, as it keeps every edit made in the app.

## Consequences

- Accepting a receipt no longer double-counts a purchase the bank already reported, and the bank row gets the
  receipt's categories.
- Every refusal is a subclass of `Receipts::Accept::Error` and reaches the form as a message, including an
  account that is not the linked transaction's (it used to be a plain `ArgumentError`, a 500 page).
- The duplicate warning keeps only "another receipt not booked yet with the same date and total"; the ledger
  side is the "Book as" list.
- Receipts accepted before this change have no record (there were none in the real data); "Accept again"
  writes one (`created` for a transaction Accept created).
- An acceptance can be undone (restore `previous`, or remove a created transaction, and a payee Accept created
  that nothing else uses), and the undo refuses when the version, the digests or the amount say the row
  changed since. When a later export changed a linked row, the export wins and the undo refuses.
