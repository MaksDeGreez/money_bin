module GroundTruthImport
  # Compares a ground-truth document read from a file with the receipt's QR ground truth, field by field,
  # where both sides have a value: the register's fiscal number, the receipt's fiscal number, the total, and
  # the date and time to the minute in Kyiv time (the QR code carries no seconds).
  #
  #   check = CrossCheck.call(receipt, document)
  #   check.compared     # => ["fiscal_number", "total", ...]  what could be compared
  #   check.disagreeing  # => ["total"]                         where the two differ
  #
  # A disagreement means the file saved under this receipt's number belongs to another receipt. Nothing
  # here returns or prints a value.
  class CrossCheck
    Outcome = Data.define(:compared, :disagreeing) do
      def agrees?
        compared.any? && disagreeing.empty?
      end

      def unverified?
        compared.empty?
      end
    end

    FIELDS = {
      "fiscal_number" => :qr_fiscal_number, "receipt_number" => :qr_receipt_number,
      "total" => :qr_total, "issued_at" => :qr_issued_at
    }.freeze

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
      Outcome.new(compared:, disagreeing:)
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
