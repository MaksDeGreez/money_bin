require "test_helper"
require_relative "../support/transaction_categoriser_stubs"

# MlClient's transaction categoriser calls (ml/README.md, "POST /categorise/transaction").
class MlClientTransactionsTest < ActiveSupport::TestCase
  include TransactionCategoriserStubs

  CATEGORIES = [
    { slug: "groceries/groceries", name: "Groceries", description: "", group: "Groceries" },
    { slug: "household-shopping/household-supplies", name: "Household supplies", description: "", group: "Household & shopping" },
    { slug: "eating-out/cafes-bars-restaurants", name: "Cafes", description: "", group: "Eating out" }
  ].freeze
  TRANSACTION = { payee: "Example Market", merchant: nil, mcc: "5411", amount: "-120.50", currency: "UAH", account_kind: "debit" }.freeze

  def categorise(transactions = [ TRANSACTION ], categories: CATEGORIES)
    MlClient.new.categorise_transactions(transactions, categories:)
  end

  test "sends the transactions and the categories, and reads three candidates each" do
    stub_categorise_transactions(source: "mix")

    result = categorise([ TRANSACTION, TRANSACTION.merge(payee: nil, comment: "an invented note") ])

    assert_equal 2, result.results.size
    assert_equal "household-shopping/household-supplies", result.results.first["candidates"].first["category_slug"]
    assert_equal "mix", result.results.first["source"]
    assert_equal [ "transaction-categoriser", MODEL_VERSION ], [ result.model_name, result.model_version ]
    body = transaction_requests.sole
    assert_equal "-120.50", body["transactions"].first["amount"]
    assert_equal CATEGORIES.map(&:stringify_keys), body["categories"]
  end

  test "an amount is a decimal string, never a Float, and never rounded" do
    stub_categorise_transactions
    [ -120.5, BigDecimal("-120.5"), "-120.505", "1e3" ].each do |amount|
      assert_raises(ArgumentError, amount.inspect) { categorise([ TRANSACTION.merge(amount:) ]) }
    end
    assert_empty transaction_requests
    categorise([ TRANSACTION.merge(amount: nil) ])
    assert_nil transaction_requests.sole["transactions"].first["amount"]
  end

  test "one to five hundred transactions per call" do
    assert_raises(ArgumentError) { categorise([]) }
    assert_raises(ArgumentError) { categorise([ TRANSACTION ] * 501) }
  end

  test "a category it was not given is an invalid answer, never passed on" do
    stub_categorise_transactions(answer: [ [ "eating-out/takeaway-fast-food", 0.9 ] ])

    error = assert_raises(MlClient::InvalidResponse) { categorise }
    assert_match "a category it was not given", error.message
  end

  test "a probability outside 0..1, an unknown source or a missing result is an invalid answer" do
    stub_categorise_transactions(answer: [ [ "groceries/groceries", 1.5 ] ])
    assert_raises(MlClient::InvalidResponse) { categorise }

    stub_categorise_transactions(source: "hosted")
    assert_raises(MlClient::InvalidResponse) { categorise }

    stub_request(:post, transaction_categoriser_url).to_return(status: 200, body: JSON.generate(results: [],
      model_name: "transaction-categoriser", model_version: MODEL_VERSION, fitted_at: "2026-11-18"))
    assert_raises(MlClient::InvalidResponse) { categorise }
  end

  test "errors keep the service's code: 501 when no artefact is set up, 422 when the categories do not match" do
    stub_transaction_categoriser_error(status: 501, code: "transaction_categoriser_not_configured")
    error = assert_raises(MlClient::BackendNotImplemented) { categorise }
    assert_equal "transaction_categoriser_not_configured", error.code
    assert_not error.transient?

    stub_transaction_categoriser_error(status: 422, code: "categories_mismatch")
    assert_equal "categories_mismatch", assert_raises(MlClient::ResponseError) { categorise }.code

    stub_request(:post, transaction_categoriser_url).to_raise(Errno::ECONNREFUSED)
    assert assert_raises(MlClient::ConnectionError) { categorise }.transient?
  end

  test "transaction data goes to an ML service on this machine only" do
    stub_request(:any, /remote\.example\.test|10\.0\.0\.5/)
    [ "http://remote.example.test:8100", "http://10.0.0.5:8100" ].each do |url|
      error = assert_raises(MlClient::NotLocal) do
        MlClient.new(base_url: url).categorise_transactions([ TRANSACTION ], categories: CATEGORIES)
      end
      assert_equal "ml_not_local", error.code
    end
    assert_not_requested :any, /remote\.example\.test|10\.0\.0\.5/
    assert MlClient.new(base_url: "http://[::1]:8100").local?
    assert MlClient.new(base_url: "http://localhost:8100").local?
  end

  test "transaction_categoriser names the artefact" do
    stub_transaction_categoriser(version: "2026-12-01-abcdefabcdef")

    model = MlClient.new.transaction_categoriser

    assert_equal [ "transaction-categoriser", "2026-12-01-abcdefabcdef" ], [ model.model_name, model.model_version ]
  end
end
