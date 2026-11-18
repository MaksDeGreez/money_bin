# The JSON of a SpendingSummaryQuery::Summary (docs/openapi.yaml, Summary).
module SpendingSummarySerializer
  module_function

  def call(summary)
    {
      from: JsonFormat.date(summary.from),
      to: JsonFormat.date(summary.to),
      currencies: summary.currencies.map do |currency|
        { currency: currency.currency, expenses: side(currency.expenses), incomes: side(currency.incomes) }
      end
    }
  end

  def side(side)
    {
      total: JsonFormat.money(side.total),
      transactions: side.transactions,
      by_category: side.by_category.map do |row|
        {
          category: CategorySerializer.reference(row.category),
          group: CategorySerializer.reference(row.group),
          amount: JsonFormat.money(row.amount),
          transactions: row.transactions
        }
      end,
      by_group: side.by_group.map { |row| { group: CategorySerializer.reference(row.group), amount: JsonFormat.money(row.amount) } },
      by_month: side.by_month.map do |month|
        {
          month: month.month,
          amount: JsonFormat.money(month.amount),
          by_category: month.by_category.map do |row|
            { category: CategorySerializer.reference(row.category), amount: JsonFormat.money(row.amount) }
          end
        }
      end
    }
  end
end
