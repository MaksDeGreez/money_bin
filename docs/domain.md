# Domain model

Money Bin tracks the money of one person, with an AI agent as a second user. It records where money is
kept (accounts), how it moves (transactions), what it was spent on (categories, through transaction lines),
who was paid (payees), and the shop receipts behind some purchases (receipts and their items). This
document describes the model and the reasons behind it. The schema itself is `db/schema.rb`.

There is one owner of all data, so ledger tables have no `user_id`.

## Entities

| Table | One row is | Key columns |
|---|---|---|
| `accounts` | A place where money is kept, in one currency | `name` (unique), `kind` (cash, debit, credit, savings, ewallet, business), `currency` (ISO 4217), `archived`, `external_id` (optional, unique), `import_digest` |
| `categories` | A group (root) or a category (child of a group) | `parent_id`, `name`, `slug` (unique), `position`, `description` |
| `payees` | The other side of a transaction: shop, service or person | `name`, `normalized_name` (unique) |
| `transactions` | One movement of money on one account | `account_id`, `occurred_on`, `occurred_at`, signed `amount`, `original_amount` + `original_currency`, `payee_id`, `comment`, `mcc`, `bank_description`, `merchant`, `source`, `source_system`, `external_id`, `status`, `transfer_id`, `lock_version`, `import_digest` |
| `transaction_lines` | A category share of a transaction (the split) | `transaction_id`, `category_id` (nullable), `amount`, `legacy_category_path`, `comment` |
| `receipts` | A photographed shop receipt and its OCR result | `transaction_id` (nullable), `status`, `images` (1 to 3 photos), `ocr_raw`, `ocr_model_name`, `ocr_model_version`, `fiscal_number`, `receipt_number`, `issued_at`, `total`, `currency`, `merchant_name`, `qr_payload`, `batch`, `sha256` |
| `receipt_items` | One line printed on a receipt | `receipt_id`, `position`, `name`, `quantity`, `unit_price`, `amount`, `discount`, `category_id`, `suggested_category_id`, `confidence`, `accepted_by_user` |

Photos are stored with Active Storage (`active_storage_*` tables), attached to a receipt as `images`.

### Fields in plain words

- **Account.** `kind` describes the account; it changes no rule. `archived` hides a closed account from
  everyday lists but keeps its history. `external_id` is the identifier a bank or an importer uses.
  `import_digest` is set by the history import (see "History import" below).
  The balance is the sum of the account's booked transaction amounts (drafts are left out, see `status`).
- **Category.** A group has no parent and only collects categories. Lines and receipt items point at
  categories, never at groups. So the level is fixed once something points at a row: a category that lines or
  items use cannot lose its parent, and a group with categories cannot get one. Moving a category to another
  group is allowed (give it a new slug). `position` orders a level (groups among groups, categories inside their
  group). `description` says in one sentence what belongs there; people, the categoriser and AI agents
  read it.
- **Payee.** `name` is how the payee is shown. `normalized_name` is the matching key (see Decisions).
- **Transaction.**
  - `amount` is signed, in the account currency: an expense is negative, an income positive.
    Because the number means money in that currency, a transaction cannot move to an account in another
    currency (UAH -100 would silently become USD -100); it is entered again on the new account instead.
  - `occurred_on` is the calendar date in Kyiv; every list and report uses it. `occurred_at` is the exact
    moment, when a source knows it (a bank feed, a receipt), else nil. Neither is derived from the other: a
    hand-entered expense has a date and no time, and a bank time near midnight belongs to the date the bank
    reports.
  - `original_amount` in `original_currency` is the operation amount when it was in another currency (a
    USD purchase paid from a UAH card).
  - `mcc` is the card network's merchant category code. `bank_description` is the bank's raw text, and
    `merchant` is the cleaned shop name. `comment` is a note from a person.
  - `source` says where the row came from: `legacy` (the history import), `receipt`, `manual`, `api`
    (the AI agent or another client) or `bank`. `external_id` is that source's own id for the row.
  - `source_system` is the system a row first came from, set by importers; it is free text and may be nil.
    `source` says which writer of this app stored the row (the history import stores every row as
    `legacy`); `source_system` keeps what the old data knew about its own origin (a bank feed, another
    budgeting app).
  - `status` says whether the money is booked:
    - `draft`: a proposal that nobody has accepted yet. It is **not counted**: balances and reports leave
      it out. Drafts are expected to come from an AI agent that proposes a transaction through the API, and
      from a receipt that waits to be matched with a bank transaction. Accepting a receipt books its draft
      (see "Acceptance");
    - `needs_review`: booked and counted, but a person must still look (for example at an uncategorised
      line);
    - `confirmed` (the default): booked, counted and complete.

    `Transaction.booked` is the scope of the counted rows (`needs_review` and `confirmed`), and
    `Transaction.draft` its opposite; `transaction.booked?` asks the same of one row. `Account#balance` and
    the report scopes `expenses` and `incomes` use booked rows only. All other rules (the line sum, the
    transfer rules, the decimal places) apply to a draft exactly as to a booked row: a draft is a complete
    transaction that is not counted yet, not a half-filled form.
  - `transfer_id` joins the two legs of a transfer.
  - `import_digest` is the SHA-256 of the export row the history import last wrote the row from; nil for
    rows no importer wrote (see "History import").
  - `lock_version` is Active Record's optimistic lock counter (see "Concurrent writers").
- **Transaction line.** `category_id` nil means "not categorised yet". `legacy_category_path` keeps the old
  app's category path ("Food / Snacks") when the history importer brings the line in, so the original label
  is never lost.
- **Receipt.** `status` moves `uploaded` -> `processing` -> `extracted` -> `reviewed`, or ends in `failed`
  (see "OCR" below). `extracted` means the items are filled in and wait for a person; `reviewed` means the
  receipt was accepted into the ledger. `ocr_raw` keeps the OCR service's full answer, or the reason of a
  failure, and `ocr_model_name` and `ocr_model_version` say which model produced it. `currency` is what OCR
  read (nil when unknown).
  `batch` is a free label for a bulk upload. `sha256` is the photo fingerprint.
- **Receipt item.** `amount` is what was paid for the item after its `discount`. It is normally positive,
  but it can be negative (a bottle deposit returned) or zero (a free item). `suggested_category` and
  `confidence` (0..1) are the categoriser's guess. `category` is the accepted category, and
  `accepted_by_user` records that a person confirmed it.

## Invariants

"Model" means a validation or callback; "DB" means a constraint or index in PostgreSQL. Where both are
listed, the model gives a readable error and the database is the safety net for code that skips the model
(`update_column`, `insert_all`, SQL).

| Rule | Where |
|---|---|
| Amounts are `decimal(15, 2)`; transaction, line and original amounts are never zero | Model + DB (`*_amount_non_zero`, `transactions_original_amount_consistent`) |
| Money has at most 2 decimal places and a receipt item quantity at most 3; more is refused, never rounded | Model only (`DecimalPlacesValidator`) |
| Currency codes are three upper-case letters (accounts, original currency, receipts) | Model (also upper-cases) + DB (`*_currency_format`) |
| Enum values (account kind, transaction source and status, receipt status) are from their lists | Model (`enum ..., validate: true`) + DB (`*_allowed` check constraints) |
| Account names are unique; an account `external_id` is unique when present | Model + DB (unique indexes) |
| An account's currency cannot change once it has transactions | Model only |
| A transaction (a transfer leg too) can move only to an account in the same currency | Model only |
| An account, a payee or a category that is in use cannot be destroyed | Model (`restrict_with_error`) + DB (foreign keys) |
| Categories have two levels: a category's parent is a group; a group with categories gets no parent; nothing is its own parent | Model; DB for "not its own parent" (`categories_not_own_parent`) |
| A category does not become a group, nor a group a category, while child categories, transaction lines or receipt items (accepted or suggested) point at it | Model only |
| Category names are unique inside their parent, group names among groups | Model + DB (unique `(parent_id, name)` with `NULLS NOT DISTINCT`) |
| Slugs are unique, well formed, and match the level (a group slug has no `/`, a category slug has one and starts with its group slug) | Model; DB checks uniqueness, format and the slash (`categories_slug_format`, `categories_slug_matches_level`), not the group prefix |
| Lines and receipt items point at categories, not groups | Model only |
| Payee `normalized_name` is unique | Model + DB (unique index) |
| `original_amount` and `original_currency` are both set or both nil; same sign as `amount` | Model + DB (`transactions_original_amount_consistent`) |
| `original_currency` differs from the account currency | Model only (the database would need a join) |
| `mcc` is exactly four digits | Model + DB (`transactions_mcc_format`) |
| `(source, external_id)` is unique when `external_id` is set | Model + DB (partial unique index) |
| A transaction that is not a transfer leg has at least one line, and its lines sum exactly to its amount | Model only (see below) |
| A line saved on its own cannot break the sum and cannot be destroyed on its own | Model only |
| A stale copy of a transaction cannot save or destroy, also when only its lines change | Model (optimistic locking, `lock_version`) |
| A transfer has exactly two legs, on different accounts, with opposite signs and no lines | DB for "at most one leg per sign" (unique index `index_transactions_one_leg_per_side`); model for the rest |
| A same-currency transfer nets to exactly zero | Model only |
| The two legs of a transfer have the same status | Model only |
| A leg cannot leave its transfer; destroying one leg destroys the other | Model only |
| A receipt has 1 to 3 photos, of photo formats only (JPEG, PNG, WebP, HEIC/HEIF), all different, each at most 15 MB | Model only |
| A receipt's `sha256` is present, 64 lower-case hex characters, and unique | Model + DB |
| A transaction has at most one receipt | Model + DB (unique index on `receipts.transaction_id`) |
| A `reviewed` receipt has a transaction: destroying the transaction moves its receipt back to `extracted` | Model (in the destroy's database transaction); the foreign key only nullifies the link |
| Receipt item positions are unique per receipt and not negative; quantity > 0; discount >= 0; confidence in 0..1 | Model + DB |

### The line sum is enforced in the model, not by a trigger

The rule "lines sum to the amount" spans two tables, so a check constraint cannot express it. A
PostgreSQL trigger could (a deferred constraint trigger that re-sums at commit), but it is not used for now:

- every write goes through the models. Lines are written as nested attributes of their transaction, which
  checks the sum before it saves. A line saved on its own that changes an amount compares itself with the
  stored transaction amount and the stored siblings, under a row lock (see "Concurrent writers"), and a
  line cannot be destroyed on its own at all;
- the trigger would have to be deferred to commit time (a transaction and its lines are written in
  several statements), which makes errors hard to read and tests slow to write;
- parallel writers are kept safe by the models too: optimistic locking and a row lock (see "Concurrent
  writers"), not by the database re-checking the sum.

The cost: anything that skips the models skips these rules. Bulk writes (`insert_all`, `upsert_all`,
`update_all`, `delete_all`), `update_column(s)` and raw SQL do not check the line sum, the transfer rules,
the decimal places or the lock version. So **every writer goes through the models**: the browser UI, the
API, and the history importer too (`Transaction.create!` with `lines_attributes`, and one `create!` per
transfer leg), even though one-by-one saves are slower than a bulk insert. Code that must skip
the models (a data migration, a test that builds bad data on purpose) checks its result itself, for example
with `Transaction.transfer_problems` and a SQL query that compares each transaction with the sum of its
lines. If a writer past the models ever becomes necessary, the trigger should come back on the table.

Transfers follow the same idea. The database refuses a third leg and two legs with the same sign. The
other rules are checked when a leg is saved, against its saved counterpart, so a single save cannot break
an existing pair. A lone leg is valid, because the first leg of a pair is always saved alone; writers
create both legs in one database transaction and check the pair afterwards (below).

### Concurrent writers

The browser, the API and the importer can write the same transaction at the same time. The line-sum rule is
checked on the copy in memory, so two stale copies could each pass it and together leave lines that do not
add up. Two mechanisms stop that:

- **Optimistic locking on `transactions`.** The `lock_version` column turns on Active Record's optimistic
  locking. Each save writes `lock_version + 1` with `WHERE lock_version = <the value it read>`, so a save or a
  destroy from a stale copy raises `ActiveRecord::StaleObjectError` and its database transaction rolls back.
  A save that changes only lines (nested attributes) still writes the transaction row: it touches
  `updated_at`, so it bumps the version too. The row update runs before the lines are written, so the loser
  writes nothing.
- **A row lock for a line saved on its own.** A new line, or a line whose amount changes, outside its
  transaction's save reads the transaction's stored `amount` and `transfer_id` with `SELECT ... FOR UPDATE`
  and sums the stored sibling lines. It never trusts the transaction copy in memory, which may hold an
  unsaved amount. The lock is held until commit, so parallel writers of that transaction wait. The save
  then bumps the transaction's `lock_version`, so a copy read before it cannot write lines over it.
  Changing only a line's category or comment needs neither.

`ActiveRecord::StaleObjectError` is an exception, not a validation error: the copy was correct when it was
read, and only the person or the client can decide what to do with their change. Callers handle it like this:

- a browser form reloads the transaction and shows "changed somewhere else, check and save again"; the form
  carries `lock_version` as a hidden field, so a page that was open for an hour also conflicts;
- the API (when it writes transactions) answers `409 Conflict` with the code `stale_transaction`, and the
  client reads the row again;
- a service that reads and writes in one go (`Receipts::Accept`) takes the row lock first
  (`transaction.lock!`), so it waits for a parallel writer instead of failing;
- nothing retries on its own: a retry with the same stale data would only fail again.

## Transfers

A transfer moves money between two own accounts. It is two transactions, one per account, that share a
`transfer_id`.

- `Transaction.transfer!(from:, to:, amount:, occurred_on:, to_amount: nil, occurred_at: nil, comment: nil,
  payee: nil, source: :manual, status: :confirmed)` creates both legs in one database transaction and
  returns `[out_leg, in_leg]`. `amount` and `to_amount` are positive numbers in each account's own
  currency. `to_amount` defaults to `amount` for a same-currency transfer and is required when the
  currencies differ. Each amount is an `Integer`, a `BigDecimal` or a plain decimal `String` (`"1250.50"`)
  with at most two decimal places. Anything else raises `ArgumentError`: a `Float` or a `Rational` (neither
  is an exact decimal amount), more than two places, or text such as `"1,5"` or `"1e3"`.
- `Transaction.transfer_problems(transfer_id)` returns the list of everything wrong with a stored transfer
  (an empty list means it is valid). `leg.transfer_problems` does the same for a leg's transfer. An
  importer that writes the legs itself calls it after the second leg, inside the same database transaction,
  and rolls back when the list is not empty.
- `leg.counterpart` returns the other leg.
- Destroying one leg destroys the other.
- Both legs have the same status. Otherwise a half-draft transfer would change one balance and not the
  other. `transfer!` gives both legs the `status` it gets; a leg saved alone with another status than its
  stored counterpart is refused. `transaction.update_status!(status)` changes the status of both legs
  together, in one database transaction (for a transaction that is not a leg it is just
  `update!(status:)`). A stale copy raises `ActiveRecord::StaleObjectError`, as any save does, and then
  neither leg changes.
- The amounts of a same-currency pair cannot be changed one leg at a time (each save would break the
  zero sum). Destroy the pair and create it again. This also applies to an import that runs again and
  finds that the source changed the amount of a same-currency transfer: it destroys the stored pair (found
  by `source` and `external_id`) and creates the two legs again, with the same deterministic
  `transfer_id`, in one database transaction (see "History import").

A bank fee is never hidden inside a leg. When moving 1000 costs 10, the out leg is -1000, the in leg is
+1000, and the fee is a separate expense of -10 with its own category ("Interest & bank fees"). So a
same-currency transfer always nets to zero, and the fee shows in spending reports. A surplus (the receiving
side got more) is a separate income the same way. The history export splits old transfers like this (see
"A fee or a surplus inside a same-currency transfer" in [`import-contract.md`](import-contract.md)). A
cross-currency pair may have any two amounts: the exchange rate is implied by them.

## Receipts

### Fingerprint

`receipts.sha256` refuses the same photo twice. It is defined on the bytes exactly as uploaded:

- one photo: the SHA-256 of its bytes, written as 64 lower-case hex characters;
- several photos: the SHA-256 of the per-photo hex digests, sorted, then joined together without a
  separator. Each digest has exactly 64 characters, so the joined text is unambiguous. Sorting makes the
  value independent of the upload order: the same two photos sent in the other order are the same receipt.

`Receipt.fingerprint(sources)` computes it from uploaded files, IO objects, Active Storage attachable hashes
(`{ io:, filename: }`) or blobs. A new receipt gets it automatically when photos are attached and the field
is blank. It is never recomputed: it identifies the original upload. Limits that are accepted:

- the same scene photographed twice gives different bytes and is not caught;
- a receipt with only some of the photos of an earlier one (one page of two) has a different fingerprint,
  so it counts as a different receipt.

The same photo cannot be attached twice to one receipt (the blobs' checksums must differ).

Photos can be attached as files, IO hashes, blobs or signed blob ids. Rails sends signed ids (Strings) when
the files were uploaded ahead of the form (direct upload); `Receipt#images=` resolves them to their blobs with
`ActiveStorage::Blob.find_signed`, so the fingerprint can read the bytes. An invalid or expired id is a
validation error on `images`, not an exception.

### OCR

A receipt's photos are read by the ML service in `ml/` (its contract is `ml/README.md`). Three pieces do
the work:

- `MlClient` (`app/services/ml_client.rb`) is the HTTP client: `health`, `ocr(images)` and
  `categorise(texts)`. It sends photos as `MlClient::Image` (`io`, `filename`, `content_type`), so it does
  not depend on Active Storage, and returns value objects that keep the parsed body. It never retries.
  Every failure is a subclass of `MlClient::Error` with a short `code` and `transient?`.
- `Receipts::ApplyOcr.call(receipt, result)` stores one OCR result (details below).
- `ReceiptOcrJob` (Sidekiq) runs the two for one receipt. Nothing enqueues it on its own: no model
  callback does it. The upload flow calls `ReceiptOcrJob.perform_later(receipt)` after it saved the
  receipt.

Who moves the status:

| From | To | By |
|---|---|---|
| (new) | `uploaded` | the upload (the column default) |
| `uploaded`, `failed` | `processing` | `ReceiptOcrJob`, when it starts |
| `processing` | `extracted` | `Receipts::ApplyOcr`, with the result |
| `processing` | `failed` | `ReceiptOcrJob`, on a permanent failure or when the retries run out |
| `extracted`, `reviewed` | `reviewed` | `Receipts::Accept` |
| `reviewed` | `extracted` | destroying its transaction (the receipt is unlinked, keeps its items and can be accepted again) |

The job starts only on `uploaded`, `processing` (its own retry, or a run that died) and `failed` (try
again by enqueuing it once more). It leaves `extracted` and `reviewed` receipts alone, so running it twice
does the work once and never overwrites what a person is reviewing. A receipt deleted before the job runs
is discarded quietly.

What is stored where:

- on success, `ocr_raw` is the service's full response body as returned (the `receipt` part plus
  `backend`, `model_name` and `model_version`). `ocr_model_name` and `ocr_model_version` are copied from
  it; `merchant_name`, `fiscal_number`, `receipt_number`, `issued_at`, `total` and `currency` come from
  the `receipt` part (a null stores nil);
- the items are replaced by the returned ones, in the same database transaction. An item's `position` is
  its place in the answer counting from 1, so position N is item N of `ocr_raw`. Amounts and quantities
  are parsed from decimal strings with `BigDecimal`; anything else (a float, unreadable text) counts as
  missing, and so does money with more than two decimal places or a quantity with more than three (the
  models refuse it rather than round it). New items have no category yet;
- on failure, `ocr_raw` is `{"error": {"code": ..., "message": ...}}` and nothing else: no stack trace and
  no response body. `code` is the service's own code (`validation_error`, `too_many_images`,
  `image_too_large`, `unsupported_media_type`, `backend_not_implemented`, `internal_error`, ...), or `ml_unreachable`,
  `ml_timeout`, `invalid_response`, `no_images` or `image_missing`. `message` is one line of at most 300
  characters. There is no separate column for the reason: `ocr_raw` already means "what the OCR step
  left".

OCR output is not always tidy, and the item rules (a name, an amount, `quantity > 0`, `discount >= 0`)
are strict. `Receipts::ApplyOcr` keeps what it can instead of failing the receipt:

- a value the model refuses in an optional field is stored as nil: an unreadable `issued_at`, a `total`
  out of range or a malformed `currency` on the receipt; a zero `quantity` or an out-of-range
  `unit_price` on an item;
- an item still refused after that (no name, no readable amount, a negative discount) is skipped. Its
  position stays free, `ocr_raw` keeps it, and the items no longer sum to `total`, which the person sees
  at review (`Receipts::Accept` then books the transaction as `needs_review`). Failing the whole receipt for one smudged line would throw away the other lines.

`Receipts::ApplyOcr` never changes a `reviewed` receipt (it raises `AlreadyReviewed`; the job then stops
quietly, since the person's result wins). Applying the same result twice gives the same rows.

Retries and timeouts:

- transient failures are retried by the job with a growing wait (Active Job's `polynomially_longer`:
  about 3 s, 18 s, 83 s, 258 s), 5 runs in all; then the receipt becomes `failed`. Transient means the
  service cannot be reached, a timeout, or a 5xx answer other than 501;
- permanent failures make the receipt `failed` at once: a 4xx answer (for example 413 `image_too_large`,
  a photo over the service's `ML_MAX_IMAGE_BYTES`, 15 MB by default, or 415 `unsupported_media_type`, a
  file whose first bytes are not a JPEG, PNG, WebP or HEIC image), 501 (the backend is only a
  placeholder), an answer that is not JSON or misses a required key, no photos attached, a photo file
  missing from storage;
- any other exception (a bug, the database gone) is raised: Sidekiq's own retries apply and the receipt
  stays `processing` until a run succeeds;
- the client opens the connection within `ML_SERVICE_OPEN_TIMEOUT` seconds (default 2), waits up to
  `ML_SERVICE_OCR_TIMEOUT` (default 120; a real model can be slow) for an OCR answer and
  `ML_SERVICE_CATEGORISE_TIMEOUT` (default 30) for a categorisation answer. `/health` waits 5 seconds.
  `ML_SERVICE_URL` is the base URL (default `http://127.0.0.1:8100`);
- `image/heif` photos are sent as `image/heic`: the receipt accepts both names, the service only the
  second.

Photo size has two limits with the same value. The `Receipt` model refuses a photo over
`Receipt::MAX_IMAGE_BYTES` (15 MB, 15,728,640 bytes), so an oversized photo is never stored. The ML service
refuses a file over `ML_MAX_IMAGE_BYTES` (the same 15 MB by default) with 413 `image_too_large`. The model's
limit is a constant: it does not read `ML_MAX_IMAGE_BYTES`. Raising that setting alone changes nothing for
uploads, and lowering it below 15 MB lets the app store photos that the OCR job then fails.

### Acceptance

When a receipt is accepted, the transaction's lines are the item amounts summed per category.
`Receipts::Accept.call(receipt, account: nil)` does this and returns the transaction:

- items are grouped by `category`; items with no category form one line with no category. A suggestion is
  used only once it was copied to `category`. A category whose items sum to zero (a free item) adds no
  line, and a category whose items sum below zero (a deposit returned) gives a line of the opposite sign;
- a receipt that already has a transaction: the items must sum to the absolute value of its amount, or
  the service raises `TotalMismatch` (it carries both figures). The lines are replaced, not added, and carry
  the transaction's sign. An `account:` argument, if given, must be that transaction's account;
- a receipt with no transaction: `account:` is required. The service creates an expense: amount = minus
  the items' sum, `source: receipt`, `occurred_on` = the Kyiv date of `issued_at` (today when unknown),
  `occurred_at` = `issued_at`, `merchant` = `merchant_name`. When the receipt currency is known, it must be
  the account currency;
- the payee is the one named by `merchant_name`, through `Payee.find_or_create_by_name!`: the payee
  normalisation (see Decisions) decides what is the same payee, and a new name creates a payee. A linked
  transaction that already has a payee keeps it (a person or a bank feed may have chosen it); only an empty
  payee is filled. A blank merchant name sets no payee. The payee is written in the service's database
  transaction, so a failed acceptance leaves no new payee, and accepting again finds the same one;
- the transaction becomes `needs_review` when a line has no category, or when the receipt's printed
  `total` is known and the items do not sum to it (OCR may have skipped an unreadable line). The items are
  still booked: the person may have changed them on purpose. `receipt.total_difference` (the total minus
  the items' sum, nil when the total is unknown) and `receipt.items_match_total?` let a screen show the gap.
  Otherwise the transaction becomes `confirmed`;
- the earlier status of a linked transaction does not matter: a `draft` (or a `confirmed` one) also ends
  `needs_review` or `confirmed`, because accepting the receipt is the review. So accepting a receipt books
  a draft: from then on it counts in balances and reports. The receipt becomes `reviewed` and is linked to
  the transaction;
- only `extracted` receipts (the first acceptance) and `reviewed` ones (accepting again after a change)
  can be accepted. `uploaded` and `processing` have no OCR result yet, and `failed` has none to trust;
- it runs in one database transaction with the receipt row locked, so a failure changes nothing and two
  parallel calls cannot book one receipt twice. Calling it twice gives the same result.

Every refusal raises a subclass of `Receipts::Accept::Error`: `NotAcceptable` (status, no items, or linked
to a transfer leg), `AccountRequired`, `CurrencyMismatch`, `NothingToBook` (the items sum to zero or less,
so there is no expense) and `TotalMismatch`.

## Decisions and why

**The model is called `Transaction`; a line points back with `parent`.** It is the domain word. Rails
forbids an association named `transaction`, because `ActiveRecord::Base#transaction` exists:
`belongs_to :transaction` raises `ArgumentError` when the class loads. So a line uses
`belongs_to :parent, class_name: "Transaction", foreign_key: :transaction_id` and a receipt uses
`belongs_to :ledger_transaction, ...`. The column is still `transaction_id`. The constant `Transaction`
resolves to the model everywhere, even though `ActiveRecord::Transaction` exists, and
`Transaction.transaction { }` still opens a database transaction.

**Enums are strings.** `kind`, `source` and `status` columns hold readable values (`"bank"`,
`"needs_review"`), not integers. A row then explains itself in SQL, in a CSV export for the data analysis,
and in API output, and reordering an enum in code cannot change the meaning of stored data. Each column has
a check constraint that lists the allowed values, so a typo cannot be stored. The cost is a few bytes per
row, and a migration whenever a value is added (the constraint must change with the enum).

**Money is `decimal(15, 2)`, signed, in the account currency.** Decimal is exact; floats are not, so all
sums and comparisons use `BigDecimal`. Two decimals fit every currency this app needs. Fifteen digits hold
amounts below 10^13, far beyond a personal budget; the models check the range so bad input gets a
validation error instead of a database error.

Money is never rounded on the way in. Rails rounds a decimal to the column's scale when it is assigned, so
`"12.345"` would quietly be stored as 12.35. `DecimalPlacesValidator` (`app/validators/`) checks the value as
it was given, before that cast, and refuses more than two decimal places on `Transaction#amount` and
`#original_amount`, `TransactionLine#amount`, `ReceiptItem#amount`, `#unit_price` and `#discount`, and
`Receipt#total`; a receipt item `quantity` (`decimal(12, 3)`) gets the same rule with three places. A
converted amount (a USD price in UAH) is rounded by the writer that converts it, on purpose, before it
reaches the model. The sign carries the direction, so a balance is `SUM(amount)` over the booked rows
and a report never needs a "kind" column.

**No currencies table.** A currency is the ISO 4217 code on the account. A transaction has no currency
column of its own: it is always in its account's currency, and an account's currency is fixed once it has
transactions. A table would add a join to every query and nothing the code needs today; exchange rates,
when they come, can key on the same codes.

**Category slugs.** Names are for people and can be renamed; the ML service and the API need a key that
does not change. A group's slug is its parameterized name (`eating-out`); a category's slug is
`<group slug>/<own part>` (`eating-out/takeaway-fast-food`, `groceries/groceries`). The ML service returns
slugs in exactly this form. Slugs are globally unique, built once from the name, and not changed by a
rename. The taxonomy comes from `db/seeds/taxonomy.yml`; the seed matches groups and categories by name and
never deletes a category.

**Payee normalisation.** Bank feeds and receipts spell one shop in several ways. `normalized_name` is
Unicode NFKC, whitespace squished, then a Unicode-aware lower case (`"ＥＸＡＭＰＬＥ  Market"` and
`"example market"` match; Cyrillic works too). Punctuation is kept on purpose: stripping it would merge
different names too eagerly, and a later rule or a person can merge payees with care.
`Payee.find_or_create_by_name!` looks up through the same key and handles a parallel insert.

**Transfers are two rows.** One row per account keeps balances a plain sum, maps a bank statement line to
one row, and allows two currencies. A fee is a separate expense, so same-currency legs net to zero (see
Transfers).

**`occurred_on` and `occurred_at` are separate.** The date is what people and reports think in, and it is
always known. The exact time is known only for some sources and is useful for ordering and for matching a
bank item to a receipt. Deriving one from the other would invent data or move rows across midnight.

**Receipt fingerprint.** It is defined on the bytes, so it is cheap, exact and does not depend on OCR.
Several photos are combined through their sorted digests, so a client can compute the same value before
uploading, in any order.

**Acceptance builds lines from categories, not from items.** A ledger line is a category share; an item is
a product. Keeping items on the receipt and summing them per category into lines gives reports one code path
for split and unsplit transactions. The items stay available for item-level analysis.

**`ocr_model_name` and `ocr_model_version`, not `model_name`.** Every Active Record class and record already
has a `model_name` method (from `ActiveModel::Naming`). A column with that name does not raise an error;
the method simply wins, so `receipt.model_name` would return an `ActiveModel::Name` and the stored value
would be hidden. Forms and URL helpers also call `model_name`.

**`status` defaults to `confirmed`.** Most rows are confirmed when written: a person typing an expense, a
bank feed, the history import. Writers that know a row needs a person set `needs_review` themselves, as
`Receipts::Accept` does for an uncategorised line. A default of `needs_review` would put every hand-entered
row into a review queue.

**A draft is a proposal and is not counted.** An AI agent may suggest a transaction that the owner has not
seen, and a receipt may wait for its bank transaction. Counting such rows would change balances and reports
on a guess. A draft therefore stays out of every sum until a person (or a receipt acceptance) books it, but
it follows every other rule, so booking it is only a status change. `needs_review` is different: the money
is real and counted; only some detail (a category) still needs a person.

**A re-import compares digests, not values.** After an import a person reviews the rows in the app: gives
a line a category, confirms a `needs_review` row, fixes a comment. A re-import that compared each stored
row with the export would see those as differences and write the export back, undoing the review. So each
imported account and transaction keeps `import_digest`, the SHA-256 of the export row it was written from,
and the next run compares the digest of the incoming row with it. The same digest means the export has
nothing new to say about the row, so the row is left as the app has it; another digest means the export
changed that row, and the export wins for it. The digest is taken over a canonical form (sorted keys,
parsed values), so an exporter that spells a decimal or a time differently does not rewrite every row.

## Rails and PostgreSQL notes

- Fixtures skip validations; `test/models/fixtures_test.rb` loads every fixture record and checks that it
  is valid.
- A failed statement inside a test's transaction makes PostgreSQL refuse everything after it. Tests that
  prove a constraint run each violating statement in its own savepoint
  (`transaction(requires_new: true)`).
- `update_column` still applies `normalizes`, so a test that needs a lower-case currency in the database
  writes it with `update_all`.
- Autosaved nested lines are validated during the parent's `valid?`, before the save callbacks. The
  "parent is in charge" flag (`managing_lines?`) is therefore set in `valid?` as well as around save and
  destroy, and that callback is declared before `has_many :lines, dependent: :destroy`.
- `occurred_at` and `issued_at` are `timestamptz`; the Rails timestamps stay `timestamp` (UTC).
- Tests never call the ML service: `test/support/ml_service_stubs.rb` stubs it with WebMock in the
  service's response shapes and keeps the requests it answered (`ml_requests`), so a test can check the
  multipart parts.
- Tests store photos in `tmp/storage`. A transaction rollback does not remove files, so
  `test/support/receipt_images.rb` deletes the files of the blobs a test created. Parallel workers share
  the folder but not their blobs, so no test wipes the whole folder. Fixture photos have blob rows but no
  bytes.

## History import

`bin/rails "import:money_bin[DIR]"` loads an export of the previous version of the app. The export format,
the checks and the rules are in [`import-contract.md`](import-contract.md); the code is in
`app/services/legacy_import/` (`Runner` is the entry point). In short:

- the whole export is verified first (manifest hashes and counts, every field, references, transfer pairs);
  nothing is written when a check fails;
- everything is written in one database transaction, through the models; `DRY_RUN=1` rolls it back;
- rows are found again on the next run: accounts by `external_id` = `legacy:<legacy_id>`, transactions
  by `source` = `legacy` and `external_id` = `legacy_id`, payees by normalised name; categories are never
  created;
- every account and transaction it writes keeps `import_digest`, the SHA-256 of a canonical form of its
  export row (`LegacyImport::RowDigest`). On the next run a row whose digest is the same is not touched at
  all, whatever a person changed in the app since: a second run of the same export writes nothing and
  keeps every review, category and comment made in the app. Only a row that changed in the export is
  written again, and then the export wins for that row. A transfer pair is written again only when the
  digest of one of its legs changed. A row without a digest counts as changed; payees are never renamed;
- a line's category comes from the taxonomy by group and category name, or is `Category.uncategorised`
  when the old category is unmapped or not in the taxonomy; `legacy_category_path` keeps the old path; a
  transaction with an uncategorised line is `needs_review`;
- a transfer's `transfer_id` is a UUID v5 of the export's `transfer_key`, and every imported pair is checked
  with `Transaction.transfer_problems` before the commit;
- the output holds counts and warnings only, never a name, a comment or an amount.

## Deferred

- Authentication, API tokens, and who (person or agent) wrote a row.
- The upload flow that enqueues `ReceiptOcrJob`, and a call to `/categorise` that fills
  `suggested_category` and `confidence` on the items.
- A database trigger for the line sum, if anything starts writing lines past the models.
- Matching bank items to receipts and to each other (two legs of a bank-to-bank transfer).
- Exchange rates and a base-currency view.
- Payee merging and categorisation rules.
- Budgets and other planning features.
