# One line printed on a receipt: a product, its quantity and price, and its category.
class CreateReceiptItems < ActiveRecord::Migration[8.1]
  def change
    create_table :receipt_items do |t|
      # The (receipt_id, position) index below starts with receipt_id, so no separate index is needed.
      t.references :receipt, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :name, null: false
      t.decimal :quantity, precision: 12, scale: 3
      t.decimal :unit_price, precision: 15, scale: 2
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.decimal :discount, precision: 15, scale: 2, null: false, default: 0
      t.references :category, foreign_key: true
      t.references :suggested_category, foreign_key: { to_table: :categories }
      t.float :confidence
      t.boolean :accepted_by_user, null: false, default: false
      t.timestamps

      t.index [ :receipt_id, :position ], unique: true
      t.check_constraint "position >= 0", name: "receipt_items_position_non_negative"
      t.check_constraint "quantity > 0", name: "receipt_items_quantity_positive"
      t.check_constraint "discount >= 0", name: "receipt_items_discount_non_negative"
      t.check_constraint "confidence >= 0 AND confidence <= 1", name: "receipt_items_confidence_range"
    end
  end
end
