# The transactions: the list with its URL filter (Transaction::Filter over TransactionsQuery), one transaction
# (where "Accept" on a receipt lands), an expense entered by hand (ManualExpense, docs/domain.md, "Manual entry"),
# categorising an uncategorised line from the list, and changing the categories of a transaction's lines from the
# list or its page (Transactions::Categorise; docs/domain.md, "Transaction suggestions").
#
# A transaction page reached from a receipt carries the receipt list's filter (Receipt::Filter) in its URL,
# so "Next receipt to review" continues through the same list.
class TransactionsController < ApplicationController
  CATEGORISE_MESSAGES = {
    categorised: nil,
    unchanged: nil,
    stale: "Changed somewhere else since this page was loaded: nothing was saved. Here it is as it is now.",
    changed: "A category was set or changed, or a new suggestion arrived, since this was opened: nothing was saved. " \
      "Here it is as it is now.",
    invalid: "Choose a category (not Uncategorised) for each line; a category cannot be cleared. Nothing was saved.",
    on_receipt: "Booked from a receipt: categorise its items on the receipt and accept it again."
  }.freeze

  def index
    @filter = Transaction::Filter.from_params(params)
    @pagination = Pagination.new(@filter.relation, page: params[:page])
    @transactions = @pagination.records.includes(*list_preloads).to_a
    @suggestion_run = TransactionSuggestionRun.latest
    @without_suggestion = TransactionLine.uncategorised.where(transaction_id: @filter.relation.unscope(:order).select(:id))
      .where(suggested_category_id: nil).distinct.count(:transaction_id)
    @accounts = Account.order(:archived, :name)
  end

  def show
    @transaction = Transaction.includes(:account, :payee, :receipt, lines: { category: :parent }).find(params[:id])
    @receipt = @transaction.receipt
    @filter = Receipt::Filter.new(params.slice(*Receipt::Filter::KEYS).permit(*Receipt::Filter::KEYS).to_h)
    @next_receipt_id = @filter.next_to_review(@receipt) if @receipt
    @accepted = params[:accepted].present?
  end

  def new
    @expense = ManualExpense.new(booking_account_id: Account.default_for(nil)&.id, occurred_on: Date.current.iso8601)
  end

  def create
    @expense = ManualExpense.new(expense_params)
    if @expense.save
      redirect_to transaction_path(@expense.transaction), status: :see_other, notice: "Expense saved."
    else
      render :new, status: :unprocessable_content
    end
  end

  # One uncategorised line, categorised from the list: "Take" (the suggestion shown) or a category chosen in the
  # picker. Choosing the category that was suggested counts as taking the suggestion. The form carries the
  # transaction's lock_version and the suggestion it showed, so an edit made since the page was loaded, or a
  # suggestion refreshed since, saves nothing (Transactions::Categorise checks both under row locks).
  def categorise
    shown_category_id = integer(params[:shown_category_id])
    # "Take" means the suggestion shown, always; Enter submits through the form's default button, "Save".
    category_id = params[:take].present? ? shown_category_id : integer(params.dig(:review, :category_id))
    taken = category_id.present? && category_id == shown_category_id
    choice = Transactions::Categorise::Choice.new(line_id: integer(params[:line_id]), category_id:,
      origin: taken ? "suggestion" : "person", shown_category_id:, shown_model_version: params[:shown_model_version].presence)
    result = Transactions::Categorise.call(params[:id], lock_version: params[:lock_version].to_i, choices: [ choice ])
    @message = CATEGORISE_MESSAGES.fetch(result.status)
    answer_on_list(result, notice: "Categorised.")
  end

  # "Change" on the list or the transaction page: one category picker per line of the transaction, loaded into the
  # Turbo Frame next to the control. Transfer legs and transactions booked from a receipt get no form.
  def categories
    @transaction = Transaction.includes(:account, :receipt, lines: { category: :parent }).find(params[:id])
    @filter = Transaction::Filter.from_params(params, :filter)
    @from_page = params[:from] == "page" || !turbo_frame_request?
  end

  # Saves "Change" (Transactions::Categorise in its edit mode): every line of the transaction with the category the
  # person saw on it and the one chosen, all together or none, so a category set or changed meanwhile saves nothing.
  # The choice is always the person's own (origin `person`), even when it is the stored suggestion. From the list the
  # answer replaces the transaction's rows, as categorising does; from the transaction page it goes back to the page.
  def update_categories
    result = Transactions::Categorise.call(params[:id], lock_version: params[:lock_version].to_i, choices: category_changes, edit: true)
    @message = CATEGORISE_MESSAGES.fetch(result.status)
    return answer_on_list(result, notice: result.unchanged? ? "Nothing changed." : "Categories saved.") unless params[:from] == "page"

    flash_message = if result.saved?
      { notice: result.unchanged? ? "Nothing changed." : "Categories saved." }
    else
      { alert: @message }
    end
    redirect_to transaction_path(params[:id], changed_categories: 1), status: :see_other, **flash_message
  end

  private
    # The rows of the list as they are now (categorise.turbo_stream: the transaction's tbody, with the message when
    # nothing was saved), or the list again without Turbo.
    def answer_on_list(result, notice:)
      @transaction = Transaction.includes(*list_preloads).find_by(id: params[:id])
      @filter = Transaction::Filter.from_params(params, :filter)

      respond_to do |format|
        format.turbo_stream { render :categorise, status: (result.saved? ? :ok : :unprocessable_content) }
        format.html do
          redirect_to transactions_path(@filter.to_params), status: :see_other, **(result.saved? ? { notice: } : { alert: @message })
        end
      end
    end

    # lines[<line id>][observed_category_id] and [category_id] from the "Change" form, as the person's choices. A
    # malformed one leaves no choice at all, which Categorise refuses.
    def category_changes
      lines = params[:lines]
      return [] unless lines.is_a?(ActionController::Parameters)

      lines.each_pair.map do |line_id, values|
        return [] unless values.is_a?(ActionController::Parameters)

        Transactions::Categorise::Choice.new(line_id: integer(line_id), category_id: integer(values[:category_id]),
          origin: "person", observed_category_id: integer(values[:observed_category_id]))
      end
    end

    def integer(value)
      Integer(value.to_s, 10, exception: false)
    end

    def list_preloads
      [ :account, :payee, :receipt, { lines: [ { category: :parent }, :suggested_category, :runner_up_category ] } ]
    end

    def expense_params
      params.fetch(:manual_expense, {}).permit(:booking_account_id, :payee_name, :occurred_on, :occurred_time,
        rows: %i[name amount category_id])
    end
end
