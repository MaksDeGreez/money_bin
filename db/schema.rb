# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_19_100000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
    t.string "kind", null: false
    t.string "currency", limit: 3, null: false
    t.boolean "archived", default: false, null: false
    t.string "external_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "import_digest"
    t.index ["external_id"], name: "index_accounts_on_external_id", unique: true
    t.index ["name"], name: "index_accounts_on_name", unique: true
    t.check_constraint "currency::text ~ '^[A-Z]{3}$'::text", name: "accounts_currency_format"
    t.check_constraint "kind::text = ANY (ARRAY['cash'::character varying, 'debit'::character varying, 'credit'::character varying, 'savings'::character varying, 'ewallet'::character varying, 'business'::character varying]::text[])", name: "accounts_kind_allowed"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "api_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "token_digest", limit: 64, null: false
    t.string "scope", default: "read", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id", "name"], name: "index_api_tokens_on_user_id_and_name_active", unique: true, where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
    t.check_constraint "scope::text = ANY (ARRAY['read'::character varying, 'read_write'::character varying]::text[])", name: "api_tokens_scope_allowed"
    t.check_constraint "token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "api_tokens_token_digest_format"
  end

  create_table "bulk_acceptance_items", force: :cascade do |t|
    t.bigint "bulk_acceptance_id", null: false
    t.bigint "transaction_id", null: false
    t.integer "lock_version", null: false
    t.bigint "line_ids", null: false, array: true
    t.bigint "category_id", null: false
    t.float "probability", null: false
    t.string "model_version", null: false
    t.string "outcome"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bulk_acceptance_id", "transaction_id"], name: "idx_on_bulk_acceptance_id_transaction_id_c5d1226bb3", unique: true
    t.index ["category_id"], name: "index_bulk_acceptance_items_on_category_id"
    t.index ["transaction_id"], name: "index_bulk_acceptance_items_on_transaction_id"
    t.check_constraint "cardinality(line_ids) > 0", name: "bulk_acceptance_items_has_lines"
    t.check_constraint "outcome::text = ANY (ARRAY['accepted'::character varying, 'stale'::character varying, 'changed'::character varying]::text[])", name: "bulk_acceptance_items_outcome_known"
    t.check_constraint "probability >= 0::double precision AND probability <= 1::double precision", name: "bulk_acceptance_items_probability_range"
  end

  create_table "bulk_acceptances", force: :cascade do |t|
    t.jsonb "filter", default: {}, null: false
    t.integer "threshold_percent", null: false
    t.string "status", default: "previewed", null: false
    t.integer "total_count", default: 0, null: false
    t.integer "accepted_count", default: 0, null: false
    t.integer "stale_count", default: 0, null: false
    t.integer "changed_count", default: 0, null: false
    t.timestamptz "confirmed_at"
    t.timestamptz "started_at"
    t.timestamptz "finished_at"
    t.string "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.check_constraint "status::text = ANY (ARRAY['previewed'::character varying, 'queued'::character varying, 'running'::character varying, 'done'::character varying, 'failed'::character varying]::text[])", name: "bulk_acceptances_status_known"
    t.check_constraint "threshold_percent >= 1 AND threshold_percent <= 100", name: "bulk_acceptances_threshold_range"
  end

  create_table "categories", force: :cascade do |t|
    t.bigint "parent_id"
    t.string "name", null: false
    t.string "slug", null: false
    t.integer "position", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id", "name"], name: "index_categories_on_parent_id_and_name", unique: true, nulls_not_distinct: true
    t.index ["slug"], name: "index_categories_on_slug", unique: true
    t.check_constraint "(parent_id IS NULL) = (strpos(slug::text, '/'::text) = 0)", name: "categories_slug_matches_level"
    t.check_constraint "parent_id <> id", name: "categories_not_own_parent"
    t.check_constraint "slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)?$'::text", name: "categories_slug_format"
  end

  create_table "payees", force: :cascade do |t|
    t.string "name", null: false
    t.string "normalized_name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["normalized_name"], name: "index_payees_on_normalized_name", unique: true
  end

  create_table "receipt_ground_truths", force: :cascade do |t|
    t.bigint "receipt_id", null: false
    t.string "source", null: false
    t.integer "schema_version", null: false
    t.jsonb "document", null: false
    t.boolean "items_known", null: false
    t.string "prefilled_by"
    t.string "source_sha256", limit: 64
    t.string "source_format"
    t.timestamptz "checked_at"
    t.string "check_outcome"
    t.text "check_note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "categories_known", default: false, null: false
    t.string "prefilled_model_version"
    t.string "prefilled_prompt_version"
    t.string "categories_prefilled_by"
    t.index ["receipt_id", "source"], name: "index_receipt_ground_truths_on_receipt_id_and_source", unique: true
    t.index ["source"], name: "index_receipt_ground_truths_on_source"
    t.check_constraint "(checked_at IS NULL) = (check_outcome IS NULL) AND (check_note IS NULL OR checked_at IS NOT NULL)", name: "receipt_ground_truths_check_consistent"
    t.check_constraint "categories_known OR NOT jsonb_path_exists(document, '$.\"items\"[*].\"category_slug\"?(@ != null)'::jsonpath) AND NOT jsonb_path_exists(document, '$.\"category_slug\"?(@ != null)'::jsonpath)", name: "receipt_ground_truths_unknown_categories_null"
    t.check_constraint "check_outcome::text = ANY (ARRAY['matches'::character varying, 'differs'::character varying]::text[])", name: "receipt_ground_truths_check_outcome_allowed"
    t.check_constraint "items_known OR (document -> 'items'::text) = '[]'::jsonb", name: "receipt_ground_truths_unknown_items_empty"
    t.check_constraint "jsonb_typeof(document) = 'object'::text AND document ? 'items'::text AND jsonb_typeof(document -> 'items'::text) = 'array'::text", name: "receipt_ground_truths_document_shape"
    t.check_constraint "schema_version > 0", name: "receipt_ground_truths_schema_version_positive"
    t.check_constraint "schema_version >= 2 OR NOT categories_known", name: "receipt_ground_truths_categories_need_version_2"
    t.check_constraint "source::text <> 'dps_xml'::text OR source_sha256 IS NOT NULL AND source_format IS NOT NULL AND prefilled_by IS NULL AND prefilled_model_version IS NULL AND prefilled_prompt_version IS NULL AND categories_prefilled_by IS NULL AND NOT categories_known", name: "receipt_ground_truths_imported_fields"
    t.check_constraint "source::text <> 'manual'::text OR source_sha256 IS NULL AND source_format IS NULL AND prefilled_by IS NOT NULL", name: "receipt_ground_truths_manual_fields"
    t.check_constraint "source::text = ANY (ARRAY['dps_xml'::character varying, 'manual'::character varying]::text[])", name: "receipt_ground_truths_source_allowed"
    t.check_constraint "source_sha256::text ~ '^[0-9a-f]{64}$'::text", name: "receipt_ground_truths_source_sha256_format"
  end

  create_table "receipt_items", force: :cascade do |t|
    t.bigint "receipt_id", null: false
    t.integer "position", null: false
    t.string "name", null: false
    t.decimal "quantity", precision: 12, scale: 3
    t.decimal "unit_price", precision: 15, scale: 2
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.decimal "discount", precision: 15, scale: 2, default: "0.0", null: false
    t.bigint "category_id"
    t.bigint "suggested_category_id"
    t.float "confidence"
    t.boolean "accepted_by_user", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name_key", null: false
    t.string "suggested_by"
    t.index ["category_id"], name: "index_receipt_items_on_category_id"
    t.index ["name_key", "category_id"], name: "index_receipt_items_on_label_memory", where: "(accepted_by_user AND (category_id IS NOT NULL))"
    t.index ["receipt_id", "position"], name: "index_receipt_items_on_receipt_id_and_position", unique: true
    t.index ["suggested_category_id"], name: "index_receipt_items_on_suggested_category_id"
    t.check_constraint "\"position\" >= 0", name: "receipt_items_position_non_negative"
    t.check_constraint "confidence >= 0::double precision AND confidence <= 1::double precision", name: "receipt_items_confidence_range"
    t.check_constraint "discount >= 0::numeric", name: "receipt_items_discount_non_negative"
    t.check_constraint "quantity > 0::numeric", name: "receipt_items_quantity_positive"
    t.check_constraint "suggested_by::text = ANY (ARRAY['memory'::character varying, 'model'::character varying]::text[])", name: "receipt_items_suggested_by_known"
  end

  create_table "receipts", force: :cascade do |t|
    t.bigint "transaction_id"
    t.string "status", default: "uploaded", null: false
    t.jsonb "ocr_raw"
    t.string "ocr_model_name"
    t.string "ocr_model_version"
    t.string "fiscal_number"
    t.string "receipt_number"
    t.timestamptz "issued_at"
    t.decimal "total", precision: 15, scale: 2
    t.string "currency", limit: 3
    t.string "merchant_name"
    t.text "qr_payload"
    t.string "batch"
    t.string "sha256", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "kind"
    t.boolean "incomplete", default: false, null: false
    t.string "card_last4", limit: 4
    t.timestamptz "qr_issued_at"
    t.decimal "qr_total", precision: 15, scale: 2
    t.string "qr_fiscal_number"
    t.string "qr_receipt_number"
    t.string "ingest_id"
    t.timestamptz "ocr_requested_at"
    t.integer "lock_version", default: 0, null: false
    t.bigint "category_id"
    t.bigint "suggested_category_id"
    t.float "suggested_category_confidence"
    t.string "ocr_prompt_version"
    t.string "filled_from"
    t.string "categoriser_model_name"
    t.timestamptz "categorised_at"
    t.string "categoriser_error"
    t.index "COALESCE(issued_at, (created_at AT TIME ZONE 'UTC'::text)) DESC, id DESC", name: "index_receipts_on_sort_time_and_id"
    t.index ["batch"], name: "index_receipts_on_batch"
    t.index ["category_id"], name: "index_receipts_on_category_id"
    t.index ["ingest_id"], name: "index_receipts_on_ingest_id", unique: true, where: "(ingest_id IS NOT NULL)"
    t.index ["kind"], name: "index_receipts_on_kind"
    t.index ["sha256"], name: "index_receipts_on_sha256", unique: true
    t.index ["status"], name: "index_receipts_on_status"
    t.index ["suggested_category_id"], name: "index_receipts_on_suggested_category_id"
    t.index ["transaction_id"], name: "index_receipts_on_transaction_id", unique: true
    t.check_constraint "card_last4::text ~ '^[0-9]{4}$'::text", name: "receipts_card_last4_format"
    t.check_constraint "currency::text ~ '^[A-Z]{3}$'::text", name: "receipts_currency_format"
    t.check_constraint "filled_from IS NULL OR filled_from::text = 'dps_xml'::text", name: "receipts_filled_from_allowed"
    t.check_constraint "ingest_id::text ~ '^rcpt_[0-9]{6,}$'::text", name: "receipts_ingest_id_format"
    t.check_constraint "kind::text = ANY (ARRAY['fiscal'::character varying, 'card_slip'::character varying]::text[])", name: "receipts_kind_allowed"
    t.check_constraint "sha256::text ~ '^[0-9a-f]{64}$'::text", name: "receipts_sha256_format"
    t.check_constraint "status::text = ANY (ARRAY['uploaded'::character varying, 'processing'::character varying, 'extracted'::character varying, 'reviewed'::character varying, 'failed'::character varying]::text[])", name: "receipts_status_allowed"
    t.check_constraint "suggested_category_confidence >= 0::double precision AND suggested_category_confidence <= 1::double precision", name: "receipts_suggested_category_confidence_range"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "transaction_lines", force: :cascade do |t|
    t.bigint "transaction_id", null: false
    t.bigint "category_id"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "legacy_category_path"
    t.text "comment"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "suggested_category_id"
    t.float "suggestion_probability"
    t.bigint "runner_up_category_id"
    t.float "runner_up_probability"
    t.string "suggestion_source"
    t.string "suggestion_model_version"
    t.timestamptz "suggested_at"
    t.string "category_origin"
    t.float "category_origin_probability"
    t.string "category_origin_model_version"
    t.index ["category_id", "transaction_id"], name: "index_transaction_lines_on_category_id_and_transaction_id"
    t.index ["runner_up_category_id"], name: "index_transaction_lines_on_runner_up_category_id", where: "(runner_up_category_id IS NOT NULL)"
    t.index ["suggested_category_id"], name: "index_transaction_lines_on_suggested_category_id", where: "(suggested_category_id IS NOT NULL)"
    t.index ["transaction_id"], name: "index_transaction_lines_on_transaction_id"
    t.check_constraint "(category_origin::text <> ALL (ARRAY['suggestion'::character varying, 'bulk'::character varying]::text[])) OR category_origin_probability IS NOT NULL AND category_origin_model_version IS NOT NULL", name: "transaction_lines_taken_suggestion_recorded"
    t.check_constraint "amount <> 0::numeric", name: "transaction_lines_amount_non_zero"
    t.check_constraint "category_origin::text = ANY (ARRAY['person'::character varying, 'suggestion'::character varying, 'bulk'::character varying]::text[])", name: "transaction_lines_category_origin_known"
    t.check_constraint "category_origin_probability >= 0::double precision AND category_origin_probability <= 1::double precision", name: "transaction_lines_category_origin_probability_range"
    t.check_constraint "runner_up_probability >= 0::double precision AND runner_up_probability <= 1::double precision", name: "transaction_lines_runner_up_probability_range"
    t.check_constraint "suggestion_probability >= 0::double precision AND suggestion_probability <= 1::double precision", name: "transaction_lines_suggestion_probability_range"
    t.check_constraint "suggestion_source::text = ANY (ARRAY['model'::character varying, 'history'::character varying, 'mix'::character varying]::text[])", name: "transaction_lines_suggestion_source_known"
  end

  create_table "transaction_suggestion_runs", force: :cascade do |t|
    t.string "status", default: "queued", null: false
    t.string "model_version"
    t.integer "total_count", default: 0, null: false
    t.integer "scored_count", default: 0, null: false
    t.integer "skipped_count", default: 0, null: false
    t.string "error"
    t.timestamptz "started_at"
    t.timestamptz "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.check_constraint "status::text = ANY (ARRAY['queued'::character varying, 'running'::character varying, 'done'::character varying, 'failed'::character varying]::text[])", name: "transaction_suggestion_runs_status_known"
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.date "occurred_on", null: false
    t.timestamptz "occurred_at"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.decimal "original_amount", precision: 15, scale: 2
    t.string "original_currency", limit: 3
    t.bigint "payee_id"
    t.text "comment"
    t.string "mcc", limit: 4
    t.text "bank_description"
    t.string "merchant"
    t.string "source", null: false
    t.string "external_id"
    t.string "status", default: "confirmed", null: false
    t.uuid "transfer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "source_system"
    t.string "import_digest"
    t.index "transfer_id, ((amount > (0)::numeric))", name: "index_transactions_one_leg_per_side", unique: true, where: "(transfer_id IS NOT NULL)"
    t.index ["account_id", "occurred_on", "id"], name: "index_transactions_on_account_id_and_occurred_on_and_id"
    t.index ["occurred_on", "id"], name: "index_transactions_on_occurred_on_and_id"
    t.index ["payee_id"], name: "index_transactions_on_payee_id"
    t.index ["source", "external_id"], name: "index_transactions_on_source_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["source"], name: "index_transactions_on_source"
    t.index ["status"], name: "index_transactions_on_status"
    t.check_constraint "amount <> 0::numeric", name: "transactions_amount_non_zero"
    t.check_constraint "mcc::text ~ '^[0-9]{4}$'::text", name: "transactions_mcc_format"
    t.check_constraint "original_amount IS NULL AND original_currency IS NULL OR original_amount IS NOT NULL AND original_currency IS NOT NULL AND original_amount <> 0::numeric AND sign(original_amount) = sign(amount)", name: "transactions_original_amount_consistent"
    t.check_constraint "original_currency::text ~ '^[A-Z]{3}$'::text", name: "transactions_original_currency_format"
    t.check_constraint "source::text = ANY (ARRAY['legacy'::character varying, 'receipt'::character varying, 'manual'::character varying, 'api'::character varying, 'bank'::character varying]::text[])", name: "transactions_source_allowed"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'needs_review'::character varying, 'confirmed'::character varying]::text[])", name: "transactions_status_allowed"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "(true)", name: "index_users_single_row", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "api_tokens", "users", on_delete: :cascade
  add_foreign_key "bulk_acceptance_items", "bulk_acceptances", on_delete: :cascade
  add_foreign_key "bulk_acceptance_items", "categories"
  add_foreign_key "bulk_acceptance_items", "transactions", on_delete: :cascade
  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "receipt_ground_truths", "receipts", on_delete: :cascade
  add_foreign_key "receipt_items", "categories"
  add_foreign_key "receipt_items", "categories", column: "suggested_category_id"
  add_foreign_key "receipt_items", "receipts"
  add_foreign_key "receipts", "categories"
  add_foreign_key "receipts", "categories", column: "suggested_category_id"
  add_foreign_key "receipts", "transactions", on_delete: :nullify
  add_foreign_key "sessions", "users", on_delete: :cascade
  add_foreign_key "transaction_lines", "categories"
  add_foreign_key "transaction_lines", "categories", column: "runner_up_category_id", on_delete: :nullify
  add_foreign_key "transaction_lines", "categories", column: "suggested_category_id", on_delete: :nullify
  add_foreign_key "transaction_lines", "transactions"
  add_foreign_key "transactions", "accounts"
  add_foreign_key "transactions", "payees"
end
