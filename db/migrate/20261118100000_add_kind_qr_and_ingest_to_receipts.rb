# What a receipt is, what its QR code says, and where it came from (docs/domain.md, "Receipts").
#
# - `kind`: `fiscal` (a cash register receipt) or `card_slip` (a card terminal slip); nil until OCR reads it.
#   A person corrects it at review.
# - `incomplete`: the receipt is torn or cut off, so its total or date cannot be read.
# - `card_last4`: the last four digits of the card on a slip, as OCR read them.
# - `qr_issued_at`, `qr_total`, `qr_fiscal_number`, `qr_receipt_number`: what the tax-service QR code says.
#   Ground truth for the OCR columns of the same names (without `qr_`); OCR never writes them.
# - `ingest_id`: the stable number the receipt ingest tool gave the receipt (`rcpt_000123`); nil for a
#   receipt uploaded in the app.
#
# Every column is new and nullable or has a default, so existing rows stay valid.
class AddKindQrAndIngestToReceipts < ActiveRecord::Migration[8.1]
  def change
    change_table :receipts, bulk: true do |t|
      t.string :kind
      t.boolean :incomplete, default: false, null: false
      t.string :card_last4, limit: 4
      t.timestamptz :qr_issued_at
      t.decimal :qr_total, precision: 15, scale: 2
      t.string :qr_fiscal_number
      t.string :qr_receipt_number
      t.string :ingest_id

      t.check_constraint "kind IN ('fiscal', 'card_slip')", name: "receipts_kind_allowed"
      t.check_constraint "card_last4 ~ '^[0-9]{4}$'", name: "receipts_card_last4_format"
      t.check_constraint "ingest_id ~ '^rcpt_[0-9]{6,}$'", name: "receipts_ingest_id_format"

      t.index :kind
      t.index :ingest_id, unique: true, where: "ingest_id IS NOT NULL"
    end
  end
end
