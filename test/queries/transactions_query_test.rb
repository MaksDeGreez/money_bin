require "test_helper"

class TransactionsQueryTest < ActiveSupport::TestCase
  def ids(**filters)
    TransactionsQuery.new(**filters).relation.pluck(:id)
  end

  def fixture_ids(*names)
    names.map { |name| transactions(name).id }
  end

  def book(account: :card_uah, on: Date.new(2026, 10, 10), amount: "-10.00", **attributes)
    Transaction.create!(account: accounts(account), occurred_on: on, amount: BigDecimal(amount), source: :manual,
      lines_attributes: [ { category: categories(:groceries), amount: BigDecimal(amount) } ], **attributes)
  end

  test "lists everything newest first, by date and then by id" do
    same_day = [ book(on: Date.new(2026, 10, 2)), book(on: Date.new(2026, 10, 2)) ]

    rows = TransactionsQuery.new.relation.to_a

    assert_equal Transaction.count, rows.size
    assert_equal rows.sort_by { |row| [ row.occurred_on, row.id ] }.reverse, rows
    assert_operator rows.index(same_day.second), :<, rows.index(same_day.first)
  end

  test "from and to are inclusive dates on occurred_on" do
    assert_equal fixture_ids(:snack, :market_split).sort, ids(from: Date.new(2026, 10, 3), to: Date.new(2026, 10, 4)).sort
    assert_equal fixture_ids(:salary), ids(to: Date.new(2026, 10, 1))
    assert_equal fixture_ids(:savings_out, :savings_in).sort, ids(from: Date.new(2026, 10, 7)).sort
  end

  test "filters by account, payee, status and source" do
    assert_equal fixture_ids(:savings_in), ids(account_id: accounts(:savings_usd).id)
    assert_equal fixture_ids(:coffee), ids(payee_id: payees(:corner_cafe).id)
    assert_equal fixture_ids(:subscription), ids(status: "needs_review")
    assert_equal fixture_ids(:snack), ids(source: "legacy")
    assert_empty ids(status: "draft")
  end

  test "a category matches transactions with a line in it, a split one under each of its categories" do
    assert_equal fixture_ids(:market_split), ids(category_id: categories(:household_supplies).id)
    assert_equal fixture_ids(:market_split), ids(category_id: categories(:groceries).id)
  end

  test "a group matches transactions with a line in any of its categories" do
    assert_equal fixture_ids(:coffee, :snack).sort, ids(category_id: categories(:eating_out).id).sort
  end

  test "q searches payee name, merchant, comment and bank description, case-insensitively" do
    assert_equal fixture_ids(:salary), ids(q: "EMPLOYER") # payee name only
    assert_equal fixture_ids(:subscription), ids(q: "streaming") # merchant and bank description
    assert_equal fixture_ids(:snack), ids(q: "pastry") # comment
    assert_equal fixture_ids(:withdrawal_out, :withdrawal_in).sort, ids(q: "withdrawal").sort
  end

  test "q is case-insensitive beyond ASCII" do
    cyrillic = book(comment: "Кава з собою")

    assert_equal [ cyrillic.id ], ids(q: "КАВА")
  end

  test "q takes LIKE wildcards literally" do
    percent = book(comment: "Discount 50% off")

    assert_equal [ percent.id ], ids(q: "50%")
    assert_empty ids(q: "_iscount 5")
  end

  test "filters combine" do
    assert_equal fixture_ids(:coffee), ids(account_id: accounts(:card_uah).id, category_id: categories(:eating_out).id, q: "cafe")
    assert_empty ids(account_id: accounts(:cash_uah).id, category_id: categories(:cafes).id)
  end

  test "pages follow each other with no gap and no repeat, also inside one day" do
    3.times { book(on: Date.new(2026, 10, 3)) }
    all = ids

    seen = []
    cursor = nil
    loop do
      page = TransactionsQuery.new.page(limit: 2, cursor:)
      assert_operator page.records.size, :<=, 2
      seen.concat(page.records.map(&:id))
      cursor = page.next_cursor
      break if page.last_page?
    end

    assert_equal all, seen
  end

  test "the last page has no cursor, also when it is exactly full" do
    count = Transaction.count

    assert_nil TransactionsQuery.new.page(limit: count).next_cursor
    assert_not_nil TransactionsQuery.new.page(limit: count - 1).next_cursor
  end

  test "a cursor keeps its place when newer rows arrive" do
    first = TransactionsQuery.new.page(limit: 3)
    book(on: Date.new(2026, 12, 1))

    second = TransactionsQuery.new.page(limit: 3, cursor: first.next_cursor)

    assert_equal ids[4, 3], second.records.map(&:id)
  end

  test "a foreign or broken cursor raises KeysetCursor::Invalid" do
    [ "not base64!", KeysetCursor.encode("2026-10-01"), KeysetCursor.encode("2026-13-01", 1), KeysetCursor.encode("2026-10-01", "1"),
      KeysetCursor.encode("2026-10-01", 0), KeysetCursor.encode(20261001, 1), Base64.urlsafe_encode64("{}") ].each do |cursor|
      assert_raises(KeysetCursor::Invalid, cursor) { TransactionsQuery.new.page(cursor:) }
    end
  end

  test "find loads one transaction with what its JSON needs" do
    transaction = TransactionsQuery.find(transactions(:market_split).id)

    assert transaction.association(:lines).loaded?
    assert transaction.association(:receipt).loaded?
    assert_raises(ActiveRecord::RecordNotFound) { TransactionsQuery.find(0) }
  end
end
