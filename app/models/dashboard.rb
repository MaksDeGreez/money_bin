# The home page's figures: spending by month, by category (or group) and by payee, a few headline figures
# and the receipt counts, for one period and one currency.
#
#   dashboard = Dashboard.new(params.permit(*Dashboard::KEYS))
#   dashboard.months       # every month of the period, oldest first, with what was spent and earned
#   dashboard.slices       # the largest categories (or groups), then "Other"
#   dashboard.payees       # TopPayeesQuery::CurrencyPayees of the currency, or nil
#
# Every money figure comes from the query objects behind the REST API and the MCP server
# (SpendingSummaryQuery, TopPayeesQuery), so the page cannot disagree with them: booked transactions only,
# transfer legs left out, split transactions by their lines, one currency at a time. This class only picks
# the period and the currency, fills empty months with zero, and sums the tail of the categories as
# "Other", all in BigDecimal. Spending is shown as a positive figure (`spent` = -expenses).
#
# The state is the URL, like the receipts filter: `period` ("last12", the default, or a year from the first
# booked row's to this one), `currency` (UAH by default) and `by` ("category", the default, or "group"). A
# value that is not a choice falls back to the default, so an old or edited URL never fails.
#
# Periods are whole calendar months: the last 12 months run from the first day of the month a year back
# to the last day of this month, and a year from 1 January to 31 December, so a booked row dated later this
# month or year (a payment booked ahead) is counted, as GET /api/v1/summary counts it for the same range.
class Dashboard
  KEYS = %i[period currency by].freeze
  LAST_12 = "last12"
  GROUPINGS = %w[category group].freeze
  DEFAULT_CURRENCY = "UAH"
  CURRENCY_FORMAT = /\A[A-Z]{3}\z/
  TOP_CATEGORIES = 10
  TOP_PAYEES = 10
  ZERO = BigDecimal("0")

  Period = Data.define(:key, :from, :to) do
    def last_12? = key == LAST_12
  end
  # `month` is the first day of the month; `spent` and `income` are positive BigDecimals (0 when none).
  Month = Data.define(:month, :spent, :income)
  # One bar of the category chart. `kind` is :category, :group, :no_category (lines with no category,
  # reported apart from the taxonomy's own Uncategorised category, as in the summary) or :other; `record`
  # the Category, `group` its group (nil where there is none); `count` how many categories "Other" holds;
  # `transactions` is nil for groups and "Other" (a split transaction would be counted in several of them).
  Slice = Data.define(:kind, :record, :group, :spent, :transactions, :count)
  # This month so far against the previous month and the same month a year before (whole months).
  Comparison = Data.define(:month, :spent, :previous_month, :previous_spent, :year_ago_month, :year_ago_spent)

  attr_reader :today, :grouping, :currency

  # An expense figure (negative, as in the ledger) as money spent (positive). Subtracted from zero rather
  # than negated: `-BigDecimal("0")` is a negative zero, which would print as "-0.00".
  def self.as_spent(amount)
    ZERO - amount
  end

  def initialize(params = {}, today: Date.current)
    params = params.to_h.symbolize_keys
    @today = today
    @currency = params[:currency].to_s.match?(CURRENCY_FORMAT) ? params[:currency] : DEFAULT_CURRENCY
    @grouping = GROUPINGS.include?(params[:by]) ? params[:by] : GROUPINGS.first
    @period_key = params[:period].to_s
  end

  DEFAULTS = { period: LAST_12, currency: DEFAULT_CURRENCY, by: GROUPINGS.first }.freeze

  # The URL parameters of this view with `changes`, defaults left out: `root_path(dashboard.to_params(by: "group"))`.
  def to_params(**changes)
    { period: period.key, currency:, by: grouping }.merge(changes).reject { |key, value| DEFAULTS[key] == value }
  end

  def period
    @period ||= if (year = available_years.find { |candidate| candidate.to_s == @period_key })
      Period.new(key: year.to_s, from: Date.new(year, 1, 1), to: Date.new(year, 12, 31))
    else
      Period.new(key: LAST_12, from: last_12_from, to: today.end_of_month)
    end
  end

  # Every year from the first booked, non-transfer row's to this one, newest first (this year always; a year
  # in between may have no rows, and then shows the empty state).
  def available_years
    @available_years ||= today.year.downto([ first_booked_on&.year || today.year, today.year ].min).to_a
  end

  # The currencies with booked rows in the period, UAH first, then by code; the chosen one is always in.
  def currencies
    @currencies ||= (summary.currencies.map(&:currency) | [ currency ])
      .sort_by { |code| [ code == DEFAULT_CURRENCY ? 0 : 1, code ] }
  end

  # Nothing booked in the chosen currency in the period.
  def empty?
    figures.nil?
  end

  # The whole ledger has nothing booked yet.
  def ledger_empty?
    first_booked_on.nil?
  end

  def spent
    figures ? self.class.as_spent(figures.expenses.total) : ZERO
  end

  def income
    figures ? figures.incomes.total : ZERO
  end

  # Every month of the period, oldest first, zero where nothing was booked.
  def months
    @months ||= begin
      spent = by_month(figures&.expenses)
      income = by_month(figures&.incomes)
      month_starts(period.from, period.to).map do |month|
        key = month.strftime("%Y-%m")
        Month.new(month:, spent: self.class.as_spent(spent.fetch(key, ZERO)), income: income.fetch(key, ZERO))
      end
    end
  end

  # The largest categories (or groups) by what was spent, then the rest summed as "Other". The lines with no
  # category are ranked like a category (the summary's row with a nil category), so outside the top they
  # are part of "Other" too.
  def slices
    @slices ||= begin
      rows = figures ? (grouping == "group" ? figures.expenses.by_group : figures.expenses.by_category) : []
      top, rest = rows.first(TOP_CATEGORIES), rows.drop(TOP_CATEGORIES)
      slices = top.map { |row| slice_of(row) }
      slices << Slice.new(kind: :other, record: nil, group: nil, spent: self.class.as_spent(rest.sum(ZERO, &:amount)), transactions: nil, count: rest.size) if rest.any?
      slices
    end
  end

  # The uncategorised spending of the period: the lines in the taxonomy's Uncategorised category (where the
  # history import puts what it could not map) and the lines with no category, as [amount spent,
  # transactions]. A split transaction with lines in both counts twice in the number, never in the amount.
  def uncategorised
    rows = figures ? figures.expenses.by_category.select { |row| row.category.nil? || row.category.slug == Category::UNCATEGORISED_SLUG } : []
    [ self.class.as_spent(rows.sum(ZERO, &:amount)), rows.sum(&:transactions) ]
  end

  def payees
    @payees ||= TopPayeesQuery.new(from: period.from, to: period.to, currency:, limit: TOP_PAYEES).call
      .currencies.find { |entry| entry.currency == currency }
  end

  def receipts
    @receipts ||= ReceiptCountsQuery.new.call
  end

  # Booked transactions a person should still look at, in every currency and period.
  def needs_review_count
    @needs_review_count ||= Transaction.needs_review.count
  end

  # This month so far, the previous month and the same month a year before, in the chosen currency.
  def comparison
    @comparison ||= begin
      side = comparison_figures&.expenses
      spent = by_month(side)
      month = today.beginning_of_month
      spent_in = ->(start) { self.class.as_spent(spent.fetch(start.strftime("%Y-%m"), ZERO)) }
      Comparison.new(month:, spent: spent_in.(month), previous_month: month.prev_month, previous_spent: spent_in.(month.prev_month),
        year_ago_month: month.prev_year, year_ago_spent: spent_in.(month.prev_year))
    end
  end

  private
    def first_booked_on
      return @first_booked_on if defined?(@first_booked_on)

      @first_booked_on = Transaction.booked.where(transfer_id: nil).minimum(:occurred_on)
    end

    def last_12_from
      today.beginning_of_month.prev_month(12)
    end

    def summary
      @summary ||= SpendingSummaryQuery.new(from: period.from, to: period.to).call
    end

    # The chosen currency's CurrencySummary, or nil when it has nothing in the period.
    def figures
      summary.currencies.find { |entry| entry.currency == currency }
    end

    # The last-12-months range covers the three months compared (whole months, this one to its last day);
    # another period needs its own summary.
    def comparison_figures
      if period.last_12?
        figures
      else
        SpendingSummaryQuery.new(from: last_12_from, to: today.end_of_month, currency:).call.currencies.first
      end
    end

    def by_month(side)
      side ? side.by_month.to_h { |row| [ row.month, row.amount ] } : {}
    end

    def month_starts(from, to)
      months = []
      month = from.beginning_of_month
      while month <= to
        months << month
        month = month.next_month
      end
      months
    end

    def slice_of(row)
      if row.is_a?(SpendingSummaryQuery::GroupAmount)
        Slice.new(kind: row.group ? :group : :no_category, record: row.group, group: nil, spent: self.class.as_spent(row.amount),
          transactions: nil, count: 1)
      else
        Slice.new(kind: row.category ? :category : :no_category, record: row.category, group: row.group,
          spent: self.class.as_spent(row.amount), transactions: row.transactions, count: 1)
      end
    end
end
