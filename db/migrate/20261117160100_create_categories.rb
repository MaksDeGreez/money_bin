# The two-level category tree: groups (no parent) and the categories inside them.
class CreateCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :categories do |t|
      # The (parent_id, name) index below starts with parent_id, so no separate index is needed.
      t.references :parent, foreign_key: { to_table: :categories }, index: false
      t.string :name, null: false
      t.string :slug, null: false
      t.integer :position, null: false
      t.text :description
      t.timestamps

      # NULLS NOT DISTINCT: group names (parent_id IS NULL) are unique too.
      t.index [ :parent_id, :name ], unique: true, nulls_not_distinct: true
      t.index :slug, unique: true
      t.check_constraint "parent_id <> id", name: "categories_not_own_parent"
      # A group slug is one part ("eating-out"); a category slug is two ("eating-out/takeaway-fast-food").
      t.check_constraint "slug ~ '^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*)?$'", name: "categories_slug_format"
      t.check_constraint "(parent_id IS NULL) = (strpos(slug, '/') = 0)", name: "categories_slug_matches_level"
    end
  end
end
