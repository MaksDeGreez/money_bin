# The transactions: the list with its URL filter (Transaction::Filter over TransactionsQuery), one transaction
# (where "Accept" on a receipt lands), an expense entered by hand (ManualExpense, docs/domain.md, "Manual entry"),
# and categorising an uncategorised line from the list (Transactions::Categorise; docs/domain.md, "Transaction
# suggestions").
#
# A transaction page reached from a receipt carries the receipt list's filter (Receipt::Filter) in its URL,
# so "Next receipt to review" continues through the same list.
class TransactionsController < ApplicationController
  CATEGORISE_MESSAGES = {
    categorised: nil,
    stale: "Changed somewhere else since this page was loaded: nothing was saved. Here it is as it is now.",
    changed: "This line has a category by now, or a new suggestion: nothing was saved. Here it is as it is now.",
    invalid: "Choose a category (not Uncategorised) first.",
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
    @transaction = Transaction.includes(*list_preloads).find_by(id: params[:id])
    @filter = Transaction::Filter.from_params(params, :filter)

    respond_to do |format|
      format.turbo_stream { render status: (result.categorised? ? :ok : :unprocessable_content) }
      format.html do
        redirect_to transactions_path(@filter.to_params), status: :see_other,
          **(result.categorised? ? { notice: "Categorised." } : { alert: @message })
      end
    end
  end

  private
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
