# A photographed shop receipt and what OCR read from it. The status list must match Receipt.statuses.
class CreateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :receipts do |t|
      # One receipt per ledger transaction at most. When the transaction goes, the receipt stays unlinked.
      t.references :transaction, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.string :status, null: false, default: "uploaded"
      t.jsonb :ocr_raw
      # Not `model_name`: Active Record classes and records already have a `model_name` method.
      t.string :ocr_model_name
      t.string :ocr_model_version
      t.string :fiscal_number
      t.string :receipt_number
      t.timestamptz :issued_at
      t.decimal :total, precision: 15, scale: 2
      t.string :currency, limit: 3
      t.string :merchant_name
      t.text :qr_payload
      t.string :batch
      t.string :sha256, limit: 64, null: false
      t.timestamps

      t.index :sha256, unique: true
      t.index :status
      t.index :batch
      t.check_constraint "status IN ('uploaded', 'processing', 'extracted', 'reviewed', 'failed')", name: "receipts_status_allowed"
      t.check_constraint "currency ~ '^[A-Z]{3}$'", name: "receipts_currency_format"
      t.check_constraint "sha256 ~ '^[0-9a-f]{64}$'", name: "receipts_sha256_format"
    end
  end
end
