require "test_helper"

module LegacyImport
  class ValuesTest < ActiveSupport::TestCase
    def refusal(reader, value)
      assert_raises(Values::Invalid) { Values.public_send(reader, value) }.message
    end

    test "amounts are decimal strings with at most two places, never zero" do
      assert_equal BigDecimal("-1250.5"), Values.amount("-1250.50")
      assert_equal BigDecimal("7"), Values.amount("7")

      assert_equal "must be a decimal string", refusal(:amount, 12.5)
      assert_equal "is not a decimal string", refusal(:amount, "1,5")
      assert_equal "is not a decimal string", refusal(:amount, "1e3")
      assert_equal "is not a decimal string", refusal(:amount, "+5.00")
      assert_equal "has more than 2 decimal places", refusal(:amount, "12.345")
      assert_equal "is zero", refusal(:amount, "-0.00")
      assert_equal "is out of range", refusal(:amount, "10000000000000.00")
    end

    test "legacy ids are integers or non-empty strings, compared as text" do
      assert_equal "12", Values.legacy_id(12)
      assert_equal "a-12", Values.legacy_id("a-12")
      assert_equal "is empty", refusal(:legacy_id, "")
      assert_equal "is empty", refusal(:legacy_id, "  ")
      assert_equal "has spaces at the start or the end", refusal(:legacy_id, " 12")
      assert_equal "has spaces at the start or the end", refusal(:legacy_id, "12\t")
      assert_equal "must be an integer or a string", refusal(:legacy_id, 1.5)
    end

    test "dates and times" do
      assert_equal Date.new(2026, 2, 28), Values.date("2026-02-28")
      assert_equal "is not a real date", refusal(:date, "2026-02-30")
      assert_equal "must be a YYYY-MM-DD string", refusal(:date, "28.02.2026")

      assert_nil Values.time_or_nil(nil)
      assert_equal Time.utc(2026, 1, 10, 7), Values.time_or_nil("2026-01-10T09:00:00+02:00")
      assert_equal Time.utc(2026, 1, 10, 7, 0, 1.5r), Values.time_or_nil("2026-01-10T07:00:01.5Z")
      assert_equal Time.utc(2026, 1, 10, 7, 0, 0.123456r), Values.time_or_nil("2026-01-10T09:00:00.123456+02:00")
      # The column keeps microseconds: a seventh digit would be lost, and the row would never settle.
      assert_equal "must be an ISO 8601 time with an offset", refusal(:time_or_nil, "2026-01-10T09:00:00.1234567+02:00")
      assert_equal "must be an ISO 8601 time with an offset", refusal(:time_or_nil, "2026-01-10T07:00Z")
      assert_equal "must be an ISO 8601 time with an offset", refusal(:time_or_nil, "2026-01-10T09:00:00")
      assert_equal "is not a real time", refusal(:time_or_nil, "2026-01-10T25:00:00Z")
    end

    test "other fields" do
      assert_equal "USD", Values.currency("USD")
      assert_equal "must be three upper-case letters", refusal(:currency, "usd")
      assert_equal "is blank", refusal(:text, "  ")
      assert_equal "must be a string", refusal(:text, 5)
      assert_nil Values.text_or_nil(nil)
      assert_equal "must be a string or null", refusal(:text_or_nil, false)
      assert_nil Values.present_text_or_nil(nil)
      assert_equal "Groceries", Values.present_text_or_nil("Groceries")
      assert_equal "is blank (use null when there is no value)", refusal(:present_text_or_nil, " ")
      assert_equal "must be a string or null", refusal(:present_text_or_nil, 3)
      assert_equal "contains a NUL character", refusal(:text, "a\u0000b")
      assert_equal "contains a NUL character", refusal(:text_or_nil, "\u0000")
      assert_equal "contains a NUL character", refusal(:legacy_id, "12\u000034")
      assert_equal false, Values.boolean(false)
      assert_equal "must be true or false", refusal(:boolean, "no")
      assert_equal "5411", Values.mcc_or_nil("5411")
      assert_nil Values.mcc_or_nil(nil)
      assert_equal "must be a string of four digits", refusal(:mcc_or_nil, 5411)
    end

    test "only id-like values are printed" do
      assert_equal "1007", Values.printable_id(1007)
      assert_equal "legacy:7", Values.printable_id("legacy:7")
      assert_equal "not printable", Values.printable_id("Some Person Name")
    end
  end
end
