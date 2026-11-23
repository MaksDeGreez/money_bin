require "test_helper"

# Receipts::Accept onto a ledger transaction the person chose (`link:`), and the booking record every acceptance
# writes (ReceiptBooking).
class Receipts::AcceptLinkTest < ActiveSupport::TestCase
  setup do
    # Extracted, issued 2026-10-08, items: water 60.00 (groceries), sandwich 95.00 (none), deposit -2.50 (groceries).
    @receipt = receipts(:corner_receipt)
    @bank = Transaction.create!(
      account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), occurred_at: Time.zone.local(2026, 10, 9, 8, 1),
      amount: "-152.50", source: :bank, external_id: "bank-row-1", status: :needs_review, merchant: "CORNER SHOP",
      import_digest: "a" * 64,
      lines_attributes: [
        { amount: "-160.00", legacy_category_path: "Food / Shops", comment: "Groceries and a refund",
          suggested_category: categories(:groceries), suggestion_probability: 0.875, runner_up_category: categories(:cafes),
          runner_up_probability: 0.0625, suggestion_source: "model", suggestion_model_version: "2026-11-18-0123456789ab",
          suggested_at: Time.utc(2026, 11, 18, 12, 0, 0, 123_456) },
        { amount: "7.50", category: categories(:groceries), category_origin: "person" }
      ]
    )
    @bank.reload
  end

  def accept(receipt = @receipt, link: @bank, link_lock_version: @bank.lock_version, **options)
    Receipts::Accept.call(Receipt.find(receipt.id), link:, link_lock_version:, **options)
  end

  def line_summary(transaction)
    TransactionLine.where(transaction_id: transaction.id).order(:id).map { |line| [ line.category&.slug, line.amount ] }
  end

  def assert_refused(error_class, message = nil, &block)
    before = line_summary(@bank)
    error = nil
    assert_no_difference [ "Transaction.count", "ReceiptBooking.count", "TransactionLine.count", "Payee.count" ] do
      error = assert_raises(error_class, &block)
    end
    assert_equal message, error.message if message
    assert_equal before, line_summary(@bank)
    assert @receipt.reload.extracted?
    assert_nil @receipt.transaction_id
    error
  end

  test "linking books onto the chosen transaction: no new transaction, its lines replaced, the receipt reviewed" do
    transaction = nil
    assert_no_difference "Transaction.count" do
      transaction = accept
    end

    assert_equal @bank, transaction
    assert_equal [ [ "groceries/groceries", BigDecimal("-57.50") ], [ nil, BigDecimal("-95.00") ] ], line_summary(@bank)
    assert @bank.reload.needs_review?, "a line has no category"
    assert_equal BigDecimal("-152.50"), @bank.amount
    assert_equal "CORNER SHOP", @bank.merchant
    assert_equal @bank, @receipt.reload.ledger_transaction
    assert @receipt.reviewed?
  end

  test "rebooked lines carry no category origin and no stored suggestion" do
    receipt_items(:corner_sandwich).update!(category: categories(:takeaway))
    accept

    lines = TransactionLine.where(transaction_id: @bank.id)
    assert lines.all? { |line| line.category_origin.nil? && line.suggested_category_id.nil? }
    assert @bank.reload.confirmed?
  end

  test "the record keeps the transaction's earlier state exactly, through the database" do
    old_lines = TransactionLine.where(transaction_id: @bank.id).order(:id).to_a
    accept

    booking = ReceiptBooking.find_by!(receipt: @receipt)
    assert booking.linked?
    assert_equal @bank.id, booking.transaction_id
    assert_equal "a" * 64, booking.transaction_import_digest
    previous = booking.previous
    assert_equal ReceiptBooking::PREVIOUS_FORMAT, previous["format"]
    assert_equal "-152.50", previous["amount"]
    assert_equal "needs_review", previous["status"]
    assert_nil previous["payee_id"]
    assert_equal old_lines.size, previous["lines"].size

    old_lines.zip(previous["lines"]).each do |line, stored|
      assert_equal ReceiptBooking::LINE_COLUMNS.sort, stored.keys.sort
      assert_kind_of String, stored["amount"]
      assert_equal line.amount, BigDecimal(stored["amount"])
      %w[id transaction_id category_id legacy_category_path comment suggested_category_id suggestion_probability
         runner_up_category_id runner_up_probability suggestion_source suggestion_model_version category_origin
         category_origin_probability category_origin_model_version].each do |column|
        expected = line.read_attribute(column)
        expected.nil? ? assert_nil(stored[column], column) : assert_equal(expected, stored[column], column)
      end
      %w[created_at updated_at suggested_at].each do |column|
        expected = line.read_attribute(column)
        next assert_nil(stored[column], column) if expected.nil?

        assert_equal expected.to_r, Time.iso8601(stored[column]).to_r, "#{column} to the microsecond"
      end
    end
    assert_equal [ BigDecimal("-160.00"), BigDecimal("7.50") ], previous["lines"].map { |line| BigDecimal(line["amount"]) }
    assert_equal "Groceries and a refund", previous["lines"].first["comment"]
    assert_equal "person", previous["lines"].second["category_origin"]
    assert_equal ReceiptBooking.lines_digest(@bank.id), booking.lines_digest
    assert_equal @bank.reload.lock_version, booking.booked_lock_version
  end

  test "an empty payee is filled from the merchant and recorded, a payee of its own is kept" do
    transaction = nil
    assert_difference "Payee.count", 1 do
      transaction = accept
    end
    booking = @receipt.reload.booking
    assert_equal "Corner Shop", transaction.payee.name
    assert_equal transaction.payee, booking.assigned_payee
    assert booking.payee_created?

    other = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: "-152.50", source: :bank,
                                payee: payees(:example_market), lines_attributes: [ { amount: "-152.50" } ])
    second = receipts(:new_receipt)
    second.update_columns(status: "extracted", total: BigDecimal("152.50"), merchant_name: "Corner Shop", currency: "UAH")
    second.items.create!(position: 1, name: "Bread", amount: "152.50")
    Receipts::Accept.call(second.reload, link: other, link_lock_version: other.lock_version)

    assert_equal payees(:example_market), other.reload.payee
    assert_nil second.reload.booking.assigned_payee
    assert_equal({ "format" => 1, "payee_id" => payees(:example_market).id }, second.booking.previous.slice("format", "payee_id"))
  end

  test "an existing payee assigned is recorded as not created" do
    Payee.create!(name: "CORNER shop")
    accept

    booking = @receipt.reload.booking
    assert_equal "CORNER shop", booking.assigned_payee.name
    assert_not booking.payee_created?
  end

  test "a transaction that changed since the page showed it is refused" do
    @bank.update!(comment: "edited elsewhere")
    assert_refused(Receipts::Accept::TransactionChanged) { accept(link_lock_version: @bank.lock_version - 1) }
    assert_refused(Receipts::Accept::TransactionChanged) { accept(link_lock_version: nil) }
  end

  test "a transaction gone since is refused" do
    id = @bank.id
    @bank.destroy!
    error = assert_raises(Receipts::Accept::LinkGone) { accept(link: id, link_lock_version: 0) }
    assert_equal "the chosen transaction no longer exists", error.message
    assert_equal 0, ReceiptBooking.where(receipt: @receipt).count
  end

  test "a transfer leg or an income is never linked" do
    leg, = Transaction.transfer!(from: accounts(:card_uah), to: accounts(:cash_uah), amount: "152.50", occurred_on: Date.new(2026, 10, 8))
    assert_refused(Receipts::Accept::NotLinkable, "the chosen transaction is a transfer leg") do
      accept(link: leg, link_lock_version: leg.lock_version)
    end

    income = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: "152.50", source: :bank,
                                 lines_attributes: [ { amount: "152.50" } ])
    assert_refused(Receipts::Accept::NotLinkable, "the chosen transaction is not an expense") do
      accept(link: income, link_lock_version: income.lock_version)
    end
  end

  test "a transaction booked from another receipt is refused" do
    receipts(:new_receipt).update_columns(transaction_id: @bank.id, status: "reviewed")

    assert_refused(Receipts::Accept::AlreadyLinked, "the chosen transaction is already booked from receipt ##{receipts(:new_receipt).id}") { accept }
  end

  test "the account's currency must be the receipt's; an unknown receipt currency links to any" do
    usd = Transaction.create!(account: accounts(:savings_usd), occurred_on: Date.new(2026, 10, 8), amount: "-152.50", source: :bank,
                              lines_attributes: [ { amount: "-152.50" } ])
    assert_refused(Receipts::Accept::CurrencyMismatch, "the receipt is in UAH but Savings USD is in USD") do
      accept(link: usd, link_lock_version: usd.lock_version)
    end

    @receipt.update_columns(currency: nil)
    assert_equal usd, accept(link: usd, link_lock_version: usd.lock_version)
  end

  test "items that do not sum to the transaction's amount are refused: nothing is added to make them fit" do
    @receipt.items.find_by(position: 2).update!(amount: "90.00")

    error = assert_refused(Receipts::Accept::TotalMismatch) { accept }
    assert_equal BigDecimal("147.50"), error.items_total
  end

  test "an account given with a link must be the transaction's" do
    assert_refused(Receipts::Accept::AccountMismatch) { accept(account: accounts(:cash_uah)) }
  end

  test "the window is a search filter, not a rule: a transaction a week away links when chosen" do
    @bank.update!(occurred_on: Date.new(2026, 10, 15))

    assert_equal @bank, accept(link_lock_version: @bank.reload.lock_version)
  end

  test "Accept again rebooks its own transaction, keeps the earlier state and refreshes the digest" do
    accept
    booking = @receipt.reload.booking
    previous = booking.previous
    digest = booking.lines_digest

    receipt_items(:corner_sandwich).update!(category: categories(:takeaway))
    assert_no_difference [ "Transaction.count", "ReceiptBooking.count" ] do
      assert_equal @bank, Receipts::Accept.call(@receipt.reload)
    end

    booking.reload
    assert_equal previous, booking.previous
    assert_equal "a" * 64, booking.transaction_import_digest
    assert_not_equal digest, booking.lines_digest
    assert_equal ReceiptBooking.lines_digest(@bank.id), booking.lines_digest
    assert_equal @bank.reload.lock_version, booking.booked_lock_version
    assert booking.linked?
  end

  test "a later edit shows: a line's comment in the digest, the payee in the version, a suggestion in neither" do
    accept
    booking = @receipt.reload.booking

    TransactionLine.where(transaction_id: @bank.id, category_id: nil)
      .update_all(suggested_category_id: categories(:cafes).id, suggestion_probability: 0.5, suggestion_source: "model",
                  suggestion_model_version: "2026-11-18-0123456789ab", suggested_at: Time.current)
    assert_equal booking.lines_digest, ReceiptBooking.lines_digest(@bank.id)
    assert_equal booking.booked_lock_version, @bank.reload.lock_version

    @bank.lines.first.update!(comment: "a note added later") # a line saved alone: the version does not move
    assert_equal booking.booked_lock_version, @bank.reload.lock_version
    assert_not_equal booking.lines_digest, ReceiptBooking.lines_digest(@bank.id)

    @bank.update!(payee: payees(:corner_cafe))
    assert_operator @bank.reload.lock_version, :>, booking.booked_lock_version
  end

  test "Accept again keeps a payee Accept created when it now assigns another one" do
    accept
    created = @receipt.reload.booking.assigned_payee
    @bank.reload.update!(payee: nil)
    Payee.create!(name: "Corner Shop Two")
    @receipt.update!(merchant_name: "Corner Shop Two")

    Receipts::Accept.call(@receipt.reload)

    booking = @receipt.booking.reload
    assert_equal "Corner Shop Two", @bank.reload.payee.name
    assert_equal created, booking.assigned_payee
    assert booking.payee_created?
  end

  test "Accept again refuses a receipt currency corrected since the booking" do
    accept
    @receipt.reload.update!(currency: "EUR")

    error = assert_raises(Receipts::Accept::CurrencyMismatch) { Receipts::Accept.call(@receipt.reload) }
    assert_equal "the receipt is in EUR but Everyday card is in UAH", error.message
  end

  test "a transaction another receipt took while this one waited is refused as taken, not as changed" do
    other = receipts(:new_receipt)
    other.update_columns(status: "extracted", total: BigDecimal("152.50"), currency: "UAH")
    other.items.create!(position: 1, name: "Bread", amount: "152.50")
    shown_version = @bank.lock_version
    Receipts::Accept.call(other.reload, link: @bank, link_lock_version: shown_version)

    assert_refused(Receipts::Accept::AlreadyLinked, "the chosen transaction is already booked from receipt ##{other.id}") do
      accept(link_lock_version: shown_version)
    end
  end

  test "Accept again refuses a transaction it has no earlier state of, rather than record the current one" do
    @receipt.update_columns(transaction_id: @bank.id, status: "reviewed")

    error = assert_raises(Receipts::Accept::NotAcceptable) { Receipts::Accept.call(@receipt.reload) }
    assert_match(/no record of its state/, error.message)
  end

  test "a linked receipt refuses a link to another transaction" do
    accept
    other = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 8), amount: "-152.50", source: :bank,
                                lines_attributes: [ { amount: "-152.50" } ])

    error = assert_raises(Receipts::Accept::AlreadyLinked) do
      Receipts::Accept.call(@receipt.reload, link: other, link_lock_version: other.lock_version)
    end
    assert_equal "the receipt is already booked on transaction ##{@bank.id}", error.message
    assert_equal [ [ nil, BigDecimal("-152.50") ] ], line_summary(other)
  end

  # As a writer that skipped the check under the row lock would see it.
  BLIND = Class.new(Receipts::Accept) do
    private def other_receipt_id(_transaction) = nil
  end

  def assert_backstop(receipt)
    second = receipts(:new_receipt)
    second.update_columns(transaction_id: @bank.id, status: "reviewed")
    before = line_summary(@bank)
    assert_no_difference [ "ReceiptBooking.count", "Transaction.count", "Payee.count" ] do
      error = assert_raises(Receipts::Accept::AlreadyLinked) do
        BLIND.new(receipt, link: @bank, link_lock_version: @bank.lock_version).call
      end
      assert_equal Receipts::Accept::BOOKED_MEANWHILE, error.message
    end
    assert_equal before, line_summary(@bank)
    assert @receipt.reload.extracted?
    assert_equal @bank.id, second.reload.transaction_id
  end

  test "the model's uniqueness check refuses a second receipt on one transaction and rolls everything back" do
    assert_backstop(Receipt.find(@receipt.id))
  end

  test "the unique index is the backstop when even the model's check is skipped" do
    receipt = Receipt.find(@receipt.id)
    with_singleton_method(receipt, :valid?, ->(*) { true }) do
      assert_backstop(receipt)
      # The savepoint kept the surrounding database transaction usable.
      assert_equal 2, TransactionLine.where(transaction_id: @bank.id).count
    end
  end

  test "a new expense writes a created record with the payee facts, and Accept without link never links" do
    transaction = nil
    assert_difference [ "Transaction.count", "ReceiptBooking.count", "Payee.count" ], 1 do
      transaction = Receipts::Accept.call(@receipt, account: accounts(:card_uah))
    end

    assert_not_equal @bank, transaction
    booking = @receipt.reload.booking
    assert booking.created?
    assert_nil booking.previous
    assert_nil booking.transaction_import_digest
    assert_equal transaction.payee, booking.assigned_payee
    assert booking.payee_created?
    assert_equal ReceiptBooking.lines_digest(transaction.id), booking.lines_digest
    assert_equal 2, TransactionLine.where(transaction_id: @bank.id).count, "the bank row is untouched"
  end

  test "a receipt booked before the record existed gets one on Accept again" do
    receipt = receipts(:market_receipt)
    receipt.booking.delete

    assert_difference "ReceiptBooking.count", 1 do
      Receipts::Accept.call(receipt.reload)
    end
    assert receipt.reload.booking.created?
  end

  test "destroying the transaction removes the record and sends the receipt back to review" do
    accept

    assert_difference "ReceiptBooking.count", -1 do
      @bank.reload.destroy!
    end
    assert @receipt.reload.extracted?
    assert_nil @receipt.transaction_id
  end
end
