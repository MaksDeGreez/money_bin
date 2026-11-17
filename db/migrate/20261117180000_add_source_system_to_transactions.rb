# The system a row first came from (a bank feed, a budgeting app, a hand-typed list), set by importers. Free
# text: the history importer copies it from the export as given. Nil when nobody knows.
class AddSourceSystemToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :source_system, :string
  end
end
