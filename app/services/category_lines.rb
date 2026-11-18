# The rule that turns a list of amounts with categories into a transaction's lines: one line per category,
# the amounts of that category summed (docs/domain.md, "Acceptance"). Receipt acceptance (the items of a
# receipt, or the one total of a card slip) and manual entry (the rows a person typed) both book through it.
#
#   CategoryLines.build(items, sign: -1)
#   # => [{ category_id: 3, amount: -57.5 }, { category_id: nil, amount: -95.0 }]
#
# - Each entry responds to `category_id` and `amount` (a BigDecimal; nil counts as zero). Entries without a
#   category form one line with no category.
# - Lines come in the order their categories first appear.
# - A category whose amounts sum to zero (a free item) adds no line; one that sums below zero (a deposit
#   returned) gives a line of the opposite sign.
# - `sign` is -1 for an expense, 1 for an income; the line amounts carry it.
#
# Plain BigDecimal arithmetic: nothing is rounded, and the lines always sum to `sign * total(entries)`.
module CategoryLines
  # One amount with its category, for callers that have no record to pass.
  Entry = Data.define(:category_id, :amount)

  module_function

  # The sum of the entries' amounts, as a BigDecimal.
  def total(entries)
    entries.sum(BigDecimal("0")) { |entry| entry.amount || 0 }
  end

  # The line attributes, ready for `lines_attributes`.
  def build(entries, sign:)
    raise ArgumentError, "sign must be 1 or -1" unless [ 1, -1 ].include?(sign)

    entries.group_by(&:category_id).filter_map do |category_id, group|
      sum = total(group)
      { category_id:, amount: sign * sum } unless sum.zero?
    end
  end

  # True when a line has no category: the transaction then needs a person's review.
  def uncategorised?(lines)
    lines.any? { |line| line[:category_id].nil? }
  end
end
