require "test_helper"

class ReceiptBookingTest < ActiveSupport::TestCase
  setup do
    @booking = receipt_bookings(:market_booking)
  end

  def linked_previous
    { "format" => 1, "amount" => "-1250.40", "status" => "confirmed", "payee_id" => nil, "lines" => [] }
  end

  test "the snapshot's line columns are exactly the table's: a new column needs a decision and a format version" do
    assert_equal TransactionLine.column_names.sort, ReceiptBooking::LINE_COLUMNS.sort
  end

  test "a created booking has no earlier state and no import digest; a linked one has both shapes right" do
    assert @booking.valid?

    @booking.previous = linked_previous
    assert_not @booking.valid?
    assert_includes @booking.errors[:previous], "must be empty for a created transaction"

    @booking.mode = "linked"
    assert @booking.valid?
    @booking.previous = { "format" => "1", "lines" => [] }
    assert_not @booking.valid?
    assert_includes @booking.errors[:previous], "must record the linked transaction's earlier state"
  end

  test "the database refuses a record of the wrong shape" do
    {
      { mode: "kept" } => "receipt_bookings_mode_allowed",
      { previous: linked_previous } => "receipt_bookings_created_shape",
      { transaction_import_digest: "a" * 64 } => "receipt_bookings_created_shape",
      { mode: "linked", previous: { "format" => 1, "amount" => -1250.4, "status" => "confirmed", "lines" => [] } } => "receipt_bookings_linked_shape",
      { mode: "linked", previous: nil } => "receipt_bookings_linked_shape",
      { lines_digest: "ABC" } => "receipt_bookings_lines_digest_format",
      { assigned_payee_id: nil, payee_created: true } => "receipt_bookings_created_payee_assigned",
      { booked_lock_version: -1 } => "receipt_bookings_booked_lock_version_not_negative"
    }.each do |columns, constraint|
      error = assert_raises(ActiveRecord::StatementInvalid, constraint) do
        ReceiptBooking.transaction(requires_new: true) { @booking.update_columns(columns) }
      end
      assert_match constraint, error.message
    end
  end

  test "one record per receipt and per transaction" do
    copy = @booking.dup
    assert_not copy.valid?
    assert copy.errors.include?(:receipt_id)
    assert copy.errors.include?(:transaction_id)
  end

  test "the lines digest ignores order and ids, and sees a category, an amount, a comment or an origin change" do
    a, b = categories(:groceries).id, categories(:cafes).id
    row = ->(category, amount, comment = nil, origin = nil) { [ category, BigDecimal(amount), comment, nil, origin, nil, nil ] }
    digest = ReceiptBooking.digest_rows([ row.(a, "-10.5"), row.(nil, "-2") ])

    assert_equal digest, ReceiptBooking.digest_rows([ row.(nil, "-2.00"), row.(a, "-10.50") ])
    assert_not_equal digest, ReceiptBooking.digest_rows([ row.(b, "-10.50"), row.(nil, "-2.00") ])
    assert_not_equal digest, ReceiptBooking.digest_rows([ row.(a, "-10.51"), row.(nil, "-1.99") ])
    assert_not_equal digest, ReceiptBooking.digest_rows([ row.(a, "-10.50", "a note"), row.(nil, "-2.00") ])
    assert_not_equal digest, ReceiptBooking.digest_rows([ row.(a, "-10.50", nil, "person"), row.(nil, "-2.00") ])
    assert_match ReceiptBooking::DIGEST_FORMAT, digest
  end

  test "the digest columns are line columns, and the stored suggestion is not among them" do
    assert_empty ReceiptBooking::DIGEST_COLUMNS - TransactionLine.column_names
    assert_empty ReceiptBooking::DIGEST_COLUMNS.grep(/suggest|runner_up/)
  end

  test "a payee a record assigned cannot be destroyed while the record stands" do
    payee = Payee.create!(name: "Only here")
    @booking.update!(assigned_payee: payee, payee_created: true)

    assert_not payee.destroy
    assert Payee.exists?(payee.id)
  end

  test "the record goes with its transaction, and the receipt returns to review" do
    receipt = receipts(:market_receipt)

    assert_difference "ReceiptBooking.count", -1 do
      transactions(:market_split).destroy!
    end
    assert receipt.reload.extracted?
  end
end
