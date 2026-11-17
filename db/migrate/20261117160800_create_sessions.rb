# A signed-in browser. The signed cookie `money_bin_v2_session_id` (Session::COOKIE_NAME) points at a row;
# signing out deletes the row.
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end
  end
end
