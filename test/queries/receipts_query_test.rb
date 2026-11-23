require "test_helper"

class ReceiptsQueryTest < ActiveSupport::TestCase
  # A receipt row written past the model: the query only reads rows, and photos do not matter here.
  def insert_receipt(issued_at:, created_at: Time.current, status: "extracted", **columns)
    sha256 = SecureRandom.hex(32)
    Receipt.insert!({ sha256:, status:, issued_at:, created_at:, updated_at: created_at, **columns })
    Receipt.find_by!(sha256:)
  end

  include ApiRequestTestHelper # count_queries

  test "newest first: by the time on the receipt, else the upload time, then by id" do
    rows = ReceiptsQuery.new.relation.to_a

    # new_receipt has no issued_at and was uploaded now; corner (Oct 8) is newer than market (Oct 3);
    # failed_receipt has no issued_at and was uploaded on Oct 1.
    assert_equal [ receipts(:new_receipt), receipts(:corner_receipt), receipts(:market_receipt), receipts(:failed_receipt) ], rows
  end

  test "an old upload with no time on it sorts by its upload time" do
    old_failed = insert_receipt(issued_at: nil, created_at: Time.zone.parse("2026-10-05 10:00"), status: "failed")

    rows = ReceiptsQuery.new.relation.to_a

    assert_equal [ receipts(:new_receipt), receipts(:corner_receipt), old_failed, receipts(:market_receipt), receipts(:failed_receipt) ], rows
  end

  test "filters by status" do
    assert_equal [ receipts(:corner_receipt) ], ReceiptsQuery.new(status: "extracted").relation.to_a
  end

  test "pages follow each other with no gap and no repeat, ties on time broken by id" do
    same_time = Time.zone.parse("2026-10-06 12:00:00.123456")
    2.times { insert_receipt(issued_at: same_time) }
    all = ReceiptsQuery.new.relation.ids

    seen = []
    cursor = nil
    loop do
      page = ReceiptsQuery.new.page(limit: 2, cursor:)
      seen.concat(page.records.map(&:id))
      cursor = page.next_cursor
      break if page.last_page?
    end

    assert_equal all, seen
  end

  test "a page counts each receipt's items in the same query" do
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    page = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ReceiptsQuery.new.page }

    assert_equal 1, queries
    assert_equal({ receipts(:new_receipt).id => 0, receipts(:corner_receipt).id => 3, receipts(:market_receipt).id => 3,
      receipts(:failed_receipt).id => 0 },
      page.records.to_h { |receipt| [ receipt.id, receipt.items_count ] })
  end

  test "a page of card slips costs the same queries whatever its size, serialised with their categories" do
    categories = [ categories(:groceries), categories(:cafes), categories(:takeaway), categories(:household_supplies) ]
    # Newer than every fixture, so the first page is slips only; each refers to both associations.
    8.times do |index|
      insert_receipt(issued_at: 1.day.from_now + index.minutes, kind: "card_slip", category_id: categories[index % 4].id,
        suggested_category_id: categories[(index + 1) % 4].id, suggested_category_confidence: 0.5)
    end
    serialise = ->(limit) { ReceiptsQuery.new.page(limit:).records.map { |receipt| ReceiptSerializer.summary(receipt) } }

    small = count_queries { serialise.call(2) }
    large = count_queries { serialise.call(20) }

    assert_equal 2, small, "the page, then one query for the categories of both associations"
    assert_equal small, large
    rows = serialise.call(20)
    assert_equal 8, rows.count { |row| row[:category] && row[:suggested_category] }
    assert_equal 4, rows.count { |row| row[:kind] == "fiscal" || row[:kind].nil? }
  end

  test "a foreign or broken cursor raises KeysetCursor::Invalid" do
    [ KeysetCursor.encode("yesterday", 1), KeysetCursor.encode(nil, 1), KeysetCursor.encode("2026-10-01T00:00:00Z", -1) ].each do |cursor|
      assert_raises(KeysetCursor::Invalid, cursor) { ReceiptsQuery.new.page(cursor:) }
    end
  end

  test "find loads the items with their categories" do
    receipt = ReceiptsQuery.find(receipts(:corner_receipt).id)

    assert receipt.association(:items).loaded?
    assert receipt.items.first.association(:suggested_category).loaded?
    assert receipt.association(:category).loaded?
    assert receipt.association(:suggested_category).loaded?
  end
end
