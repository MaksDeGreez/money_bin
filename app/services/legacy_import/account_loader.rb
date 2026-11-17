module LegacyImport
  # Writes the accounts of the export. An account is found by `external_id` = "legacy:<legacy_id>"
  # (EXTERNAL_ID_PREFIX), created when missing, updated in place when its name, kind, currency or archived
  # flag differs, and not written at all when it is the same. Legacy accounts that the export no longer has
  # are left alone and counted in a warning.
  #
  # Returns a Hash of legacy_id => Account.
  class AccountLoader
    EXTERNAL_ID_PREFIX = "legacy:".freeze

    def self.external_id(legacy_id)
      "#{EXTERNAL_ID_PREFIX}#{legacy_id}"
    end

    def self.call(rows, report)
      new(rows, report).call
    end

    def initialize(rows, report)
      @rows = rows
      @report = report
    end

    def call
      stored = Account.where("external_id LIKE ?", "#{EXTERNAL_ID_PREFIX}%").index_by(&:external_id)
      exported = @rows.map { |row| self.class.external_id(row.legacy_id) }
      missing = (stored.keys - exported).size
      @report.warn("#{missing} legacy accounts in the database are not in this export; they were left alone") if missing.positive?

      @rows.to_h { |row| [ row.legacy_id, load(row, stored[self.class.external_id(row.legacy_id)]) ] }
    end

    private
      def load(row, account)
        account ||= Account.new(external_id: self.class.external_id(row.legacy_id))
        account.assign_attributes(name: row.name, kind: row.kind, currency: row.currency, archived: row.archived)
        outcome = account.new_record? ? :created : (account.has_changes_to_save? ? :updated : :unchanged)
        RecordErrors.save!(account, Location.of(row)) unless outcome == :unchanged
        @report.count(:accounts, outcome)
        account
      end
  end
end
