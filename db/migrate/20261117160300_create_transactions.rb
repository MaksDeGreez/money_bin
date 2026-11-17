# One movement of money on one account. The source and status lists must match the enums in Transaction.
class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      # The (account_id, occurred_on) index below starts with account_id, so no separate index is needed.
      t.references :account, null: false, foreign_key: true, index: false
      t.date :occurred_on, null: false
      t.timestamptz :occurred_at
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.decimal :original_amount, precision: 15, scale: 2
      t.string :original_currency, limit: 3
      t.references :payee, foreign_key: true
      t.text :comment
      t.string :mcc, limit: 4
      t.text :bank_description
      t.string :merchant
      t.string :source, null: false
      t.string :external_id
      t.string :status, null: false, default: "confirmed"
      t.uuid :transfer_id
      t.timestamps

      t.index [ :account_id, :occurred_on ]
      t.index :occurred_on
      t.index :status
      t.index [ :source, :external_id ], unique: true, where: "external_id IS NOT NULL"
      # At most one outgoing and one incoming leg per transfer: so never a third leg, and never two legs with
      # the same sign. It also serves every lookup by transfer_id.
      t.index "transfer_id, (amount > 0)", unique: true, where: "transfer_id IS NOT NULL", name: "index_transactions_one_leg_per_side"

      t.check_constraint "amount <> 0", name: "transactions_amount_non_zero"
      t.check_constraint "(original_amount IS NULL AND original_currency IS NULL) OR " \
        "(original_amount IS NOT NULL AND original_currency IS NOT NULL AND original_amount <> 0 AND " \
        "sign(original_amount) = sign(amount))", name: "transactions_original_amount_consistent"
      t.check_constraint "original_currency ~ '^[A-Z]{3}$'", name: "transactions_original_currency_format"
      t.check_constraint "mcc ~ '^[0-9]{4}$'", name: "transactions_mcc_format"
      t.check_constraint "source IN ('legacy', 'receipt', 'manual', 'api', 'bank')", name: "transactions_source_allowed"
      t.check_constraint "status IN ('draft', 'needs_review', 'confirmed')", name: "transactions_status_allowed"
    end
  end
end
