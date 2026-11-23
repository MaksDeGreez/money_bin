require "test_helper"

# "Undo the acceptance" on a receipt page (ReceiptsController#undo_accept, Receipts::UndoAccept).
class ReceiptUndoAcceptTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in_as users(:owner)
    # Extracted, issued 2026-10-08, items summing to 152.50.
    @receipt = receipts(:corner_receipt)
    @bank = Transaction.create!(
      account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), amount: "-152.50", source: :bank, status: :needs_review,
      lines_attributes: [ { amount: "-152.50", legacy_category_path: "Food / Shops", comment: "from the bank" } ]
    ).reload
  end

  def link
    Receipts::Accept.call(Receipt.find(@receipt.id), link: @bank, link_lock_version: @bank.reload.lock_version)
    @receipt.reload
  end

  def undo_params(receipt = @receipt.reload)
    { lock_version: receipt.lock_version, transaction_lock_version: receipt.ledger_transaction&.lock_version }
  end

  test "undoing needs a signed-in session" do
    link
    sign_out

    post undo_accept_receipt_path(@receipt), params: undo_params
    assert_redirected_to new_session_path
    assert @receipt.reload.reviewed?
  end

  test "a linked receipt's page offers the undo, carrying the versions it shows, behind a confirmation" do
    link
    get receipt_path(@receipt)

    assert_select "form[action=?]", undo_accept_receipt_path(@receipt), 1 do |(form)|
      assert_match "gets back the lines, status and payee it had before", form["data-turbo-confirm"]
      assert_select "button", text: /Undo the acceptance/
      assert_select "input[name=lock_version][value=?]", @receipt.lock_version.to_s
      assert_select "input[name=transaction_lock_version][value=?]", @bank.reload.lock_version.to_s
    end
    assert_select "form##{dom_id(@receipt, :review_form)} form", 0, "not nested in the review form"
  end

  test "a created booking's confirmation says the transaction is deleted" do
    get receipt_path(receipts(:market_receipt))

    assert_select "form[action=?][data-turbo-confirm*=?]", undo_accept_receipt_path(receipts(:market_receipt)), "is deleted"
  end

  test "a transaction the receipt did not create, booked without a record, offers no undo" do
    @receipt.update_columns(transaction_id: @bank.id, status: "reviewed")
    get receipt_path(@receipt)

    assert_select "form[action=?]", undo_accept_receipt_path(@receipt), 0
    assert_select "p", text: /its earlier state is not known, so the acceptance cannot be undone here/
  end

  test "a receipt not booked has no undo" do
    get receipt_path(@receipt)

    assert_select "form[action=?]", undo_accept_receipt_path(@receipt), 0
  end

  test "the transaction page points to the receipt for the undo" do
    link
    get transaction_path(@bank)

    assert_select "a[href^=?]", receipt_path(@receipt)
    assert_select "span", text: "The receipt's page can undo the acceptance."
  end

  test "undoing goes back to the receipt, now reviewable with Book as, with a notice" do
    link
    post undo_accept_receipt_path(@receipt), params: undo_params

    assert_redirected_to receipt_path(@receipt)
    assert_match "The acceptance is undone: transaction ##{@bank.id} has its earlier lines, status and payee back.", flash[:notice]
    assert_match "The receipt waits for review again.", flash[:notice]
    assert @receipt.reload.extracted?
    assert_equal [ [ BigDecimal("-152.50"), "from the bank" ] ], @bank.lines.reload.map { |line| [ line.amount, line.comment ] }

    follow_redirect!
    assert_select "form##{dom_id(@receipt, :review_form)}"
    assert_select "input[name='receipt[booking]'][value=?]", @bank.id.to_s
    assert_select "form[action=?]", undo_accept_receipt_path(@receipt), 0
  end

  test "undoing a created booking says the transaction is deleted" do
    receipt = receipts(:market_receipt)
    transaction = receipt.ledger_transaction
    post undo_accept_receipt_path(receipt), params: undo_params(receipt)

    assert_redirected_to receipt_path(receipt)
    assert_match "the transaction it created (##{transaction.id}) is deleted", flash[:notice]
    assert_not Transaction.exists?(transaction.id)
  end

  test "a refusal goes back to the receipt with the reason, and nothing is undone" do
    link
    stale = undo_params
    @bank.reload.update!(comment: "edited later")

    post undo_accept_receipt_path(@receipt), params: stale
    assert_redirected_to receipt_path(@receipt)
    assert_equal "Nothing was undone: the transaction changed somewhere else after the page was opened.", flash[:alert]

    post undo_accept_receipt_path(@receipt), params: undo_params
    assert_match(/\ANothing was undone: the transaction changed after the receipt was booked on it \(the transaction itself/, flash[:alert])
    assert @receipt.reload.reviewed?
    assert_equal @bank, @receipt.ledger_transaction
  end

  test "an undo of a receipt that is not booked is refused with a reason" do
    post undo_accept_receipt_path(@receipt), params: { lock_version: @receipt.lock_version }

    assert_redirected_to receipt_path(@receipt)
    assert_match "Nothing was undone: the receipt is not booked into the ledger", flash[:alert]
  end

  test "the redirect keeps the list filter" do
    link
    post undo_accept_receipt_path(@receipt, status: "reviewed"), params: undo_params

    assert_redirected_to receipt_path(@receipt, status: "reviewed")
  end
end
