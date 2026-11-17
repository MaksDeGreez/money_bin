require "test_helper"
require_relative "../support/ml_service_stubs"
require_relative "../support/receipt_images"

class MlClientTest < ActiveSupport::TestCase
  include MlServiceStubs
  include ReceiptImages

  def client(**options)
    MlClient.new(**options)
  end

  def image(bytes = png_bytes, filename: "receipt.png", content_type: "image/png")
    MlClient::Image.new(io: StringIO.new(bytes), filename:, content_type:)
  end

  def with_env(values)
    saved = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  # --- configuration

  test "uses the default URL and timeouts" do
    with_env("ML_SERVICE_URL" => nil, "ML_SERVICE_OPEN_TIMEOUT" => nil, "ML_SERVICE_OCR_TIMEOUT" => nil,
      "ML_SERVICE_CATEGORISE_TIMEOUT" => nil) do
      ml = client

      assert_equal URI("http://127.0.0.1:8100"), ml.base_url
      assert_equal 2.0, ml.open_timeout
      assert_equal 120.0, ml.ocr_timeout
      assert_equal 30.0, ml.categorise_timeout
    end
  end

  test "reads the URL and timeouts from the environment" do
    with_env("ML_SERVICE_URL" => "http://ml.example.test:9000/v1/", "ML_SERVICE_OPEN_TIMEOUT" => "0.5",
      "ML_SERVICE_OCR_TIMEOUT" => "300", "ML_SERVICE_CATEGORISE_TIMEOUT" => "10") do
      ml = client

      assert_equal 0.5, ml.open_timeout
      assert_equal 300.0, ml.ocr_timeout
      assert_equal 10.0, ml.categorise_timeout
      stub_request(:get, "http://ml.example.test:9000/v1/health").to_return(body: JSON.generate(ml_health_body))
      assert_equal "stub", ml.health.backend
    end
  end

  test "arguments win over the environment" do
    with_env("ML_SERVICE_OCR_TIMEOUT" => "300") do
      assert_equal 7.0, client(ocr_timeout: 7).ocr_timeout
    end
  end

  test "a timeout that is not a positive number is refused" do
    with_env("ML_SERVICE_OCR_TIMEOUT" => "soon") do
      error = assert_raises(ArgumentError) { client }
      assert_includes error.message, "ML_SERVICE_OCR_TIMEOUT"
    end
    assert_raises(ArgumentError) { client(open_timeout: 0) }
    assert_raises(ArgumentError) { client(categorise_timeout: -1) }
  end

  test "each call uses its own read timeout" do
    opened = []
    original = Net::HTTP.method(:start)
    starter = ->(*args, **options, &block) { opened << options && original.call(*args, **options, &block) }
    stub_ml_health
    stub_ml_ocr
    stub_ml_categorise([ "bread" ])

    with_singleton_method(Net::HTTP, :start, starter) do
      ml = client(open_timeout: 1, ocr_timeout: 90, categorise_timeout: 15)
      ml.health
      ml.ocr([ image ])
      ml.categorise([ "bread" ])
    end

    assert_equal [ 1.0 ] * 3, opened.map { |options| options[:open_timeout] }
    assert_equal [ MlClient::HEALTH_TIMEOUT, 90.0, 15.0 ], opened.map { |options| options[:read_timeout] }
  end

  # --- health

  test "health returns the backend and model" do
    stub_ml_health

    health = client.health

    assert_equal "ok", health.status
    assert_equal "stub", health.backend
    assert_equal "stub-ocr", health.model_name
    assert_equal "0.1.0", health.model_version
    assert_equal ml_health_body.deep_stringify_keys, health.body
    assert health.body.frozen?
  end

  test "health with a missing key is an invalid response" do
    stub_ml(:health, status: 200, body: { status: "ok" })

    error = assert_raises(MlClient::InvalidResponse) { client.health }
    assert_equal "the ML service answer misses backend, model_name, model_version", error.message
  end

  # --- ocr

  test "ocr sends each photo as an images part and returns the receipt" do
    stub_ml_ocr
    first, second = png_bytes(red: 1), png_bytes(red: 2)

    result = client.ocr([ image(first, filename: "front.png"), image(second, filename: "back.jpg", content_type: "image/jpeg") ])

    request = ml_requests(:ocr).sole
    assert_match %r{\Amultipart/form-data; boundary=\S+\z}, request.headers["Content-Type"]
    assert_equal "application/json", request.headers["Accept"]
    parts = multipart_parts(request)
    assert_equal %w[images images], parts.pluck(:name)
    assert_equal %w[front.png back.jpg], parts.pluck(:filename)
    assert_equal %w[image/png image/jpeg], parts.pluck(:content_type)
    assert_equal [ first, second ], parts.pluck(:body)
    assert_equal "Sample Grocer", result.receipt["merchant"]
    assert_equal "117.40", result.receipt["total"]
    assert_equal [ "Oat milk 1 l", "Apples" ], result.receipt["items"].pluck("name")
    assert_equal %w[stub stub-ocr 0.1.0], [ result.backend, result.model_name, result.model_version ]
    assert_equal ml_ocr_body.deep_stringify_keys, result.body
    assert result.body.dig("receipt", "items", 0).frozen?
  end

  test "ocr reads each photo from the start and keeps odd file names safe" do
    stub_ml_ocr
    io = StringIO.new(png_bytes)
    io.read

    client.ocr([ MlClient::Image.new(io:, filename: %(a"b\r\n.png), content_type: "image/png") ])

    part = multipart_parts(ml_requests(:ocr).sole).sole
    assert_equal "a_b__.png", part[:filename]
    assert_equal png_bytes, part[:body]
  end

  test "ocr accepts three photos and refuses none or four" do
    stub_ml_ocr
    client.ocr((1..3).map { |red| image(png_bytes(red:)) })
    assert_equal 3, multipart_parts(ml_requests(:ocr).sole).size

    assert_raises(ArgumentError) { client.ocr([]) }
    assert_raises(ArgumentError) { client.ocr((1..4).map { image }) }
  end

  test "ocr allows null fields and no items" do
    stub_ml_ocr(receipt: { merchant: nil, fiscal_number: nil, receipt_number: nil, issued_at: nil, items: [] })

    receipt = client.ocr([ image ]).receipt

    assert_nil receipt["merchant"]
    assert_equal [], receipt["items"]
  end

  test "ocr answers that miss required parts are invalid responses" do
    {
      ml_ocr_body.except(:receipt) => "misses receipt",
      ml_ocr_body.merge(receipt: "text") => "has no object at receipt",
      ml_ocr_body(receipt: {}).tap { |body| body[:receipt] = body[:receipt].except(:total, :items) } => "misses receipt.total, receipt.items",
      ml_ocr_body(receipt: { items: "none" }) => "has no list of objects at receipt.items",
      ml_ocr_body(receipt: { items: [ { name: "Tea" } ] }) => "misses receipt.items[0].amount",
      ml_ocr_body.except(:model_version) => "misses model_version"
    }.each do |body, message|
      stub_ml(:ocr, status: 200, body:)
      error = assert_raises(MlClient::InvalidResponse) { client.ocr([ image ]) }
      assert_includes error.message, message
      assert_equal "invalid_response", error.code
      assert_not error.transient?
    end
  end

  test "an answer that is not JSON, or not an object, is an invalid response" do
    stub_ml(:ocr, status: 200, body: "<html>receipt</html>")
    error = assert_raises(MlClient::InvalidResponse) { client.ocr([ image ]) }
    assert_equal "the ML service answer is not valid JSON", error.message

    stub_ml(:ocr, status: 200, body: "[1, 2]")
    error = assert_raises(MlClient::InvalidResponse) { client.ocr([ image ]) }
    assert_equal "the ML service answer is not a JSON object", error.message
  end

  # --- categorise

  test "categorise posts the texts as JSON and returns the results" do
    stub_ml_categorise([ "milk 2.5% 900g", "dish soap" ])

    result = client.categorise([ "milk 2.5% 900g", "dish soap" ])

    request = ml_requests(:categorise).sole
    assert_equal "application/json", request.headers["Content-Type"]
    assert_equal({ "texts" => [ "milk 2.5% 900g", "dish soap" ] }, JSON.parse(request.body))
    assert_equal [ "milk 2.5% 900g", "dish soap" ], result.results.pluck("text")
    assert_equal "groceries/groceries", result.results.first["candidates"].first["category_slug"]
    assert_equal 0.71, result.results.first["candidates"].first["score"]
    assert_equal %w[stub stub-categoriser 0.1.0], [ result.backend, result.model_name, result.model_version ]
    assert_equal result.body["results"], result.results
  end

  test "categorise answers that miss required parts are invalid responses" do
    good = ml_categorise_body([ "tea" ])
    {
      good.except(:results) => "misses results",
      good.merge(results: [ "tea" ]) => "has no list of objects at results",
      good.merge(results: [ { text: "tea" } ]) => "misses results[0].candidates",
      good.merge(results: [ { text: "tea", candidates: [ 1 ] } ]) => "has no list of objects at results[0].candidates",
      good.merge(results: [ { text: "tea", candidates: [ { score: 0.5 } ] } ]) => "misses results[0].candidates[0].category_slug"
    }.each do |body, message|
      stub_ml(:categorise, status: 200, body:)
      error = assert_raises(MlClient::InvalidResponse) { client.categorise([ "tea" ]) }
      assert_includes error.message, message
    end
  end

  # --- error answers

  test "a 4xx answer is a response error with the service's code and message" do
    stub_ml_error(:ocr, status: 415, code: "unsupported_media_type", message: "File 'r.gif' has type 'image/gif'.")

    error = assert_raises(MlClient::ResponseError) { client.ocr([ image ]) }

    assert_instance_of MlClient::ResponseError, error
    assert_equal 415, error.status
    assert_equal "unsupported_media_type", error.code
    assert_equal "unsupported_media_type", error.service_code
    assert_equal "File 'r.gif' has type 'image/gif'.", error.service_message
    assert_equal "the ML service answered 415 unsupported_media_type: File 'r.gif' has type 'image/gif'.", error.message
    assert_not error.transient?
  end

  test "a 413 for a photo over the size limit is a permanent response error" do
    stub_ml_error(:ocr, status: 413, code: "image_too_large", message: "File 'r.jpg' is larger than the limit of 15728640 bytes.")

    error = assert_raises(MlClient::ResponseError) { client.ocr([ image ]) }

    assert_instance_of MlClient::ResponseError, error
    assert_equal 413, error.status
    assert_equal "image_too_large", error.code
    assert_not error.transient?
  end

  test "a 422 from categorise is a response error" do
    stub_ml_error(:categorise, status: 422, code: "validation_error", message: "texts.0: text must not be empty")

    error = assert_raises(MlClient::ResponseError) { client.categorise([ " " ]) }
    assert_equal "validation_error", error.code
  end

  test "a 501 answer means the backend is not implemented" do
    stub_ml_error(:ocr, status: 501, code: "backend_not_implemented", message: "The mlx backend is a placeholder.")

    error = assert_raises(MlClient::BackendNotImplemented) { client.ocr([ image ]) }

    assert_kind_of MlClient::ResponseError, error
    assert_equal 501, error.status
    assert_equal "backend_not_implemented", error.code
    assert_not error.transient?
  end

  test "a 5xx answer is a transient server error" do
    stub_ml_error(:ocr, status: 500, code: "internal_error", message: "Internal server error.")

    error = assert_raises(MlClient::ServerError) { client.ocr([ image ]) }

    assert_equal 500, error.status
    assert_equal "internal_error", error.code
    assert error.transient?
  end

  test "an error answer in another shape keeps only the status" do
    stub_ml(:health, status: 502, body: "<html>Bad gateway: secret upstream detail</html>")

    error = assert_raises(MlClient::ServerError) { client.health }

    assert_equal 502, error.status
    assert_nil error.service_code
    assert_equal "http_502", error.code
    assert_equal "the ML service answered 502 without an error code: no error details", error.message
    assert_not_includes error.message, "secret"

    stub_ml(:health, status: 404, body: { detail: "Not Found" })
    error = assert_raises(MlClient::ResponseError) { client.health }
    assert_equal "http_404", error.code
    assert_equal "no error details", error.service_message
  end

  test "a long service message is cut short" do
    stub_ml_error(:ocr, status: 422, code: "validation_error", message: "x" * 2000)

    error = assert_raises(MlClient::ResponseError) { client.ocr([ image ]) }

    assert_equal MlClient::MAX_MESSAGE_LENGTH, error.service_message.length
  end

  # --- network failures

  test "a timeout raises TimeoutError" do
    stub_request(:post, ml_url("/ocr")).to_timeout

    error = assert_raises(MlClient::TimeoutError) { client.ocr([ image ]) }

    assert_equal "ml_timeout", error.code
    assert error.transient?
    assert_kind_of MlClient::Error, error
  end

  test "a read timeout raises TimeoutError" do
    stub_request(:post, ml_url("/categorise")).to_raise(Net::ReadTimeout)

    assert_raises(MlClient::TimeoutError) { client.categorise([ "tea" ]) }
  end

  test "a refused or broken connection raises ConnectionError" do
    [ Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, EOFError, Errno::EHOSTUNREACH ].each do |failure|
      stub_request(:get, ml_url("/health")).to_raise(failure)

      error = assert_raises(MlClient::ConnectionError, failure.name) { client.health }
      assert_equal "ml_unreachable", error.code
      assert error.transient?
      assert_includes error.message, failure.name
    end
  end

  test "the base error class is not transient" do
    error = MlClient::Error.new("boom")

    assert_equal "ml_error", error.code
    assert_not error.transient?
  end
end
