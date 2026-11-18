module McpTools
  # spending_summary: SpendingSummaryQuery, as GET /api/v1/summary.
  class SpendingSummary < Base
    tool_name "spending_summary"
    title "Spending summary"
    description <<~TEXT.squish
      How much was spent and earned in a date range: expenses and incomes in total, by category, by category
      group and by calendar month, separately for each currency. Use it for questions like "how much did I
      spend on groceries last month" or "what were my biggest expenses this year". Rules: only booked
      transactions count (drafts are proposals and are left out); transfers between the owner's own accounts
      are neither spending nor income and are left out; a transaction split into several categories counts
      each share in its own category. Expense amounts are NEGATIVE, as in the ledger ("-800.00" means 800.00
      spent); income amounts are positive. Amounts are decimal strings in the currency named next to them;
      there are no exchange rates, so never add or compare amounts of two different currencies. A category
      group (e.g. slug "groceries") is the sum of its categories ("groceries/groceries", ...); list_categories
      gives every slug. To compare two periods (this month and the same month a year ago), call the tool once
      per period with the same kind of range. Lines with no category are reported with a null category.
    TEXT
    input_schema(
      type: "object",
      properties: {
        from: DATE_SCHEMA.merge(description: "First day of the range, YYYY-MM-DD, inclusive. A month is its first to its last day."),
        to: DATE_SCHEMA.merge(description: "Last day of the range, YYYY-MM-DD, inclusive; not before from."),
        currency: {
          type: "string", pattern: "^[A-Z]{3}$",
          description: "Only this currency (ISO 4217 code that an account uses, e.g. UAH). Leave it out to get every currency, each on its own."
        }
      },
      required: %w[from to],
      additionalProperties: false
    )
    output_schema OutputSchema.of("Summary")
    annotations(**ANNOTATIONS, title: "Spending summary")

    class << self
      private
        def answer(from:, to:, currency: nil)
          from, to = QueryArguments.date_range(QueryArguments.date(:from, from), QueryArguments.date(:to, to))
          currency = currency.nil? ? nil : QueryArguments.currency(:currency, currency)
          json = SpendingSummarySerializer.call(SpendingSummaryQuery.new(from:, to:, currency:).call)

          [ text(json), json ]
        end

        def text(json)
          lines = [ "Booked transactions from #{json[:from]} to #{json[:to]}, transfers between own accounts left out. " \
            "Expenses are negative. Each currency stands alone: never add two currencies together." ]
          lines << "Nothing was booked in this range." if json[:currencies].empty?
          json[:currencies].each do |summary|
            currency = summary[:currency]
            lines << "" << "#{currency}:"
            lines.concat(side_lines("Expenses", summary[:expenses], currency))
            lines.concat(side_lines("Incomes", summary[:incomes], currency))
          end
          lines.join("\n")
        end

        def side_lines(label, side, currency)
          lines = [ "  #{label}: #{money(side[:total], currency)} in #{side[:transactions]} transaction(s)" ]
          return lines if side[:transactions].zero?

          lines << "    by group: " + side[:by_group].map { |row| "#{reference(row[:group])} #{row[:amount]}" }.join("; ")
          lines << "    by category: " + side[:by_category].map { |row| "#{reference(row[:category])} #{row[:amount]}" }.join("; ")
          lines << "    by month: " + side[:by_month].map { |row| "#{row[:month]} #{row[:amount]}" }.join("; ")
        end

        def reference(category)
          category ? "#{category[:name]} (#{category[:slug]})" : "No category"
        end
    end
  end
end
