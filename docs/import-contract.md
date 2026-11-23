# History import: the export contract

The history importer loads an export of the previous version of the app into the ledger:

```sh
bin/rails "import:money_bin[/path/to/export]"            # import
DRY_RUN=1 bin/rails "import:money_bin[/path/to/export]"  # do everything, print the counts, roll back
```

This document is the contract between the exporter (a task in the previous app, written separately) and
the importer (`app/services/legacy_import/`, `lib/tasks/import.rake`). Schema version: **1**.

## Where the export lives

The real export holds personal data. Keep it **outside this repository**, for example in a private folder
under your home directory, and pass its path to the task. Never copy it into the repository (a folder named
`data` is ignored at any depth, but the safe place is outside the tree). The only export in the repository
is the invented fixture `test/fixtures/files/legacy_export/`.

## Files

An export is one folder with five files. All are UTF-8.

| File | Format | Content |
|---|---|---|
| `MANIFEST.json` | one JSON object | what the export is and how to check it |
| `accounts.jsonl` | JSON Lines | one account per line |
| `categories.jsonl` | JSON Lines | one old category per line, with its mapping |
| `payees.jsonl` | JSON Lines | one payee per line |
| `transactions.jsonl` | JSON Lines | one transaction (or transfer leg) per line, with its lines |

**JSON Lines**: one JSON object per line, separated by `\n`. A final newline after the last line is
optional (and recommended). Empty lines are not allowed. A file with no rows is an empty file (0 bytes).

**General rules for the data files**

- Every key listed below must be present in every row, also when its value is `null`. The only exception is
  a line's `comment`, which may be left out.
- Keys that are not listed are ignored; the importer prints a warning that names them.
- `legacy_id` is a JSON integer or a non-empty string. It is compared as text, so `12` and `"12"` are the
  same id. A string id must not be blank and must not start or end with a space (or any other whitespace):
  the app strips stored ids, so such an id could not be found again. It must be unique inside its file. References (`account_legacy_id`, `payee_legacy_id`,
  `category_legacy_id`) follow the same rule and must name a row of the referenced file.
- Every amount is a **decimal string**: an optional `-`, digits, and optionally `.` and digits, with at most
  two decimal places (`"-1250.50"`, `"7"`, `"0.05"`). Not a JSON number, no `+`, no exponent, no thousands
  separator, no comma. Zero is refused. The magnitude must be below 10^13.
- Dates are `"YYYY-MM-DD"`. Times are ISO 8601 with seconds and an offset: `"2026-01-10T09:00:00+02:00"`,
  `"2026-01-15T07:45:00Z"`. An optional fraction of a second with at most six digits (`"...:00.250+02:00"`)
  is allowed; the database keeps microseconds, so a seventh digit is refused rather than rounded.
- Currencies are ISO 4217 codes, three upper-case letters (`"UAH"`).
- "string" below means a JSON string; "or null" means the value may be `null`.

### `MANIFEST.json`

| Key | Type | Meaning |
|---|---|---|
| `schema_version` | integer | must be `1` |
| `exported_at` | string or null | when the export was made (ISO 8601); informational |
| `legacy_git_sha` | string or null | the commit of the previous app that made the export; informational |
| `date_from` | string or null | first date of the exported window (`YYYY-MM-DD`), null when open |
| `date_to` | string or null | last date of the exported window, null when open |
| `counts` | object | file name → number of lines in that file |
| `sha256` | object | file name → SHA-256 of the file's bytes, 64 hex characters |
| `warnings` | array | anything the exporter wants to say; the importer prints only how many there are |

`counts` and `sha256` must list exactly the four data files (`accounts.jsonl`, `categories.jsonl`,
`payees.jsonl`, `transactions.jsonl`), no more and no fewer. The line count is the number of `\n` characters,
plus one when the file is not empty and does not end with `\n`. The hash is over the exact bytes of the
file. Each file is read once, and its rows are parsed from the bytes that were hashed, so a file that
changes during the import is never read unchecked.

### `accounts.jsonl`

| Key | Type | Meaning |
|---|---|---|
| `legacy_id` | integer or string | the old account id |
| `name` | string, not blank | the account name; unique among the accounts of the export (after squishing whitespace) and in the app |
| `kind` | string | one of `cash`, `debit`, `credit`, `savings`, `ewallet`, `business` (the final kind: the importer does not translate) |
| `currency` | string | ISO 4217 code |
| `archived` | boolean | `true` for a closed account |

### `categories.jsonl`

| Key | Type | Meaning |
|---|---|---|
| `legacy_id` | integer or string | the old category id |
| `legacy_path` | string, not blank | the old category path as people saw it (`"Food / Snacks"`) |
| `group_en` | string or null | the group name in the new taxonomy (`db/seeds/taxonomy.yml`), null when unmapped; a blank string is refused |
| `category_en` | string or null | the category name inside that group, null when unmapped; a blank string is refused |

### `payees.jsonl`

| Key | Type | Meaning |
|---|---|---|
| `legacy_id` | integer or string | the old payee id |
| `name` | string | the payee name; must not be blank after normalisation |

### `transactions.jsonl`

| Key | Type | Meaning |
|---|---|---|
| `legacy_id` | integer or string | the old transaction id |
| `account_legacy_id` | integer or string | the account (in `accounts.jsonl`) |
| `occurred_on` | string | the calendar date (`YYYY-MM-DD`), taken as given |
| `occurred_at` | string or null | the exact time with its offset, or null when unknown |
| `amount` | decimal string | signed, in the account currency: an expense negative, an income positive |
| `currency` | string | must equal the account's currency |
| `original_amount` | decimal string or null | the operation amount in another currency (a USD purchase on a UAH card); same sign as `amount` |
| `original_currency` | string or null | its currency; set together with `original_amount`, and different from `currency` |
| `payee_legacy_id` | integer, string or null | the payee (in `payees.jsonl`) |
| `comment` | string or null | a note from a person |
| `mcc` | string or null | the merchant category code, exactly four digits (`"5411"`) |
| `bank_description` | string or null | the bank's raw text |
| `merchant` | string or null | the cleaned shop name |
| `source_system` | string or null | the system the row first came from (free text: a bank feed, an app) |
| `transfer_key` | string or null | set on both legs of a transfer, the same non-blank value on both; null otherwise |
| `lines` | array | the category split; `[]` for a transfer leg, at least one line otherwise |

A line:

| Key | Type | Meaning |
|---|---|---|
| `amount` | decimal string | the line amount; the lines of a transaction sum exactly to its `amount` |
| `category_legacy_id` | integer, string or null | the old category (in `categories.jsonl`), null for an uncategorised line |
| `comment` | string or null, **optional** | a note on this line; the key may be missing |

## What the importer does

### 1. Verify, before writing anything

The importer reads and checks the whole export first. Any of these stops the import, and nothing is
written:

- the folder or `MANIFEST.json` is missing, the manifest is not a JSON object, a manifest key is missing,
  `schema_version` is not `1`, `counts` / `sha256` are not objects, `warnings` is not an array,
  `exported_at` / `legacy_git_sha` are neither a string nor null, or `date_from` / `date_to` are neither a real
  `YYYY-MM-DD` date nor null;
- a data file is not listed in both `counts` and `sha256`, the manifest lists another file, a listed file is
  missing, its SHA-256 or its line count does not match, or it is not valid UTF-8;
- a line is empty, is not valid JSON, or is not a JSON object;
- a required key is missing, or a value has the wrong type or form (see the tables);
- a text value (a name, a path, a comment, an id, ...) holds a NUL character (`\u0000`), which the database
  cannot store;
- a duplicate `legacy_id` inside a file, a blank one, or one with whitespace at the start or the end; two
  accounts with the same name;
- an account `kind` outside the list;
- an amount that is not a decimal string, has more than two decimal places, is zero or is out of range;
- a transaction currency that is not its account's; `original_amount` without `original_currency` (or the
  other way round), with the other sign, or with the transaction currency;
- an ordinary transaction without lines, or whose lines do not sum exactly to its amount; a transfer leg with
  lines;
- a reference to an account, payee or category that the export does not have;
- a `transfer_key` with one leg or more than two; two legs on one account; two legs with the same sign; a
  same-currency pair that does not net to exactly zero.

All problems found are listed together (the first 50, then a count).

### 2. Write, all or nothing

Everything is written in **one database transaction**, through the models (so every model rule applies:
the line sum, the transfer rules, the decimal places). Any error rolls everything back. With `DRY_RUN=1` the
importer does all the work, prints the counts, and rolls back.

Things that can still stop the import at this stage (and roll everything back):

- the taxonomy is not loaded (`Category.uncategorised` is missing: run `bin/rails db:seed`);
- a model refuses a row, for example an account name that an account outside this export already uses, or an
  account currency that would change while the account has transactions;
- replacing a transfer pair would delete a stored transaction that is not in this export (see below);
- `Transaction.transfer_problems` finds a problem in an imported pair after the writes.

### Identity and updates (idempotency)

| Entity | Found by |
|---|---|
| account | `external_id` = `"legacy:<legacy_id>"` (for example `legacy:12`) |
| payee | normalised name (`Payee.normalize_name`: Unicode NFKC, squished whitespace, lower case) |
| category | never created; found by group and category name in the taxonomy |
| transaction | `source` = `legacy` and `external_id` = `legacy_id` as text |

- Every account and transaction the importer writes keeps `import_digest`: the SHA-256 of a canonical form
  of the export row it was written from (below). That is how the next run tells "the export changed this
  row" from "a person changed this row in the app".
- A row that is missing is created (also one that was deleted in the app).
- A stored row whose `import_digest` equals the digest of its export row is **unchanged**: it is not written
  at all, whatever a person changed in the app since (a category given to a line, a `needs_review` row
  confirmed, a comment fixed, an account renamed). So a second run of the same export writes nothing and
  keeps every local edit. The report counts how many unchanged rows differ from the export today ("with
  local edits kept").
- A stored row whose export row changed (another digest) is written again from the export, and counted as
  updated: the export wins for that row, and a local edit of it is lost. A stored row with no digest counts
  as changed.
- Accounts: name, kind, currency and archived flag are written in place. Accounts of the export may swap
  names (or pass them round) between two exports: an account whose name changes first takes a temporary
  name inside the database transaction, so the unique name rule does not stop the swap. A name held by an
  account that is not in the export still stops the import.
- Payees: an existing payee is never renamed. Several old payees whose names normalise to the same key
  fold into one payee (the first one in the file names it); the report counts how many folded.
- Transactions: the fields are written in place; the lines are replaced only when they differ (amount,
  category, old path or comment, in order). A row that moves to an account in another currency cannot be
  changed in place (the app refuses that move); it is destroyed and created again, with the same
  `source` and `external_id`, in the same database transaction.
- Transfer pairs: a pair is written only when the digest of at least one of its legs changed (or the rows
  are not yet this pair). When only details of the changed legs differ (dates, comment, payee, ...), those
  legs are saved in place and the other leg is left alone. When an account, an amount or the status of a
  changed leg differs, or the two rows are not yet this pair (a new `transfer_key`, a row that was an
  ordinary transaction), the stored rows are destroyed and the pair is created again from the export in the
  same database transaction. A row that stops being a leg is replaced the same way.
  The importer never deletes a stored row that the export does not have: when replacing would destroy one
  (the old counterpart of a leg, or a row that holds the pair's transfer id), the import stops.
- A transaction a receipt was booked onto in the app (its lines replaced by the receipt's items,
  `docs/domain.md`, "Booking onto a transaction") follows the same rule: unchanged, it keeps the receipt's
  lines; changed in the export, the export wins. Its lines are rewritten in place (the receipt stays linked,
  and its booking record's digests no longer match), or the row is destroyed and created again (the booking
  record goes with it and the receipt returns to review). The report does not count these apart.
- Rows stored by an earlier import that this export does not have (accounts and transactions) are left
  alone and counted in a warning.
- The `Lines` and `Status` counts of the report describe the export (what each row gets from it), also for
  rows left unchanged.

**The digest.** `import_digest` is the SHA-256 (64 lower-case hex characters) of the JSON text
`[1, "account" | "transaction", {...}]`, where the object holds the row's fields with its keys sorted, so the
order of keys in the file does not matter, and every value written by its type, so its spelling does not
matter either: ids as text (`12` and `"12"` are the same), amounts as the parsed decimal (`"-120"` and
`"-120.00"` are the same), dates as `YYYY-MM-DD`, times in UTC with six fraction digits (any offset), an
account name squished, other text as given. A transaction's digest also covers what its references write:
the payee's normalised name, and for each line (in order) its amount, its comment and its old category's
`legacy_path`, `group_en` and `category_en`. So a changed mapping in `categories.jsonl` or a payee that
the export now names differently also writes the rows that use them. The code is
`LegacyImport::RowDigest`.

### Categories and status

A line's category:

| Case | Category | `legacy_category_path` | Counted as |
|---|---|---|---|
| `category_legacy_id` is null | none | none | no category |
| `group_en` or `category_en` is null | Uncategorised | the old `legacy_path` | unmapped |
| the pair is not in the taxonomy | Uncategorised | the old `legacy_path` | not in taxonomy (a **warning** listing the old ids) |
| the pair is in the taxonomy and is `Uncategorised` / `Uncategorised` | Uncategorised | the old `legacy_path` | mapped to Uncategorised by the export |
| the pair is in the taxonomy (any other category) | that category | the old `legacy_path` | mapped |

Each line is counted once, so the five figures of the report's `Lines` row add up to the number of lines,
and every line not counted as mapped makes its transaction `needs_review`.

Names are compared exactly (case-sensitive) after squishing whitespace, against the group name and the
category name of `db/seeds/taxonomy.yml`. The old path is kept on mapped lines too, since several old
categories may fold into one new one.

A transaction is `needs_review` when at least one of its lines has no category or lands in Uncategorised,
and `confirmed` otherwise. Transfer legs are always `confirmed`. Every imported row has `source` = `legacy`.

### Transfers

`transfer_id` = UUID version 5 (RFC 9562, SHA-1) of the `transfer_key` (its UTF-8 bytes) under the fixed
namespace **`bdf1a284-e14e-4f36-a890-6310852e90d7`** (`LegacyImport::TransferId::NAMESPACE`). The same key
always gives the same id, on every run and every machine. In Python: `uuid.uuid5(uuid.UUID(namespace), key)`.

### Money and dates

Amounts are parsed with `BigDecimal` from the strings and never rounded. `occurred_on` is stored as given;
`occurred_at` is parsed with its offset (stored in UTC) or stays null. `source_system` is copied to the
transaction column of the same name.

### Output

The importer prints counts and warnings only. It never prints a name, a payee, a comment, a description or
an amount: not in its normal output, not in its error messages, and Active Record's SQL log is silenced
while it runs. Errors name the file, the line number, the `legacy_id` (when it looks like an id), the
field and the kind of problem. Model refusals are reported as attribute names and error types
(`name taken`), never as Active Record's messages; a model rule that gives a sentence instead of a type is
shown as `invalid` (`currency invalid`), since a sentence may quote a value. The manifest's `warnings`
are only counted.

A successful first run of the fixture export prints:

```
Legacy import: export schema 1, dates 2026-01-01 to 2026-03-31, 1 manifest warning
Accounts: 5 created, 0 updated, 0 unchanged (0 with local edits kept)
Payees: 4 created, 0 updated, 0 unchanged, 1 folded into another payee
Transactions: 15 created, 0 updated, 0 unchanged (0 with local edits kept), 3 transfer pairs (0 recreated)
Lines: 7 mapped to a category, 1 mapped to Uncategorised by the export, 1 sent to Uncategorised (no mapping), 1 sent to Uncategorised (names not in the taxonomy), 1 without a category
Status: 11 confirmed, 4 needs_review
Warnings: 1
  - 1 old category name a group and category that are not in the taxonomy; their lines went to Uncategorised (legacy_ids 15)
Done: the import was committed.
```

A second run of the same export prints `0 created, 0 updated, 5 unchanged` for the accounts and
`0 created, 0 updated, 15 unchanged` for the transactions, with the same `Lines` and `Status` counts.

A failed run prints the problems to standard error and exits with status 1:

```
The import stopped (1 problem).
  - transactions.jsonl line 7 (legacy_id 1007): transfer_key joins two same-currency legs that do not net to zero (the leg on line 8); a fee must be a separate expense row
Nothing was written.
```

## Notes for the exporter

- Send the **final account kinds** (`cash`, `debit`, `credit`, `savings`, `ewallet`, `business`); the
  importer does not translate kinds and stops on any other value.
- **Both legs** of a transfer must be in the export, with the same `transfer_key`. A date window must not
  cut a pair: widen the window or include the other leg.
- Transfer legs have `lines: []`.
- An uncategorised line has `category_legacy_id: null`.
- A line's `comment` is optional: leave it out or send `null` when there is none.
- Amounts are strings with at most two decimal places (`"-1250.50"`), never JSON numbers and never zero.
- Each transaction's `currency` equals its account's currency; an amount in another currency goes to
  `original_amount` / `original_currency`.
- Each `legacy_id` is unique in its file and the same on every run, so a second export finds the rows of
  the first.

### A fee or a surplus inside a same-currency transfer

The two legs of a same-currency transfer must net to exactly zero. When the old data has legs of different
sizes (the bank took a fee, or added something), the exporter splits the difference into a row of its own:

- **both legs** carry the **smaller** of the two magnitudes (one negative, one positive);
- the **difference** becomes **one extra transaction on the account whose leg was larger**: an **expense**
  on the sending account for a fee (the out leg was larger), an **income** on the receiving account for a
  surplus (the in leg was larger). So the sum of each account's rows does not change;
- the extra row has `transfer_key: null`, the `occurred_on` and `occurred_at` of the leg it is cut from,
  its `currency`, and **one line** with its full amount and its category (for a fee usually the old
  category that maps to `Debt & credit` / `Interest & bank fees`);
- its `legacy_id` is **unique in the file and the same on every run**. The agreed form is the leg's id
  with a suffix, as a string: `"1007-fee"`.

For example, moving 1000 that cost 10: the out leg `-1000.00`, the in leg `1000.00`, and the row
`"1007-fee"` with `-10.00`. The fixture export has such a transfer (`T-0010`, legacy ids 1012, 1013 and
`"1012-fee"`).

### What the exporter writes

Both sides agree that the exporter writes exactly this, and the importer checks it:

- every key of the tables above is always present in every row, with `null` when there is no value, never
  missing; the only exception is a line's optional `comment`;
- `occurred_at` is ISO 8601 in UTC with `Z` and whole seconds (`"2026-01-10T07:00:00Z"`), or `null`; the
  importer also reads other offsets and a fraction of at most six digits;
- `counts` and `sha256` in `MANIFEST.json` are keyed by data file name (`"accounts.jsonl"`, ...), list the
  four data files and do not list the manifest itself; they are computed on the final files;
- every line of a data file ends with `\n`, the last one too;
- `mcc` is exactly four digits as a string (`"5411"`) or `null`;
- `legacy_id` (and every reference to one) is a JSON integer or a string, compared as text (`12` and `"12"`
  are the same id); a string has no whitespace at either end;
- `source_system` may be `null`.
