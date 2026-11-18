# The payees that took the most money in a date range, per currency, with how many transactions each.
#
# The rules are SpendingSummaryQuery's (docs/decisions/0007-read-api.md), so the figures add up to its
# expense totals for the same range and currency:
# - only booked transactions count (Transaction.booked); a draft is a proposal, not money spent;
# - transfer legs are left out;
# - each currency stands alone: two currencies are never added together;
# - only expenses (a transaction with a negative amount, as in Transaction.expenses); their lines are
#   summed, so a split transaction counts once, with its whole amount, for its one payee, and an
#   opposite-sign line inside it (a bottle deposit returned) lowers the payee's figure;
# - amounts keep the ledger's sign: expense figures are negative.
#
# Per currency: the `limit` largest payees (largest magnitude first, ties by name), what the other payees
# took together (`other`), and the expenses with no payee (`without_payee`). The three parts add up to
# `total`, which equals SpendingSummaryQuery's `expenses.total` for the same range and currency.
#
# Two queries whatever the range: one grouped sum of lines and the names of the payees shown.
class TopPayeesQuery
  Result = Data.define(:from, :to, :currencies)
  CurrencyPayees = Data.define(:currency, :total, :transactions, :payees, :other, :without_payee)
  PayeeAmount = Data.define(:payee, :amount, :transactions)
  # The payees outside the top: their number, what they took and in how many transactions.
  Rest = Data.define(:payees, :amount, :transactions)
  # Expenses with no payee.
  Unnamed = Data.define(:amount, :transactions)

  DEFAULT_LIMIT = 10
  MAX_LIMIT = 100
  ZERO = BigDecimal("0")

  # One grouped row: the expense lines of one payee (nil for none) in one currency.
  PayeeSum = Data.define(:currency, :payee_id, :amount, :transactions)

  # `from` and `to` are Dates (inclusive); `currency` an ISO 4217 code or nil for every currency; `limit`
  # how many payees to name (1 to MAX_LIMIT).
  def initialize(from:, to:, currency: nil, limit: DEFAULT_LIMIT)
    raise ArgumentError, "from must not be after to" if from > to
    raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}" unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)

    @from = from
    @to = to
    @currency = currency
    @limit = limit
  end

  def call
    sums = payee_sums
    names = payee_names(sums)

    currencies = sums.group_by(&:currency).sort.map do |currency, of_currency|
      named, unnamed = of_currency.partition(&:payee_id)
      ranked = named.sort_by { |sum| [ -sum.amount.abs, names[sum.payee_id]&.name.to_s, sum.payee_id ] }
      top, rest = ranked.first(@limit), ranked.drop(@limit)

      CurrencyPayees.new(
        currency:,
        total: of_currency.sum(ZERO, &:amount),
        transactions: of_currency.sum(&:transactions),
        payees: top.map { |sum| PayeeAmount.new(payee: names.fetch(sum.payee_id), amount: sum.amount, transactions: sum.transactions) },
        other: Rest.new(payees: rest.size, amount: rest.sum(ZERO, &:amount), transactions: rest.sum(&:transactions)),
        without_payee: Unnamed.new(amount: unnamed.sum(ZERO, &:amount), transactions: unnamed.sum(&:transactions))
      )
    end
    Result.new(from: @from, to: @to, currencies:)
  end

  private
    # The same transactions as SpendingSummaryQuery's expense side.
    def counted
      scope = Transaction.expenses.where(occurred_on: @from..@to)
      @currency ? scope.where(accounts: { currency: @currency }) : scope
    end

    def payee_sums
      TransactionLine.joins(parent: :account).merge(counted)
        .group("accounts.currency", "transactions.payee_id")
        .pluck("accounts.currency", "transactions.payee_id", Arel.sql("SUM(transaction_lines.amount)"),
          Arel.sql("COUNT(DISTINCT transactions.id)"))
        .map { |values| PayeeSum.new(*values) }
    end

    # The names are needed to break ties, so every payee of the range is read. A ledger has a few thousand
    # payees; one range has far fewer.
    def payee_names(sums)
      ids = sums.filter_map(&:payee_id).uniq
      ids.empty? ? {} : Payee.where(id: ids).index_by(&:id)
    end
end
