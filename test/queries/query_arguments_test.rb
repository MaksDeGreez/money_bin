require "test_helper"

# The value checks the REST API and the MCP tools share. Query-string Strings and JSON values (Integers)
# must mean the same thing.
class QueryArgumentsTest < ActiveSupport::TestCase
  def refused(name, &block)
    error = assert_raises(QueryArguments::Invalid, &block)
    assert_equal name.to_s, error.name
    error.message
  end

  test "an id is an Integer or a String of digits, within a bigint, of a row that exists" do
    id = accounts(:card_uah).id

    assert_equal id, QueryArguments.id(:account_id, id, Account)
    assert_equal id, QueryArguments.id(:account_id, id.to_s, Account)
    [ 0, -1, 2**63, "0", "12abc", " 1", 1.5, nil, true ].each do |value|
      assert_includes refused(:account_id) { QueryArguments.id(:account_id, value, Account) }, "must be a positive integer id", value.inspect
    end
    assert_includes refused(:account_id) { QueryArguments.id(:account_id, 999_999_999, Account) }, "names no account (id 999999999)"
  end

  test "a category is a group or a category, by slug or by id" do
    assert_equal categories(:groceries_group).id, QueryArguments.category(:category, "groceries")
    assert_equal categories(:groceries).id, QueryArguments.category(:category, "groceries/groceries")
    assert_equal categories(:groceries).id, QueryArguments.category(:category, categories(:groceries).id)
    assert_equal categories(:groceries).id, QueryArguments.category(:category, categories(:groceries).id.to_s)
    assert_includes refused(:category) { QueryArguments.category(:category, "Groceries") }, "names no category or group (slug Groceries)"
    assert_includes refused(:category) { QueryArguments.category(:category, "") }, "must not be empty"
  end

  test "dates, ranges, text, currencies, enums and limits" do
    assert_equal Date.new(2026, 10, 1), QueryArguments.date(:from, "2026-10-01")
    assert_includes refused(:from) { QueryArguments.date(:from, "2026-13-01") }, "is not a valid date"
    assert_includes refused(:from) { QueryArguments.date(:from, 20261001) }, "must be a date as YYYY-MM-DD"
    assert_includes refused(:to) { QueryArguments.date_range(Date.new(2026, 10, 2), Date.new(2026, 10, 1)) }, "must not be before 'from'"
    assert_equal [ nil, nil ], QueryArguments.date_range(nil, nil)

    assert_equal "cafe", QueryArguments.text(:q, " cafe ")
    assert_includes refused(:q) { QueryArguments.text(:q, "x" * 201) }, "at most 200 characters"
    assert_includes refused(:q) { QueryArguments.text(:q, "\xFF".dup.force_encoding("UTF-8")) }, "UTF-8"
    assert_includes refused(:q) { QueryArguments.text(:q, 5) }, "must be a single text value"

    assert_equal "USD", QueryArguments.currency(:currency, "USD")
    assert_includes refused(:currency) { QueryArguments.currency(:currency, "usd") }, "three upper-case letters"

    assert_equal "draft", QueryArguments.enum(:status, "draft", Transaction.statuses.values)
    assert_includes refused(:status) { QueryArguments.enum(:status, "DRAFT", Transaction.statuses.values) }, "must be one of: draft, needs_review, confirmed"

    assert_equal 200, QueryArguments.limit(:limit, 200)
    assert_equal 7, QueryArguments.limit(:limit, "7")
    [ 0, 201, "201", "1e2", 1.0 ].each do |value|
      assert_includes refused(:limit) { QueryArguments.limit(:limit, value) }, "from 1 to 200", value.inspect
    end
  end
end
