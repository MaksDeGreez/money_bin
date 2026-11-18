require "test_helper"

class JsonFormatTest < ActiveSupport::TestCase
  test "money is a string with exactly two places" do
    assert_equal "-1250.40", JsonFormat.money(BigDecimal("-1250.4"))
    assert_equal "0.00", JsonFormat.money(BigDecimal("0"))
    assert_equal "0.00", JsonFormat.money(BigDecimal("-0"))
    assert_equal "-0.05", JsonFormat.money(BigDecimal("-0.05"))
    assert_equal "1000.00", JsonFormat.money(1000)
    assert_equal "9999999999999.99", JsonFormat.money(BigDecimal("9999999999999.99"))
    assert_nil JsonFormat.money(nil)
  end

  test "quantities have exactly three places" do
    assert_equal "0.850", JsonFormat.quantity(BigDecimal("0.85"))
    assert_equal "2.000", JsonFormat.quantity(BigDecimal("2"))
  end

  test "a float is refused, and so is a value it would have to round" do
    assert_raises(ArgumentError) { JsonFormat.money(12.5) }
    assert_raises(ArgumentError) { JsonFormat.money("12.50") }
    assert_raises(ArgumentError) { JsonFormat.money(BigDecimal("1.005")) }
  end

  test "dates are ISO 8601 and times carry the Kyiv offset" do
    assert_equal "2026-10-03", JsonFormat.date(Date.new(2026, 10, 3))
    assert_equal "2026-10-03T18:40:00+03:00", JsonFormat.time(Time.utc(2026, 10, 3, 15, 40))
    assert_equal "2026-12-03T17:40:00+02:00", JsonFormat.time(Time.utc(2026, 12, 3, 15, 40))
    assert_nil JsonFormat.time(nil)
    assert_nil JsonFormat.date(nil)
  end
end
