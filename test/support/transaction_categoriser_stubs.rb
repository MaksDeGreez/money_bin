# WebMock stubs for the ML service's transaction categoriser (ml/README.md, "POST /categorise/transaction"), with
# invented answers. Include it in a test case.
#
#   stub_transaction_categoriser(version: "2026-11-18-0123456789ab")  # GET: which artefact answers
#   stub_categorise_transactions(answer: [ [ "groceries/groceries", 0.93 ], [ "eating-out/cafes-bars-restaurants", 0.04 ] ])
#   transaction_requests  # the parsed POST bodies, oldest first
module TransactionCategoriserStubs
  MODEL_VERSION = "2026-11-18-0123456789ab".freeze
  ANSWER = [ [ "household-shopping/household-supplies", 0.93 ], [ "eating-out/cafes-bars-restaurants", 0.04 ], [ "groceries/groceries", 0.02 ] ].freeze

  def transaction_categoriser_url
    MlClient.new.base_url.to_s.chomp("/") + "/categorise/transaction"
  end

  def stub_transaction_categoriser(version: MODEL_VERSION)
    stub_request(:get, transaction_categoriser_url).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(model_name: "transaction-categoriser", model_version: version, fitted_at: "2026-11-18T15:00:00+00:00",
        configuration: "tfidf", encoder: nil, encoder_loaded: false, load_seconds: "0.010"))
  end

  # Every transaction of a request gets `answer` ([[slug, probability], ...], best first) and `source`.
  def stub_categorise_transactions(answer: ANSWER, source: "model", version: MODEL_VERSION)
    stub_request(:post, transaction_categoriser_url).to_return do |request|
      body = JSON.parse(request.body)
      transaction_requests << body
      results = body["transactions"].map do
        { candidates: answer.map { |slug, probability| { category_slug: slug, probability: } }, source:,
          history: (source == "model" ? nil : "payee"), history_weight: (source == "model" ? 0.0 : 0.6) }
      end
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate(results:, model_name: "transaction-categoriser", model_version: version,
          fitted_at: "2026-11-18T15:00:00+00:00", elapsed_seconds: "0.010") }
    end
  end

  def stub_transaction_categoriser_error(status:, code:, method: :post)
    stub_request(method, transaction_categoriser_url).to_return(status:, headers: { "Content-Type" => "application/json" },
      body: JSON.generate(error: { code:, message: "Invented error message." }))
  end

  def transaction_requests
    @transaction_requests ||= []
  end
end
