# The SHA-256 of the export row an importer last wrote a record from (LegacyImport::RowDigest). A later run
# that finds the same digest leaves the record alone, so changes a person made in the app since are kept;
# only a changed export row is written again. Nil for rows no importer wrote.
class AddImportDigestToTransactionsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :import_digest, :string
    add_column :accounts, :import_digest, :string
  end
end
