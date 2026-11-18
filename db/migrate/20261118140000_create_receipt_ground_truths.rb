# What a receipt really says, according to one source (docs/domain.md, "Receipt ground truth"). One row per
# receipt and source: `dps_xml` (a receipt file a person saved from the tax service's receipt page, read by
# the ground-truth import) or `manual` (a person's reading of the print, saved from the review form later).
#
# - `document`: the receipt in the OCR contract's shape (ml/README.md), money and quantities as decimal
#   strings; `schema_version` says which shape. `items_known` says whether the source gave item lines at
#   all: false with an empty list means "no item ground truth", true with an empty list "the receipt has no
#   items".
# - `prefilled_by`: the model or source that filled the form before a person corrected it (nil for imported
#   records). Such a record is not test ground truth for that model.
# - `source_sha256`, `source_format`: for an imported record, the SHA-256 of the file and the name of the
#   format variant that read it. Never the file's path or content.
# - `checked_at`, `check_outcome`, `check_note`: a person compared the record with the printed receipt.
#
# It is separate from booking: nothing here points at a transaction, an item or an OCR column.
class CreateReceiptGroundTruths < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_ground_truths do |t|
      t.references :receipt, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :source, null: false
      t.integer :schema_version, null: false
      t.jsonb :document, null: false
      t.boolean :items_known, null: false
      t.string :prefilled_by
      t.string :source_sha256, limit: 64
      t.string :source_format
      t.timestamptz :checked_at
      t.string :check_outcome
      t.text :check_note
      t.timestamps

      t.index [ :receipt_id, :source ], unique: true
      t.index :source

      t.check_constraint "source IN ('dps_xml', 'manual')", name: "receipt_ground_truths_source_allowed"
      t.check_constraint "schema_version > 0", name: "receipt_ground_truths_schema_version_positive"
      # `document ? 'items'` first: without the key, `document -> 'items'` is NULL and a CHECK passes on NULL.
      t.check_constraint "jsonb_typeof(document) = 'object' AND document ? 'items' AND jsonb_typeof(document -> 'items') = 'array'",
        name: "receipt_ground_truths_document_shape"
      t.check_constraint "items_known OR document -> 'items' = '[]'::jsonb",
        name: "receipt_ground_truths_unknown_items_empty"
      t.check_constraint "source_sha256 ~ '^[0-9a-f]{64}$'", name: "receipt_ground_truths_source_sha256_format"
      t.check_constraint "source <> 'dps_xml' OR (source_sha256 IS NOT NULL AND source_format IS NOT NULL AND prefilled_by IS NULL)",
        name: "receipt_ground_truths_imported_fields"
      t.check_constraint "source <> 'manual' OR (source_sha256 IS NULL AND source_format IS NULL)",
        name: "receipt_ground_truths_manual_fields"
      t.check_constraint "check_outcome IN ('matches', 'differs')", name: "receipt_ground_truths_check_outcome_allowed"
      t.check_constraint "(checked_at IS NULL) = (check_outcome IS NULL) AND (check_note IS NULL OR checked_at IS NOT NULL)",
        name: "receipt_ground_truths_check_consistent"
    end
  end
end
