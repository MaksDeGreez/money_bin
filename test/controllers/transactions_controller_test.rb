require "test_helper"

class TransactionsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:owner) }

  test "every transaction page needs a signed-in session" do
    sign_out

    get transaction_path(transactions(:coffee))
    assert_redirected_to new_session_path
    get new_transaction_path
    assert_redirected_to new_session_path
    assert_no_difference -> { Transaction.count } do
      post transactions_path, params: { manual_expense: { booking_account_id: accounts(:cash_uah).id, occurred_on: "2026-10-08", rows: [ { amount: "5" } ] } }
    end
    assert_redirected_to new_session_path
  end

  test "a transaction page shows its account, date, payee, amount, status, lines and receipt" do
    transaction = transactions(:market_split)

    get transaction_path(transaction)

    assert_response :success
    assert_select "h1", "Transaction ##{transaction.id}"
    assert_select ".data-row", text: /Amount\s*-1 250.40 UAH/
    assert_select ".data-row", text: /Status\s*Confirmed/
    assert_select ".data-row", text: /Account\s*Everyday card \(UAH\)/
    assert_select ".data-row", text: /Date\s*2026-10-03\s*· 18:40/
    assert_select ".data-row", text: /Payee\s*Example Market/
    assert_select ".data-row a[href=?]", receipt_path(receipts(:market_receipt)), text: "rcpt_000041"
    assert_select "tbody tr", text: /Groceries \/ Groceries\s*-1 000.40 UAH/
    assert_select "tbody tr", text: /Household & shopping \/ Household supplies\s*-250.00 UAH/
    assert_select "a#next-receipt[href=?]", receipt_path(receipts(:corner_receipt)), text: /Next receipt to review/
    assert_select "a#next-receipt[autofocus]", false, "the focus waits there only right after an accept"
  end

  test "a transaction that needs review says why; a legacy line shows its old category" do
    get transaction_path(transactions(:subscription))
    assert_select ".callout", text: /Needs review:\s*a line has no category/

    get transaction_path(transactions(:snack))
    assert_select "tbody tr", text: /Before: Food \/ Snacks/
    assert_select ".data-row", text: /Receipt\s*—/
  end

  test "a transfer leg has no lines to show" do
    get transaction_path(transactions(:withdrawal_out))

    assert_select "p", text: "A transfer leg: it has no lines."
  end

  test "the new expense form starts on the last account used, today, with one empty row" do
    travel_to Time.zone.local(2026, 11, 18, 10, 0) do
      get new_transaction_path
    end

    assert_response :success
    assert_select "nav[aria-label=Main] a[href=?][aria-current=page]", new_transaction_path, text: "Add expense"
    assert_select "form[action=?][data-controller~=form-guard][data-controller~=money-totals]", transactions_path do
      assert_select "select[name='manual_expense[booking_account_id]'] option[selected][value=?]", accounts(:card_uah).id.to_s
      assert_select "input[name='manual_expense[occurred_on]'][value=?]", "2026-11-18"
      assert_select "input[name='manual_expense[rows][0][amount]']", 1
      assert_select "select[name='manual_expense[rows][0][category_id]'][hidden]"
      assert_select "template input[name='manual_expense[rows][NEW_ROW][amount]']"
      assert_select "button[name=intent][value=save]", text: /Save expense/
    end
  end

  test "saving an expense books it and shows the transaction" do
    params = { booking_account_id: accounts(:cash_uah).id, payee_name: "Corner Shop", occurred_on: "2026-10-08", occurred_time: "09:30",
               rows: { "0" => { name: "Bread", amount: "40,40", category_id: categories(:groceries).id },
                       "1" => { name: "", amount: "", category_id: "" } } }

    assert_difference -> { Transaction.count }, 1 do
      post transactions_path, params: { manual_expense: params }
    end

    transaction = Transaction.order(:id).last
    assert_redirected_to transaction_path(transaction)
    assert_equal [ BigDecimal("-40.40"), "manual", "confirmed" ], [ transaction.amount, transaction.source, transaction.status ]
    follow_redirect!
    assert_select ".data-row", text: /Source\s*Manual/
  end

  test "a refused expense renders the form again with the typed rows and the errors" do
    params = { booking_account_id: accounts(:cash_uah).id, occurred_on: "2026-10-08",
               rows: { "0" => { name: "Bread", amount: "40.404", category_id: categories(:groceries).id } } }

    assert_no_difference -> { Transaction.count } do
      post transactions_path, params: { manual_expense: params }
    end

    assert_response :unprocessable_content
    assert_select "form[data-form-guard-dirty-value=true]"
    assert_select "input[name='manual_expense[rows][0][amount]'][value=?][aria-invalid=true]", "40.404"
    assert_select "input[name='manual_expense[rows][0][name]'][value=?]", "Bread"
    assert_select "select[name='manual_expense[rows][0][category_id]'] option[selected][value=?]", categories(:groceries).id.to_s
    assert_select ".line-row-errors", text: /Amount must have at most 2 decimal places/
  end

  test "Change on the transaction page saves every line and comes back to the page, the focus on Change" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)

    get transaction_path(coffee)
    assert_select "section a##{dom_id(coffee, :change_categories)}[href=?][data-turbo-frame=?]", categories_transaction_path(coffee, from: "page"), dom_id(coffee, :categories)
    assert_select "a##{dom_id(coffee, :change_categories)}[data-controller=autofocus]", false

    get categories_transaction_path(coffee, from: "page"), headers: { "Turbo-Frame" => dom_id(coffee, :categories) }
    assert_select "form[action=?] input[name=from][value=page]", categories_transaction_path(coffee)

    patch categories_transaction_path(coffee), params: { from: "page", lock_version: coffee.lock_version,
      lines: { line.id => { observed_category_id: categories(:cafes).id, category_id: categories(:takeaway).id } } }

    assert_redirected_to transaction_path(coffee, changed_categories: 1)
    assert_equal "Categories saved.", flash[:notice]
    assert_equal [ categories(:takeaway), "person" ], [ line.reload.category, line.category_origin ]
    follow_redirect!
    assert_select "a##{dom_id(coffee, :change_categories)}[data-controller=autofocus]"
    assert_select "tbody tr", text: /Eating out \/ Takeaway/
  end

  test "Change on the transaction page: nothing changed is a notice, a refusal an alert" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)
    form = { from: "page", lock_version: coffee.lock_version, lines: { line.id => { observed_category_id: categories(:cafes).id, category_id: categories(:cafes).id } } }

    patch categories_transaction_path(coffee), params: form
    assert_equal "Nothing changed.", flash[:notice]

    form[:lines][line.id][:observed_category_id] = categories(:groceries).id
    patch categories_transaction_path(coffee), params: form
    assert_redirected_to transaction_path(coffee, changed_categories: 1)
    assert_match "A category was set or changed", flash[:alert]
    assert_equal categories(:cafes), line.reload.category
  end

  test "opened on its own, Change is a page of its own that goes back to the transaction" do
    get categories_transaction_path(transactions(:coffee))

    assert_select "h1", "Change categories"
    assert_select "form input[name=from][value=page]"
  end

  test "a transaction booked from a receipt links to the receipt instead of Change; a transfer leg has neither" do
    get transaction_path(transactions(:market_split))
    assert_select "a[href=?]", receipt_path(receipts(:market_receipt)), text: "Change on the receipt"
    assert_select "a[data-turbo-frame]", false

    get transaction_path(transactions(:withdrawal_out))
    assert_select "a[data-turbo-frame]", false
    assert_select "turbo-frame", false
  end
end
