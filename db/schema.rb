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

ActiveRecord::Schema[8.1].define(version: 2026_11_17_160600) do
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
    t.index ["category_id"], name: "index_receipt_items_on_category_id"
    t.index ["receipt_id", "position"], name: "index_receipt_items_on_receipt_id_and_position", unique: true
    t.index ["suggested_category_id"], name: "index_receipt_items_on_suggested_category_id"
    t.check_constraint "\"position\" >= 0", name: "receipt_items_position_non_negative"
    t.check_constraint "confidence >= 0::double precision AND confidence <= 1::double precision", name: "receipt_items_confidence_range"
    t.check_constraint "discount >= 0::numeric", name: "receipt_items_discount_non_negative"
    t.check_constraint "quantity > 0::numeric", name: "receipt_items_quantity_positive"
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
    t.index ["batch"], name: "index_receipts_on_batch"
    t.index ["sha256"], name: "index_receipts_on_sha256", unique: true
    t.index ["status"], name: "index_receipts_on_status"
    t.index ["transaction_id"], name: "index_receipts_on_transaction_id", unique: true
    t.check_constraint "currency::text ~ '^[A-Z]{3}$'::text", name: "receipts_currency_format"
    t.check_constraint "sha256::text ~ '^[0-9a-f]{64}$'::text", name: "receipts_sha256_format"
    t.check_constraint "status::text = ANY (ARRAY['uploaded'::character varying, 'processing'::character varying, 'extracted'::character varying, 'reviewed'::character varying, 'failed'::character varying]::text[])", name: "receipts_status_allowed"
  end

  create_table "transaction_lines", force: :cascade do |t|
    t.bigint "transaction_id", null: false
    t.bigint "category_id"
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.string "legacy_category_path"
    t.text "comment"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id"], name: "index_transaction_lines_on_category_id"
    t.index ["transaction_id"], name: "index_transaction_lines_on_transaction_id"
    t.check_constraint "amount <> 0::numeric", name: "transaction_lines_amount_non_zero"
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
    t.index "transfer_id, ((amount > (0)::numeric))", name: "index_transactions_one_leg_per_side", unique: true, where: "(transfer_id IS NOT NULL)"
    t.index ["account_id", "occurred_on"], name: "index_transactions_on_account_id_and_occurred_on"
    t.index ["occurred_on"], name: "index_transactions_on_occurred_on"
    t.index ["payee_id"], name: "index_transactions_on_payee_id"
    t.index ["source", "external_id"], name: "index_transactions_on_source_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["status"], name: "index_transactions_on_status"
    t.check_constraint "amount <> 0::numeric", name: "transactions_amount_non_zero"
    t.check_constraint "mcc::text ~ '^[0-9]{4}$'::text", name: "transactions_mcc_format"
    t.check_constraint "original_amount IS NULL AND original_currency IS NULL OR original_amount IS NOT NULL AND original_currency IS NOT NULL AND original_amount <> 0::numeric AND sign(original_amount) = sign(amount)", name: "transactions_original_amount_consistent"
    t.check_constraint "original_currency::text ~ '^[A-Z]{3}$'::text", name: "transactions_original_currency_format"
    t.check_constraint "source::text = ANY (ARRAY['legacy'::character varying, 'receipt'::character varying, 'manual'::character varying, 'api'::character varying, 'bank'::character varying]::text[])", name: "transactions_source_allowed"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'needs_review'::character varying, 'confirmed'::character varying]::text[])", name: "transactions_status_allowed"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "receipt_items", "categories"
  add_foreign_key "receipt_items", "categories", column: "suggested_category_id"
  add_foreign_key "receipt_items", "receipts"
  add_foreign_key "receipts", "transactions", on_delete: :nullify
  add_foreign_key "transaction_lines", "categories"
  add_foreign_key "transaction_lines", "transactions"
  add_foreign_key "transactions", "accounts"
  add_foreign_key "transactions", "payees"
end
