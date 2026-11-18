# Labels, money and chart data for the home page (Dashboard). Nothing here adds money up: the figures come
# from Dashboard and its query objects as BigDecimals, and this module only writes them out.
#
# What a chart receives (docs/decisions/0013-dashboard-charts.md): Chartkick's multi-series format, every
# money value as an exact decimal string (JsonFormat.money, never a Float) and, per point, the text its
# tooltip shows, formatted here from the same BigDecimal (`library: { exact: [...] }`, read by
# app/javascript/charts.js). Chart.js turns the strings into numbers only to draw the bars.
module DashboardHelper
  # Money as stored, two decimals, thousands split by a space: "1 250.40", "1 250.40 UAH". Never through a Float.
  def dashboard_money(amount, currency = nil)
    [ number_with_precision(amount, precision: 2, delimiter: " "), currency ].compact.join(" ")
  end

  def dashboard_month(month)
    month.strftime("%b %Y")
  end

  def dashboard_period_label(period)
    period.last_12? ? "the last 12 months" : period.key
  end

  def dashboard_period_options(dashboard)
    [ [ "Last 12 months", Dashboard::LAST_12 ] ] + dashboard.available_years.map { |year| [ year.to_s, year.to_s ] }
  end

  def dashboard_slice_label(slice, grouping)
    case slice.kind
    when :category, :group then slice.record.name
    when :no_category then "No category"
    when :other then "Other (#{pluralize(slice.count, grouping)})"
    end
  end

  def dashboard_transactions(count)
    pluralize(number_with_delimiter(count, delimiter: " "), "transaction") if count
  end

  def dashboard_month_series(dashboard)
    months = dashboard.months
    labels = months.map { |row| dashboard_month(row.month) }
    [
      dashboard_series("Spent", labels, months.map(&:spent), months.map { |row| dashboard_money(row.spent, dashboard.currency) }),
      dashboard_series("Income", labels, months.map(&:income), months.map { |row| dashboard_money(row.income, dashboard.currency) })
    ]
  end

  def dashboard_slice_series(dashboard)
    slices = dashboard.slices
    labels = dashboard_unique_labels(slices.map { |slice| dashboard_slice_label(slice, dashboard.grouping) })
    tooltips = slices.map { |slice| [ dashboard_money(slice.spent, dashboard.currency), dashboard_transactions(slice.transactions) ].compact.join(" · ") }
    [ dashboard_series("Spent", labels, slices.map(&:spent), tooltips) ]
  end

  def dashboard_payee_series(payees, currency)
    labels = dashboard_unique_labels(payees.payees.map { |row| row.payee.name })
    spent = payees.payees.map { |row| Dashboard.as_spent(row.amount) }
    tooltips = payees.payees.map { |row| "#{dashboard_money(Dashboard.as_spent(row.amount), currency)} · #{dashboard_transactions(row.transactions)}" }
    [ dashboard_series("Spent", labels, spent, tooltips) ]
  end

  # The receipt pipeline as one series of counts (Integers).
  def dashboard_receipt_series(rows)
    [ dashboard_series("Receipts", rows.map(&:first), rows.map(&:last), rows.map { |_, count| pluralize(number_with_delimiter(count, delimiter: " "), "receipt") }) ]
  end

  # [label, count] pairs for the receipts chart and table.
  def dashboard_receipt_rows(counts)
    [
      [ "Stored", counts.total ],
      [ "Read by OCR", counts.read_by_ocr ],
      [ "Waiting for review", counts.by_status.fetch("extracted") ],
      [ "Accepted into the ledger", counts.by_status.fetch("reviewed") ],
      [ "OCR failed", counts.by_status.fetch("failed") ],
      [ "With ground truth", counts.with_ground_truth ]
    ]
  end

  # One Chartkick series. `values` are BigDecimals (money, written as exact decimal strings) or Integers
  # (counts); a Float is refused.
  def dashboard_series(name, labels, values, tooltips)
    data = labels.zip(values).map do |label, value|
      raise ArgumentError, "chart values must be BigDecimal or Integer, got #{value.class}" unless value.is_a?(BigDecimal) || value.is_a?(Integer)

      [ label, value.is_a?(BigDecimal) ? JsonFormat.money(value) : value ]
    end
    { name:, data:, library: { exact: tooltips } }
  end

  # Chartkick merges points with the same label, so two payees or categories that share a name get a
  # number: "Market", "Market (2)".
  def dashboard_unique_labels(labels)
    seen = Hash.new(0)
    labels.map do |label|
      seen[label] += 1
      seen[label] == 1 ? label : "#{label} (#{seen[label]})"
    end
  end
end
