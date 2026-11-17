require "test_helper"

class DecimalPlacesValidatorTest < ActiveSupport::TestCase
  test "fits? checks the exact value" do
    fitting = [ 7, BigDecimal("12.34"), "12.340", " 1.5 ", Rational(5, 2), 12.5, -0.01 ]
    too_long = [ 12.345, 0.105, BigDecimal("0.001"), "1.005", Rational(10, 3) ]

    fitting.each { |value| assert DecimalPlacesValidator.fits?(value, 2), value.inspect }
    too_long.each { |value| assert_not DecimalPlacesValidator.fits?(value, 2), value.inspect }
    [ nil, "abc", "1,5", Float::NAN, BigDecimal("Infinity") ].each do |value|
      assert_not DecimalPlacesValidator.fits?(value, 2), value.inspect
    end
  end

  test "leaves values that are not numbers to the numericality validation" do
    line = transactions(:coffee).lines.build(amount: "about ten")

    assert_not line.valid?
    assert_equal [ "is not a number" ], line.errors[:amount]
  end

  test "needs a non-negative Integer maximum" do
    assert_raises(ArgumentError) { DecimalPlacesValidator.new(attributes: [ :amount ], maximum: 1.5) }
    assert_raises(ArgumentError) { DecimalPlacesValidator.new(attributes: [ :amount ]) }
  end
end
