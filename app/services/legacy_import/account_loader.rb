module LegacyImport
  # Writes the accounts of the export. An account is found by `external_id` = "legacy:<legacy_id>"
  # (EXTERNAL_ID_PREFIX). It is created when missing. A stored account whose `import_digest` equals the
  # digest of its export row (RowDigest) is not written at all, whatever a person changed in the app since;
  # otherwise its name, kind, currency and archived flag are written from the export. Legacy accounts that
  # the export no longer has are left alone and counted in a warning.
  #
  # Account names are unique, and the rule is checked on every save, so two accounts could not swap names
  # (or pass them round) one save at a time. Every stored account whose name the export changes therefore
  # first takes a temporary name (TEMPORARY_NAME), then all of them get their final names. Both steps run in
  # the import's database transaction, so a temporary name is never seen outside it, and a name that an
  # account outside the export holds still stops the import.
  #
  # Returns a Hash of legacy_id => Account.
  class AccountLoader
    EXTERNAL_ID_PREFIX = "legacy:".freeze
    TEMPORARY_NAME = "legacy import: renaming ".freeze

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

      plans = @rows.map { |row| [ row, stored[self.class.external_id(row.legacy_id)], RowDigest.account(row) ] }
      free_names(plans)
      plans.to_h { |row, account, digest| [ row.legacy_id, load(row, account, digest) ] }
    end

    private
      def free_names(plans)
        plans.each do |row, account, digest|
          next if account.nil? || account.import_digest == digest
          next if account.name == Account.normalize_value_for(:name, row.name)

          account.name = "#{TEMPORARY_NAME}#{SecureRandom.uuid}"
          RecordErrors.save!(account, Location.of(row))
        end
      end

      def load(row, account, digest)
        if account&.import_digest == digest
          @report.count(:accounts, :unchanged)
          @report.count_kept(:accounts) if local_edits?(account, row)
          return account
        end

        outcome = account ? :updated : :created
        account ||= Account.new(external_id: self.class.external_id(row.legacy_id))
        account.assign_attributes(attributes(row).merge(import_digest: digest))
        RecordErrors.save!(account, Location.of(row))
        @report.count(:accounts, outcome)
        account
      end

      def attributes(row)
        { name: row.name, kind: row.kind, currency: row.currency, archived: row.archived }
      end

      def local_edits?(account, row)
        attributes(row).any? { |name, value| account.public_send(name) != Account.normalize_value_for(name, value) }
      end
  end
end
