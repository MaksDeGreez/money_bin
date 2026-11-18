# Indexes for the read API's queries (docs/decisions/0007-read-api.md, "Indexes").
#
# - Transactions are listed by (occurred_on DESC, id DESC) and paged by that pair, so the date indexes gain
#   `id` as their last column: a page is then an index range scan with no sort, with or without an
#   account filter. Each old index is a prefix of its replacement, so nothing that used it loses.
# - `source` gets an index of its own for the source filter.
# - The category filter looks for a line of the transaction in a set of categories; (category_id,
#   transaction_id) answers that from the index alone. It replaces the category_id index (its prefix),
#   which the foreign key's checks keep using.
# - Receipts are listed by the time on the receipt, else the upload time, then id (ReceiptsQuery).
class AddReadApiIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :transactions, :occurred_on, name: "index_transactions_on_occurred_on"
    add_index :transactions, %i[occurred_on id]

    remove_index :transactions, %i[account_id occurred_on], name: "index_transactions_on_account_id_and_occurred_on"
    add_index :transactions, %i[account_id occurred_on id]

    add_index :transactions, :source

    remove_index :transaction_lines, :category_id, name: "index_transaction_lines_on_category_id"
    add_index :transaction_lines, %i[category_id transaction_id]

    add_index :receipts, "COALESCE(issued_at, (created_at AT TIME ZONE 'UTC')) DESC, id DESC",
      name: "index_receipts_on_sort_time_and_id"
  end
end
