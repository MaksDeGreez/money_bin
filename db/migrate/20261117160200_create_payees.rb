# The other side of a transaction: a shop, a service or a person.
class CreatePayees < ActiveRecord::Migration[8.1]
  def change
    create_table :payees do |t|
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.timestamps

      t.index :normalized_name, unique: true
    end
  end
end
