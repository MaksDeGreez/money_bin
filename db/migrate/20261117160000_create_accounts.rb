# A place where money is kept, in one currency. The kind list must match Account.kinds.
class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.string :currency, limit: 3, null: false
      t.boolean :archived, null: false, default: false
      t.string :external_id
      t.timestamps

      t.index :name, unique: true
      # A unique index lets many NULLs through, so only accounts that have an external id are unique.
      t.index :external_id, unique: true
      t.check_constraint "kind IN ('cash', 'debit', 'credit', 'savings', 'ewallet', 'business')", name: "accounts_kind_allowed"
      t.check_constraint "currency ~ '^[A-Z]{3}$'", name: "accounts_currency_format"
    end
  end
end
