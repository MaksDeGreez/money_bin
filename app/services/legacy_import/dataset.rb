module LegacyImport
  # A verified export: typed rows that the loaders can write without checking them again. Built by Verifier.
  # Every row keeps its `file` and `line`, so a later problem can still say where it came from.
  class Dataset < Data.define(:manifest, :accounts, :categories, :payees, :transactions, :warnings)
    AccountRow = Data.define(:file, :line, :legacy_id, :name, :kind, :currency, :archived)
    CategoryRow = Data.define(:file, :line, :legacy_id, :legacy_path, :group_en, :category_en)
    PayeeRow = Data.define(:file, :line, :legacy_id, :name)
    TransactionRow = Data.define(
      :file, :line, :legacy_id, :account_legacy_id, :occurred_on, :occurred_at, :amount, :currency,
      :original_amount, :original_currency, :payee_legacy_id, :comment, :mcc, :bank_description, :merchant,
      :source_system, :transfer_key, :lines
    ) do
      def transfer_leg?
        !transfer_key.nil?
      end
    end
    LineRow = Data.define(:amount, :category_legacy_id, :comment)
  end
end
