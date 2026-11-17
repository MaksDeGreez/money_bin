module LegacyImport
  # Writes the payees of the export. A payee is found by its normalised name (Payee.normalize_name), so
  # several old payees that differ only in case, width or spacing fold into one; the first one in the file
  # gives the new payee its name. An existing payee is never renamed, so `updated` stays 0: the payee is the
  # same, whatever spelling the export uses.
  #
  # Returns a Hash of legacy_id => Payee.
  class PayeeLoader
    def self.call(rows, report)
      new(rows, report).call
    end

    def initialize(rows, report)
      @rows = rows
      @report = report
    end

    def call
      keys = @rows.to_h { |row| [ row.legacy_id, Payee.normalize_name(row.name) ] }
      payees = Payee.where(normalized_name: keys.values.uniq).index_by(&:normalized_name)
      @report.payees_folded = keys.size - keys.values.uniq.size

      seen = Set.new
      @rows.each do |row|
        key = keys.fetch(row.legacy_id)
        # The first row with a name decides; later rows with the same normalised name fold into it.
        next unless seen.add?(key)

        if payees.key?(key)
          @report.count(:payees, :unchanged)
        else
          payees[key] = create(row)
        end
      end
      keys.transform_values { |key| payees.fetch(key) }
    end

    private
      def create(row)
        payee = Payee.new(name: row.name)
        RecordErrors.save!(payee, Location.of(row))
        @report.count(:payees, :created)
        payee
      end
  end
end
