require "test_helper"
require "turbo/broadcastable/test_helper"

# Receipts::UndoAccept: a linked booking gives the transaction back its earlier state, a created one removes the
# transaction, and the receipt waits for review again with nothing else lost.
class Receipts::UndoAcceptTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  MODEL_VERSION = "2026-11-18-0123456789ab".freeze

  setup do
    # Extracted, issued 2026-10-08, items: water 60.00 (groceries), sandwich 95.00 (none), deposit -2.50 (groceries);
    # a manual ground-truth record (corner_manual).
    @receipt = receipts(:corner_receipt)
    @bank = bank_row
  end

  # A bank row as the history import leaves it: a split with an opposite-sign line, a comment, a legacy category
  # path, a stored suggestion and a category taken from a suggestion.
  def bank_row(status: :needs_review, payee: nil, first_category: nil, second_category: categories(:groceries),
               suggested: categories(:groceries))
    Transaction.create!(
      account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), occurred_at: Time.zone.local(2026, 10, 9, 8, 1),
      amount: "-152.50", source: :bank, external_id: "bank-row-1", status:, merchant: "CORNER SHOP", payee:,
      import_digest: "a" * 64,
      lines_attributes: [
        { amount: "-160.00", category: first_category, legacy_category_path: "Food / Shops", comment: "Groceries and a refund",
          suggested_category: suggested, suggestion_probability: 0.8731, runner_up_category: categories(:cafes),
          runner_up_probability: 0.0625, suggestion_source: "model", suggestion_model_version: MODEL_VERSION,
          suggested_at: Time.utc(2026, 11, 18, 12, 0, 0, 123_456) },
        { amount: "7.50", category: second_category, comment: "bottle deposit", category_origin: "suggestion",
          category_origin_probability: 0.91, category_origin_model_version: MODEL_VERSION }
      ]
    ).reload
  end

  def link(transaction = @bank)
    Receipts::Accept.call(Receipt.find(@receipt.id), link: transaction, link_lock_version: transaction.reload.lock_version)
  end

  # With the versions as stored unless given: the page was rendered just now.
  def undo(receipt = @receipt, lock_version: nil, transaction_lock_version: nil)
    receipt = Receipt.find(receipt.id)
    lock_version ||= receipt.lock_version
    transaction_lock_version ||= Transaction.where(id: receipt.transaction_id).pick(:lock_version)
    Receipts::UndoAccept.call(receipt, lock_version:, transaction_lock_version:)
  end

  def line_rows(transaction_id)
    TransactionLine.where(transaction_id:).order(:id).map { |line| line.attributes.except("id") }
  end

  def receipt_state(receipt)
    receipt = Receipt.find(receipt.id)
    { receipt: receipt.attributes.except("status", "transaction_id", "lock_version", "updated_at"),
      items: receipt.items.order(:id).map(&:attributes), ground_truths: receipt.ground_truths.order(:id).map(&:attributes),
      images: receipt.images.map(&:blob_id) }
  end

  # The refusal changes nothing: the transaction and its lines, the receipt and its record, the payees.
  def assert_refused(error_class, message = nil, receipt: @receipt, **versions)
    transaction_id = Receipt.find(receipt.id).transaction_id
    before = [ line_rows(transaction_id), Transaction.find_by(id: transaction_id)&.attributes, Receipt.find(receipt.id).attributes,
               ReceiptBooking.find_by(receipt_id: receipt.id)&.attributes ]
    error = nil
    assert_no_difference [ "Transaction.count", "TransactionLine.count", "ReceiptBooking.count", "Payee.count" ] do
      error = assert_raises(error_class) { undo(receipt, **versions) }
    end
    assert_kind_of Receipts::UndoAccept::Error, error
    assert_match message, error.message if message
    assert_equal before, [ line_rows(transaction_id), Transaction.find_by(id: transaction_id)&.attributes, Receipt.find(receipt.id).attributes,
                           ReceiptBooking.find_by(receipt_id: receipt.id)&.attributes ]
    error
  end

  test "a linked booking round trip: every column of every line comes back, the receipt waits for review again" do
    original_lines = line_rows(@bank.id)
    original_line_ids = TransactionLine.where(transaction_id: @bank.id).order(:id).ids
    receipt_before = receipt_state(@receipt)
    link
    assert_not_equal original_lines, line_rows(@bank.id)

    result = nil
    assert_no_difference "Transaction.count" do
      result = undo
    end

    assert_equal :linked, result.mode
    assert_not result.transaction_deleted?
    assert_empty result.dropped
    assert_equal original_lines, line_rows(@bank.id), "every column but the id, timestamps to the microsecond"
    assert_empty TransactionLine.where(id: original_line_ids), "the restored lines are new rows"
    restored = TransactionLine.where(transaction_id: @bank.id).order(:id)
    assert_equal [ BigDecimal("-160.00"), BigDecimal("7.50") ], restored.map(&:amount)
    assert_equal [ "Food / Shops", nil ], restored.map(&:legacy_category_path)
    assert_equal 0.8731, restored.first.suggestion_probability
    assert_equal Time.utc(2026, 11, 18, 12, 0, 0, 123_456), restored.first.suggested_at
    assert_equal [ "suggestion", 0.91, MODEL_VERSION ], restored.second.values_at(:category_origin, :category_origin_probability, :category_origin_model_version)

    @bank.reload
    assert @bank.needs_review?
    assert_nil @bank.payee_id
    assert_equal BigDecimal("-152.50"), @bank.amount
    assert_equal "a" * 64, @bank.import_digest

    @receipt.reload
    assert @receipt.extracted?
    assert_nil @receipt.transaction_id
    assert_nil @receipt.booking
    assert_equal 0, ReceiptBooking.where(transaction_id: @bank.id).count
    assert_equal receipt_before, receipt_state(@receipt), "items, categories, ground truth, OCR and QR columns, photos"
    assert_not @receipt.pristine?

    # Linking again afterwards works, and records the restored state.
    assert_equal @bank, link
    assert_equal "needs_review", @receipt.reload.booking.previous["status"]
    assert @receipt.reviewed?
  end

  test "the undo refreshes the receipt's pages and the list" do
    link
    undo

    assert_turbo_stream_broadcasts @receipt, count: 1
    assert_turbo_stream_broadcasts Receipts::LiveUpdate::STREAM, count: 1
  end

  test "the earlier status and payee come back: a draft stays a draft, a payee of its own stays" do
    @bank.destroy!
    @bank = bank_row(status: :draft, payee: payees(:example_market))
    link
    assert @bank.reload.confirmed? || @bank.needs_review?

    result = undo

    assert @bank.reload.draft?
    assert_equal payees(:example_market), @bank.payee
    assert_not result.payee_kept?
    assert_not result.payee_removed?
  end

  test "a refreshed stored suggestion alone does not block the undo, and the earlier one comes back" do
    original_lines = line_rows(@bank.id)
    link
    TransactionLine.where(transaction_id: @bank.id, category_id: nil)
      .update_all(suggested_category_id: categories(:cafes).id, suggestion_probability: 0.5, suggestion_source: "model",
                  suggestion_model_version: MODEL_VERSION, suggested_at: Time.current)

    assert_equal :linked, undo.mode
    assert @receipt.reload.extracted?
    assert_equal original_lines, line_rows(@bank.id)
  end

  test "an edit in the app since the booking: refused with the way out, and Accept again then undo works" do
    original_lines = line_rows(@bank.id)
    link
    TransactionLine.where(transaction_id: @bank.id, category_id: nil).first.update!(category: categories(:takeaway))

    error = assert_refused(Receipts::UndoAccept::ChangedSinceBooking, /\(its lines\)/)
    assert_match "To undo anyway, accept the receipt again first", error.message

    Receipts::Accept.call(Receipt.find(@receipt.id))
    undo
    assert_equal original_lines, line_rows(@bank.id)
  end

  test "a stale receipt or transaction version is refused" do
    link
    receipt_version = Receipt.find(@receipt.id).lock_version
    transaction_version = @bank.reload.lock_version

    assert_refused(Receipts::UndoAccept::Stale, /receipt changed somewhere else/, lock_version: receipt_version - 1)
    assert_refused(Receipts::UndoAccept::Stale, /transaction changed somewhere else/, transaction_lock_version: transaction_version - 1)
  end

  test "a page opened before an Accept again cannot undo the newer booking" do
    link
    shown_receipt = Receipt.find(@receipt.id).lock_version
    shown_transaction = @bank.reload.lock_version
    receipt_items(:corner_sandwich).update!(category: categories(:takeaway))
    Receipts::Accept.call(Receipt.find(@receipt.id))

    assert_refused(Receipts::UndoAccept::Stale, lock_version: shown_receipt, transaction_lock_version: shown_transaction)
  end

  test "a line whose category changed on its own since the booking is refused" do
    link
    TransactionLine.where(transaction_id: @bank.id).order(:id).first.update!(category: categories(:cafes))
    assert_equal @receipt.reload.booking.booked_lock_version, @bank.reload.lock_version, "a line saved alone keeps the version"

    assert_refused(Receipts::UndoAccept::ChangedSinceBooking, /\(its lines\)/)
  end

  test "an edit of the transaction since the booking is refused" do
    link
    @bank.reload.update!(comment: "edited later")

    assert_refused(Receipts::UndoAccept::ChangedSinceBooking, /its version moved/)
  end

  test "a row a later import rewrote is refused: the export wins" do
    link
    Transaction.where(id: @bank.id).update_all(import_digest: "b" * 64)

    error = assert_refused(Receipts::UndoAccept::ChangedSinceBooking, /a later import rewrote it/)
    assert_no_match(/accept the receipt again/, error.message)
  end

  test "an amount that is not the recorded one is refused" do
    link
    booking = @receipt.reload.booking
    booking.update_column(:previous, booking.previous.merge("amount" => "-150.00"))

    assert_refused(Receipts::UndoAccept::ChangedSinceBooking, /its amount/)
  end

  test "a record of an unknown format is refused" do
    link
    booking = @receipt.reload.booking
    booking.update_column(:previous, booking.previous.merge("format" => 2))

    assert_refused(Receipts::UndoAccept::UnknownFormat, /format 2/)
  end

  test "a record with a line it cannot read is refused" do
    link
    booking = @receipt.reload.booking
    lines = booking.previous["lines"].map { |line| line.merge("amount" => 7.5) }
    booking.update_column(:previous, booking.previous.merge("lines" => lines))

    assert_refused(Receipts::UndoAccept::NotUndoable, /unreadable a line's amount/)
  end

  test "earlier lines that no longer add up are refused after the first writes, and everything is rolled back" do
    link
    booking = @receipt.reload.booking
    lines = booking.previous["lines"].map { |line| line.merge("amount" => "-1.00") }
    booking.update_column(:previous, booking.previous.merge("lines" => lines))

    assert_refused(Receipts::UndoAccept::NotUndoable, /earlier state cannot be restored: Lines must add up/)
    assert @receipt.reload.reviewed?
    assert_equal booking.lines_digest, ReceiptBooking.lines_digest(@bank.id)
  end

  BUSY = Class.new(Receipts::UndoAccept) do
    private def undo = raise(ActiveRecord::Deadlocked, "deadlock detected")
  end

  test "a lock lost to a parallel writer is a refusal to try again" do
    link
    receipt = Receipt.find(@receipt.id)

    error = assert_raises(Receipts::UndoAccept::Busy) do
      BUSY.new(receipt, lock_version: receipt.lock_version, transaction_lock_version: @bank.reload.lock_version).call
    end
    assert_match "try again", error.message
  end

  test "a transfer leg is refused" do
    leg, = Transaction.transfer!(from: accounts(:card_uah), to: accounts(:cash_uah), amount: "152.50", occurred_on: Date.new(2026, 10, 8))
    @receipt.update_columns(transaction_id: leg.id, status: "reviewed")

    assert_refused(Receipts::UndoAccept::NotUndoable, /transfer leg/)
  end

  test "a transaction of another source without a record is refused: its earlier state is not known" do
    @receipt.update_columns(transaction_id: @bank.id, status: "reviewed")

    assert_refused(Receipts::UndoAccept::NotUndoable, /no record of the transaction's state/)
  end

  test "a receipt that is not booked is refused" do
    assert_raises(Receipts::UndoAccept::NotBooked) do
      Receipts::UndoAccept.call(@receipt, lock_version: @receipt.lock_version, transaction_lock_version: nil)
    end
  end

  test "a category deleted since comes back as no category, without its origin, and is reported" do
    bakery = Category.create!(parent: categories(:groceries_group), name: "Bakery")
    @bank.destroy!
    @bank = bank_row(second_category: bakery)
    link
    bakery.destroy!

    result = undo

    line = TransactionLine.where(transaction_id: @bank.id).order(:id).second
    assert_nil line.category_id
    assert_equal [ nil, nil, nil ], line.values_at(:category_origin, :category_origin_probability, :category_origin_model_version)
    assert_equal [ "its category no longer exists" ], result.dropped
    assert @bank.reload.needs_review?
  end

  test "a category turned into a group comes back as no category, and a confirmed transaction then needs review" do
    bakery = Category.create!(parent: categories(:groceries_group), name: "Bakery")
    @bank.destroy!
    @bank = bank_row(status: :confirmed, first_category: categories(:groceries), second_category: bakery)
    link
    bakery.update!(parent: nil, slug: "bakery")

    result = undo

    assert_equal [ categories(:groceries).id, nil ], TransactionLine.where(transaction_id: @bank.id).order(:id).pluck(:category_id)
    assert_equal [ "its category is now a group" ], result.dropped
    assert @bank.reload.needs_review?
  end

  test "a suggested category deleted since drops the whole stored suggestion" do
    bakery = Category.create!(parent: categories(:groceries_group), name: "Bakery")
    @bank.destroy!
    @bank = bank_row(suggested: bakery)
    link
    bakery.destroy!

    result = undo

    line = TransactionLine.where(transaction_id: @bank.id).order(:id).first
    assert_equal [ nil ] * 7, line.values_at(*Receipts::UndoAccept::SUGGESTION_COLUMNS)
    assert_equal "Groceries and a refund", line.comment
    assert_equal [ "its suggested category no longer exists" ], result.dropped
  end

  test "a runner-up deleted since drops only the runner-up" do
    bakery = Category.create!(parent: categories(:groceries_group), name: "Bakery")
    @bank.destroy!
    @bank = bank_row
    TransactionLine.where(transaction_id: @bank.id, category_id: nil).update_all(runner_up_category_id: bakery.id)
    link
    bakery.destroy!

    result = undo

    line = TransactionLine.where(transaction_id: @bank.id).order(:id).first
    assert_equal [ categories(:groceries).id, 0.8731, nil, nil ],
      line.values_at(:suggested_category_id, :suggestion_probability, :runner_up_category_id, :runner_up_probability)
    assert_equal [ "its runner-up suggestion no longer exists" ], result.dropped
  end

  test "a runner-up recorded without a best suggestion (the database nullified it) comes back as recorded" do
    TransactionLine.where(transaction_id: @bank.id, category_id: nil).update_all(suggested_category_id: nil)
    original_lines = line_rows(@bank.id)
    link

    result = undo

    assert_empty result.dropped
    assert_equal original_lines, line_rows(@bank.id)
    assert_equal categories(:cafes).id, TransactionLine.where(transaction_id: @bank.id).order(:id).first.runner_up_category_id
  end

  test "an earlier payee that no longer exists is reported and left empty" do
    link
    booking = @receipt.reload.booking
    booking.update_column(:previous, booking.previous.merge("payee_id" => Payee.maximum(:id) + 1000))

    result = undo

    assert_nil @bank.reload.payee_id
    assert_includes result.dropped, "its earlier payee no longer exists"
  end

  test "a payee Accept created is removed when nothing else uses it" do
    link
    created = @bank.reload.payee
    assert @receipt.reload.booking.payee_created?

    result = nil
    assert_difference "Payee.count", -1 do
      result = undo
    end
    assert result.payee_removed?
    assert_nil @bank.reload.payee_id
    assert_not Payee.exists?(created.id)
  end

  test "a payee Accept created stays when another transaction uses it" do
    link
    created = @bank.reload.payee
    Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 10), amount: "-5.00", source: :manual,
                        payee: created, lines_attributes: [ { amount: "-5.00" } ])

    result = nil
    assert_no_difference "Payee.count" do
      result = undo
    end
    assert_not result.payee_removed?
    assert_nil @bank.reload.payee_id
  end

  # A second receipt from the same shop, linked onto another bank row without a payee.
  def second_receipt_on(transaction, merchant_name: "Corner Shop")
    receipt = receipts(:new_receipt)
    receipt.update_columns(status: "extracted", total: BigDecimal("40.00"), merchant_name:, currency: "UAH",
                           issued_at: Time.utc(2026, 10, 9, 9))
    receipt.items.create!(position: 1, name: "Bread", amount: "40.00")
    Receipts::Accept.call(receipt.reload, link: transaction, link_lock_version: transaction.reload.lock_version)
    receipt.reload
  end

  def bank_row_of_40(payee: nil)
    Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), amount: "-40.00", source: :bank,
                        payee:, lines_attributes: [ { amount: "-40.00" } ]).reload
  end

  test "a payee two bookings assigned goes with the last undo, whichever comes first" do
    link
    created = @bank.reload.payee
    other_bank = bank_row_of_40
    second = second_receipt_on(other_bank)
    assert_equal created, other_bank.reload.payee
    assert_not second.booking.payee_created?, "the second acceptance found the payee"

    assert_not undo.payee_removed?, "the other bank row still uses it"
    assert second.booking.reload.payee_created?, "the remaining booking inherits it"

    assert undo(second).payee_removed?
    assert_not Payee.exists?(created.id)
    assert_nil other_bank.reload.payee_id
  end

  test "a payee another booking's earlier state names is kept for that booking's undo" do
    link
    created = @bank.reload.payee
    other_bank = bank_row_of_40(payee: created)
    second = second_receipt_on(other_bank, merchant_name: nil)
    assert_equal created.id, second.booking.previous["payee_id"]
    other_bank.reload.update!(payee: nil)
    Receipts::Accept.call(Receipt.find(second.id)) # re-records the row without a payee

    assert_not undo.payee_removed?
    assert Payee.exists?(created.id)

    undo(second)
    assert_equal created, other_bank.reload.payee
  end

  test "another booking's earlier payee of another type does not fail the payee check" do
    link
    created = @bank.reload.payee
    second = second_receipt_on(bank_row_of_40, merchant_name: nil)
    second.booking.update_column(:previous, second.booking.previous.merge("payee_id" => "not a number"))

    assert undo.payee_removed?
    assert_not Payee.exists?(created.id)
  end

  test "the created flag goes only to a booking that still names the payee" do
    link
    created = @bank.reload.payee
    other_bank = bank_row_of_40
    second = second_receipt_on(other_bank)
    other_bank.reload.update!(payee: nil)
    Payee.create!(name: "Corner Bakery")
    second.update!(merchant_name: "Corner Bakery")
    Receipts::Accept.call(Receipt.find(second.id)) # now assigns another payee, one that existed
    assert_equal "Corner Bakery", second.booking.reload.assigned_payee.name
    Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 10), amount: "-5.00", source: :manual,
                        payee: created, lines_attributes: [ { amount: "-5.00" } ])

    assert_not undo.payee_removed?
    assert_not second.booking.reload.payee_created?
  end

  # As a writer that missed a reference under the row lock would see it.
  BLIND_TO_PAYEES = Class.new(Receipts::UndoAccept) do
    private def payee_in_use?(_payee) = false
  end

  test "a payee that cannot be deleted stays, and the undo still commits" do
    link
    created = @bank.reload.payee
    other = Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 10), amount: "-5.00", source: :manual,
                                payee: created, lines_attributes: [ { amount: "-5.00" } ])

    receipt = Receipt.find(@receipt.id)
    result = BLIND_TO_PAYEES.new(receipt, lock_version: receipt.lock_version, transaction_lock_version: @bank.lock_version).call

    assert_not result.payee_removed?
    assert Payee.exists?(created.id)
    assert_equal created, other.reload.payee
    assert @receipt.reload.extracted?
    assert_equal 2, TransactionLine.where(transaction_id: @bank.id).count
  end

  test "a payee a person set between two acceptances stays" do
    link
    created = @bank.reload.payee
    @bank.update!(payee: payees(:corner_cafe))
    Receipts::Accept.call(Receipt.find(@receipt.id))

    result = undo

    assert result.payee_kept?
    assert_equal payees(:corner_cafe), @bank.reload.payee
    assert result.payee_removed?, "the payee Accept created is no longer used"
    assert_not Payee.exists?(created.id)
  end

  test "a created booking: the transaction and its lines are deleted, the receipt waits for review again" do
    receipt_before = receipt_state(@receipt)
    transaction = Receipts::Accept.call(Receipt.find(@receipt.id), account: accounts(:card_uah))
    line_ids = transaction.lines.ids

    result = nil
    assert_difference [ "Transaction.count", "ReceiptBooking.count", "Payee.count" ], -1 do
      result = undo
    end

    assert_equal :created, result.mode
    assert result.transaction_deleted?
    assert result.payee_removed?
    assert_not Transaction.exists?(transaction.id)
    assert_empty TransactionLine.where(id: line_ids)
    @receipt.reload
    assert @receipt.extracted?
    assert_nil @receipt.transaction_id
    assert_equal receipt_before, receipt_state(@receipt)
    assert_equal 2, TransactionLine.where(transaction_id: @bank.id).count, "the bank row is untouched"
  end

  test "a created booking accepted again, then undone" do
    transaction = Receipts::Accept.call(Receipt.find(@receipt.id), account: accounts(:card_uah))
    receipt_items(:corner_sandwich).update!(category: categories(:takeaway))
    Receipts::Accept.call(Receipt.find(@receipt.id))
    assert transaction.reload.confirmed?

    assert undo.transaction_deleted?
    assert_not Transaction.exists?(transaction.id)
    assert @receipt.reload.extracted?
  end

  test "a created transaction edited since the booking is refused" do
    transaction = Receipts::Accept.call(Receipt.find(@receipt.id), account: accounts(:card_uah))
    transaction.reload.lines.first.update!(comment: "a note")

    assert_refused(Receipts::UndoAccept::ChangedSinceBooking, /its lines/)
  end

  test "a receipt transaction booked before records existed is deleted, its payee kept" do
    receipt = receipts(:market_receipt)
    receipt.booking.delete
    transaction = receipt.ledger_transaction

    result = nil
    assert_no_difference "Payee.count" do
      result = undo(receipt)
    end

    assert_equal :unrecorded, result.mode
    assert_not Transaction.exists?(transaction.id)
    assert receipt.reload.extracted?
    assert Payee.exists?(payees(:example_market).id)
  end

  def preview_item(transaction)
    line_ids = TransactionLine.where(transaction_id: transaction.id, category_id: nil).ids
    bulk_acceptances(:needs_review_preview).items.create!(
      ledger_transaction: transaction, lock_version: transaction.reload.lock_version, line_ids:,
      category: categories(:takeaway), probability: 0.95, model_version: MODEL_VERSION
    )
  end

  test "a bulk-acceptance preview of a restored transaction is stale" do
    link
    item = preview_item(@bank)

    undo

    assert_equal "stale", item.reload.apply!
    assert_equal [ nil, categories(:groceries).id ], TransactionLine.where(transaction_id: @bank.id).order(:id).pluck(:category_id)
  end

  test "a bulk-acceptance preview of a deleted transaction goes with it" do
    transaction = Receipts::Accept.call(Receipt.find(@receipt.id), account: accounts(:card_uah))
    item = preview_item(transaction)

    undo

    assert_not BulkAcceptanceItem.exists?(item.id)
  end
end
