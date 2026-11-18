require "test_helper"

# AccountBalancesQuery, CategoryTreeQuery and KeysetCursor.
class LedgerReferenceQueriesTest < ActiveSupport::TestCase
  test "every account with its booked balance, open accounts first, then by name" do
    rows = AccountBalancesQuery.new.call

    assert_equal [ accounts(:cash_uah), accounts(:card_uah), accounts(:savings_usd), accounts(:old_wallet) ], rows.map(&:account)
    assert_equal [ "1940.00", "4334.60", "1000.00", "0.00" ].map { BigDecimal(it) }, rows.map(&:balance)
    rows.each { |row| assert_equal row.account.balance, row.balance }
  end

  test "a draft does not move a balance" do
    Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 9), amount: BigDecimal("-500"), source: :api,
      status: :draft, lines_attributes: [ { category: categories(:groceries), amount: BigDecimal("-500") } ])

    assert_equal BigDecimal("1940.00"), AccountBalancesQuery.new.call.find { |row| row.account == accounts(:cash_uah) }.balance
  end

  test "the category tree: groups in order, each with its categories in order" do
    tree = CategoryTreeQuery.new.call

    assert_equal Category.groups.ordered.to_a, tree.map(&:group)
    eating_out = tree.find { |node| node.group == categories(:eating_out) }
    assert_equal [ categories(:cafes), categories(:takeaway) ], eating_out.categories
    assert_equal Category.leaves.count, tree.sum { |node| node.categories.size }
  end

  test "a cursor round-trips its values and refuses anything else" do
    cursor = KeysetCursor.encode("2026-10-03", 42)

    assert_match(/\A[A-Za-z0-9_-]+\z/, cursor)
    assert_equal [ "2026-10-03", 42 ], KeysetCursor.decode(cursor, size: 2)
    [ nil, 42, "", "a" * (KeysetCursor::MAX_LENGTH + 1), "has space", "@@@", KeysetCursor.encode(1, 2, 3),
      Base64.urlsafe_encode64("not json", padding: false), Base64.urlsafe_encode64('{"a":1}', padding: false) ].each do |value|
      assert_raises(KeysetCursor::Invalid, value.inspect) { KeysetCursor.decode(value, size: 2) }
    end
  end
end
