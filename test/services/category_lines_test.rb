require "test_helper"

class CategoryLinesTest < ActiveSupport::TestCase
  Entry = CategoryLines::Entry

  test "amounts are summed per category, in the order categories first appear, with the sign" do
    entries = [ Entry.new(category_id: 2, amount: BigDecimal("10.10")), Entry.new(category_id: nil, amount: BigDecimal("5")),
                Entry.new(category_id: 2, amount: BigDecimal("0.20")), Entry.new(category_id: 3, amount: BigDecimal("-1.50")) ]

    assert_equal [ { category_id: 2, amount: BigDecimal("-10.30") }, { category_id: nil, amount: BigDecimal("-5") },
                   { category_id: 3, amount: BigDecimal("1.50") } ], CategoryLines.build(entries, sign: -1)
    assert_equal BigDecimal("13.80"), CategoryLines.total(entries)
    assert CategoryLines.uncategorised?(CategoryLines.build(entries, sign: 1))
  end

  test "a category that sums to zero adds no line, and the lines always sum to the signed total" do
    entries = [ Entry.new(category_id: 1, amount: BigDecimal("0.10")), Entry.new(category_id: 1, amount: BigDecimal("-0.10")),
                Entry.new(category_id: 2, amount: BigDecimal("0.20")), Entry.new(category_id: 2, amount: BigDecimal("0.10")) ]
    lines = CategoryLines.build(entries, sign: -1)

    assert_equal [ { category_id: 2, amount: BigDecimal("-0.30") } ], lines
    assert_equal(-CategoryLines.total(entries), lines.sum { |line| line[:amount] })
    assert lines.all? { |line| line[:amount].is_a?(BigDecimal) }, "never a Float: 0.1 + 0.2 is exactly 0.3"
  end

  test "the sign must be 1 or -1" do
    assert_raises(ArgumentError) { CategoryLines.build([], sign: 0) }
  end
end
