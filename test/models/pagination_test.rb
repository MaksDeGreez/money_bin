require "test_helper"

class PaginationTest < ActiveSupport::TestCase
  test "splits an ordered relation into pages" do
    relation = Receipt.order(:id)
    all = relation.pluck(:id)

    first = Pagination.new(relation, page: nil, per_page: 3)
    assert_equal [ 1, 2, all.size ], [ first.page, first.pages, first.total_count ]
    assert_equal all.first(3), first.records.pluck(:id)
    assert_nil first.previous_page
    assert_equal 2, first.next_page
    assert_equal [ 1, 3 ], [ first.first_item, first.last_item ]

    last = Pagination.new(relation, page: "2", per_page: 3)
    assert_equal all.drop(3), last.records.pluck(:id)
    assert_equal 1, last.previous_page
    assert_nil last.next_page
    assert_equal [ 4, all.size ], [ last.first_item, last.last_item ]
  end

  test "a page out of range shows the nearest page" do
    relation = Receipt.order(:id)

    assert_equal 1, Pagination.new(relation, page: "-3", per_page: 3).page
    assert_equal 1, Pagination.new(relation, page: "abc", per_page: 3).page
    assert_equal 2, Pagination.new(relation, page: "99", per_page: 3).page
  end

  test "an empty relation is one empty page" do
    pagination = Pagination.new(Receipt.none, page: 5)

    assert_equal [ 1, 1, 0, 0, 0 ], [ pagination.page, pagination.pages, pagination.total_count, pagination.first_item, pagination.last_item ]
    assert_empty pagination.records
  end
end
