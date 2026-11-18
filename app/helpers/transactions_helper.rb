# Formatting for the transactions list and its review of suggestions.
module TransactionsHelper
  STATUS_TONES = { "confirmed" => :accent, "needs_review" => :signal, "draft" => :muted }.freeze
  SUGGESTION_SOURCES = { "model" => "the model", "history" => "the payee's history", "mix" => "the model and the payee's history" }.freeze

  # [[group name, [[group name (all), group id], [category name, id], ...]], ...] for the filter's select: a group
  # means any of its categories (TransactionsQuery).
  def transaction_filter_categories
    Category.groups.ordered.includes(:children).map do |group|
      [ group.name, [ [ "#{group.name} (all)", group.id ], *group.children.map { |category| [ category.name, category.id ] } ] ]
    end
  end

  def transaction_status_badge(transaction)
    ui_badge(transaction.status.humanize, tone: STATUS_TONES.fetch(transaction.status))
  end

  # The categories of a transaction's lines, in words: "Groceries", "Groceries, Household", "No category".
  def transaction_categories(transaction)
    return tag.span("Transfer", class: "text-ink-muted") if transaction.transfer_leg?

    names = transaction.lines.map { |line| line.uncategorised? ? nil : line.category.name }.uniq
    labels = names.map { |name| name || tag.span("Uncategorised", class: "text-ink-muted") }
    safe_join(labels, ", ")
  end

  # The uncategorised lines of a transaction (none for a transfer leg).
  def transaction_review_lines(transaction)
    transaction.transfer_leg? ? [] : transaction.lines.select(&:uncategorised?)
  end

  # "Groceries · 93 %" for a line's best suggestion.
  def transaction_suggestion(line)
    "#{line.suggested_category.full_name} · #{receipt_confidence(line.suggestion_probability)}"
  end

  # "then Eating out / Cafes · 4 %" for the runner-up, or nil.
  def transaction_runner_up(line)
    return unless line.runner_up_category

    "then #{line.runner_up_category.full_name} · #{receipt_confidence(line.runner_up_probability)}"
  end

  def transaction_suggestion_source(line)
    "from #{SUGGESTION_SOURCES.fetch(line.suggestion_source, 'the model')}"
  end

  # One line about the latest suggestion run: what it did, or why it failed.
  def transaction_suggestion_run_summary(run)
    return "Suggestions have not been computed yet." unless run

    case run.status
    when "queued" then "Suggestions are queued."
    when "running" then "Computing suggestions: #{run.scored_count + run.skipped_count} of #{run.total_count} transactions."
    when "done"
      "Suggestions by #{run.model_version} (#{run.scored_count} scored, #{run.skipped_count} with nothing to go on), #{l(run.finished_at, format: :short)}."
    else
      "The last refresh failed (#{run.error}); the categoriser may not be running or set up (ml/README.md)."
    end
  end
end
