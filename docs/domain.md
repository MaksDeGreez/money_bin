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
| `transaction_lines` | A category share of a transaction (the split) | `transaction_id`, `category_id` (nullable), `amount`, `legacy_category_path`, `comment`, the stored suggestion (`suggested_category_id`, `suggestion_probability`, `runner_up_category_id`, `runner_up_probability`, `suggestion_source`, `suggestion_model_version`, `suggested_at`), the category's provenance (`category_origin`, `category_origin_probability`, `category_origin_model_version`) |
| `transaction_suggestion_runs` | One refresh of the stored transaction suggestions | `status`, `model_version`, `total_count`, `scored_count`, `skipped_count`, `error`, `started_at`, `finished_at` |
| `bulk_acceptances`, `bulk_acceptance_items` | "Accept suggestions at or above N %" for a list filter, and one transaction of it as previewed | `filter`, `threshold_percent`, `status`, the counts; per item `transaction_id`, `lock_version`, `line_ids`, `category_id`, `probability`, `model_version`, `outcome` (`accepted`, `stale`, `changed`, `failed`) |
| `receipts` | A photographed shop receipt, its OCR result and its QR ground truth | `transaction_id` (nullable), `status`, `kind`, `incomplete`, `images` (1 to 3 photos), `ocr_raw`, `ocr_model_name`, `ocr_model_version`, `ocr_prompt_version`, `filled_from`, `categoriser_model_name`, `categorised_at`, `categoriser_error`, `fiscal_number`, `receipt_number`, `issued_at`, `total`, `currency`, `merchant_name`, `card_last4`, `qr_payload`, `qr_issued_at`, `qr_total`, `qr_fiscal_number`, `qr_receipt_number`, `batch`, `ingest_id`, `sha256`, `ocr_requested_at`, `category_id`, `suggested_category_id`, `suggested_category_confidence`, `lock_version` |
| `receipt_ground_truths` | What a receipt really says, according to one source (a saved tax-service file, a person) | `receipt_id`, `source`, `document` (the OCR receipt shape), `schema_version`, `items_known`, `categories_known`, `prefilled_by`, `prefilled_model_version`, `prefilled_prompt_version`, `categories_prefilled_by`, `source_sha256`, `source_format`, `checked_at`, `check_outcome`, `check_note` |
| `receipt_items` | One line printed on a receipt | `receipt_id`, `position`, `name`, `quantity`, `unit_price`, `amount`, `discount`, `category_id`, `suggested_category_id`, `confidence`, `suggested_by`, `name_key`, `accepted_by_user` |

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
  is never lost. A line with no category or with the taxonomy's Uncategorised is **uncategorised**
  (`TransactionLine.uncategorised`); such a line may carry the transaction categoriser's stored suggestion,
  and `category_origin` says how a person set its category from the transactions list (see "Transaction
  suggestions").
- **Receipt.** `status` moves `uploaded` -> `processing` -> `extracted` -> `reviewed`, or ends in `failed`
  (see "OCR" below). `extracted` means the items are filled in and wait for a person; `reviewed` means the
  receipt was accepted into the ledger. `ocr_raw` keeps the OCR service's full answer, or the reason of a
  failure, and `ocr_model_name`, `ocr_model_version` and `ocr_prompt_version` say which model and prompt
  produced the fields and items (they stay when "Enter by hand" keeps the items of an earlier read).
  `filled_from` is `dps_xml` once a person filled the fields and items from the receipt's tax-service record
  in the review form, and `categoriser_model_name` names the categoriser whose suggestions the items (and a
  slip) carry: `Receipts::SuggestCategories` sets it (see "Category suggestions"), with `categorised_at`
  (when suggestions were last filled) and `categoriser_error` (the code of a failed request to the
  categoriser, nil when it answered). A new OCR result clears both.
  The three say what pre-filled the review form when the receipt is saved as ground truth (see "The pre-fill
  rule"). `currency` is what OCR
  read (nil when unknown).
  `kind` says what the paper is: `fiscal` (a cash register receipt, the kind with a tax QR code) or
  `card_slip` (a card terminal slip: a total and a card number, usually no items); nil means "not known
  yet". OCR sets it (once the ML service's answer carries `kind`: no backend sends it yet, see
  `ml/README.md`) and a person corrects it at review; nothing else does (see "QR ground truth" for why a
  QR code does not). `incomplete` marks a torn or cut-off receipt whose total or date cannot be read
  (false by default). `card_last4` is the last four digits of the card printed on a slip, as OCR read them.
  `qr_payload` is the text of the receipt's QR code, and `qr_issued_at`, `qr_total`, `qr_fiscal_number` and
  `qr_receipt_number` are what a tax-service QR code says (see "QR ground truth").
  `batch` is a free label for a bulk upload (for a loaded receipt, the ingest batch). `ingest_id` is the
  stable number the receipt ingest tool gave the receipt (`rcpt_000123`, see "Receipt load"); nil for a
  receipt uploaded in the app. `sha256` is the photo fingerprint. `ocr_requested_at` is when OCR was last
  queued for the receipt, nil when no request waits (see "Who enqueues OCR"). `ocr_batch_id` is the OCR
  batch the receipt waits in, nil when it waits in none (see "OCR in a batch").
  `category` is a card slip's one category: a slip has no items and is booked as one line, its `total` in
  this category; a person chooses it at review, and only a `card_slip` keeps one. `suggested_category` and
  `suggested_category_confidence` (0..1) are the guess for a slip, from its payee's history or the transaction
  categoriser (see "Card slip suggestions"); the item categoriser leaves a slip alone. `lock_version` is the receipt's version, which the review form carries (see "Review").
- **Receipt item.** `amount` is what was paid for the item after its `discount`. It is normally positive,
  but it can be negative (a bottle deposit returned) or zero (a free item). `suggested_category` and
  `confidence` (0..1) are the categoriser's guess, and `suggested_by` where it came from: `memory` (the
  owner's own earlier labels) or `model` (the ML service). `category` is the accepted category, and
  `accepted_by_user` records that a person confirmed it. `name_key` is the name normalised for the label
  memory (`ItemName.key`), kept in step with the name on every save.

## Invariants

"Model" means a validation or callback; "DB" means a constraint or index in PostgreSQL. Where both are
listed, the model gives a readable error and the database is the safety net for code that skips the model
(`update_column`, `insert_all`, SQL).

| Rule | Where |
|---|---|
| Amounts are `decimal(15, 2)`; transaction, line and original amounts are never zero | Model + DB (`*_amount_non_zero`, `transactions_original_amount_consistent`) |
| Money has at most 2 decimal places and a receipt item quantity at most 3; more is refused, never rounded | Model only (`DecimalPlacesValidator`) |
| Currency codes are three upper-case letters (accounts, original currency, receipts) | Model (also upper-cases) + DB (`*_currency_format`) |
| Enum values (account kind, transaction source and status, receipt status and kind) are from their lists; a receipt's `kind` may be nil | Model (`enum ..., validate: true`) + DB (`*_allowed` check constraints) |
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
| A receipt item's `suggested_by` is `memory`, `model` or nil; its `name_key` is `ItemName.key(name)`, never null | Model; DB for the values and the null (`receipt_items_suggested_by_known`) |
| Filling suggestions never writes an item's `category_id` or `accepted_by_user`, nor the receipt's `lock_version` | `Receipts::SuggestCategories` (tested) |
| Filling a slip's suggestion never writes its `category_id` or `lock_version` | `Receipts::SuggestSlipCategory` (tested) |
| Filling a line's suggestion never writes its category or amount, nor the transaction's `lock_version` | `Transactions::SuggestCategories` (tested) |
| Categorising from the list writes only an uncategorised line, never over a newer version of its transaction | `Transactions::Categorise` (row lock and `lock_version`, tested) |
| A suggestion's probabilities are in 0..1, its source is `model`, `history` or `mix`, a category's origin is `person`, `suggestion` or `bulk` and needs a category, and a taken suggestion records its probability and artefact | Model + DB (`transaction_lines_*` checks) |
| A bulk acceptance item is applied at most once and has one outcome (`accepted`, `stale`, `changed`, `failed`) | Model (`BulkAcceptanceItem#apply!` under a row lock); DB for the values and the one item per transaction (unique index) |
| A receipt's `card_last4` is exactly four digits when present | Model + DB (`receipts_card_last4_format`) |
| A receipt's `ingest_id` is `rcpt_` and six or more digits, and unique when present | Model + DB (`receipts_ingest_id_format`, partial unique index) |
| A receipt's `incomplete` is never nil | Model + DB (not null, default false) |
| A receipt's `category` and `suggested_category` are categories, not groups; `suggested_category_confidence` is in 0..1 | Model; DB for the range (`receipts_suggested_category_confidence_range`) |
| A card slip is booked from its total and its one category; a slip with items, or without a total, is refused | Model only (`Receipts::Accept`) |
| A review save never writes `ocr_raw`, `ocr_model_*`, the QR ground truth, `ingest_id`, `batch`, the photos or `status` | Model only (`Receipts::Review` assigns only the form's fields) |
| A review form rendered from an older version of the receipt (or of its booked transaction) saves nothing | Model only (`Receipts::Review` compares `lock_version` under a row lock) |
| OCR never writes the QR ground truth (`qr_*`, `qr_payload`), `ingest_id`, `batch` or `incomplete` | Model only (`Receipts::ApplyOcr` assigns only its own fields) |
| A receipt is queued for OCR at most once while a request waits, and a `reviewed` one never | Model only (`Receipts::RequestOcr`, under a row lock; `ReceiptOcrJob` checks again when it starts) |
| A ground-truth document has exactly the OCR receipt's keys, money as two-place and quantities as three-place decimal strings (never JSON numbers) | Model only (`ReceiptGroundTruth::Document`); DB checks that it is an object with an `items` list (`receipt_ground_truths_document_shape`) |
| One ground-truth record per receipt and source; `source` is `dps_xml` or `manual` | Model + DB (unique index, `receipt_ground_truths_source_allowed`) |
| A ground-truth record without item lines from its source has an empty item list | Model + DB (`receipt_ground_truths_unknown_items_empty`) |
| An imported (`dps_xml`) record has its file digest and format variant and no `prefilled_by`; a `manual` one has neither digest nor variant | Model + DB (`receipt_ground_truths_imported_fields`, `receipt_ground_truths_manual_fields`) |
| A check has both its time and its outcome (`matches` / `differs`); a note only with a check | Model + DB (`receipt_ground_truths_check_consistent`, `receipt_ground_truths_check_outcome_allowed`) |
| Nothing that books a receipt or runs OCR writes a ground-truth record, and the import writes nothing else; a checked record is never replaced by the import | Model only (`GroundTruthImport::Runner` writes `receipt_ground_truths` only) |
| A receipt's `sha256` and photos change only through the receipt load, and only while the receipt is pristine (no OCR result, items, transaction or ground truth) | Model only (`ReceiptLoad::Writer`, under a row lock) |

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
- the receipt review form carries the receipt's `lock_version` and, for an accepted receipt, its
  transaction's; a mismatch saves nothing and keeps the typed values on the page (see "Review");
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
is blank. It identifies the original upload, so nothing in the app recomputes it. It is changed only by
the receipt load, and only while the receipt is pristine: when the ingest tool regrouped the photos of a
receipt (a merge or a split), the loader replaces its photos and sets the new fingerprint explicitly (see
"Receipt load"). Limits that are accepted:

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
- `ReceiptOcrJob` (Sidekiq) runs the two for one receipt. Only `Receipts::RequestOcr` enqueues it (see
  "Who enqueues OCR"): no model callback does, and neither does the receipt load.
- The job has its own queue, `receipt_ocr`, worked by a Sidekiq capsule with one thread
  (`config/sidekiq.yml`). A local OCR model reads one receipt at a time; with several jobs in parallel each
  would wait for the others inside the ML service and run into the client's OCR timeout. Other jobs keep the
  default capsule (4 threads), and the threads of all capsules together stay within the database
  connection pool, since every thread may hold a connection.

Who moves the status:

| From | To | By |
|---|---|---|
| (new) | `uploaded` | the upload (the column default) |
| `uploaded` | `processing` | `ReceiptOcrJob`, when it starts |
| `failed`, `extracted` | `processing` | `ReceiptOcrJob`, when it starts on a request to read it again (`ocr_requested_at` set) |
| `processing` | `extracted` | `Receipts::ApplyOcr`, with the result |
| `processing` | `failed` | `ReceiptOcrJob`, on a permanent failure or when the retries run out |
| `uploaded`, `failed` | `extracted` | `Receipts::EnterByHand` ("Enter by hand": a person types it) |
| `uploaded`, `failed` | `extracted` | `OcrBatches::ApplyResults`, with a batch's answer (see "OCR in a batch") |
| `uploaded`, `failed` | `failed` | `OcrBatches::ApplyResults` or `OcrBatches::Submit`, when the batch could not read it |
| `extracted`, `reviewed` | `reviewed` | `Receipts::Accept` |
| `reviewed` | `extracted` | destroying its transaction (the receipt is unlinked, keeps its items and can be accepted again) |

The job starts only on `uploaded`, `processing` (its own retry, or a run that died), and on `failed` and
`extracted` while a request to read it again waits (a failed receipt stays failed until a person asks).
It leaves other `failed` and `extracted` receipts and every `reviewed` one alone, so running it twice does the work once and never
overwrites what a person is reviewing. When it starts it clears `ocr_requested_at`; a request for a receipt
that was accepted in the meantime is cleared without reading it. A receipt deleted before the job runs is
discarded quietly.

### Who enqueues OCR

`Receipts::RequestOcr` is the one place that queues `ReceiptOcrJob`, from three places in the app:

| When | Which receipts | Method |
|---|---|---|
| A receipt page is opened, and right after an upload | the receipt, when it is `uploaded` (never read) | `first_read` |
| "Read again" on a receipt page | the receipt, when it is `failed`, `extracted` (after a confirmation: its items are replaced), or `processing` for over an hour (stuck: the job was lost) | `read_again` |
| "Read all in this filter" on the list | every `uploaded` receipt of the filter and every `failed` one without items, on every page, in the list's order | `read_all` |

None of them takes a receipt that waits in an OCR batch (`ocr_batch_id` set; see "OCR in a batch"), and a
batch takes none that waits for a read one at a time. A batch's answer that needs the repair pass is handed
to this queue through `read_all`.

A `reviewed` receipt is never queued: it was accepted into the ledger, and a new OCR result must not change
it (`Receipts::ApplyOcr` refuses it too). A `processing` one is being read already, unless it has been
for longer than `Receipt::OCR_STUCK_AFTER` (an hour, while one read takes minutes with its retries): then
the job was most likely lost (Sidekiq killed mid-job loses it) and the page says so and offers "Read
again". A `failed` receipt can still hold items from an earlier read (a re-read of an `extracted` one that
failed); "Read all" leaves it alone and "Read again" asks first, because a new read replaces them.

**Once.** A request claims its receipts by setting `ocr_requested_at`, in one database transaction that
locks the rows and takes only those where it is nil. The job clears it when it starts. So opening a page
twice, clicking twice, or "Read all" over receipts that are already waiting queues nothing more; two
requests at the same moment are serialised by the row lock, and the second sees the first one's value. The
job is queued after the claim commits, one push per job (Sidekiq's bulk push does not report which jobs it
queued); when the queue (Redis) cannot be reached, the claims of the jobs not queued are taken back and the
page says so, so a receipt never looks queued when it is not. A request older than a day counts
as lost (the queue was emptied by hand) and may be made again; the page then offers "Read again" again. A duplicate job would be harmless anyway:
the OCR queue runs one job at a time, and the second finds the receipt read and does nothing.

**What "opening" means.** A real GET of the receipt page. Turbo's link prefetch (on hover) and the
browser's speculative loads send `Sec-Purpose: prefetch`; such a request, and a HEAD request, queue
nothing. Links to receipt pages also carry `data-turbo-prefetch="false"`, so a prefetched page (which
queued nothing) is never shown in place of a real visit.

**Re-reading a `failed` or `extracted` receipt** needs a request that still waits when the job starts: a
stray duplicate job finds none and leaves the receipt alone, and so does a job that runs after its request
counted as lost (the page offered "Read again" again by then, so it must not look unqueued and still run). A re-read that fails leaves the receipt `failed`, with its
earlier items still there (only a successful read replaces them).

"Read all" can queue hundreds of receipts; the OCR capsule reads them one at a time, so with a local model
this takes hours. The confirmation and the notice say so.

### OCR in a batch

A hosted model's batch mode reads many receipts in one submission, at about half the price, with results
in minutes to a day (`ml/README.md`, "Batch mode"; reasons in `docs/decisions/0017-ocr-batch-mode.md`). It
is off unless the ML service allows it (`OPENROUTER_BATCH_ALLOW_RETENTION`): a batch is not zero-retention,
the provider keeps the photos and answers until the batch is deleted (at most 30 days). The app never reads
that setting; it asks the service (`/ocr/batches/capability`, `OcrBatches::Availability`, kept for five
minutes).

**Entities.** `OcrBatch`: one provider batch of up to a hundred receipts, with its own life cycle (`state`),
what the provider last said (`provider_status`), the provider's batch id, model and provider, the request
counts, the estimated and the actual cost in US dollars (BigDecimal, `numeric` without a scale: every
digit the provider reported), and the times it was submitted, last checked, is due to be checked, expires,
finished and was deleted upstream (with what the provider did with its copy). `OcrBatchEntry`: one receipt
in one batch, with its random key (`custom_id`, 24 URL-safe characters from SecureRandom; the only link
between a provider result and a receipt, kept only in this table) and its outcome. `receipts.ocr_batch_id`
is the hold: the open batch the receipt waits in.

**Sending.** "Read in a batch" on the receipts list (`OcrBatchesController`) shows only when the service
says batch mode is available, in a lazy Turbo Frame so the list never waits for the service. Its
confirmation states the number of receipts and batches, the estimated cost (rough: within a factor of
two), that results take up to a day, and what the provider keeps. `OcrBatches::Create` takes the receipts
"Read all in this filter" would queue (unread, and failed without items to lose) that have photos, splits
them in the list's order into batches of at most `max_receipts` (100) and 150 MB of stored photos, creates
them `pending` with one entry each, and sets each receipt's hold, all in one database transaction.
`OcrBatchSubmitJob` sends the pending batches one at a time (`OcrBatches::Submit`).

**The queue-once rule.** The hold is a column on the receipt, written under the receipt's row lock, as
`Receipts::RequestOcr` writes `ocr_requested_at`. The batch claim takes only receipts with neither a
waiting request nor a hold, and `RequestOcr.readable` skips held receipts, so a receipt is never in a
batch and the synchronous queue at once, nor in two open batches. Opening a held receipt's page queues
nothing; "Read again" says it waits in a batch; `ReceiptOcrJob` leaves a held receipt alone (a stray job
from a request that counted as lost); the receipt load treats it as not pristine, so its photos are not
regrouped while the provider has them. A held receipt keeps its status (`uploaded`, or `failed`, never
`processing`): its page and list row show "In a batch", the batch's number and since when, and it is not
`ocr_in_flight?`, so "Enter by hand" stays offered.

| `OcrBatch.state` | Meaning | Next |
|---|---|---|
| `pending` | created, receipts held, waiting for the submitter (also after a retry wait) | `submitting` |
| `submitting` | the photos are being sent | `running`; `pending` (nothing reached the provider: tried again after 1, 5, 15 and 60 minutes, then `failed`); `failed` (refused for good); `unknown` (sent, answer lost); two `pending` batches (too large: split in half) |
| `running` | the provider has it; checked when due | `applying`; `failed` (failed, expired, cancelled, or OpenRouter no longer has it) |
| `applying` | completed; results being stored entry by entry | `finished` |
| `finished` | every entry resolved | deleted upstream |
| `failed`, `unknown` | its waiting entries released | deleted upstream when the provider had it |

`unknown` is the one case the app cannot settle: the photos were sent and the answer was lost (a timeout
after sending, a server error after the upload, an answer whose batch id cannot be read, a worker stopped
mid-send, noticed after 15 minutes). The provider may have the batch, but sending it again could pay for it
twice, so the receipts are released and the batches page says to look for it in OpenRouter's logs and
delete it there.

**Polling.** There is no webhook: the app has no public URL. `OcrBatchPollJob` runs `OcrBatches::Poll`
(each due batch gets one `OcrBatches::Check`) and queues itself again for when the next batch is due,
between 30 seconds and 15 minutes; a running batch is checked after 1 minute, then 1.5, 2.25, ... up to 15.
One chain at a time: its token and due time are in the cache, and a job of a retired chain stops. A lost
chain (the queue emptied, the worker killed, the cache cleared) is started again by `ensure_scheduled`
once it is ten minutes overdue, from the batches page, the receipts list's offer, a new batch and the
worker's start; "Check now" starts a fresh chain at once. Two runs never overlap (a PostgreSQL advisory
lock), and a check that fails (the service down, batch mode switched off, a rate limit) only records
`check_error_code`/`check_error_message` and waits at least five minutes.

**Results** (`OcrBatches::ApplyResults`). Each waiting entry is resolved in its own database transaction,
with the entry row and then the receipt row locked:

| Entry outcome | When | The receipt |
|---|---|---|
| `applied` | an answer | stored by `Receipts::ApplyOcr` exactly as a read one at a time (fields, items, `extracted`, `ocr_raw` with the model and prompt plus the batch accounting); then its category suggestions come from `ReceiptCategoriseJob` (the same `Receipts::SuggestCategories` step), one receipt at a time on the OCR capsule, so a batch of thousands does not hold up the poller |
| `sync_queued` | the answer needs the repair pass (`ocr_parse_failed`), while the batch has handed over fewer than max(5, 10%) of its receipts | handed to the normal queue (`Receipts::RequestOcr.read_all`) after the commit |
| `failed` | any other error, a parse failure over that limit, or no result for the key | `failed` with the reason in `ocr_raw`, as a read one at a time records it; "Read again" can try |
| `released` | the batch failed, expired or was lost; or storing this entry raised (a bug, reported) | back to what it was, hold cleared |
| `superseded` | the receipt is no longer held by this batch, or no longer `uploaded`/`failed` (entered by hand, deleted) | untouched: the person's work wins |

So a poll that runs twice, or dies half way, never applies a result twice, never loses one (an entry is
either still `waiting` or resolved together with its receipt's change), and never leaves a receipt held by
a finished batch. "Enter by hand" clears the hold under the row lock the batch also takes, so the batch's
later result for that receipt is `superseded`; acceptance needs a reviewable receipt, which a held one
never is. The limit on hand-overs is there because a parse failure in most of a batch means something
systematic (a model that cannot follow the schema), and reading hundreds again at full price is not done
unasked.

**Deleting upstream.** As soon as a batch is `finished` or `failed` and the provider had it, the next
check deletes it at OpenRouter (which also deletes the provider's copy where it can) and records
`deleted_upstream_at` and `upstream_deletion` (`deleted`, `unsupported`: the provider keeps its copy under
its own rules, `not_applicable`, or `gone`: OpenRouter no longer had it). A deletion that fails is tried
again by the poller; the batch stays on its list until it is deleted.

**Pages.** `/ocr-batches` lists every batch with its state, the reason if it failed, the last check's
problem, its receipts (a link to the receipts list filtered by the batch, `ocr_batch=<id>`), provider,
estimated and actual cost and times, and whether batch mode is available now and what it keeps.
`/ocr-batches/:id` adds the counts at the provider, the next check, the expiry, what happened to the
provider's copy, the entries per outcome and every receipt that was not simply read, with the reason.
Both refresh live (`OcrBatches::LiveUpdate`, the stream `ocr_batches` and the batch's own); the receipts
refresh through `Receipts::LiveUpdate` as for a read one at a time.

### Receipt pages

- `/receipts` (`ReceiptsController#index`): 50 receipts to a page (`Pagination`, a COUNT and an OFFSET; no
  gem for a list of a few thousand rows). Newest first (`Receipt.newest_first`): receipts uploaded in the
  app (no ingest number) by upload time, then loaded ones by ingest number, highest first, compared as a
  number. The filter (`Receipt::Filter`: batch, status, kind, tax QR, incomplete, ground truth, the check of
  a tax-service record, the OCR batch it was sent in) is a GET form; its state is the URL, carried by every link (rows, pages, counts,
  receipt pages and back). A value that is not a choice is ignored. The counts per status apply every filter
  but the status; the ground-truth choices (labelled by hand, not labelled by hand, with a tax-service record,
  with none) and the check choices (checked against the print or not) show their counts under every other
  filter. A "Truth" column marks each row ("By hand", "Tax" with its check), and a progress line says how
  many receipts of the list (the ground-truth filter left out) are labelled by hand and how many items their
  records hold.
- `/receipts/:id`: the photos in upload order next to the review form (see "Review") while the receipt is
  reviewable (`extracted` or `reviewed`, no OCR queued or running), and next to the stored data, read-only,
  otherwise. Previous / next walk the filtered list (the ids of the whole filter, plucked: cheap at this
  size). A `failed` receipt shows the stored failure code and message. Under the data column the receipt's
  ground truth (see "Receipt ground truth"): which sources exist, when each was saved, what pre-filled a
  person's record, and a tax-service record next to the receipt with its check.
- `/receipts/new`: one to three photos and an optional batch, sent with the form (no direct upload: Rails'
  Active Storage routes are not drawn). The model's rules are the form's errors; a photo set that was
  already uploaded links to the existing receipt.

**How photos are served.** Rails' own Active Storage routes are not drawn: they skip sign-in.
`Receipts::PhotosController` (`GET /receipts/:receipt_id/photos/:id/:size`) is an ordinary controller
behind sign-in, so a request without a session gets the sign-in redirect like any page. `:id` is the
photo's attachment, looked up among this receipt's photos only: a photo of another receipt or any other
attachment is a 404. Sizes: `thumb` (240 px) and `page` (1600 px) are JPEG variants named on
`Receipt#images`, made by libvips on the first request and kept (`active_storage_variant_records`); `full`
is the photo as uploaded when it is a JPEG, PNG or WebP, and a full-size JPEG copy otherwise (HEIC), so
every browser shows it. Variants are stripped of metadata. The `Content-Type` comes from an allow-list,
never from the stored blob; a blob that is not a photo, or a file that is gone, is a 404, a photo that
cannot be decoded a 422. Responses are `Cache-Control: private, max-age=86400` with an ETag: the photo of
an attachment never changes (a regrouped receipt gets new attachments).

**QR match.** The receipt page shows the tax QR values next to the OCR values of the same fields
(`Receipt::QrComparison`). Both present: "Match" or "Mismatch". A total matches when the two decimals are
equal (125.4 and 125.40 match, nothing is rounded); a time when it is the same minute in Kyiv time (the QR
code carries minutes only, so OCR's seconds are left out); a fiscal or receipt number when the texts are
equal after trimming spaces at the ends, with nothing else normalised. One side only is shown as such,
never as a match.

**Live updates.** The receipt page subscribes to its receipt's Turbo stream and the list to the
`receipts` stream (`turbo_stream_from`, signed stream names, over Action Cable through Redis, so a job in
the Sidekiq process reaches the browser). `Receipts::LiveUpdate` is called explicitly, because the job
writes with `update_columns`: by `ReceiptOcrJob` when it starts and when it fails, by
`Receipts::ApplyOcr` with the result, and by `Receipts::RequestOcr` when OCR is queued. It sends a Turbo
"refresh" (morph, scroll kept) after the database transaction commits: the page fetches itself again with
its own filter and morphs, so the status badge, the data column, the rows and the counts change and
nothing else moves. A refresh rather than replacing parts with rendered partials, because Action Cable
does not promise the order of messages: a job that fails within milliseconds of starting could otherwise
leave "Reading" on the page. Turbo drops a refresh that arrives while a visit is still running (say the
"Reading" refresh), and a page misses what was broadcast before its stream subscribed (a fast job right
after an upload, a cable that dropped while the laptop slept, a page restored by the back button). So the
pages carry a small Stimulus controller (`live_refresh_controller.js`) that asks for one more refresh once
such a visit is done, and whenever the stream (re)connects while the page shows OCR queued or running. A failed broadcast is logged and
reported, never raised into the job. A refresh never lands on a review form with unsaved changes (see
"Review").

Only a signed-in browser opens the WebSocket (`ApplicationCable::Connection` reads the same signed
session cookie as the pages), and a stream is joined only through a name the app signed. The connection
is identified by its session: signing out, and a new password (which ends every other session), close
the ended sessions' sockets once the deletion has committed, and their reconnect is refused.

What is stored where:

- on success, `ocr_raw` is the service's full response body as returned (the `receipt` part plus
  `backend`, `model_name`, `model_version`, `prompt_version`, `repaired` and `elapsed_seconds`).
  `ocr_model_name` and `ocr_model_version` are copied from it; `merchant_name`, `fiscal_number`,
  `receipt_number`, `issued_at`, `total` and `currency` come from the `receipt` part (a null stores nil).
  A real model does not always read everything, so every one of those, including `total` and `currency`,
  may be null; so may an item's `quantity` and `unit_price`. The keys are always present. `kind`
  (`fiscal` or `card_slip`, in any letter case) and `card_last4` (four ASCII digits) are stored when the
  answer carries a valid value; anything else, a missing key included, stores nil. `sum_matches_total`
  stays in `ocr_raw` only. The QR ground truth, `qr_payload`, `ingest_id`, `batch`, `incomplete` and the
  photos are never touched;
- the items are replaced by the returned ones, in the same database transaction. An item's `position` is
  its place in the answer counting from 1, so position N is item N of `ocr_raw`. Amounts and quantities
  are parsed from decimal strings with `BigDecimal`; anything else (a float, unreadable text) counts as
  missing, and so does money with more than two decimal places or a quantity with more than three (the
  models refuse it rather than round it). New items have no category yet;
- on failure, `ocr_raw` is `{"error": {"code": ..., "message": ...}}` and nothing else: no stack trace and
  no response body. `code` is the service's own code (`validation_error`, `too_many_images`,
  `image_too_large`, `unsupported_media_type`, `image_unreadable`, `ocr_parse_failed`,
  `backend_not_implemented`, `internal_error`, and with the hosted backend `openrouter_*` codes such as
  `openrouter_rate_limited` or `openrouter_provider_unverified`, listed in `ml/README.md`), or `ml_unreachable`,
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
  a photo over the service's `ML_MAX_IMAGE_BYTES`, 15 MB by default; 415 `unsupported_media_type`, a
  file whose first bytes are not a JPEG, PNG, WebP or HEIC image; 422 `image_unreadable`, a file that
  cannot be decoded; or 422 `ocr_parse_failed`, the model's answer was not valid receipt JSON even after
  one repair pass: the model is deterministic, so the same photos would fail the same way, and the
  receipt waits for a retry by hand or manual entry; 424, the hosted model's service refused the
  request, for example for lack of credits), 501 (the backend cannot do it, or a setting is missing), an
  answer that is not JSON or misses a required key, no photos attached, a photo file
  missing from storage;
- any other exception (a bug, the database gone) is raised: Sidekiq's own retries apply and the receipt
  stays `processing` until a run succeeds;
- the client opens the connection within `ML_SERVICE_OPEN_TIMEOUT` seconds (default 2), waits up to
  `ML_SERVICE_OCR_TIMEOUT` (default 120; a real model can be slow) for an OCR answer and
  `ML_SERVICE_CATEGORISE_TIMEOUT` (default 120: one receipt's items, perhaps after another receipt's OCR) for a categorisation answer. `/health` waits 5 seconds.
  `ML_SERVICE_URL` is the base URL (default `http://127.0.0.1:8100`);
- `image/heif` photos are sent as `image/heic`: the receipt accepts both names, the service only the
  second.

Photo size has two limits with the same value. The `Receipt` model refuses a photo over
`Receipt::MAX_IMAGE_BYTES` (15 MB, 15,728,640 bytes), so an oversized photo is never stored. The ML service
refuses a file over `ML_MAX_IMAGE_BYTES` (the same 15 MB by default) with 413 `image_too_large`. The model's
limit is a constant: it does not read `ML_MAX_IMAGE_BYTES`. Raising that setting alone changes nothing for
uploads, and lowering it below 15 MB lets the app store photos that the OCR job then fails.

### QR ground truth

A Ukrainian fiscal receipt carries a QR code that links to the tax service's receipt check page. Its query
holds the register's fiscal number, the receipt's fiscal number, the total, the date and the time. The
receipt ingest tool reads it (`tools/receipt_ingest/README.md`, "QR codes"), and the receipt load stores it
in four columns of their own: `qr_issued_at`, `qr_total`, `qr_fiscal_number` and `qr_receipt_number`. Each
is named after the OCR column it is compared with (`issued_at`, `total`, `fiscal_number`,
`receipt_number`).

Why separate columns, and why OCR never writes them:

- they are two sources with different trust. The QR code is printed by the cash register and decoded
  exactly; OCR reads the printed text and can be wrong. Keeping both lets a review screen show where they
  disagree, and lets the OCR evaluation score the model against values it did not produce;
- if OCR wrote into the same columns, or the QR values were copied over the OCR ones, the ground truth would
  be lost the first time either step ran again;
- `tax_qr?` (any of the four present) and the scopes `with_tax_qr` / `without_tax_qr` let a list filter on
  them.

A tax QR code does not set `kind`. `kind` holds what OCR read and what a person corrected; an evaluation
that needs "this is a fiscal receipt" takes it from the QR columns themselves. A QR field that could not be
read stays nil (the others are still stored), and a receipt whose photos carry two different QR codes
(`qr_conflict`) gets no QR value at all, `qr_payload` included: it is not known which code is its own.

### Acceptance

When a receipt is accepted, the transaction's lines are the item amounts summed per category.
`Receipts::Accept.call(receipt, account: nil)` does this and returns the transaction. The grouping is
`CategoryLines` (`app/services/category_lines.rb`), the same code manual entry books with:

- items are grouped by `category`; items with no category form one line with no category. A suggestion is
  used only once it was copied to `category`. A category whose items sum to zero (a free item) adds no
  line, and a category whose items sum below zero (a deposit returned) gives a line of the opposite sign;
- a card slip (`kind` `card_slip`) has no items: it is booked as one line, its `total` in the receipt's
  own `category` (no category gives a line with none). A slip that still has items is refused
  (`NotAcceptable`: remove them or make it a fiscal receipt), and so is one without a total. "The booked
  total" below is the items' sum, or a slip's total (`Receipt#booking_total`);
- a receipt that already has a transaction: the booked total must be the absolute value of its amount, or
  the service raises `TotalMismatch` (it carries both figures). The lines are replaced, not added, and carry
  the transaction's sign. An `account:` argument, if given, must be that transaction's account;
- a receipt with no transaction: `account:` is required. The service creates an expense: amount = minus
  the booked total, `source: receipt`, `occurred_on` = the Kyiv date of `issued_at` (today when unknown),
  `occurred_at` = `issued_at`, `merchant` = `merchant_name`. When the receipt currency is known, it must be
  the account currency;
- the payee is the one named by `merchant_name`, through `Payee.find_or_create_by_name!`: the payee
  normalisation (see Decisions) decides what is the same payee, and a new name creates a payee. A linked
  transaction that already has a payee keeps it (a person or a bank feed may have chosen it); only an empty
  payee is filled. A blank merchant name sets no payee. The payee is written in the service's database
  transaction, so a failed acceptance leaves no new payee, and accepting again finds the same one;
- the transaction becomes `needs_review` when a line has no category, or when the receipt's printed
  `total` is known and the items do not sum to it (OCR may have skipped an unreadable line; never for a
  slip, whose line is its total). `Receipts::Accept.review_reasons` says why in words, for the
  transaction page. The items are
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

Every refusal raises a subclass of `Receipts::Accept::Error`: `NotAcceptable` (status, no items, a slip
with items or without a total, or linked to a transfer leg), `AccountRequired`, `CurrencyMismatch`,
`NothingToBook` (the booked total is zero or less, so there is no expense) and `TotalMismatch`.

### Category suggestions

Every item of a receipt gets a suggested category with a confidence, so the owner can take the confident
ones in bulk ("Accept suggestions from N %") and look only at the doubtful ones. `Receipts::SuggestCategories`
fills them, in this order of trust (the reasons: `docs/decisions/0015-item-categoriser.md`):

1. **The label memory** (below): an item whose name the owner already labelled on another receipt gets that
   category, `suggested_by: "memory"`.
2. **The ML service** (`/categorise`, `CATEGORISE_BACKEND`): the other items of the receipt, in one call,
   with the candidate categories (`Categories::ItemCandidates`: every category except Uncategorised and
   Adjustments, with names, descriptions and groups) and the shop's name as context. The answer may only
   name those slugs (the client refuses anything else as an invalid answer). Each item gets the best
   candidate and its score, `suggested_by: "model"`. Whether the score is calibrated depends on the
   service's setup (`ml/README.md`); the page shows it as a percentage either way.

**When.** Right after OCR stores the items, in the same `ReceiptOcrJob`, so the suggestions arrive right
behind the items instead of behind every other queued read. "Suggest categories again" on the receipt
page queues `ReceiptCategoriseJob`, which asks again without reading the receipt; its queue
(`receipt_categorise`) is worked by the OCR capsule's one thread before the OCR queue, so a request does
not wait behind hundreds of queued reads. Only an `extracted` receipt with items gets suggestions; a card
slip has none (it gets its own `suggested_category`, see "Card slip suggestions").

**What never overwrites what.**

- A suggestion never writes `category` or `accepted_by_user`: a category a person chose stays, and the
  item's suggestion fields are refreshed beside it. Taking a suggestion is a person's choice in the form
  ("Use", Enter, "Accept suggestions"), which the save marks `accepted_by_user`.
- Suggestions are not form fields, so filling them does not move the receipt's `lock_version`: a review
  form open meanwhile stays valid, and a later save keeps them.
- A new OCR result replaces the items, so their suggestions go with them and new ones are filled.
- The service answers outside the receipt's lock (a local model takes seconds); the writes then happen
  under it. An item renamed or removed meanwhile is skipped, and a receipt no longer `extracted` (accepted,
  read again) is not written at all.
- A failure of the categoriser (the service down, a timeout, a 501 from a backend that cannot categorise,
  an invalid answer) never fails the receipt: OCR's result stays, the label memory's suggestions are still
  stored, the other items keep what they had, the receipt is `extracted` and records the error code in
  `categoriser_error`; the page says the categoriser could not answer and offers "Suggest categories again".
  A bug in the filling itself is reported and recorded as `internal_error`, never raised: a retry of the
  OCR job would find the receipt read and do nothing.

**Provenance.** `suggested_by` says per item where its suggestion came from. `categoriser_model_name`
says, for the pre-fill rule of the ground truth, whose suggestions the items carry: the model's name when
any item carries a model's suggestion (the model that answered, or after a failure the one recorded
before), `label-memory` (`LabelMemory::CATEGORISER_NAME`) when the memory filled them all, nil when no item
has a suggestion. A mix of memory and model names the model: the receipt must leave the model's test set,
and the memory, a rule over the owner's own labels, keeps it; that makes the memory's own score slightly
optimistic on such receipts (an accepted limit; the per-item source stays in `suggested_by` should the
evaluation need it). When suggestions are filled again by a different categoriser on a receipt where a
person already chose a category, the receipt records `source:unknown` instead of the new name: the earlier
suggestions may have shaped that choice, and naming only the latest would let the earlier categoriser be
scored on it. A memory-only or model receipt otherwise always names its categoriser, so it is not lost to
every categoriser; a receipt whose items carry suggestions of an unknown source (filled before this
existed) stays nil, which the pre-fill rule reads as `source:unknown`.

**Limits, accepted.** A taken suggestion counts as a person's label, so the memory can repeat what the
model or the memory suggested before (two taken suggestions already reach 0.92); the evaluation measures
the memory on labels it did not pre-fill. The stub categoriser (the ML service's default) suggests invented
categories: set `CATEGORISE_BACKEND` (to `mlx`, or `off`) when OCR runs on a real model; the page names the
categoriser (`stub-categoriser`) in its summary line. The confidence is stored as a number only: whether
the service calibrated it is in its answer (`calibrated`) but not on the item yet.

### Card slip suggestions

A card slip has no items: it is booked as one line, its total in one category (`receipts.category`). Its
suggestion (`suggested_category`, `suggested_category_confidence`) comes from its merchant, as a
transaction's would. `Receipts::SuggestSlipCategory` fills it:

1. **The payee's history** (`PayeeHistory`): the payee the merchant name matches by the payee normalisation
   (see Decisions), and the categories its booked transactions (not transfer legs) have lines in, each
   transaction counted once per category, and only a person's labels (a category taken from a transaction
   suggestion, `category_origin` `suggestion` or `bulk`, does not count: the history must not repeat the
   model with a history's confidence). The label memory's rule decides: the category of a strict
   majority (a tie suggests nothing), with the confidence (agreeing + 1) / (transactions + 1.25), used only
   from 0.75 up ("consistent enough": one booking 0.89, two that agree 0.92, 3 of 4 0.76; 2 of 3 is 0.71 and
   goes to the model). `categoriser_model_name` becomes `payee-history`.
2. **The transaction categoriser** otherwise (`/categorise/transaction`, local only), given the merchant name
   as payee and merchant and the total as an expense; its best category and probability, and the model's
   name in `categoriser_model_name`.

**When.** Right after OCR reads a receipt as a slip (in `ReceiptOcrJob`), when a review save turns a receipt
into a card slip (`ReceiptCategoriseJob`), and on "Suggest a category again". Only an `extracted` slip with a
merchant; the written suggestion must still match the merchant asked about.

**What never overwrites what.** As for items: it never writes `category_id` or `lock_version`; a failure of
the service never fails the receipt (the code goes to `categoriser_error`, an earlier suggestion stays). The
review form shows the suggestion under the slip's category with its source; "Use" (or Enter in the empty
field) takes it, and the save stores it.

**The pre-fill rule.** `categoriser_model_name` is what `categories_prefilled_by` records for a slip saved as
ground truth (`payee-history` or the model's name), so a categoriser is not evaluated on a slip it
pre-filled; when the source changes on a slip whose category a person already chose, the receipt records
`source:unknown`, as for items. With `CATEGORISE_BACKEND=off` slip suggestions are off too: the switch exists
to label receipts with no suggestion on screen, and a slip's category is part of that label.

### Label memory

`LabelMemory` (`app/queries/label_memory.rb`) answers: what did the owner call items with this name?

- **Only a person's labels**: items with `accepted_by_user` and a category among the candidates, on other
  receipts than the one being suggested for (an item's own label is not a memory of it). A suggestion the
  person took counts: they chose it.
- **The name key** (`ItemName.key`, stored as `receipt_items.name_key`, indexed for the lookup with the
  category, only over labelled rows): Unicode NFKC, lower case, the Latin letters that look like Cyrillic
  ones in print (a, b, c, e, h, i, k, m, o, p, t, x, y) turned into those, then everything but letters and
  digits dropped (spaces, punctuation, apostrophes). So "МОЛ 2,5% 900Г" and "Мол2.5%900г" match, and so do a
  name printed with a Latin "K" and one with a Cyrillic "К". Weights, volumes and pack sizes are kept: they
  are welded to the name in irregular forms ("Хл400", "Вод1.5літ"), stripping them would need a parser that
  guesses, and the same product from the same shop prints the same way, which is what the memory is for.
  A missed match only costs a model call; a wrong merge would put one product's label on another.
- **The rule**: the category given most often under the key, when it has a strict majority (more than half
  of the labels); a tie or a split vote suggests nothing and the model decides.
- **The confidence**: with `n` labels of which `k` agree, (k + 1) / (n + 1.25), the mean of a Beta(1 + k,
  0.25 + n − k) posterior for "the next item with this name gets this category", from a weak prior that a
  name keeps its category (mean 0.8, worth 1.25 labels). One label gives 0.89, two that agree 0.92, four
  0.95, and a disagreement pulls it down fast (2 of 3: 0.71). With the form's default threshold (90%) one
  earlier label is not enough to take in bulk, two are. It is the memory's own rule, not a measured
  precision: the evaluation measures it like a model's.
- `ml/evaluation/label_memory.py` is the same rule for the offline runs; the Ruby and Python tests read the
  same name cases (`ml/tests/fixtures/item_name_keys.json`), so the two cannot drift apart.

## Review

A person corrects a receipt in the review form on its page and books it from there. The form is
`receipts/_review`; `Receipts::Review` (`app/services/receipts/review.rb`) stores it.

**What a save does.** "Save" overwrites the receipt's columns (kind, merchant, `issued_at` in Kyiv time,
total, currency, fiscal and receipt numbers, card digits, incomplete, a slip's category) and its items with
what the person typed; the receipt stays `extracted`. It never writes `ocr_raw` (the model's original
answer, which the OCR evaluation reads), `ocr_model_*`, the QR ground truth (`qr_*`, `qr_payload`),
`ingest_id`, `batch`, the photos or `status`: they are not form fields. In detail:

- money and quantities are read by `MoneyInput`: a comma is accepted as the decimal separator, spaces
  between thousands are dropped, and anything but a plain decimal (an exponent, two separators) is an error
  next to the field. The value reaches the model as text, so more places than the column keeps is an error
  ("never rounded"), and every kept item is validated even when its cast value did not change (`60.004`
  casts to a stored `60.00`, so Rails would see no change);
- an item whose category a person set or changed gets `accepted_by_user` (cleared when the category is
  cleared); an untouched item keeps its flag. "Use" next to a suggestion, Enter in an empty category field
  and "Accept suggestions from N %" take suggestions the same way: they choose the category, the save marks
  it;
- a row added by a person gets a position after every stored item and after every item of the OCR answer,
  so position N still names item N of `ocr_raw`; a removed row's item is deleted and its position stays
  free; a new row left blank is ignored;
- validation errors appear next to the field or on the row that caused them, and the typed values stay on
  the form. Nothing is saved while any of them stands.

**What an acceptance does.** "Accept" saves and then runs `Receipts::Accept` with the chosen account, in
one database transaction: a refusal (no account, `CurrencyMismatch`, `NothingToBook`, `TotalMismatch`, a
slip with items) leaves nothing saved and shows the reason on the form, with the typed values (a row
marked for removal stays marked). A successful save or acceptance refreshes the receipt's other open pages and
the list (`Receipts::LiveUpdate`); a form there with unsaved changes is not refreshed, and its save is refused
as stale. The page then
opens the transaction (`/transactions/:id`): its lines, its status, why it needs review, and "Next receipt
to review" (the next `extracted` receipt of the list's filter after this one, wrapping around), which has the
focus. A `reviewed` receipt changes only through "Accept again" (save and rebook together), never by a plain
save that would leave items and lines apart. The account a form starts on is the last one used by hand or
from a receipt (`Account.default_for`, read from the ledger), among the active accounts in the receipt's
currency; an account chosen before a Save stays chosen on the page the save returns to.

**Card slips.** A slip has no items and one category for its total. Switching a receipt with items to
"Card slip" shows a confirmation in the form; the items are removed only by a save with it checked, and a
save without it is refused next to the kind. Switching to another kind clears a slip's category.

**Entering by hand.** `Receipts::EnterByHand` ("Enter by hand" on an `uploaded` or `failed` receipt) makes
the receipt `extracted`, so the form opens on it. It invents nothing: an unread receipt starts with no
items, and a failed one keeps the items of an earlier successful read, if it has any. `ocr_raw` becomes
`{"entered_by_hand": {"started_at": ..., "previous_error": ...}}` (the failure it replaces, if any);
`ocr_model_name` and `ocr_model_version` stay as they were (nil for a receipt no model read, the model of the
kept items for a failed one): none is invented. A waiting OCR request
is withdrawn under the row lock the OCR job also takes, so a job queued earlier later finds an `extracted`
receipt with no request and leaves it alone. A receipt being read is refused.

**The duplicate warning.** A fiscal receipt and its card slip are often two photographed receipts of one
purchase. Before "Accept", the form warns (`Receipt::DuplicateCheck`) about a transaction on the chosen
account with the same Kyiv date and the same amount as accepting would book, and about another receipt
not booked yet with the same Kyiv date of `issued_at` and the same total, with links. It is a warning, not a
block: two equal purchases on one day happen. It reflects the values as last saved.

**Changed somewhere else.** The receipt has a `lock_version` (Active Record's optimistic locking). The form
carries the version it was rendered from, and for a reviewed receipt also its transaction's
`lock_version`. Every writer of the reviewable data moves it: `Receipts::ApplyOcr` (always, since it
replaces the items), a review save, `Receipts::EnterByHand`, `Receipts::Accept`, the unlink when the
transaction is destroyed, and `Receipts::RequestOcr`'s claim (Rails' `update_all` moves the lock column).
Under the receipt's row lock the save compares them: a form rendered before OCR read the receipt again or
before another tab saved it saves nothing and says "changed somewhere else"; the typed values stay on the
page (on a detached copy of the receipt, so items that no longer exist do not matter), with a link to the
current version. While OCR is queued or running nothing is saved either, and the page shows the stored data
read-only instead of the form.

**Live refreshes and unsaved work.** A live refresh (see "Live updates") refetches the whole page and morphs
it, which would put the stored values back into a form a person is typing in. So `form_guard_controller.js`
marks the form dirty on any change (and a form re-rendered after a refused save starts dirty), and while it
is dirty it skips Turbo "refresh" stream actions, stops `live_refresh_controller.js` from asking for a
refresh, and refuses to morph the form (a refresh already on its way when the typing started); a notice says
the page has news. The form's own submission is never held back: the response of a refused save (422, 409)
renders with its errors and the typed values, and focus goes to the first field marked invalid. While a submission is on its way the
form is inert, so nothing typed then is lost to the response. Leaving the page while dirty asks first. The
server is still the authority: a stale save is refused as above. What the forms post (`receipt[...]`,
`manual_expense[...]`, and `ground_truth_check[...]` from the check of a tax-service record) is filtered out
of the request log.

**Keyboard.** Tab follows the reading order (the header fields, then each item row left to right). Enter
never submits the form: in the last item row it adds a row (focus on its name), in another row it moves to
the same field of the next row. In the category picker, typing filters the categories and groups, Enter or
Tab takes the highlighted one, and Escape puts the chosen one back; only a category from the list can be
sent. Ctrl+S (Cmd+S) saves, Ctrl+Shift+S (Cmd+Shift+S) saves as ground truth (missing Shift only saves) and
Ctrl+Enter (Cmd+Enter) accepts. Focus moves to the row that takes a removed
row's place, and after a refused save to the first field marked invalid.

**The live totals** in the form's footer (items, total, difference, QR total) are recalculated in the
browser as the person types, on integer hundredths (`BigInt`), never floating point, with the rules of
`MoneyInput`. They are a preview: the figures rendered with the page are the server's.

**One document per receipt.** Everything the form edits lives on the receipt row and its items, so "Save as
ground truth" snapshots the corrected receipt as one document without touching `ocr_raw` (see "Manual ground
truth").

## Transaction suggestions

The ledger's uncategorised lines (no category, or the taxonomy's Uncategorised; most came from the history
import) get a suggestion from the transaction categoriser (`docs/decisions/0006-transaction-categoriser.md`,
"Serving"), and the transactions list (`/transactions`) is where a person takes or corrects them.

**The list.** Newest first, paginated, filtered by the URL (`Transaction::Filter` over `TransactionsQuery`:
dates, account, category or group, status, source, payee name, text, "uncategorised only", "booked expenses
only", currency). Each row links to the transaction's page. The dashboard's "needs review" figure links to
`status=needs_review`, its uncategorised spending to `uncategorised=1&expense=1` with the period and currency
(booked expenses, as the figure counts them).

**Where suggestions live.** On the line: the best category and its probability, the runner-up and its
probability, the source (`model`; `mix` when the payee's or the MCC's history weighed in; `history` when it
decided), the artefact (`suggestion_model_version`: its fit date and file hash) and the time.
`Transactions::SuggestCategories`, run by `TransactionSuggestionsJob` from "Refresh suggestions" (one run at a
time, `TransactionSuggestionRun` records its progress and failure), sends every transaction with an
uncategorised line whose suggestion is missing (never made, or its category deleted since) or from another
artefact to the ML service in batches of 200, and writes the suggestion columns of the lines still
uncategorised with `update_all`: never a category, an amount or a `lock_version`, so it cannot disturb a
person's edit. It writes under the lines' row locks, taken in id order as categorising takes them, so the two
wait for each other instead of deadlocking. A new artefact therefore refreshes every suggestion; the same
artefact asks nothing again. A transaction with no text and no MCC is skipped. Lines a person categorised keep
their last suggestion, for the record. `MlClient#categorise_transactions` sends transaction data only to an ML
service on this machine (`ML_SERVICE_URL` on a loopback host); any other URL raises `MlClient::NotLocal`
(`ml_not_local`) before anything is sent. Suggestions here are independent of `CATEGORISE_BACKEND`: that switch
is about receipt labelling.

**Taking one.** Under each transaction with uncategorised lines the list shows, per line, the suggestion with
its probability and source, the runner-up, "Take", and the category picker with "Save" (a split transaction
line by line; transfer legs have no lines and never appear). A transaction booked from a receipt shows a link
to its receipt instead: "Accept again" rebuilds its lines from the items, so it is categorised there. The keys:
j / k move between lines (the arrows too, once a line has the focus), t takes, c opens the picker; focus moves
to the next waiting line. `Transactions::Categorise` does the write:

- only an uncategorised line is written: a category already set (by anyone) is never overwritten, the answer
  is "has a category by now";
- the form carries the transaction's `lock_version` and the suggestion it showed (category and artefact);
  under row locks on the transaction and its lines a newer version saves nothing ("changed somewhere
  else"), and so does a suggestion refreshed since it was shown: "Take" saves exactly the suggestion on
  screen, never a newer one, and a category picked by hand is refused too in that rare race. The row is then
  shown as it is now. "Take" always means the suggestion shown; Enter submits through the form's default
  button, "Save", so it saves the category picked, never the suggestion;
- a transaction booked from a receipt is refused (`on_receipt`), and a save the model's rules refuse is
  `invalid`, never an exception;
- the lines are saved through their transaction (nested autosave), so the line rules hold and the version
  moves;
- **status:** `needs_review` becomes `confirmed` when no line is uncategorised any more and nothing else
  needs a look (a receipt whose items do not sum to its printed total keeps it); a draft stays a draft
  (categorising books nothing); a confirmed one stays confirmed (`Transaction#status_after_categorising`);
- **provenance:** `category_origin` is `suggestion` when the chosen category is the suggestion shown (taken
  with "Take" or picked by hand: it was on screen), `person` otherwise, and `bulk` from a bulk acceptance;
  a taken suggestion records its probability and artefact as stored on the line, verified under the lock
  (required by the model and a check; an origin needs a category). A retraining tells the model's own
  accepted output from a person's labels by this (`docs/decisions/0006-transaction-categoriser.md`,
  "Self-training"), and the payee history of slips counts only a person's labels. Categories set elsewhere
  (receipts, manual entry, the import) have no origin.

**The bulk action.** "Accept suggestions from N %" for the list's current filter:

1. **Preview** (`BulkAcceptance.preview!`): a snapshot, one item per transaction of the filter with an
   uncategorised line whose stored suggestion reaches N %: its `lock_version`, the line, the suggestion
   (category, probability, artefact). Split transactions are left out (the model scores a transaction as a
   whole, so all its lines carry one suggestion; a person decides them line by line), and so are
   transactions booked from a receipt. The page shows how many transactions, per category, and which
   artefacts. Nothing is written to the ledger.
2. **Confirmation** by a person (`confirm!`, once: a second click is told it is applied once). A preview
   nobody confirmed is never applied and can be dropped.
3. **The job** (`BulkAcceptanceJob`) applies each item at most once: under the item's row lock, an item with
   an outcome is skipped, and the categorising (`Transactions::Categorise`, origin `bulk`) and the outcome are
   written in one database transaction. An item whose transaction was edited after the preview (a newer
   `lock_version`) is `stale`, one whose line has a category by now or carries another suggestion (a refresh
   by a new artefact; checked under the lines' row locks, so a refresh cannot slip in between) is `changed`:
   both are skipped and counted, never overwritten. One the ledger's rules refuse is `failed` (nothing
   written) and the job goes on. An item whose transaction was deleted goes with it. A second acceptance over
   the same rows finds them stale or changed. The page follows the progress live; an unexpected error marks
   the run `failed`, a confirmed or running one that has not moved for an hour (its job lost, a worker killed
   mid-run) counts as lost, and "Resume" carries on where either stopped (should the old job still be alive,
   each item is still applied once).

**Limits, accepted.** The probabilities are the model's own, not calibrated on the ledger; the selection
JSON has the precision at each threshold on the validation slice. Suggestions refresh only on "Refresh
suggestions" (or the job), not when a new uncategorised line appears.

## Manual entry

`/transactions/new` is the same form without a receipt: an account, a payee (optional), a date, an
optional time (Kyiv time) and rows of name, amount and category, with the same live footer and keyboard.
`ManualExpense` (`app/models/manual_expense.rb`) books one expense transaction with `source: manual`: amount =
minus the rows' sum, lines = the row amounts summed per category through `CategoryLines`, `needs_review` when
a line has no category. The rows themselves are not stored: without a receipt there are no items to keep
them on, so only the lines remain. Amounts follow the same rules as the review form (a comma is accepted,
nothing is rounded); rows may be negative, but they must sum above zero. The payee and the transaction are
written in one database transaction, so a failure leaves neither. Incomes and transfers are not entered
here.

## Receipt load

`bin/rails "receipts:load[DIR]"` loads the output folder of the receipt ingest tool (`tools/receipt_ingest/`,
its `receipts.jsonl` and `images/`). The code is in `app/services/receipt_load/` (`Runner` is the entry
point). It is meant to run again after every ingest run.

Checks before any write (`ReceiptLoad::Verifier`); any problem stops the load and nothing is written:

- every line is a JSON object with the keys and types the loader needs; receipt ids are `rcpt_` and six
  or more digits and unique; no two lines to load have the same photos;
- every image file is a regular file inside DIR (no absolute path, no `..`, no symlink out of it), with
  the recorded size and SHA-256, and the line's `fingerprint` is `Receipt.fingerprint` of the images;
- `qr_fields` values are null or parse: `issued_at` an ISO 8601 time with an offset (at most six
  fractional digits, what the column keeps), `total` a decimal with two places (read with `BigDecimal`,
  never a float). A total too large for `decimal(15, 2)` is stored as nil with a warning instead: one
  misread QR code must not stop every receipt.

Skipped and counted, not problems: a line without images; a line with more than three photos
(`too_many_parts`: fix the grouping in the ingest tool's override file and run it again); a line flagged
`processing_failed` or `raw_missing` whose files fail the check (the tool says it may leave such a line;
its next run repairs it), with a warning. Crops are not loaded.

Finding the receipt of a line: by `ingest_id` first, then by `sha256` (the line's fingerprint).

| Found | What happens |
|---|---|
| nothing | a new receipt: `uploaded`, the photos in part order, `sha256` = the fingerprint, `ingest_id`, `batch`, `qr_payload` and the `qr_*` columns |
| a receipt with the same `sha256` (and the same or no `ingest_id`) | only the ingest fields are written (`ingest_id` when blank, `batch`, `qr_payload`, `qr_*`), and only when they differ; OCR fields, `kind`, `incomplete`, items, status and the transaction are never touched. A photo file missing from storage is uploaded again |
| the same `ingest_id`, another `sha256` (the tool regrouped the photos) | while the receipt is pristine (`uploaded`, no items, no transaction, no ground truth), checked again under a row lock: its photos are replaced and its `sha256` set to the new fingerprint; otherwise a conflict |
| one receipt by `ingest_id` and another by `sha256`, or a `sha256` match that carries another `ingest_id` | a conflict |

A conflict is left alone and reported with ids. A loaded receipt whose `ingest_id` is no longer in the file
(the tool merged, excluded or regrouped it) is deleted while pristine, and kept and reported otherwise:
never silently. These go first, so a merge (the photos of a retired receipt join another one) settles in
one run. A receipt uploaded in the app (no `ingest_id`) is never deleted.

**One database transaction per receipt, not one for the whole load.** The history import is all or nothing
because its rows refer to each other (transfer pairs, payees, accounts). Receipts do not: each stands
alone. And the photo files are written by Active Storage to the disk, outside any database transaction, so
one transaction over 1.4 GB of photos would still not make the files all or nothing. Instead each receipt
is safe on its own:

- its photo files are uploaded first, then attached inside the receipt's database transaction, so a
  committed receipt always has its files. Each blob row is made before its upload, so when an upload
  fails, the transaction fails, or a regrouped receipt turns out not to be pristine, every blob row and
  file made for that receipt is deleted again;
- the storage service compares the stored bytes with the MD5 from the check, so a file that changed in
  between fails its receipt instead of being stored;
- the match is made before the row lock, so it is checked again under the lock: a receipt that another
  run regrouped in between is a conflict, not a receipt that gets the wrong QR values;
- a receipt that fails is counted and named, the others go on, and the task exits with status 1;
- a second run of the same folder writes nothing, so a load that stopped half way is simply run again. A
  run that was killed between an upload and its commit can leave unattached blobs
  (`ActiveStorage::Blob.unattached`); they hold no receipt and can be purged.

`DRY_RUN=1` does all of it inside one outer database transaction, with a savepoint per receipt, and rolls
back at the end. It uploads no file: it creates blob rows only (marked as identified, so attaching them does
not read a file), which the rollback removes.

The load never sets `kind` and never enqueues OCR. It prints counts per outcome (in total and per batch, by
the batch folder name, as the ingest tool's own summary does) and warnings with receipt ids, never a QR
payload, a raw photo name, a total or a date; Active Record's SQL log
is silenced while it runs, for the same reason. A real run needs Redis: attaching a photo enqueues Active
Storage's analysis job, and the task checks Redis before it writes.

## Receipt ground truth

The OCR evaluation needs to know what a receipt really says. The QR code gives the total, the date and time
and the two fiscal numbers ("QR ground truth"), but not the items. A `receipt_ground_truths` row
(`ReceiptGroundTruth`) is "what this receipt says, according to one source", items included:

| Column | Meaning |
|---|---|
| `receipt_id` | the receipt (required) |
| `source` | `dps_xml`: a receipt file a person saved from the tax service's receipt page, read by the ground-truth import; `manual`: a person's reading of the print, saved from the review form ("Save as ground truth"). One row per receipt and source |
| `document` | the receipt in the shape of the OCR contract's `receipt` object (`ml/README.md`): `kind`, `merchant`, `fiscal_number`, `receipt_number`, `issued_at`, `total`, `currency`, `card_last4`, `is_return`, `category_slug` and `items` (`name`, `quantity`, `unit_price`, `amount`, `discount`, `category_slug`). Every key is present; any value but an item's name may be null (not known), an item's `amount` and `discount` too, unlike in an OCR answer |
| `schema_version` | the shape of `document`: 1 (no categories) or 2 (with `category_slug`); see "Schema versions" |
| `items_known` | whether the source gave item lines at all |
| `categories_known` | whether the document gives every category (each item's, and a card slip's own); false means none is given |
| `prefilled_by`, `prefilled_model_version`, `prefilled_prompt_version` | what filled the review form before a person corrected it (a model's name, `source:hand` or `source:dps_xml`), and the model's version and prompt version; nil for an imported record. See "The pre-fill rule" |
| `categories_prefilled_by` | the categoriser whose suggestions were on the form when the person chose the categories (`source:unknown` when suggestions were there and nothing recorded whose); nil when none was, and for an imported record |
| `source_sha256`, `source_format` | for an imported record: the SHA-256 of the file and the format variant that read it. Never the file's path or content |
| `checked_at`, `check_outcome`, `check_note` | a person compared the record with the printed receipt: `matches` or `differs`, with an optional note |

Why it is built this way:

- **A table of its own, not columns on the receipt or its items.** The receipt's own columns and items are
  what OCR read and a person then corrected for the ledger; they change on every review. Ground truth must
  stay put while the receipt is reworked, and a receipt can have it from more than one source (a saved file
  and a person's reading) to compare. A JSON document per row fits that: a receipt's items are read and
  written as one unit, and the evaluation never queries one item.
- **Never part of booking.** A ground-truth record never creates or changes a transaction, a receipt item,
  a receipt's status or its OCR or QR columns, and nothing that changes those writes here: editing the
  receipt, accepting it, deleting its transaction or running OCR again leaves the record as it was. If the
  evaluation's answers could move with the ledger, a model would be scored against values it helped make.
  Only deleting the receipt removes its records (`ON DELETE CASCADE`): ground truth for a receipt that no
  longer exists has nothing to score. A receipt with a ground-truth record is not pristine
  (`Receipt#pristine?`), so the receipt load neither deletes it when it leaves the ingest set nor replaces
  its photos when the ingest tool regroups them: it keeps the receipt and reports it.
- **The OCR shape, with decimal strings.** Money is a string with exactly two places and a quantity one with
  three (`"12.50"`, `"0.500"`), never a JSON number: a float never holds money, nothing is rounded, and one
  spelling per value means the evaluation compares a prediction with the ground truth through one code
  path. `ReceiptGroundTruth::Document` is the explicit validator (keys, types, formats; problems name keys,
  never values), and the database checks what a constraint can express.
- **`items_known` is stored, not inferred.** "This receipt has no items" (a card slip) and "the source gave
  no item lines" are different facts that an empty list cannot tell apart. With `items_known` false the list
  must be empty (`receipt_ground_truths_unknown_items_empty`), and the evaluation leaves the receipt out of
  item scores instead of counting every predicted item as wrong.
- **`prefilled_by`.** A person who corrects a form a model filled in tends to keep what looks right, so the
  result leans towards that model's answer. Such a record is not test ground truth for that model
  (`independent_of?(model_name)`); it still is for every other model. An imported record was filled by no
  model, so it has no `prefilled_by` (a database constraint). The same holds for categories and the
  categoriser whose suggestions were on the form (`categories_independent_of?`).
- **Checked.** An imported record is what the file says. A person can compare it with the printed receipt and
  record `matches` or `differs` (`record_check!`, `clear_check!`; see "Checking an imported record"); a check
writes its own columns only, so `updated_at` keeps saying when the content was saved. Once
  checked, the import no longer replaces it when the file changes: the person's judgement is about this
  version, and the change is reported as a conflict instead.

### Schema versions

Version 2 adds categories: `category_slug` on each item and on the receipt (a card slip's one category; null
for any other kind). The values are category slugs (`group/category`, never a group's slug), the key the ML
service's contract uses for a category: a renamed category keeps its slug, so a record stays right.
`categories_known` true means every item has one and a slip has its own; false means every category is null
(both a validation and a database constraint, as `items_known` has). Version 1 is the same without the two
keys, and cannot say categories are known.

Both versions stay readable, and a stored record is never rewritten to a newer one: an imported record may
have been checked by a person, and its content does not change with the shape. Everything that reads a
record takes `current_document`, which reads a version 1 document as version 2 with null categories
(`ReceiptGroundTruth::Document.upgrade`); the validator checks each record against its own version. Every
writer writes version 2: the import (with null categories) and "Save as ground truth". The import counts a
version 1 record whose file and format variant are unchanged, and whose document reads the same, as
unchanged: it neither rewrites it nor, when it was checked, turns it into a conflict. The export writes every
record as version 2 (one shape) and says in `stored_schema_version` what it was stored as.

### Manual ground truth

"Save as ground truth" in the review form (`intent=ground_truth`, Ctrl+Shift+S) saves the form as "Save"
does and then writes or replaces the receipt's `manual` record (`Receipts::SaveGroundTruth`), in one
database transaction with the receipt row locked. It never creates or changes a transaction and never moves
the receipt's status: a receipt can be labelled without being accepted, and accepted without being
labelled. "Save" and "Accept" never write ground truth.

- **A snapshot.** The record is built from the receipt as stored after the save
  (`ReceiptGroundTruth::Snapshot`), never from the form's text: the header fields (`issued_at` in Kyiv time
  with its offset, an empty text field as null, `is_return` null since the receipt does not record
  returns), the items in position order with their categories as slugs, and a slip's category. Money has
  exactly two places and a quantity three; a stored value with more would raise rather than be rounded. Later
  edits of the receipt, its items, the ledger (accepting, deleting the transaction), a new OCR result or a
  renamed category leave it as it was saved; only saving it again changes it.
- **Before saving**, each gap is an error on its field, with the typed values kept: the kind set; a total and
  a date and time unless the receipt is marked incomplete; a fiscal receipt's items (each with a name and an
  amount, as always); every item's category and a slip's own, unless "Save without categories" is ticked
  (then, when a category is missing, the record says categories are not known and carries none). Whether the
  items sum to the total is shown in the footer, not enforced: a receipt can print a rounding line.
- **A booked receipt** (`reviewed`) is saved as ground truth as it is stored: its form must change nothing,
  since changing a booked receipt is "Accept again"; a form with changes is refused with that advice.
- **Replacing.** When a record exists and the new snapshot differs (a field, an item, what pre-filled it),
  the first attempt rolls everything back, form included, and shows a short summary (how many fields, which,
  and how many items changed, added or removed) with "Replace the ground truth". That button sends a token,
  the digest of the stored record and the new snapshot: a record changed in between, or a form changed again
  after the question, asks again. Saving what the record already says writes nothing. Replacing clears a
  person's check of the old content.
- After saving, the receipt page opens with "Next receipt to label" focused: the next receipt of the list's
  filter, after this one and wrapping around, without manual ground truth and with its form open
  (`extracted` or `reviewed`, no OCR queued or running); the receipt may have left a "Not labelled by hand"
  filter, so its place is found without that filter. A progress line says how far labelling is in the list.
  An account chosen on the form stays chosen, as after a Save.

**Fill the form from the tax-service record.** Where a receipt has a `dps_xml` record and its form is open
(not booked), the form offers to copy the record's header fields and items into the form, as unsaved edits
(`receipt_review_controller.js`; the server prepares the values in the form's own formats, so the browser
converts nothing). A field the record leaves unknown is emptied, so nothing of the model's answer stays;
every row is replaced and the new rows have no category. The hidden `filled_from` field becomes `dps_xml`,
and any save then stores it on the receipt (only that value, and only when the record exists).

### Labelling without suggestions

A categoriser is not evaluated on labels it pre-filled (below), and that includes the label memory. So
labels that are fair to every categoriser come from receipts labelled with no suggestion on screen at all.
`CATEGORISE_BACKEND=off` (in the shared `.env`, read by the app and the ML service; restart both) switches
every suggestion off, the label memory's included (`ItemSuggestions`):

- a receipt read meanwhile gets its items and no suggestion; `Receipts::SuggestCategories` does nothing
  and records nothing, so `categoriser_model_name` stays nil and a ground-truth record saved from it has
  `categories_prefilled_by` nil: test ground truth for every categoriser;
- the review form shows no suggestion, no "Use", no "Accept suggestions" and no "Suggest categories again",
  and Enter in an empty category takes nothing; a suggestion stored earlier stays on the item, hidden;
- "Suggest categories again" is refused, and the ML service answers `/categorise` with 501.

The protocol:

1. Set `CATEGORISE_BACKEND=off` and restart the app and the ML service.
2. Read a share of the receipts (for example "Read all" over a batch kept for testing) and label each one
   with "Save as ground truth", all before step 3: a suggestion filled later on a receipt a person labelled
   marks it `source:unknown` (see "Category suggestions").
3. Set `CATEGORISE_BACKEND` back to the backend that should suggest. A receipt read while suggestions were
   off gets them with "Suggest categories again" whenever wanted.

Two limits: a receipt that already carried suggestions before the switch keeps them on its items, so its
record still names their categoriser (it leaves that categoriser's test set, on the safe side); and the
person's own memory of earlier receipts is not switched off.

### The pre-fill rule

`prefilled_by` names what filled the form the person corrected, derived from what the receipt records
(`ReceiptGroundTruth::Prefill.of`):

| The receipt | `prefilled_by` | versions |
|---|---|---|
| `filled_from` is `dps_xml` | `source:dps_xml` | none |
| else `ocr_model_name` is set | that model's name | `ocr_model_version`, `ocr_prompt_version` |
| else an OCR answer is stored without a model name | `source:unknown-model` | as stored |
| else (entered by hand from nothing) | `source:hand` | none |

`Receipts::ApplyOcr` writes the model's name, version and prompt version together and replaces every field
and item, and clears `filled_from` and `categoriser_model_name`. "Enter by hand" keeps them: a failed
receipt that keeps the items of an earlier read is still that model's answer, and an unread one has none.
A model name never starts with `source:`, so the two fixed values cannot be taken for a model. The rule
leans towards leaving a receipt out of a model's test set: a person who cleared everything a model filled
and typed it again still gets the model.

**Read again after a correction.** When a receipt a person corrected (or labelled) is read again by another
model, the new answer replaces the fields and items, so the form then holds that model's answer: a record
saved from it names the new model. A record saved before keeps the model it names (a snapshot). A form that
was open while the new answer arrived is refused as stale (`lock_version`), so a record can never carry the
corrections of one model's answer under another model's name. What a person remembers from an earlier
answer is not tracked: an accepted limit.

**Categories.** `categories_prefilled_by` is `receipts.categoriser_model_name` when a kept item (or a card
slip) carries a suggestion at the time of saving, `source:unknown` when one does and the receipt does not say
whose (the evaluation then leaves the record out for every categoriser), and nil when none does or the
record has no categories. A new OCR result replaces the items and so clears `categoriser_model_name` and a
slip's own suggestion; a
review save keeps it (it is not a form field). Rows filled from the tax-service record carry no suggestion.

**In the evaluation.** A record whose `prefilled_by` is a model's name is not test ground truth for that
model, whatever its version or prompt (the same weights answer much the same); one whose
`categories_prefilled_by` names a categoriser is not test ground truth for that categoriser's categories.
Records pre-filled by `source:hand` or `source:dps_xml`, and imported records, count for every model;
`source:unknown-model` (an OCR answer that named no model) counts for none. The names are stored exactly,
as the ML service reports them: one model served by two backends has two names (a local quantised repository
id, a hosted provider's id), so the evaluation maps each name to a model identity before it applies the rule
(`ml/evaluation/models.py`): the same base model whatever its quantisation, host or dated slug; another size
or version of a family is another model; a name it cannot place leaves the record out.

### Checking an imported record

A receipt page with a `dps_xml` record shows it next to the photos: its header and items beside the
receipt's saved values (items paired by their place in the list; categories and `is_return` left out, the
file has neither), each difference marked, and "Matches the print" / "Differs from the print" with an
optional note (`Receipts::GroundTruthChecksController`: `POST` and `DELETE /receipts/:id/ground_truth_check`).
A checked record can be checked again (the new outcome and note replace the old ones) or forgotten. A check
is about the content the person looked at: the page carries the record's `content_version` (a digest of the
document, `items_known` and `categories_known`), and a check is refused when a new import replaced the record
in between, with the new content shown. A check writes only the record's check columns: never its document,
the receipt or its items. The note is posted as `ground_truth_check[note]`, filtered from the request log. The plan is to check
30 to 50 imported records against the print.

### What never touches what

| Writer | Ground truth | Receipt, items | Transaction | Status |
|---|---|---|---|---|
| "Save", "Accept" | never | yes | "Accept" books | "Accept" moves it |
| "Save as ground truth" | writes the `manual` record | as "Save" (nothing on a booked receipt) | never | never |
| A check | the `dps_xml` record's check columns | never | never | never |
| The import | the `dps_xml` record (never a checked one) | never | never | never |
| OCR, "Enter by hand" | never | yes | never | yes |
| The receipt load | never | its own columns only (QR, ingest, photos of a pristine receipt) | never | never |
| Deleting a transaction | never | unlinks the receipt | yes | `reviewed` back to `extracted` |

### Ground-truth import

`bin/rails "receipts:import_ground_truth_xml[DIR]"` (`GroundTruthImport::Runner`, `DRY_RUN=1` rolls back)
reads the receipt files a person saved by hand from the tax service's receipt page, one file per receipt,
named after the receipt's ingest number (`rcpt_000123.xml`), from a private folder outside the repository
(`~/Documents/money_bin_data/dps_xml/`). It reads local files only: nothing in this app requests anything
from the tax service (`docs/decisions/0010-receipt-ground-truth.md` says why).

- The folder must be outside every git repository. Only plain files named `rcpt_NNNNNN.xml` are read;
  other entries (other names, folders, symbolic links) are counted and ignored. Nothing is written in the
  folder.
- `DpsXml::Reader` turns a file into a document. It refuses, with a counted warning, a file over 2 MB, a
  file with a document type declaration (entity expansion and external entities are how an XML file
  explodes or reads other files; libxml2 is also told not to substitute entities, load a DTD or use the
  network), a file that is not well-formed, a layout it does not know and a document that is neither a sale
  nor a return. The format knowledge is in one class per variant (`DpsXml::Check01` today). A value that is
  not an exact decimal with at most two places (three for a quantity), or too large for the document, is
  left out and counted, never rounded; so is a time that does not exist (inside the spring clock change).
  A file without item lines gives a record with `items_known` false, and so does a file with an item row
  the reader cannot keep (no name): a shorter list would look complete. The cashier's name and other
  fields it does not use are never read.
- The receipt is found by `ingest_id`; a file whose receipt is not loaded is skipped with a warning.
- **Cross-check** (`GroundTruthImport::CrossCheck`). The file is compared with the receipt's QR ground
  truth where both have a value: the register's fiscal number, the receipt's fiscal number, the total, and
  the date and time to the minute in Kyiv time. A disagreement means another receipt's file was saved under
  this number, so the file is not imported; the warning names the receipt id and the fields, never the
  values. Agreeing on the register's number proves little (every receipt of that register shares it), so a
  file agrees only when it also matches on the receipt's own fiscal number, or on the total and the time
  together. A file that cannot show this is still imported, as unverified: with a warning naming the
  receipt when the QR code has those values and the file lacks them (`unverifiable`: most likely a tag the
  reader does not know), and counted only when the QR code itself lacks them (`no_qr`: no QR code, or one
  read only in part). The export carries the status, so the evaluation can keep to verified records. A
  file refused for a disagreement never deletes a record stored from it earlier; the warning says so, and
  the export marks the record.
- The receipt's `dps_xml` record is created; left alone when the file's digest and the format variant are
  the same as last time; replaced when either changed (a corrected variant reads the files again), unless a
  person has checked the record: that is a counted conflict and the record stays.
- One database transaction per file; nothing in one file stops the others (an unexpected error is counted
  as failed, and the task then exits with status 1). The output is counts per outcome, counts of values left
  out by kind, and warnings with receipt ids; never a shop name, an item, an amount, a date or a file's
  content. The SQL log is silenced while it runs.

`bin/rails "receipts:export_ground_truth[OUT_DIR]"` (`GroundTruthExport`) writes every record to
`OUT_DIR/ground_truth.jsonl` for the offline evaluation (`ml/evaluation/` reads files): `receipt_id`,
`ingest_id`, `source`, `source_format`, `saved_at`, `prefilled_by`, `prefill_kind` (`model`, `hand`,
`dps_xml`, null), `prefilled_model_version`, `prefilled_prompt_version`, `categories_prefilled_by`,
`checked_at`, `check_outcome`, `qr_check`, `items_known`, `categories_known`, `schema_version` (always 2),
`stored_schema_version` and `document` (as version 2, categories as `category_slug`). With `prefilled_by`
and `categories_prefilled_by` the evaluation applies the pre-fill rule. `qr_check` is the cross-check made again at export time
(`agrees`, `disagrees`, `unverifiable`, `no_qr`), so a record that QR values loaded or changed later
contradict is marked and the evaluation can leave it out. The evaluation harness (`make eval`, `docs/decisions/0014-evaluation-harness.md`) reads this file: it leaves out a `dps_xml` record that `disagrees` and any record checked as `differs`, prefers `dps_xml` to `manual`, and leaves a record out of a run whose model pre-filled it (`prefilled_by`, `prefilled_model_version`; names are mapped to a model identity in `ml/evaluation/models.py`, so a local quantised build and the hosted id of the same model are one model, and an unknown name leaves the record out). It refuses a folder inside a git repository, creates it readable by the
owner only and writes the file with mode 0600 through a new temporary file (exclusive, never through a
link); it prints the count only.

## Reports

`SpendingSummaryQuery` (behind `GET /api/v1/summary`) is the one report so far. Its rules follow from the
model above:

- only booked rows count (`Transaction.booked`); a draft is in no figure;
- transfer legs are left out: they move money between own accounts, and a fee is already its own expense;
- a transaction is an expense when its amount is negative and an income when it is positive, as in the
  `expenses` and `incomes` scopes; a refund booked as a positive row is therefore an income;
- its lines are summed per category, so a split transaction gives each category its share, and an
  opposite-sign line (a bottle deposit returned) lowers its category inside the expense;
- a group's figure is the sum of its categories; a line with no category stays apart (no category, no group);
- each currency is summed on its own: there are no exchange rates, so two currencies are never added;
- months are calendar months of `occurred_on`, and amounts keep the ledger's sign.

The reasons are in [`decisions/0007-read-api.md`](decisions/0007-read-api.md).

`TopPayeesQuery` ranks payees by what they took in a range, per currency, with the same rules on the
expense side: its named payees, the other payees and the spending with no payee add up to the summary's
expense total for the same range and currency. A split transaction counts once, whole, for its payee.
`ReceiptCountsQuery` counts the receipts per status, read by OCR (`ocr_model_name` set) and with ground
truth; it is a pipeline state, so it has no period or currency.

The dashboard (the home page, `Dashboard`) shows these figures for a period (the last 12 full months and
the current one, or a calendar year) and one currency; spending is shown positive there, and the
categories beyond the ten largest are summed as "Other"; lines with no category are shown as "No
category", apart from the Uncategorised category, and the headline's uncategorised figure is the two
together. Reasons:
[`decisions/0013-dashboard-charts.md`](decisions/0013-dashboard-charts.md).

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
`Receipt#total` and `#qr_total`; a receipt item `quantity` (`decimal(12, 3)`) gets the same rule with three places. A
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
uploading, in any order. The receipt ingest tool computes the same value for its `fingerprint`, which is how
the receipt load recognises a receipt that was uploaded in the app first.

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
- `occurred_at`, `issued_at` and `qr_issued_at` are `timestamptz`; the Rails timestamps stay `timestamp`
  (UTC).
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

- Who (person or agent) wrote a row. Authentication and API tokens are in place
  (`docs/decisions/0002-authentication-and-api-tokens.md`).
- Writes over the API and the MCP server (an agent proposing a draft, accepting a receipt). Reading is in
  place: the read API (transactions, accounts with balances, the category tree, a spending summary and
  receipts; `docs/openapi.yaml`, `docs/decisions/0007-read-api.md`) and the read-only MCP server at `/mcp`,
  whose tools call the same query objects (`docs/decisions/0008-mcp-server.md`).
- The item-level metrics over the exported ground truth (`ml/evaluation/`), with the pre-fill rule.
- Recording which suggestion a person took for each item, should the evaluation need more than
  "suggestions were on the form" (the source of each suggestion is on the item, `suggested_by`, but not in
  the ground-truth snapshot).
- A model trained on the collected item labels (nearest neighbours or logistic regression
  on embeddings), once labels exist: it would be one more `CATEGORISE_BACKEND`, or a step between the label
  memory and the zero-shot model.
- Editing a booked transaction in the app (its amount, date or account), and entering an income or a
  transfer by hand. Category suggestions while typing a manual expense (the transaction categoriser could
  suggest a row's category from the payee; left out to keep the form as it is).
- Refreshing transaction suggestions on their own when a new uncategorised line appears (today: "Refresh
  suggestions"), and calibrating their probabilities on the ledger.
- A slip's category and suggestion in the read API and the MCP tools (the booked line already carries the
  category).
- A database trigger for the line sum, if anything starts writing lines past the models.
- Matching bank items to receipts and to each other (two legs of a bank-to-bank transfer).
- Exchange rates and a base-currency view (the dashboard shows one currency at a time until then).
- Top payees and receipt counts over the REST API and the MCP server (their query objects are ready).
- Payee merging and categorisation rules.
- Budgets and other planning features.
