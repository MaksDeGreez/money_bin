# WebMock stubs for the Python ML service (ml/README.md is its contract). Include it in a test case.
#
# The bodies follow the service's response shapes with invented values. Every builder takes overrides, so a
# test changes only the part it is about:
#
#   stub_ml_ocr(receipt: { merchant: nil, items: [] })
#   stub_ml_error(:ocr, status: 422, code: "too_many_images", message: "Send at most 3 files, got 4.")
#   stub_ml_error(:ocr, status: 413, code: "image_too_large", message: "File 'r.jpg' is larger than the limit of 15728640 bytes.")
module MlServiceStubs
  ML_HEALTH = { status: "ok", backend: "stub", model_name: "stub-ocr", model_version: "0.1.0" }.freeze
  ML_OCR_RECEIPT = {
    merchant: "Sample Grocer",
    fiscal_number: "3000000007",
    receipt_number: "000451",
    issued_at: "2026-09-14T10:20:00+03:00",
    total: "117.40",
    currency: "UAH",
    items: [
      { name: "Oat milk 1 l", quantity: "1.000", unit_price: "54.90", amount: "54.90", discount: "0.00" },
      { name: "Apples", quantity: "1.250", unit_price: "52.00", amount: "62.50", discount: "2.50" }
    ]
  }.freeze

  ENDPOINTS = { health: [ :get, "/health" ], ocr: [ :post, "/ocr" ], categorise: [ :post, "/categorise" ] }.freeze

  # The service URL the client under test uses (ML_SERVICE_URL or the default).
  def ml_url(path)
    MlClient.new.base_url.to_s.chomp("/") + path
  end

  def ml_health_body(**overrides)
    ML_HEALTH.merge(overrides)
  end

  def ml_ocr_body(receipt: {}, **overrides)
    { receipt: ML_OCR_RECEIPT.merge(receipt), backend: "stub", model_name: "stub-ocr", model_version: "0.1.0" }
      .merge(overrides)
  end

  # An MlClient::OcrResult as the client returns it for ml_ocr_body(...), without any HTTP.
  def ml_ocr_result(receipt: {}, **overrides)
    body = JSON.parse(JSON.generate(ml_ocr_body(receipt:, **overrides)), freeze: true)
    MlClient::OcrResult.new(body:, receipt: body["receipt"], **body.slice("backend", "model_name", "model_version").symbolize_keys)
  end

  # Three candidates per text, best first, like the service.
  def ml_categorise_body(texts, slugs: %w[groceries/groceries household-shopping/household-supplies eating-out/takeaway-fast-food])
    results = texts.map do |text|
      { text:, candidates: slugs.zip([ 0.71, 0.18, 0.11 ]).map { |slug, score| { category_slug: slug, score: } } }
    end
    { results:, backend: "stub", model_name: "stub-categoriser", model_version: "0.1.0" }
  end

  def stub_ml_health(body = ml_health_body)
    stub_ml(:health, status: 200, body:)
  end

  def stub_ml_ocr(receipt: {}, **overrides)
    stub_ml(:ocr, status: 200, body: ml_ocr_body(receipt:, **overrides))
  end

  def stub_ml_categorise(texts, **options)
    stub_ml(:categorise, status: 200, body: ml_categorise_body(texts, **options))
  end

  # An error answer in the service's shape: { "error": { "code", "message" } }.
  def stub_ml_error(endpoint, status:, code:, message: "Invented error message.")
    stub_ml(endpoint, status:, body: { error: { code:, message: } })
  end

  # `body` is a Hash (sent as JSON) or a String (sent as is). Requests the stub answers are kept in
  # `ml_requests(endpoint)`.
  def stub_ml(endpoint, status:, body:)
    method, path = ENDPOINTS.fetch(endpoint)
    text = body.is_a?(String) ? body : JSON.generate(body)
    stub_request(method, ml_url(path)).to_return do |request|
      ml_requests(endpoint) << request
      { status:, body: text, headers: { "Content-Type" => "application/json" } }
    end
  end

  # The requests the stubs of `endpoint` answered in this test, oldest first.
  def ml_requests(endpoint)
    (@ml_requests ||= Hash.new { |hash, key| hash[key] = [] })[endpoint]
  end

  # The parts of a multipart/form-data request, as [{ name:, filename:, content_type:, body: }], in order.
  def multipart_parts(request)
    boundary = request.headers["Content-Type"][/boundary=(\S+)/, 1]
    raise ArgumentError, "not a multipart request" unless boundary

    request.body.b.split("--#{boundary}".b)[1..-2].map do |part|
      head, body = part.delete_prefix("\r\n").split("\r\n\r\n".b, 2)
      {
        name: head[/name="([^"]*)"/, 1],
        filename: head[/filename="([^"]*)"/, 1],
        content_type: head[/^Content-Type: (.+)$/i, 1]&.strip,
        body: body.delete_suffix("\r\n")
      }
    end
  end
end
