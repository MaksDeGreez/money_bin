# The category split of a transaction. The lines of a transaction sum to its amount (checked in the model).
class CreateTransactionLines < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_lines do |t|
      t.references :transaction, null: false, foreign_key: true
      t.references :category, foreign_key: true
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.string :legacy_category_path
      t.text :comment
      t.timestamps

      t.check_constraint "amount <> 0", name: "transaction_lines_amount_non_zero"
    end
  end
end
