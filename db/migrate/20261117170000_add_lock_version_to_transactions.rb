# Optimistic locking for transactions. Every save of a transaction, and every change of its lines through it,
# bumps lock_version, so a save from a stale copy raises ActiveRecord::StaleObjectError instead of writing
# lines that no longer add up (docs/domain.md, "Concurrent writers").
class AddLockVersionToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :lock_version, :integer, null: false, default: 0
  end
end
