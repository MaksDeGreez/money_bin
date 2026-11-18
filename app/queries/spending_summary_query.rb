# Expenses and incomes for a date range, by category, by group and by month, per currency.
#
# The rules (docs/decisions/0007-read-api.md):
# - only booked transactions count (Transaction.booked): a draft is a proposal, not money spent;
# - transfer legs are left out: moving money between own accounts is neither spending nor income;
# - each currency is summed on its own (the account currency). Two currencies are never added together,
#   since there are no exchange rates yet; `currency` limits the summary to one;
# - a transaction is an expense when its amount is negative and an income when it is positive (the same
#   rule as Transaction.expenses / .incomes). Its lines are then summed per category, so a split
#   transaction gives each category its own share, and a line of the opposite sign inside it (a bottle
#   deposit returned) lowers that category's figure. A refund booked as a positive transaction is an
#   income;
# - amounts keep the ledger's sign: expense figures are negative, income figures positive;
# - a group's figure is the sum of its categories' figures. Lines with no category are reported with a
#   nil category (and a nil group);
# - months are calendar months of `occurred_on`; a month with nothing in it is absent.
#
# Two queries for the figures and one for the category names, whatever the range.
class SpendingSummaryQuery
  Summary = Data.define(:from, :to, :currencies)
  CurrencySummary = Data.define(:currency, :expenses, :incomes)
  # `transactions` counts transactions; in `by_category` a split transaction counts once in each of its
  # categories.
  Side = Data.define(:total, :transactions, :by_category, :by_group, :by_month)
  CategoryAmount = Data.define(:category, :group, :amount, :transactions)
  GroupAmount = Data.define(:group, :amount)
  MonthAmount = Data.define(:month, :amount, :by_category)
  MonthCategoryAmount = Data.define(:category, :amount)

  # One grouped row of line sums.
  LineSum = Data.define(:currency, :expense, :category_id, :month, :amount, :transactions)

  ZERO = BigDecimal("0")

  # `from` and `to` are Dates (inclusive); `currency` an ISO 4217 code or nil for every currency.
  def initialize(from:, to:, currency: nil)
    raise ArgumentError, "from must not be after to" if from > to

    @from = from
    @to = to
    @currency = currency
  end

  def call
    sums = line_sums
    counts = transaction_counts
    categories = Category.all.index_by(&:id)

    currencies = sums.map(&:currency).uniq.sort.map do |currency|
      of_currency = sums.select { |sum| sum.currency == currency }
      CurrencySummary.new(
        currency:,
        expenses: side(of_currency.select(&:expense), counts.fetch([ currency, true ], 0), categories),
        incomes: side(of_currency.reject(&:expense), counts.fetch([ currency, false ], 0), categories)
      )
    end
    Summary.new(from: @from, to: @to, currencies:)
  end

  private
    # The booked, non-transfer transactions of the range, as conditions on `transactions` (the caller joins
    # `accounts`, which the currency condition needs).
    def counted
      scope = Transaction.booked.where(transfer_id: nil, occurred_on: @from..@to)
      @currency ? scope.where(accounts: { currency: @currency }) : scope
    end

    def line_sums
      expense = Arel.sql("transactions.amount < 0")
      month = Arel.sql("to_char(transactions.occurred_on, 'YYYY-MM')")
      TransactionLine.joins(parent: :account).merge(counted)
        .group("accounts.currency", expense, "transaction_lines.category_id", month)
        .pluck("accounts.currency", expense, "transaction_lines.category_id", month,
          Arel.sql("SUM(transaction_lines.amount)"), Arel.sql("COUNT(DISTINCT transactions.id)"))
        .map { |values| LineSum.new(*values) }
    end

    # { [currency, expense?] => number of transactions }
    def transaction_counts
      counted.joins(:account).group("accounts.currency", Arel.sql("transactions.amount < 0")).count
    end

    def side(sums, transactions, categories)
      by_category = sums.group_by(&:category_id).map do |category_id, of_category|
        category = categories[category_id]
        CategoryAmount.new(category:, group: category && categories[category.parent_id], amount: total(of_category),
          transactions: of_category.sum(&:transactions))
      end

      Side.new(
        total: total(sums),
        transactions:,
        by_category: by_size(by_category) { |row| row.category&.slug },
        by_group: by_group(by_category),
        by_month: by_month(sums, categories)
      )
    end

    def by_group(by_category)
      rows = by_category.group_by(&:group).map do |group, of_group|
        GroupAmount.new(group:, amount: of_group.sum(ZERO, &:amount))
      end
      by_size(rows) { |row| row.group&.slug }
    end

    def by_month(sums, categories)
      sums.group_by(&:month).sort.map do |month, of_month|
        rows = of_month.map { |sum| MonthCategoryAmount.new(category: categories[sum.category_id], amount: sum.amount) }
        MonthAmount.new(month:, amount: total(of_month), by_category: by_size(rows) { |row| row.category&.slug })
      end
    end

    def total(sums)
      sums.sum(ZERO, &:amount)
    end

    # Largest magnitude first; ties by slug, the rows with no category last.
    def by_size(rows)
      rows.sort_by { |row| [ -row.amount.abs, yield(row).nil? ? 1 : 0, yield(row).to_s ] }
    end
end
