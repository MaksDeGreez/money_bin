# One transaction, read-only (where "Accept" on a receipt lands), and an expense entered by hand
# (ManualExpense, docs/domain.md, "Manual entry"). There is no list of transactions yet.
#
# A transaction page reached from a receipt carries the receipt list's filter (Receipt::Filter) in its URL,
# so "Next receipt to review" continues through the same list.
class TransactionsController < ApplicationController
  def show
    @transaction = Transaction.includes(:account, :payee, :receipt, lines: { category: :parent }).find(params[:id])
    @receipt = @transaction.receipt
    @filter = Receipt::Filter.new(params.slice(*Receipt::Filter::KEYS).permit(*Receipt::Filter::KEYS).to_h)
    @next_receipt_id = @filter.next_to_review(@receipt) if @receipt
    @accepted = params[:accepted].present?
  end

  def new
    @expense = ManualExpense.new(account_id: Account.default_for(nil)&.id, occurred_on: Date.current.iso8601)
  end

  def create
    @expense = ManualExpense.new(expense_params)
    if @expense.save
      redirect_to transaction_path(@expense.transaction), status: :see_other, notice: "Expense saved."
    else
      render :new, status: :unprocessable_content
    end
  end

  private
    def expense_params
      params.fetch(:manual_expense, {}).permit(:account_id, :payee_name, :occurred_on, :occurred_time,
        rows: %i[name amount category_id])
    end
end
