# The item categoriser (docs/decisions/0015-item-categoriser.md):
#
# - receipt_items.name_key: the item name normalised for the label memory (ItemName.key), set by the model on
#   every save; backfilled here. The label memory looks up accepted labels by it (a partial index).
# - receipt_items.suggested_by: where the suggestion came from, `memory` (the owner's own earlier labels) or
#   `model` (the ML service). Existing suggestions came from no known source and get `model`.
# - receipts.categorised_at: when suggestions were last filled; categoriser_error: the code of a failed request
#   to the categoriser (nil when it answered). receipts.categoriser_model_name (whose suggestions are on the
#   items) came with the labelling change.
class AddItemCategoriserColumns < ActiveRecord::Migration[8.1]
  # A frozen copy of the model's view of the table, so later model changes cannot break this migration.
  class MigrationItem < ActiveRecord::Base
    self.table_name = "receipt_items"
  end

  def up
    add_column :receipt_items, :name_key, :string
    add_column :receipt_items, :suggested_by, :string
    add_column :receipts, :categorised_at, :timestamptz
    add_column :receipts, :categoriser_error, :string

    MigrationItem.reset_column_information
    MigrationItem.find_each { |item| item.update_columns(name_key: ItemName.key(item.name)) }
    execute "UPDATE receipt_items SET suggested_by = 'model' WHERE suggested_category_id IS NOT NULL"

    change_column_null :receipt_items, :name_key, false
    add_check_constraint :receipt_items, "suggested_by IN ('memory', 'model')", name: "receipt_items_suggested_by_known"
    add_index :receipt_items, %i[name_key category_id], where: "accepted_by_user AND category_id IS NOT NULL",
      name: "index_receipt_items_on_label_memory"
  end

  def down
    remove_index :receipt_items, name: "index_receipt_items_on_label_memory"
    remove_check_constraint :receipt_items, name: "receipt_items_suggested_by_known"
    remove_column :receipts, :categoriser_error
    remove_column :receipts, :categorised_at
    remove_column :receipt_items, :suggested_by
    remove_column :receipt_items, :name_key
  end
end
