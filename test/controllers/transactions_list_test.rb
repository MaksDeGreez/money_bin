require "test_helper"

# The transactions list (/transactions): its filter, categorising a line from it, the bulk acceptance and the
# suggestion refresh.
class TransactionsListTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:owner)
    @transaction = transactions(:subscription)
    @line = transaction_lines(:subscription_line)
  end

  # What the list's form carries about the suggestion it shows.
  def shown(line = @line)
    { shown_category_id: line.suggested_category_id, shown_model_version: line.suggestion_model_version }
  end

  test "every page of it needs a signed-in session" do
    sign_out

    get transactions_path
    assert_redirected_to new_session_path
    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version, take: "1" }
    assert_redirected_to new_session_path
    get categories_transaction_path(@transaction)
    assert_redirected_to new_session_path
    patch categories_transaction_path(@transaction), params: { lock_version: @transaction.lock_version,
      lines: { @line.id => { observed_category_id: "", category_id: categories(:cafes).id } } }
    assert_redirected_to new_session_path
    post transactions_bulk_acceptances_path, params: { threshold_percent: 90 }
    assert_redirected_to new_session_path
    post transactions_suggestion_runs_path
    assert_redirected_to new_session_path
    assert_nil @line.reload.category
  end

  test "the list shows every transaction newest first, each linking to its page, in the navigation" do
    get transactions_path

    assert_response :success
    assert_select "nav[aria-label=Main] a[href=?][aria-current=page]", transactions_path
    rows = css_select("tbody[id^=list_transaction] > tr:first-child a.data-grid-link").map { |link| link["href"] }
    assert_equal Transaction.order(occurred_on: :desc, id: :desc).map { |t| transaction_path(t) }, rows
  end

  test "the filter lives in the URL and narrows the list through the query object" do
    get transactions_path(status: "needs_review", account_id: accounts(:card_uah).id, from: "2026-10-01", to: "2026-10-31", source: "bank")
    assert_select "tbody[id^=list_transaction]", 1
    assert_select "tbody[id=?]", "list_transaction_#{@transaction.id}"
    assert_select "select[name=status] option[selected][value=needs_review]"

    get transactions_path(category_id: categories(:groceries_group).id)
    assert_select "tbody[id^=list_transaction]", 1
    get transactions_path(payee: "corner")
    assert_select "tbody[id=?]", "list_transaction_#{transactions(:coffee).id}"
    get transactions_path(q: "streaming", uncategorised: "1", currency: "UAH")
    assert_select "tbody[id^=list_transaction]", 1

    get transactions_path(status: "nonsense", from: "not a date", account_id: "x")
    assert_response :success
    assert_select "tbody[id^=list_transaction]", Transaction.count
  end

  test "an uncategorised line shows its suggestion, its runner-up and the controls to categorise it" do
    get transactions_path(status: "needs_review")

    assert_select "tr[id=?]", "review_transaction_line_#{@line.id}" do
      assert_select "strong", text: "Household & shopping / Household supplies · 91%"
      assert_select "span", text: /then Eating out \/ Cafes.* · 5%/
      assert_select "button[name=take][value='1']", text: /Take/
      assert_select "input[name=lock_version][value=?]", @transaction.lock_version.to_s
      assert_select "input[name=shown_category_id][value=?]", categories(:household_supplies).id.to_s
      assert_select "input[name=shown_model_version][value=?]", @line.suggestion_model_version
      assert_select "select[name='review[category_id]']"
    end
    assert_select "tr[id^=review_transaction_line_]", 1
  end

  # A suggestion sits under its own transaction, inside that transaction's tbody, and the table is marked as
  # grouped, so the divider is drawn under the pair. Without it the divider fell between a transaction and
  # its suggestion, and each suggestion read as the next transaction's.
  test "a suggestion is in its transaction's own block, after the transaction's row" do
    get transactions_path(status: "needs_review")

    assert_response :success
    assert_select "table.data-grid.data-grid-grouped"
    assert_select "tbody##{dom_id(@transaction, :list)}" do
      assert_select "tr:first-child td", text: /#{Regexp.escape(I18n.l(@transaction.occurred_on))}/
      assert_select "tr:first-child + tr.data-grid-sub##{dom_id(@line, :review)}"
      assert_select "tr.data-grid-sub:last-child"
    end
  end

  test "Take categorises the line with its suggestion and answers with the transaction's rows" do
    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version, take: "1",
      **shown, filter: { status: "needs_review" } }, as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][target=?]", "list_transaction_#{@transaction.id}"
    @line.reload
    assert_equal [ categories(:household_supplies), "suggestion", 0.91 ], [ @line.category, @line.category_origin, @line.category_origin_probability ]
    assert_equal "confirmed", @transaction.reload.status
  end

  test "another category chosen in the picker is the person's" do
    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version,
      review: { category_id: categories(:cafes).id } }

    assert_redirected_to transactions_path
    assert_equal [ categories(:cafes), "person" ], [ @line.reload.category, @line.category_origin ]
  end

  test "Take always saves the suggestion shown, whatever the picker holds; Enter saves the picker" do
    get transactions_path
    assert_select "tr[id=?] form", "review_transaction_line_#{@line.id}" do |forms|
      first = forms.first.css("button[type=submit], input[type=submit]").first
      assert_equal "Save", first["value"], "the default (first) button is Save, so Enter never takes the suggestion"
    end

    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version, take: "1",
      review: { category_id: categories(:cafes).id }, **shown }

    assert_equal [ categories(:household_supplies), "suggestion" ], [ @line.reload.category, @line.category_origin ]
  end

  test "a line booked from a receipt links to the receipt instead of offering a category" do
    transaction = receipts(:market_receipt).ledger_transaction
    transaction.lines.first.update!(category: nil)

    get transactions_path
    assert_select "tr[id=?]", "review_transaction_line_#{transaction.lines.first.id}" do
      assert_select "a[href=?]", receipt_path(receipts(:market_receipt)), text: "the receipt"
      assert_select "form", false
    end
  end

  test "a stale row saves nothing and shows the transaction as it is now" do
    seen = @transaction.lock_version
    @transaction.update!(comment: "edited elsewhere")

    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: seen, take: "1", **shown }, as: :turbo_stream

    assert_response :unprocessable_content
    assert_match "Changed somewhere else", response.body
    assert_nil @line.reload.category
  end

  test "Take saves the suggestion that was shown, never one refreshed since" do
    form = shown
    @line.update_columns(suggested_category_id: categories(:cafes).id, suggestion_model_version: "2026-12-01-abcdefabcdef")

    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version, take: "1", **form },
      as: :turbo_stream

    assert_response :unprocessable_content
    assert_match "a new suggestion", response.body
    assert_nil @line.reload.category
  end

  test "a line of another transaction or a category already chosen is not touched" do
    coffee_line = transaction_lines(:coffee_line)
    post categorise_transaction_path(@transaction), params: { line_id: coffee_line.id, lock_version: @transaction.lock_version, take: "1", **shown }
    assert_equal categories(:cafes), coffee_line.reload.category
    assert_nil @line.reload.category
  end

  test "the bulk action previews, confirms once, and runs as a job" do
    assert_difference -> { BulkAcceptance.count } do
      post transactions_bulk_acceptances_path, params: { threshold_percent: 90, filter: { status: "needs_review" } }
    end
    acceptance = BulkAcceptance.order(:id).last
    assert_redirected_to transactions_bulk_acceptance_path(acceptance)
    assert_equal({ "status" => "needs_review" }, acceptance.filter)

    get transactions_bulk_acceptance_path(acceptance)
    assert_select "td", text: "Household & shopping / Household supplies"
    assert_select "button", text: "Accept 1 transaction"
    assert_nil @line.reload.category

    assert_enqueued_with(job: BulkAcceptanceJob) { patch transactions_bulk_acceptance_path(acceptance) }
    assert_no_enqueued_jobs(only: BulkAcceptanceJob) { patch transactions_bulk_acceptance_path(acceptance) }
    assert_equal "Already confirmed: it is applied once.", flash[:alert]

    perform_enqueued_jobs
    assert_equal categories(:household_supplies), @line.reload.category
    get transactions_bulk_acceptance_path(acceptance)
    assert_select ".data-row", text: /Accepted\s*1/
  end

  test "a bad threshold is refused, and only an unconfirmed preview can be dropped" do
    post transactions_bulk_acceptances_path, params: { threshold_percent: 0 }
    assert_redirected_to transactions_path
    assert_match "whole percent", flash[:alert]

    preview = bulk_acceptances(:needs_review_preview)
    assert_difference -> { BulkAcceptance.count }, -1 do
      delete transactions_bulk_acceptance_path(preview)
    end
    assert_redirected_to transactions_path(status: "needs_review")
  end

  test "Refresh suggestions queues one run" do
    assert_enqueued_with(job: TransactionSuggestionsJob) { post transactions_suggestion_runs_path(filter: { status: "needs_review" }) }
    assert_redirected_to transactions_path(status: "needs_review")
    assert_no_enqueued_jobs(only: TransactionSuggestionsJob) { post transactions_suggestion_runs_path }
    assert_equal "Suggestions are already being refreshed.", flash[:alert]
  end

  test "the dashboard's needs-review and uncategorised figures link to the list" do
    get root_path

    assert_select "a[href=?]", transactions_path(status: "needs_review")
    assert_select "a[href^=?][href*='uncategorised=1'][href*='expense=1']", transactions_path
    get transactions_path(expense: "1")
    assert_select "tbody[id^=list_transaction]", Transaction.expenses.count
    get transactions_path(expense: "1", status: "draft")
    assert_select "tbody[id^=list_transaction]", 0
    get transactions_path(expense: "1", status: "needs_review")
    assert_select "tbody[id^=list_transaction]", 1
  end

  # --- "Change" -----------------------------------------------------------------------------------------------

  def frame_headers(transaction)
    { "Turbo-Frame" => dom_id(transaction, :categories) }
  end

  def change_params(transaction, chosen, observed: {})
    lines = transaction.lines.reload.to_h do |line|
      category = chosen.key?(line) ? chosen[line] : line.category
      [ line.id, { observed_category_id: observed.fetch(line, line.category)&.id.to_s, category_id: category&.id.to_s } ]
    end
    { lock_version: transaction.reload.lock_version, lines: }
  end

  def invented_split
    Transaction.create!(account: accounts(:card_uah), occurred_on: Date.new(2026, 10, 9), amount: BigDecimal("-100"), source: "bank",
      merchant: "Invented Shop", lines_attributes: [ { amount: BigDecimal("-60"), category: categories(:groceries) },
                                                      { amount: BigDecimal("-40"), category: categories(:cafes) } ])
  end

  test "a categorised row offers Change, a link into an empty frame of its own; receipt, transfer and uncategorised rows do not" do
    coffee = transactions(:coffee)

    get transactions_path(payee: "corner")

    assert_select "tbody##{dom_id(coffee, :list)} td" do
      assert_select "a##{dom_id(coffee, :change_categories)}[data-turbo-frame=?][href=?]", dom_id(coffee, :categories),
        categories_transaction_path(coffee, filter: { payee: "corner" }), text: /Change/
      assert_select "turbo-frame##{dom_id(coffee, :categories)}:not([src]):not([loading])", text: ""
    end

    get transactions_path
    market = transactions(:market_split)
    assert_select "tbody##{dom_id(market, :list)}" do
      assert_select "a[data-turbo-frame]", false
      assert_select "turbo-frame", false
      assert_select "a[href=?][data-turbo-prefetch=false]", receipt_path(receipts(:market_receipt)), text: "Change on the receipt"
    end
    assert_select "tbody##{dom_id(transactions(:withdrawal_out), :list)}" do
      assert_select "a[data-turbo-frame]", false
      assert_select "turbo-frame", false
    end
    assert_select "a##{dom_id(@transaction, :change_categories)}", 0,
      "a row with an uncategorised line is categorised under it, next to its suggestion, never with Change"
  end

  test "Change loads a picker per line with the category it shows, the list's filter and no suggestion" do
    get categories_transaction_path(@transaction, filter: { status: "needs_review" }), headers: frame_headers(@transaction)

    assert_response :success
    assert_select "turbo-frame##{dom_id(@transaction, :categories)} form[action=?][data-controller=category-change]", categories_transaction_path(@transaction) do |form|
      assert_not_includes form.first["data-action"], "review-queue", "the review queue's advance is not attached here"
      assert_select "input[name=_method][value=patch]"
      assert_select "input[name=lock_version][value=?]", @transaction.lock_version.to_s
      assert_select "input[name='filter[status]'][value=needs_review]"
      assert_select "input[name=from]", false
      assert_select "input[name=?][value='']", "lines[#{@line.id}][observed_category_id]"
      assert_select "select[name=?]", "lines[#{@line.id}][category_id]"
      assert_select "[data-combobox-suggestion-value]", false
      assert_select "input[name^=shown]", false
      assert_select "input[type=submit][value=Save]"
    end
    assert_select "h1", false, "inside the frame, no page around it"
  end

  test "a split gets one picker per line, each with its amount and its category" do
    split = invented_split
    first, second = split.lines.to_a

    get categories_transaction_path(split), headers: frame_headers(split)

    assert_select "select[name^=lines]", 2
    [ [ first, categories(:groceries) ], [ second, categories(:cafes) ] ].each do |line, category|
      assert_select "input[name=?][value=?]", "lines[#{line.id}][observed_category_id]", category.id.to_s
      assert_select "select[name=?] option[selected][value=?]", "lines[#{line.id}][category_id]", category.id.to_s
    end
    assert_select "span", text: "-60.00 UAH"
    assert_select "input[aria-label=?]", "Category of the line of -40.00 UAH, Invented Shop"
  end

  test "Change on a receipt's transaction or a transfer leg offers no form" do
    get categories_transaction_path(transactions(:market_split)), headers: frame_headers(transactions(:market_split))
    assert_select "form", false
    assert_select "a[href=?]", receipt_path(receipts(:market_receipt)), text: "the receipt"

    get categories_transaction_path(transactions(:withdrawal_out)), headers: frame_headers(transactions(:withdrawal_out))
    assert_select "form", false
    assert_select "p", text: "A transfer leg: it has no lines."
  end

  test "saving Change from the list replaces the category and answers with the row" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)

    patch categories_transaction_path(coffee), params: { **change_params(coffee, { line => categories(:groceries) }), filter: { payee: "corner" } },
      as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream[action=replace][target=?]", dom_id(coffee, :list) do
      assert_select "template a##{dom_id(coffee, :change_categories)}[href=?][data-controller=autofocus]", categories_transaction_path(coffee, filter: { payee: "corner" })
      assert_select "template [role=alert]", false
    end
    assert_equal [ categories(:groceries), "person" ], [ line.reload.category, line.category_origin ]
  end

  test "the same categories save nothing, quietly" do
    coffee = transactions(:coffee)
    version = coffee.lock_version

    patch categories_transaction_path(coffee), params: change_params(coffee, {}), as: :turbo_stream

    assert_response :success
    assert_select "turbo-stream template [role=alert]", false
    assert_equal version, coffee.reload.lock_version
  end

  test "a category changed since Change was opened saves nothing and says so" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)
    form = change_params(coffee, { line => categories(:groceries) })
    line.update_columns(category_id: categories(:takeaway).id)

    patch categories_transaction_path(coffee), params: form, as: :turbo_stream

    assert_response :unprocessable_content
    assert_match "A category was set or changed", response.body
    assert_equal categories(:takeaway), line.reload.category
  end

  test "clearing a category is refused; without Turbo the list comes back with the answer" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)

    patch categories_transaction_path(coffee), params: { **change_params(coffee, { line => nil }), filter: { payee: "corner" } }
    assert_redirected_to transactions_path(payee: "corner")
    assert_match "cannot be cleared", flash[:alert]
    assert_equal categories(:cafes), line.reload.category

    patch categories_transaction_path(coffee), params: change_params(coffee, { line => categories(:groceries) })
    assert_redirected_to transactions_path
    assert_equal "Categories saved.", flash[:notice]

    patch categories_transaction_path(coffee), params: { lock_version: coffee.reload.lock_version, lines: "nonsense" }
    assert_match "Choose a category", flash[:alert]
    patch categories_transaction_path(coffee), params: { lock_version: coffee.reload.lock_version,
      lines: { "abc" => { observed_category_id: categories(:cafes).id, category_id: categories(:takeaway).id } } }
    assert_match "cannot be cleared", flash[:alert], "a key that is not a line id is a bad form, not a change made meanwhile"
    assert_equal categories(:groceries), line.reload.category
  end

  test "taking a suggestion from the list still answers without the focus on Change" do
    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version, take: "1", **shown },
      as: :turbo_stream

    assert_select "template a##{dom_id(@transaction, :change_categories)}:not([data-controller])"
  end

  test "a category picked from the queue's picker with nothing chosen keeps the queue's own message" do
    post categorise_transaction_path(@transaction), params: { line_id: @line.id, lock_version: @transaction.lock_version, review: { category_id: "" } },
      as: :turbo_stream

    assert_response :unprocessable_content
    assert_match "Choose a category (not Uncategorised) first.", response.body
  end

  test "a Change form without its version or its line snapshot saves nothing" do
    coffee = transactions(:coffee)
    line = transaction_lines(:coffee_line)
    snapshot = { observed_category_id: categories(:cafes).id.to_s, category_id: categories(:takeaway).id.to_s }

    [
      { lines: { line.id => snapshot } },
      { lock_version: coffee.lock_version, lines: { line.id => snapshot.except(:observed_category_id) } },
      { lock_version: coffee.lock_version, lines: { line.id => snapshot.merge(observed_category_id: "cafes") } },
      { lock_version: { "x" => "1" }, lines: { line.id => snapshot } }
    ].each do |params|
      patch categories_transaction_path(coffee), params:, as: :turbo_stream
      assert_response :unprocessable_content
      assert_match "Choose a category", response.body
    end
    assert_equal categories(:cafes), line.reload.category
  end

  test "Change saved for a transaction deleted meanwhile takes its row off the list, or goes back to the list" do
    split = invented_split
    form = change_params(split, {})
    split.destroy!

    patch categories_transaction_path(split), params: form, as: :turbo_stream
    assert_response :unprocessable_content
    assert_select "turbo-stream[action=remove][target=?]", dom_id(split, :list)

    patch categories_transaction_path(split), params: form.merge(return_to: "page")
    assert_redirected_to transactions_path
    assert_equal "This transaction is gone: nothing was saved.", flash[:alert]
  end

  test "Change for a transaction that does not exist is not found" do
    get categories_transaction_path(id: 0), headers: { "Turbo-Frame" => "categories_transaction_0" }
    assert_response :not_found
  end
end
