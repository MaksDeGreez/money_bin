# The owner who signs in through the browser. The app has exactly one user (see User).
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.timestamps

      t.index :email_address, unique: true
      # Every row has the same value for the expression `true`, so a unique index on it allows one row
      # only. This is the safety net behind the model's one-user rule.
      t.index "(true)", unique: true, name: "index_users_single_row"
    end
  end
end
