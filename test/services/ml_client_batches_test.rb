require "test_helper"
require_relative "../support/ml_batch_stubs"

class MlClientBatchesTest < ActiveSupport::TestCase
  include MlBatchStubs

  KEY = "AAAAAAAAAAAAAAAAAAAAAAAA".freeze

  def image(bytes, filename: "rcpt_000123_private.jpg")
    MlClient::Image.new(io: StringIO.new(bytes), filename:, content_type: "image/jpeg")
  end

  test "capability and estimate" do
    stub_ml_batch_capability
    stub_ml_batch_estimate(cost: "0.000000123456789012345", cost_max: "0.5")

    capability = MlClient.new.ocr_batch_capability
    estimate = MlClient.new.estimate_ocr_batch(receipts: 3, images: 4)

    assert capability.available
    assert_equal 100, capability.max_receipts
    assert_equal [ "anthropic" ], capability.providers
    assert_equal BigDecimal("0.000000123456789012345"), estimate.cost_usd
    assert_kind_of BigDecimal, estimate.cost_usd
    assert_equal({ "receipts" => 3, "images" => 4 }, JSON.parse(ml_batch_requests(:post, "/ocr/batches/estimate").sole.body))
  end

  test "an unavailable capability is an answer, not an error" do
    stub_ml_batch_capability(available: false, code: "openrouter_batch_not_allowed", message: "Batch mode is off.")

    capability = MlClient.new.ocr_batch_capability

    assert_not capability.available
    assert_equal "openrouter_batch_not_allowed", capability.code
  end

  test "create uploads a manifest of keys and the photos in order, without their file names" do
    stub_ml_batch_create
    receipts = [
      MlClient::BatchReceipt.new(key: KEY, images: [ image("one"), image("two") ]),
      MlClient::BatchReceipt.new(key: "B" * 24, images: [ image("three") ])
    ]

    status = MlClient.new.create_ocr_batch(receipts)

    parts = multipart_parts(ml_batch_requests(:post, "/ocr/batches").sole)
    assert_equal %w[manifest images images images], parts.map { |part| part[:name] }
    assert_equal [ { "key" => KEY, "images" => 2 }, { "key" => "B" * 24, "images" => 1 } ], JSON.parse(parts.first[:body])
    assert_equal %w[one two three], parts.drop(1).map { |part| part[:body] }
    assert_equal [ "image" ] * 3, parts.drop(1).map { |part| part[:filename] }
    assert_not_includes ml_batch_requests(:post, "/ocr/batches").sole.body, "rcpt_000123"
    assert_equal "batch_t1", status.id
    assert_equal "running", status.state
    assert_equal BigDecimal("0.0025"), status.estimated_cost_usd
    assert_equal Time.utc(2026, 11, 19, 10), status.expires_at
  end

  test "create refuses a receipt without photos or with too many" do
    assert_raises(ArgumentError) { MlClient.new.create_ocr_batch([]) }
    assert_raises(ArgumentError) { MlClient.new.create_ocr_batch([ MlClient::BatchReceipt.new(key: KEY, images: []) ]) }
    four = Array.new(4) { image("x") }
    assert_raises(ArgumentError) { MlClient.new.create_ocr_batch([ MlClient::BatchReceipt.new(key: KEY, images: four) ]) }
  end

  test "status, results and delete" do
    stub_ml_batch_status("batch_t1", state: "running", cost_usd: "0.0001")
    stub_ml_batch_results("batch_t1", [ ml_batch_ok(KEY), ml_batch_error("B" * 24, "ocr_parse_failed") ])
    stub_ml_batch_delete("batch_t1", upstream_status: "unsupported")
    client = MlClient.new

    status = client.ocr_batch("batch_t1")
    results = client.ocr_batch_results("batch_t1")
    deletion = client.delete_ocr_batch("batch_t1")

    assert_equal BigDecimal("0.0001"), status.cost_usd
    assert_equal [ 2, 1, 0 ], [ status.requests_total, status.requests_completed, status.requests_failed ]
    assert_equal "completed", results.batch.state
    assert_equal BigDecimal("0.004000000001"), results.batch.cost_usd
    ok = MlClient::Batches.ocr_result(results.results.first)
    assert_equal "example/vision-model", ok.model_name
    assert_equal "Sample Grocer", ok.receipt["merchant"]
    assert_equal "batch", ok.body["mode"]
    assert_equal "unsupported", deletion.upstream_status
  end

  test "a result without the receipt's required keys is an invalid answer" do
    broken = ml_batch_ok(KEY)
    broken[:ocr] = broken[:ocr].except(:model_name)
    stub_ml_batch_results("batch_t1", [ broken ])

    error = assert_raises(MlClient::InvalidResponse) { MlClient.new.ocr_batch_results("batch_t1") }
    assert_includes error.message, "results[0].ocr.model_name"
  end

  test "an unknown state is an invalid answer" do
    stub_ml_batch_status("batch_t1", state: "sleeping")
    assert_raises(MlClient::InvalidResponse) { MlClient.new.ocr_batch("batch_t1") }
  end

  test "costs that are not decimal strings are unknown, never floats" do
    stub_ml_batch_status("batch_t1", cost_usd: 0.5)
    assert_nil MlClient.new.ocr_batch("batch_t1").cost_usd
  end

  test "a batch id is checked before it goes into a URL" do
    [ "../health", "a/b", "", "x" * 129, nil ].each do |bad|
      assert_raises(ArgumentError) { MlClient.new.ocr_batch(bad) }
    end
  end

  test "errors keep the client's classes" do
    stub_ml_batch_error(:get, "/ocr/batches/batch_t1", status: 501, code: "openrouter_batch_not_allowed")
    stub_ml_batch_error(:get, "/ocr/batches/batch_t1/results", status: 503, code: "openrouter_rate_limited")
    stub_ml_batch_error(:delete, "/ocr/batches/batch_t1", status: 404, code: "batch_not_found")
    stub_ml_batch_error(:post, "/ocr/batches", status: 413, code: "batch_too_large")

    off = assert_raises(MlClient::BackendNotImplemented) { MlClient.new.ocr_batch("batch_t1") }
    assert_equal "openrouter_batch_not_allowed", off.code
    limited = assert_raises(MlClient::ServerError) { MlClient.new.ocr_batch_results("batch_t1") }
    assert limited.transient?
    gone = assert_raises(MlClient::ResponseError) { MlClient.new.delete_ocr_batch("batch_t1") }
    assert_equal "batch_not_found", gone.code
    large = assert_raises(MlClient::ResponseError) do
      MlClient.new.create_ocr_batch([ MlClient::BatchReceipt.new(key: KEY, images: [ image("x") ]) ])
    end
    assert_equal "batch_too_large", large.code
  end

  test "a create request waits for ML_SERVICE_BATCH_TIMEOUT" do
    stub_request(:post, ml_url("/ocr/batches")).to_timeout
    with_env("ML_SERVICE_BATCH_TIMEOUT" => "7") do
      assert_equal 7.0, MlClient.new.send(:batch_timeout)
    end
    assert_raises(MlClient::TimeoutError) do
      MlClient.new.create_ocr_batch([ MlClient::BatchReceipt.new(key: KEY, images: [ image("x") ]) ])
    end
  end
end
