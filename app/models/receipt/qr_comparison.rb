# What the tax-service QR code says next to what OCR read, field by field (docs/domain.md, "QR ground truth").
#
#   Receipt::QrComparison.new(receipt).rows
#   # => [#<Row field: :total, qr: 1250.4, ocr: 1250.4, state: :match>, ...]
#
# A row's state:
# - `:match` / `:mismatch` when both values are present;
# - `:qr_only` / `:ocr_only` when one is missing; `:none` when both are.
#
# "Match" means:
# - total: the same amount, compared as decimals (125.4 and 125.40 match; 125.41 does not);
# - issued at: the same minute in Kyiv time. The QR code carries the time to the minute, so the seconds of
#   an OCR reading are left out;
# - fiscal number and receipt number: the same text once spaces at either end are removed. Nothing else is
#   normalised: a leading zero or a letter that differs is a mismatch, since the QR code is exact.
class Receipt::QrComparison
  FIELDS = { issued_at: :qr_issued_at, total: :qr_total, fiscal_number: :qr_fiscal_number, receipt_number: :qr_receipt_number }.freeze

  Row = Data.define(:field, :qr, :ocr, :state) do
    def both? = state == :match || state == :mismatch
  end

  def initialize(receipt)
    @receipt = receipt
  end

  def rows
    FIELDS.map do |ocr_field, qr_field|
      qr = @receipt.public_send(qr_field)
      ocr = @receipt.public_send(ocr_field)
      Row.new(field: ocr_field, qr:, ocr:, state: state(ocr_field, qr, ocr))
    end
  end

  # Fields where both sources have a value and they differ.
  def mismatches
    rows.select { |row| row.state == :mismatch }
  end

  private
    def state(field, qr, ocr)
      return :none if qr.nil? && ocr.nil?
      return :qr_only if ocr.nil?
      return :ocr_only if qr.nil?

      same?(field, qr, ocr) ? :match : :mismatch
    end

    def same?(field, qr, ocr)
      case field
      when :total then BigDecimal(qr.to_s) == BigDecimal(ocr.to_s)
      when :issued_at then minute(qr) == minute(ocr)
      else qr.to_s.strip == ocr.to_s.strip
      end
    end

    def minute(time)
      time.in_time_zone.change(sec: 0)
    end
end
