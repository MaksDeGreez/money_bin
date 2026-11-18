module GroundTruthImport
  # Compares a ground-truth document read from a file with the receipt's QR ground truth, field by field,
  # where both sides have a value: the register's fiscal number, the receipt's fiscal number, the total, and
  # the date and time to the minute in Kyiv time (the QR code carries no seconds).
  #
  #   check = CrossCheck.call(receipt, document)
  #   check.status       # => :agrees, :disagrees, :unverifiable or :no_qr
  #   check.disagreeing  # => ["total"]  where the two differ (field names only)
  #
  # Agreeing on the register's number alone proves little: every receipt of that register shares it. So a
  # file agrees only when nothing differs and it matches on identifying evidence: the receipt's own fiscal
  # number, or the total together with the time. When the QR code has that evidence but the file does not
  # (a value left out, a tag the reader does not know), the file is `unverifiable`. When the QR code itself
  # lacks it (no QR code, or one read only in part), the file cannot be checked: `no_qr`. Only `disagrees`
  # keeps a file out; the other two are imported as unverified, and the export carries the status.
  #
  # A disagreement means the file saved under this receipt's number belongs to another receipt. Nothing
  # here returns or prints a value.
  class CrossCheck
    FIELDS = {
      "fiscal_number" => :qr_fiscal_number, "receipt_number" => :qr_receipt_number,
      "total" => :qr_total, "issued_at" => :qr_issued_at
    }.freeze
    # Each set of fields identifies one receipt when all of them agree.
    EVIDENCE = [ %w[receipt_number], %w[total issued_at] ].freeze

    Outcome = Data.define(:compared, :disagreeing, :qr_has_evidence) do
      def status
        return :disagrees if disagreeing.any?
        return :agrees if EVIDENCE.any? { |fields| (fields - compared).empty? }

        qr_has_evidence ? :unverifiable : :no_qr
      end

      def stored?
        status != :disagrees
      end
    end

    def self.call(receipt, document)
      compared = []
      disagreeing = []
      FIELDS.each do |field, column|
        file_value = document[field]
        qr_value = receipt[column]
        next if file_value.nil? || qr_value.nil?

        compared << field
        disagreeing << field unless same?(field, file_value, qr_value)
      end
      qr_has_evidence = EVIDENCE.any? { |fields| fields.all? { |field| !receipt[FIELDS.fetch(field)].nil? } }
      Outcome.new(compared:, disagreeing:, qr_has_evidence:)
    end

    def self.same?(field, file_value, qr_value)
      case field
      when "total" then BigDecimal(file_value) == qr_value
      when "issued_at" then minute(Time.iso8601(file_value)) == minute(qr_value)
      else file_value.strip == qr_value.strip
      end
    end

    def self.minute(time)
      time.in_time_zone(Time.find_zone!("Europe/Kyiv")).change(sec: 0)
    end
    private_class_method :same?, :minute
  end
end
