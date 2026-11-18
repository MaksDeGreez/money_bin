require "test_helper"

class MoneyInputTest < ActiveSupport::TestCase
  test "reads decimals with a comma or a dot, spaces between thousands and a typographic minus" do
    {
      "12.50" => "12.50", "12,50" => "12.50", " 1 250,40 " => "1250.40", "1 250.40" => "1250.40", "1 250" => "1250",
      "−2,50" => "-2.50", "+3" => "3", ",5" => ".5", "-0.335" => "-0.335", "12.345" => "12.345"
    }.each { |text, expected| assert_equal expected, MoneyInput.normalize(text), text.inspect }
  end

  test "blank is an empty string" do
    [ "", "  ", " " ].each { |text| assert_equal "", MoneyInput.normalize(text) }
  end

  test "anything else is not a decimal number" do
    [ "abc", "1e3", "1,250.40", "1.250,40", "12.5.0", "0x10", "12 UAH", "--1", "1,2,3", "." ].each do |text|
      assert_nil MoneyInput.normalize(text), text
    end
  end

  test "a value that is not a String passes through" do
    assert_nil MoneyInput.normalize(nil)
    assert_equal BigDecimal("1"), MoneyInput.normalize(BigDecimal("1"))
  end
end
