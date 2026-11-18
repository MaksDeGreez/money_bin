require "test_helper"
require_relative "../../support/transaction_categoriser_stubs"

class Transactions::SuggestCategoriesTest < ActiveSupport::TestCase
  include TransactionCategoriserStubs

  NEW_VERSION = "2026-12-01-abcdefabcdef".freeze

  setup do
    @line = transaction_lines(:subscription_line)
    @transaction = transactions(:subscription)
  end

  def run_suggestions
    Transactions::SuggestCategories.call(TransactionSuggestionRun.create!)
  end

  test "an artefact that already scored a line is not asked again" do
    stub_transaction_categoriser(version: MODEL_VERSION)
    stub_categorise_transactions

    run = run_suggestions

    assert_equal [ "done", 0, 0 ], [ run.status, run.total_count, run.scored_count ]
    assert_empty transaction_requests
  end

  test "a new artefact refreshes every uncategorised line, in batches, without touching anything else" do
    stub_transaction_categoriser(version: NEW_VERSION)
    stub_categorise_transactions(version: NEW_VERSION, source: "mix")
    lock_version = @transaction.lock_version
    coffee = transaction_lines(:coffee_line)
    uncategorised = 3.times.map do |index|
      Transaction.create!(account: accounts(:cash_uah), occurred_on: Date.new(2026, 10, 9), amount: BigDecimal("-10.5"), source: "manual",
        comment: "Invented #{index}", status: "needs_review", lines_attributes: [ { amount: BigDecimal("-10.5"), category: categories(:uncategorised) } ])
    end

    run = with_batch(2) { run_suggestions }

    assert_equal [ "done", 4, 4, 0, NEW_VERSION ], [ run.status, run.total_count, run.scored_count, run.skipped_count, run.model_version ]
    assert_equal 2, transaction_requests.size
    @line.reload
    assert_equal [ categories(:household_supplies), 0.93, categories(:cafes), 0.04, "mix", NEW_VERSION ],
      [ @line.suggested_category, @line.suggestion_probability, @line.runner_up_category, @line.runner_up_probability, @line.suggestion_source, @line.suggestion_model_version ]
    assert_nil @line.category
    assert_equal lock_version, @transaction.reload.lock_version
    assert_equal categories(:uncategorised), uncategorised.first.lines.first.reload.category
    assert_nil coffee.reload.suggested_category_id
    sent = transaction_requests.flat_map { |body| body["transactions"] }
    subscription = sent.find { |item| item["merchant"] == "Example Streaming" }
    assert_equal({ "payee" => nil, "comment" => nil, "bank_description" => "EXAMPLE STREAMING", "merchant" => "Example Streaming",
      "mcc" => "4899", "amount" => "-830.0", "currency" => "UAH", "account_kind" => "debit" }, subscription)
    assert_not sent.any? { |item| item["categories"] }
    assert_equal Categories::TransactionCandidates.payload.map(&:stringify_keys), transaction_requests.first["categories"]
    assert_not_includes transaction_requests.first["categories"].map { |c| c["slug"] }, Category::UNCATEGORISED_SLUG
  end

  test "a suggestion whose category was deleted is asked again" do
    stub_transaction_categoriser(version: MODEL_VERSION)
    stub_categorise_transactions
    @line.update_columns(suggested_category_id: nil)

    run = run_suggestions

    assert_equal [ 1, 1 ], [ run.total_count, run.scored_count ]
    assert_equal categories(:household_supplies), @line.reload.suggested_category
  end

  test "an ML service that is not on this machine gets no transaction data" do
    stub_request(:any, /remote\.example\.test/)
    with_env("ML_SERVICE_URL" => "http://remote.example.test:8100") do
      run = run_suggestions

      assert_equal [ "failed", "ml_not_local" ], [ run.status, run.error ]
    end
    assert_not_requested :any, /remote\.example\.test/
  end

  test "a transaction with nothing to go on is skipped, not sent" do
    stub_transaction_categoriser(version: NEW_VERSION)
    stub_categorise_transactions(version: NEW_VERSION)
    @transaction.update!(mcc: nil, bank_description: nil, merchant: nil)

    run = run_suggestions

    assert_equal [ 1, 0, 1 ], [ run.total_count, run.scored_count, run.skipped_count ]
    assert_empty transaction_requests
  end

  test "a failure of the service is recorded on the run, not raised" do
    stub_transaction_categoriser_error(status: 501, code: "transaction_categoriser_not_configured", method: :get)

    run = run_suggestions

    assert_equal [ "failed", "transaction_categoriser_not_configured" ], [ run.status, run.error ]
    assert_equal MODEL_VERSION, @line.reload.suggestion_model_version
  end

  test "one run at a time" do
    TransactionSuggestionRun.create!(status: "running")
    assert_nil TransactionSuggestionRun.start
    TransactionSuggestionRun.update_all(updated_at: 2.hours.ago)
    assert TransactionSuggestionRun.start
  end

  test "the job works the run and skips a finished one" do
    stub_transaction_categoriser(version: NEW_VERSION)
    stub_categorise_transactions(version: NEW_VERSION)
    run = TransactionSuggestionRun.create!

    TransactionSuggestionsJob.perform_now(run)
    TransactionSuggestionsJob.perform_now(run)

    assert run.reload.done?
    assert_equal 1, transaction_requests.size
  end

  private
    def with_batch(size)
      original = Transactions::SuggestCategories::BATCH
      Transactions::SuggestCategories.send(:remove_const, :BATCH)
      Transactions::SuggestCategories.const_set(:BATCH, size)
      yield
    ensure
      Transactions::SuggestCategories.send(:remove_const, :BATCH)
      Transactions::SuggestCategories.const_set(:BATCH, original)
    end
end
