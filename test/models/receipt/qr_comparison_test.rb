require "test_helper"

class Receipt::QrComparisonTest < ActiveSupport::TestCase
  def compare(**attributes)
    receipt = Receipt.new(**attributes)
    Receipt::QrComparison.new(receipt).rows.index_by(&:field).transform_values(&:state)
  end

  test "the fixture receipt whose QR code agrees with OCR matches on every field" do
    rows = Receipt::QrComparison.new(receipts(:market_receipt)).rows

    assert_equal %i[issued_at total fiscal_number receipt_number], rows.map(&:field)
    assert rows.all? { |row| row.state == :match }
    assert_empty Receipt::QrComparison.new(receipts(:market_receipt)).mismatches
  end

  test "totals are compared exactly, as decimals" do
    assert_equal :match, compare(qr_total: BigDecimal("125.4"), total: BigDecimal("125.40"))[:total]
    assert_equal :mismatch, compare(qr_total: BigDecimal("125.40"), total: BigDecimal("125.41"))[:total]
    assert_equal :mismatch, compare(qr_total: BigDecimal("0.10"), total: BigDecimal("0.01"))[:total]
  end

  test "times are compared to the minute in Kyiv time" do
    qr = Time.zone.parse("2026-11-02 09:15:00")

    assert_equal :match, compare(qr_issued_at: qr, issued_at: qr + 59.seconds)[:issued_at]
    assert_equal :match, compare(qr_issued_at: qr, issued_at: Time.utc(2026, 11, 2, 7, 15, 30))[:issued_at]
    assert_equal :mismatch, compare(qr_issued_at: qr, issued_at: qr + 60.seconds)[:issued_at]
    assert_equal :mismatch, compare(qr_issued_at: qr, issued_at: qr - 1.second)[:issued_at]
  end

  test "numbers are compared as text, without normalising" do
    assert_equal :match, compare(qr_fiscal_number: "4000000001", fiscal_number: " 4000000001 ")[:fiscal_number]
    assert_equal :mismatch, compare(qr_fiscal_number: "4000000001", fiscal_number: "04000000001")[:fiscal_number]
    assert_equal :mismatch, compare(qr_receipt_number: "A-1024", receipt_number: "a-1024")[:receipt_number]
  end

  test "a value on one side only, or on neither, is not a match or a mismatch" do
    states = compare(qr_total: BigDecimal("1"), fiscal_number: "1")

    assert_equal :qr_only, states[:total]
    assert_equal :ocr_only, states[:fiscal_number]
    assert_equal :none, states[:issued_at]
  end
end
