require_relative "ml_service_stubs"

# WebMock stubs for the ML service's batch endpoints (ml/README.md, "Batch mode"), with invented values. Include
# it in a test case (it includes MlServiceStubs).
#
#   stub_ml_batch_capability                         # available, 100 receipts per batch
#   stub_ml_batch_create(id: "batch_t1")             # POST /ocr/batches
#   stub_ml_batch_status("batch_t1", state: "running")
#   stub_ml_batch_results("batch_t1", [ ml_batch_ok(key), ml_batch_error(key, "ocr_parse_failed") ])
#   stub_ml_batch_delete("batch_t1")
#   stub_ml_batch_error(:get, "/ocr/batches/batch_t1", status: 501, code: "openrouter_batch_not_allowed")
module MlBatchStubs
  include MlServiceStubs

  def ml_batch_capability_body(**overrides)
    { available: true, code: nil, message: nil, backend: "openrouter", model_name: "example/vision-model",
      model_version: "example/vision-model-20260101", providers: [ "anthropic" ], max_receipts: 100,
      max_upload_bytes: 300 * 1024 * 1024, retention_days: 30, prompt_price_usd: "0.0000005",
      completion_price_usd: "0.0000025" }.merge(overrides)
  end

  def ml_batch_status_body(id = "batch_t1", state: "running", **overrides)
    { id:, state:, provider_status: (state == "running" ? "in_progress" : state), provider: "Anthropic",
      model_name: "example/vision-model", requests: { total: 2, completed: 1, failed: 0 }, cost_usd: nil,
      estimated_cost_usd: nil, created_at: "2026-11-18T10:00:00Z", expires_at: "2026-11-19T10:00:00Z",
      finished_at: nil, error: nil }.merge(overrides)
  end

  # One "ok" result: the /ocr answer's shape plus the batch accounting.
  def ml_batch_ok(key, receipt: {}, cost: "0.000412345678901")
    ocr = ml_ocr_body(receipt:, backend: "openrouter", model_name: "example/vision-model",
      model_version: "example/vision-model-20260101").merge(prompt_version: "abc123def456", repaired: false,
      elapsed_seconds: nil, mode: "batch", batch_id: "batch_t1", provider: "Anthropic", cost_usd: cost,
      prompt_tokens: 2600, completion_tokens: 900, finish_reason: "stop")
    { key:, status: "ok", ocr:, error: nil, cost_usd: cost }
  end

  def ml_batch_error(key, code, retry_sync: true, message: "Invented reason.", cost: nil)
    { key:, status: "error", ocr: nil, error: { code:, message:, retry_sync: }, cost_usd: cost }
  end

  def stub_ml_batch_capability(**overrides)
    stub_ml_batch(:get, "/ocr/batches/capability", body: ml_batch_capability_body(**overrides))
  end

  def stub_ml_batch_estimate(cost: "0.0123", cost_max: "0.0456")
    stub_ml_batch(:post, "/ocr/batches/estimate",
      body: { receipts: 1, images: 1, prompt_tokens: 2100, completion_tokens_typical: 1200, completion_tokens_max: 3072,
              cost_usd: cost, cost_usd_max: cost_max, model_name: "example/vision-model",
              model_version: "example/vision-model-20260101", basis: "Rough: within a factor of two either way." })
  end

  def stub_ml_batch_create(id: "batch_t1", **overrides)
    stub_ml_batch(:post, "/ocr/batches", status: 202,
      body: ml_batch_status_body(id, state: "running", estimated_cost_usd: "0.0025", **overrides))
  end

  def stub_ml_batch_status(id = "batch_t1", **options)
    stub_ml_batch(:get, "/ocr/batches/#{id}", body: ml_batch_status_body(id, **options))
  end

  def stub_ml_batch_results(id, results, cost: "0.004000000001")
    oks = results.count { |item| item[:status] == "ok" }
    parse = results.count { |item| item.dig(:error, :code) == "ocr_parse_failed" }
    stub_ml_batch(:get, "/ocr/batches/#{id}/results",
      body: { batch: ml_batch_status_body(id, state: "completed", cost_usd: cost, finished_at: "2026-11-18T10:30:00Z"),
              results:, counts: { ok: oks, parse_failed: parse, failed: results.size - oks - parse, ignored: 0 } })
  end

  def stub_ml_batch_delete(id = "batch_t1", upstream_status: "deleted")
    stub_ml_batch(:delete, "/ocr/batches/#{id}",
      body: { id:, deleted: true, openrouter: "deleted", upstream_provider: "Anthropic", upstream_status: })
  end

  def stub_ml_batch_error(method, path, status:, code:, message: "Invented error message.")
    stub_ml_batch(method, path, status:, body: { error: { code:, message: } })
  end

  # Requests answered are kept in `ml_batch_requests(method, path)`.
  def stub_ml_batch(method, path, body:, status: 200)
    stub_request(method, ml_url(path)).to_return do |request|
      ml_batch_requests(method, path) << request
      { status:, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
    end
  end

  def ml_batch_requests(method, path)
    (@ml_batch_requests ||= Hash.new { |hash, key| hash[key] = [] })[[ method, path ]]
  end
end
