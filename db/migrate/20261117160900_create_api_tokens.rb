# Personal API tokens for AI agents and scripts. Only a SHA-256 digest of the token is stored (see
# ApiToken). The scope list must match ApiToken.scopes.
class CreateApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, limit: 64, null: false
      t.string :scope, null: false, default: "read"
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps

      t.index :token_digest, unique: true
      # Revoked tokens keep their names, so a name can be used again once its old token is revoked.
      t.index [ :user_id, :name ], unique: true, where: "revoked_at IS NULL", name: "index_api_tokens_on_user_id_and_name_active"
      t.check_constraint "scope IN ('read', 'read_write')", name: "api_tokens_scope_allowed"
      t.check_constraint "token_digest ~ '^[0-9a-f]{64}$'", name: "api_tokens_token_digest_format"
    end
  end
end
