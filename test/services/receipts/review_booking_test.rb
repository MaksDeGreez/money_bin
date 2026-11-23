require "test_helper"

# "Book as" on the review form: Receipts::Review books onto a ledger transaction the person chose, or as a new
# expense, and refuses a choice made on a list that is no longer the list (docs/domain.md, "Booking onto a
# transaction").
class Receipts::ReviewBookingTest < ActiveSupport::TestCase
  setup do
    @receipt = receipts(:corner_receipt) # extracted, 2026-10-08, items sum to 152.50
    @bank = Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), amount: "-152.50", source: :bank,
                                status: :needs_review, lines_attributes: [ { amount: "-152.50", comment: "bank note" } ])
  end

  def form(receipt = @receipt, **changes)
    items = receipt.items.each_with_index.to_h do |item, index|
      [ index.to_s, { id: item.id.to_s, name: item.name, quantity: item.quantity&.to_s("F"), unit_price: item.unit_price&.to_s("F"),
                      discount: item.discount.to_s("F"), amount: item.amount.to_s("F"), category_id: item.category_id.to_s, _destroy: "0" } ]
    end
    { lock_version: receipt.lock_version.to_s, kind: receipt.kind.to_s, merchant_name: receipt.merchant_name.to_s,
      issued_at: receipt.issued_at&.in_time_zone&.strftime("%Y-%m-%dT%H:%M:%S").to_s, total: receipt.total&.to_s("F").to_s,
      currency: receipt.currency.to_s, items_attributes: items }.merge(changes)
  end

  # What the page lists now, as its hidden fields carry it.
  def shown(receipt = @receipt)
    found = ReceiptLinkCandidates.new(Receipt.find(receipt.id))
    { shown_candidate_ids: found.candidate_ids.join(" "), shown_linked_ids: found.linked_ids.join(" "),
      shown_exact_ids: found.exact_ids.join(" "),
      link_lock_versions: found.candidates.to_h { |candidate| [ candidate.id.to_s, candidate.transaction.lock_version.to_s ] } }
  end

  def accept(params)
    review = Receipts::Review.new(Receipt.find(@receipt.id), params, intent: "accept")
    [ review.call, review ]
  end

  test "a chosen ledger transaction is booked onto: no new transaction, its lines replaced" do
    saved = nil
    assert_no_difference "Transaction.count" do
      saved, review = accept(form(merchant_name: "Corner Shop 2", **shown, booking: @bank.id.to_s))
      assert_equal @bank, review.transaction
    end

    assert saved
    assert_equal @bank, @receipt.reload.ledger_transaction
    assert_equal "Corner Shop 2", @receipt.merchant_name
    assert @receipt.booking.linked?
    assert_equal [ BigDecimal("-57.50"), BigDecimal("-95.00") ], @bank.lines.reload.map(&:amount)
  end

  test "no choice at all is refused and nothing is saved" do
    saved, review = accept(form(merchant_name: "Typed", **shown))

    assert_not saved
    assert_equal [ Receipts::Review::CHOICE_NEEDED ], review.form_receipt.errors[:booking]
    assert_equal "Typed", review.form_receipt.merchant_name, "the typed value stays on the form"
    assert_equal "Corner Shop", @receipt.reload.merchant_name
    assert @receipt.extracted?
  end

  test "a new expense chosen on a page that did not list the match is refused with the fresh list" do
    assert_no_difference [ "Transaction.count", "ReceiptBooking.count" ] do
      saved, review = accept(form(booking: "new", account_id: accounts(:card_uah).id.to_s, shown_candidate_ids: "", shown_linked_ids: ""))

      assert_not saved
      assert review.candidates_changed?
      assert_nil review.booking, "nothing stays chosen: the person chooses again"
      assert_equal [ Receipts::Review::CANDIDATES_CHANGED ], review.form_receipt.errors[:booking]
      assert_equal [ @bank.id ], review.link_candidates.candidate_ids
    end
  end

  test "a corrected date that brings a match is refused, and the list is the one for the typed date" do
    @bank.update!(occurred_on: Date.new(2026, 10, 20))
    params = form(issued_at: "2026-10-19T10:00:00", booking: "new", account_id: accounts(:card_uah).id.to_s, **shown)
    assert_equal "", params[:shown_candidate_ids], "the page, at the saved date, listed nothing"

    saved, review = accept(params)

    assert_not saved
    assert review.candidates_changed?
    assert_equal [ @bank.id ], review.link_candidates.candidate_ids
    assert_equal Time.zone.local(2026, 10, 19, 10), review.form_receipt.issued_at
    assert_equal Time.zone.local(2026, 10, 8, 12, 5), @receipt.reload.issued_at, "nothing was saved"
  end

  test "a new expense with no match anywhere books as before" do
    @bank.destroy!
    assert_difference "Transaction.count", 1 do
      saved, review = accept(form(booking: "new", account_id: accounts(:card_uah).id.to_s, **shown))
      assert saved
      assert review.transaction.from_receipt?
    end
    assert @receipt.reload.booking.created?
  end

  test "a new expense is still the person's choice when there are matches" do
    assert_difference "Transaction.count", 1 do
      saved, = accept(form(booking: "new", account_id: accounts(:cash_uah).id.to_s, **shown))
      assert saved
    end
    assert_equal accounts(:cash_uah), @receipt.reload.ledger_transaction.account
  end

  test "the account goes to the booking only with a new expense" do
    saved, review = accept(form(booking: @bank.id.to_s, account_id: accounts(:cash_uah).id.to_s, **shown))

    assert saved
    assert_equal @bank, review.transaction
    assert_equal accounts(:card_uah), review.transaction.account
  end

  test "a transaction that changed since the page is refused next to Book as, and is chosen again" do
    params = form(booking: @bank.id.to_s, **shown)
    @bank.update!(comment: "edited elsewhere")

    saved, review = accept(params)

    assert_not saved
    assert_match(/changed somewhere else/, review.form_receipt.errors[:booking].first)
    assert_nil review.booking
    assert_equal @bank.reload.lock_version, review.link_candidates.candidates.first.transaction.lock_version
    assert @receipt.reload.extracted?
  end

  test "a choice that is not on the list is refused" do
    other = transactions(:coffee)
    saved, review = accept(form(booking: other.id.to_s, **shown).merge(link_lock_versions: { other.id.to_s => other.lock_version.to_s }))

    assert_not saved
    assert_equal [ Receipts::Review::CHOICE_NEEDED ], review.form_receipt.errors[:booking]
    assert_equal 1, other.lines.count
  end

  test "correcting the items so that a candidate no longer matches exactly is a changed list" do
    params = form(**shown, booking: @bank.id.to_s)
    params[:items_attributes]["1"] = params[:items_attributes]["1"].merge(amount: "90.00")

    saved, review = accept(params)

    assert_not saved
    assert review.candidates_changed?
    assert_empty review.link_candidates.exact_ids
  end

  test "items that do not sum to the chosen transaction are refused with the reason, nothing saved" do
    receipt_items(:corner_sandwich).update!(amount: "90.00")
    params = form(@receipt.reload, **shown, booking: @bank.id.to_s, merchant_name: "Typed")

    saved, review = accept(params)

    assert_not saved
    assert_match(/the items sum to 147.5 but the transaction amount is -152.5\. Accepting replaces the chosen transaction's lines/,
      review.form_receipt.errors[:booking].first)
    assert_equal @bank.id.to_s, review.booking, "the choice stays"
    assert_equal "Corner Shop", @receipt.reload.merchant_name
  end

  test "a candidate that became an exact match since the page is a changed list: a new expense must be chosen again" do
    @receipt.update_columns(total: BigDecimal("160.00"))
    @bank.update!(amount: "-160.00", lines_attributes: [ { id: @bank.lines.first.id, amount: "-160.00" } ])
    params = form(booking: "new", account_id: accounts(:card_uah).id.to_s, **shown)
    assert_equal "", params[:shown_exact_ids], "the page flagged the row: the items summed to 152.50"
    params[:items_attributes]["1"] = params[:items_attributes]["1"].merge(amount: "102.50") # now 160.00

    assert_no_difference "Transaction.count" do
      saved, review = accept(params)
      assert_not saved
      assert review.candidates_changed?
      assert_equal [ @bank.id ], review.link_candidates.exact_ids
    end
  end

  test "a lock that cannot be had is a message on the form, not an error page" do
    with_singleton_method(Receipts::Accept, :call, ->(*, **) { raise ActiveRecord::Deadlocked, "deadlock detected" }) do
      saved, review = accept(form(merchant_name: "Typed", booking: @bank.id.to_s, **shown))

      assert_not saved
      assert_equal [ Receipts::Review::LOCK_FAILED ], review.form_receipt.errors[:base]
      assert_nil review.link_candidates, "the page reads the list again"
      assert_nil review.booking, "and the person chooses again"
    end
    assert_equal "Corner Shop", @receipt.reload.merchant_name
  end

  test "the list after a refusal under the lock is read with the typed items, before the rollback" do
    params = form(booking: @bank.id.to_s, **shown)
    params[:items_attributes]["1"] = params[:items_attributes]["1"].merge(amount: "90.00") # typed: 147.50
    params[:shown_exact_ids] = "" # as a page showing these items would
    @bank.update!(comment: "edited elsewhere")

    saved, review = accept(params)

    assert_not saved
    assert_match(/changed somewhere else/, review.form_receipt.errors[:booking].first)
    assert_equal BigDecimal("147.50"), review.link_candidates.receipt.booking_total
    assert_includes review.link_candidates.amounts, BigDecimal("147.50")
  end

  test "a refusal rolls the save back inside a caller's own transaction too" do
    ActiveRecord::Base.transaction do
      saved, = accept(form(merchant_name: "Typed", **shown))
      assert_not saved
      assert_equal "Corner Shop", Receipt.where(id: @receipt.id).pick(:merchant_name)
    end
  end

  test "a transaction another receipt took since the page is a changed list, now shown as taken" do
    params = form(booking: @bank.id.to_s, **shown)
    other = receipts(:new_receipt)
    other.update_columns(status: "extracted", total: BigDecimal("152.50"), currency: "UAH")
    other.items.create!(position: 1, name: "Bread", amount: "152.50")
    Receipts::Accept.call(other.reload, link: @bank, link_lock_version: @bank.lock_version)

    saved, review = accept(params)

    assert_not saved
    assert review.candidates_changed?
    assert_equal [ @bank.id ], review.link_candidates.linked_ids
    assert_empty review.link_candidates.candidate_ids
  end

  test "Accept again refuses a currency corrected since the booking, next to the currency" do
    receipt = receipts(:market_receipt)
    params = form(receipt, currency: "EUR", transaction_lock_version: receipt.ledger_transaction.lock_version.to_s)

    review = Receipts::Review.new(Receipt.find(receipt.id), params, intent: "accept")

    assert_not review.call
    assert_equal [ "Not accepted: the receipt is in EUR but Everyday card is in UAH." ], review.form_receipt.errors[:currency]
    assert_equal "UAH", receipt.reload.currency
  end

  test "Accept again ignores an account and the Book as fields: an account mismatch never raises" do
    receipt = receipts(:market_receipt)
    params = form(receipt, booking: @bank.id.to_s, account_id: accounts(:cash_uah).id.to_s,
                  transaction_lock_version: receipt.ledger_transaction.lock_version.to_s)

    review = Receipts::Review.new(Receipt.find(receipt.id), params, intent: "accept")

    assert review.call
    assert_equal transactions(:market_split), review.transaction
    assert_equal 1, @bank.lines.count
  end
end
