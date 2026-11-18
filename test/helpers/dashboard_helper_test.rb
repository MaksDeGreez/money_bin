require "test_helper"

class DashboardHelperTest < ActionView::TestCase
  test "money is written from the BigDecimal, two places, thin groups, never a negative zero" do
    assert_equal "1 250.40 UAH", dashboard_money(BigDecimal("1250.4"), "UAH")
    assert_equal "12 345 678 901.23", dashboard_money(BigDecimal("12345678901.23"))
    assert_equal "0.00", dashboard_money(Dashboard.as_spent(BigDecimal("0")))
    assert_equal "-0.30", dashboard_money(BigDecimal("0.1") + BigDecimal("0.2") - BigDecimal("0.6"))
  end

  test "a series carries exact decimal strings and the tooltip text; a Float is refused" do
    series = dashboard_series("Spent", %w[A B], [ BigDecimal("0.1") + BigDecimal("0.2"), 3 ], [ "0.30 UAH", "3 receipts" ])

    assert_equal({ name: "Spent", data: [ [ "A", "0.30" ], [ "B", 3 ] ], library: { exact: [ "0.30 UAH", "3 receipts" ] } }, series)
    assert_raises(ArgumentError) { dashboard_series("Spent", %w[A], [ 0.3 ], [ "0.30" ]) }
  end

  test "labels that repeat get a number, so the chart keeps every point" do
    assert_equal [ "Market", "Cafe", "Market (2)" ], dashboard_unique_labels(%w[Market Cafe Market])
  end

  test "slice labels" do
    other = Dashboard::Slice.new(kind: :other, record: nil, group: nil, spent: BigDecimal("1"), transactions: nil, count: 3)
    none = Dashboard::Slice.new(kind: :no_category, record: nil, group: nil, spent: BigDecimal("1"), transactions: 2, count: 1)

    assert_equal "Other (3 categories)", dashboard_slice_label(other, "category")
    assert_equal "Other (3 groups)", dashboard_slice_label(other, "group")
    assert_equal "No category", dashboard_slice_label(none, "category")
  end
end
