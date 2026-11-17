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
  same id. It must be unique inside its file. References (`account_legacy_id`, `payee_legacy_id`,
  `category_legacy_id`) follow the same rule and must name a row of the referenced file.
- Every amount is a **decimal string**: an optional `-`, digits, and optionally `.` and digits, with at most
  two decimal places (`"-1250.50"`, `"7"`, `"0.05"`). Not a JSON number, no `+`, no exponent, no thousands
  separator, no comma. Zero is refused. The magnitude must be below 10^13.
- Dates are `"YYYY-MM-DD"`. Times are ISO 8601 with seconds and an offset: `"2026-01-10T09:00:00+02:00"`,
  `"2026-01-15T07:45:00Z"`, an optional fraction (`"...:00.250+02:00"`) is allowed.
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
file.

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
| `group_en` | string or null | the group name in the new taxonomy (`db/seeds/taxonomy.yml`), null when unmapped |
| `category_en` | string or null | the category name inside that group, null when unmapped |

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
  `schema_version` is not `1`, `counts` / `sha256` are not objects or `warnings` is not an array;
- a data file is not listed in both `counts` and `sha256`, the manifest lists another file, a listed file is
  missing, its SHA-256 or its line count does not match, or it is not valid UTF-8;
- a line is empty, is not valid JSON, or is not a JSON object;
- a required key is missing, or a value has the wrong type or form (see the tables);
- a duplicate `legacy_id` inside a file; two accounts with the same name;
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
- a model refuses a row, for example an account name that another account of the app already uses, or an
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

- A row that is missing is created. A row that differs from what is stored is updated in place. A row that
  is the same is not written at all. Running the same export twice changes nothing the second time.
- Accounts: name, kind, currency and archived flag are updated in place.
- Payees: an existing payee is never renamed. Several old payees whose names normalise to the same key
  fold into one payee (the first one in the file names it); the report counts how many folded.
- Transactions: the fields are updated in place; the lines are replaced only when they differ (amount,
  category, old path or comment, in order).
- Transfer pairs: when only details change (dates, comment, payee, ...), each leg is saved in place. When an
  account, an amount or the status of a leg changes, or the two rows are not yet this pair (a new
  `transfer_key`, a row that was an ordinary transaction), the stored rows are destroyed and the pair is
  created again in the same database transaction. A row that stops being a leg is replaced the same way.
  The importer never deletes a stored row that the export does not have: when replacing would destroy one
  (the old counterpart of a leg, or a row that holds the pair's transfer id), the import stops.
- Rows stored by an earlier import that this export does not have (accounts and transactions) are left
  alone and counted in a warning.
- Changes made by hand to imported rows are overwritten when the export says otherwise: the export is the
  source of truth for the rows it has.

### Categories and status

A line's category:

| Case | Category | `legacy_category_path` | Counted as |
|---|---|---|---|
| `category_legacy_id` is null | none | none | no category |
| `group_en` or `category_en` is null | Uncategorised | the old `legacy_path` | unmapped |
| the pair is not in the taxonomy | Uncategorised | the old `legacy_path` | not in taxonomy (a **warning** listing the old ids) |
| the pair is in the taxonomy | that category | the old `legacy_path` | mapped |

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
(`name taken`), never as Active Record's messages. The manifest's `warnings` are only counted.

A successful run prints, for example:

```
Legacy import: export schema 1, dates 2026-01-01 to 2026-03-31, 1 manifest warning
Accounts: 5 created, 0 updated, 0 unchanged
Payees: 4 created, 0 updated, 0 unchanged, 1 folded into another payee
Transactions: 11 created, 0 updated, 0 unchanged, 2 transfer pairs (0 recreated)
Lines: 6 mapped to a taxonomy category, 1 sent to Uncategorised (no mapping), 1 sent to Uncategorised (names not in the taxonomy), 1 without a category
Status: 8 confirmed, 3 needs_review
Warnings: 1
  - 1 old category name a group and category that are not in the taxonomy; their lines went to Uncategorised (legacy_ids 15)
Done: the import was committed.
```

A failed run prints the problems to standard error and exits with status 1:

```
The import stopped (1 problem).
  - transactions.jsonl line 7 (legacy_id 1007): transfer_key joins two same-currency legs that do not net to zero (the leg on line 8); a fee must be a separate expense row
Nothing was written.
```

## Notes for the exporter

- Send the **final account kinds** (`cash`, `debit`, `credit`, `savings`, `ewallet`, `business`); the
  importer does not translate kinds and stops on any other value.
- A bank fee inside a transfer must become a **separate expense row** (with its own line and category), so
  the two legs of a same-currency transfer net to exactly zero.
- **Both legs** of a transfer must be in the export, with the same `transfer_key`. A date window must not
  cut a pair: widen the window or include the other leg.
- Transfer legs have `lines: []`.
- An uncategorised line has `category_legacy_id: null`.
- A line's `comment` is optional: leave it out or send `null` when there is none.
- Amounts are strings with at most two decimal places (`"-1250.50"`), never JSON numbers and never zero.
- `occurred_at` carries seconds and an offset (`"2026-01-10T09:00:00+02:00"`), or is `null`.
- Each transaction's `currency` equals its account's currency; an amount in another currency goes to
  `original_amount` / `original_currency`.
- Every listed key is present in every row (use `null`), each `legacy_id` is unique in its file, and the
  manifest's `counts` and `sha256` are computed on the final files.
