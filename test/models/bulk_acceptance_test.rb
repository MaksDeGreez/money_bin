require "test_helper"

class BulkAcceptanceTest < ActiveJob::TestCase
  VERSION = "2026-11-18-0123456789ab".freeze

  setup do
    @line = transaction_lines(:subscription_line)
    @transaction = transactions(:subscription)
    @others = 2.times.map { |index| uncategorised_transaction(probability: 0.95 - (index * 0.2), merchant: "Invented #{index}") }
  end

  def uncategorised_transaction(probability:, merchant:, status: "needs_review", category: categories(:groceries))
    transaction = Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 9), amount: BigDecimal("-10"), source: "manual",
      merchant:, status:, lines_attributes: [ { amount: BigDecimal("-10") } ])
    transaction.lines.first.update_columns(suggested_category_id: category.id, suggestion_probability: probability,
      suggestion_source: "model", suggestion_model_version: VERSION)
    transaction
  end

  def preview(threshold = 90, **filter)
    BulkAcceptance.preview!(filter: Transaction::Filter.new(filter), threshold_percent: threshold)
  end

  test "the preview takes the filter's transactions whose suggestion reaches the threshold, as they are now" do
    acceptance = preview(90, status: "needs_review")

    assert_equal 2, acceptance.total_count
    assert_equal [ @transaction.id, @others.first.id ].sort, acceptance.items.map(&:transaction_id).sort
    item = acceptance.items.find_by(transaction_id: @transaction.id)
    assert_equal [ @transaction.lock_version, [ @line.id ], categories(:household_supplies).id, 0.91, VERSION ],
      [ item.lock_version, item.line_ids, item.category_id, item.probability, item.model_version ]
    assert_equal [ [ categories(:groceries), 1 ], [ categories(:household_supplies), 1 ] ], acceptance.counts_by_category
    assert_equal({ VERSION => 2 }, acceptance.counts_by_model_version)
    assert_equal [ @transaction.id ], preview(90, q: "Streaming").items.map(&:transaction_id)
    assert_equal 0, preview(90, payee: "nobody").total_count
    assert_equal 3, preview(70).total_count
    assert_equal 2, preview(91).total_count, "at the threshold counts"
    assert_equal 1, preview(92).total_count
    assert acceptance.previewed?
    assert_nil @line.reload.category
  end

  test "nothing happens before a person confirms, and confirming happens once" do
    acceptance = preview

    BulkAcceptanceJob.perform_now(acceptance)
    assert_nil @line.reload.category

    assert acceptance.confirm!
    assert_not acceptance.confirm!
    assert acceptance.queued?
  end

  test "the job categorises each item once, records the provenance, and confirms what is complete" do
    acceptance = preview
    acceptance.confirm!

    BulkAcceptanceJob.perform_now(acceptance)

    acceptance.reload
    assert_equal [ "done", 2, 0, 0 ], [ acceptance.status, acceptance.accepted_count, acceptance.stale_count, acceptance.changed_count ]
    @line.reload
    assert_equal [ categories(:household_supplies), "bulk", 0.91, VERSION ], [ @line.category, @line.category_origin, @line.category_origin_probability, @line.category_origin_model_version ]
    assert_equal "confirmed", @transaction.reload.status
    assert_nil @others.last.lines.first.reload.category
  end

  test "running it again, or a second acceptance over the same rows, applies nothing twice" do
    acceptance = preview
    second = preview
    acceptance.confirm!
    second.confirm!
    BulkAcceptanceJob.perform_now(acceptance)
    versions = [ @transaction.reload.lock_version, @others.first.reload.lock_version ]

    acceptance.update!(status: "running")
    BulkAcceptanceJob.perform_now(acceptance)
    BulkAcceptanceJob.perform_now(second)

    assert_equal versions, [ @transaction.reload.lock_version, @others.first.reload.lock_version ]
    assert_equal 2, acceptance.reload.accepted_count
    assert_equal [ 0, 2 ], [ second.reload.accepted_count, second.stale_count + second.changed_count ]
  end

  test "a transaction edited after the preview is skipped and counted, never overwritten" do
    acceptance = preview
    acceptance.confirm!
    @transaction.update!(comment: "edited by a person meanwhile")
    @others.first.lines.first.update!(category: categories(:cafes))

    BulkAcceptanceJob.perform_now(acceptance)

    acceptance.reload
    assert_equal [ 0, 1, 1 ], [ acceptance.accepted_count, acceptance.stale_count, acceptance.changed_count ]
    assert_nil @line.reload.category
    assert_equal categories(:cafes), @others.first.lines.first.reload.category
    assert_equal "needs_review", @transaction.reload.status
  end

  test "a suggestion refreshed by another artefact after the preview is not taken" do
    acceptance = preview
    acceptance.confirm!
    @line.update_columns(suggestion_model_version: "2026-12-01-abcdefabcdef")

    BulkAcceptanceJob.perform_now(acceptance)

    assert_equal 1, acceptance.reload.changed_count
    assert_nil @line.reload.category
  end

  test "a failed run is marked, keeps what it did, and resumes where it stopped" do
    acceptance = preview
    acceptance.confirm!
    calls = 0
    failing = lambda do |item_self|
      calls += 1
      raise "an invented failure" if calls == 2

      item_self.send(:__original_apply!)
    end
    BulkAcceptanceItem.alias_method :__original_apply!, :apply!
    BulkAcceptanceItem.define_method(:apply!) { failing.call(self) }
    begin
      BulkAcceptanceJob.perform_now(acceptance)
    ensure
      BulkAcceptanceItem.alias_method :apply!, :__original_apply!
      BulkAcceptanceItem.remove_method :__original_apply!
    end

    acceptance.reload
    assert_equal [ "failed", "RuntimeError", 1 ], [ acceptance.status, acceptance.error, acceptance.accepted_count ]
    assert acceptance.resume!
    BulkAcceptanceJob.perform_now(acceptance)
    assert_equal [ "done", 2 ], [ acceptance.reload.status, acceptance.accepted_count ]
  end

  test "the threshold is a whole percent from 1 to 100" do
    assert_raises(ActiveRecord::RecordInvalid) { preview(0) }
    assert_raises(ActiveRecord::RecordInvalid) { preview(101) }
  end
end
