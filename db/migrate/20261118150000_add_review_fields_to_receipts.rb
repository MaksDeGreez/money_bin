# What the review form needs on a receipt (docs/domain.md, "Review").
#
# - `lock_version`: Active Record's optimistic lock counter. The review form carries it, so a save from a
#   page rendered before OCR read the receipt again, or before another tab saved it, is refused instead of
#   overwriting the newer data. Every writer of the receipt's reviewable data bumps it (a save of the
#   receipt row; Receipts::ApplyOcr and the review save always write the row).
# - `category_id`: the one category of a card slip, which has no items and is booked as one line. A person
#   chooses it in the form; only a `card_slip` keeps one.
# - `suggested_category_id`, `suggested_category_confidence`: room for the categoriser's guess for a slip
#   (filled by a later change), as receipt items have it.
#
# Every column is new and nullable or has a default, so existing rows stay valid.
class AddReviewFieldsToReceipts < ActiveRecord::Migration[8.1]
  def change
    change_table :receipts, bulk: true do |t|
      t.integer :lock_version, default: 0, null: false
      t.references :category, foreign_key: true
      t.references :suggested_category, foreign_key: { to_table: :categories }
      t.float :suggested_category_confidence

      t.check_constraint "suggested_category_confidence >= 0 AND suggested_category_confidence <= 1",
        name: "receipts_suggested_category_confidence_range"
    end
  end
end
