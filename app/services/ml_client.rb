require "net/http"
require "securerandom"

# HTTP client for the Python ML service in ml/ (its contract is ml/README.md).
#
#   client = MlClient.new
#   client.health                                       # => MlClient::Health
#   client.ocr([ MlClient::Image.new(io:, filename:, content_type:) ])  # => MlClient::OcrResult
#   client.categorise([ "milk 2.5% 900g" ])             # => MlClient::CategoriseResult
#
# Every result keeps the parsed response body (`body`, a deeply frozen Hash with string keys) next to the
# parts the app reads. Money and quantities stay decimal strings here; the caller parses them with
# BigDecimal.
#
# The client does not retry: the caller decides what to do with each failure. All failures raise a subclass
# of MlClient::Error, and `transient?` says whether trying again later can help:
#
# - ConnectionError        the service cannot be reached (refused, unknown host, connection reset). Transient.
# - TimeoutError           opening the connection or waiting for the answer took too long. Transient.
# - ResponseError          the service answered with an error status (4xx). Keeps `status`, the service's
#                          `code` and its message.
#   - ServerError          a 5xx answer other than 501. Transient.
#   - BackendNotImplemented the selected backend is only a placeholder (501).
# - InvalidResponse        a 2xx answer that is not JSON or misses a required key.
#
# Exception messages never quote the response body, only the service's own error message.
#
# Timeouts are in seconds. Each has a default and an environment variable (see .env.example):
# ML_SERVICE_OPEN_TIMEOUT for opening the connection, ML_SERVICE_OCR_TIMEOUT for reading an OCR answer (a
# real model can take a while) and ML_SERVICE_CATEGORISE_TIMEOUT for a categorisation answer.
class MlClient
  DEFAULT_URL = "http://127.0.0.1:8100".freeze
  DEFAULT_OPEN_TIMEOUT = 2
  DEFAULT_OCR_TIMEOUT = 120
  DEFAULT_CATEGORISE_TIMEOUT = 30
  HEALTH_TIMEOUT = 5
  MAX_IMAGES = 3
  # The longest service error message kept in an exception.
  MAX_MESSAGE_LENGTH = 500

  # One photo to send. `io` is anything with `read` (File, StringIO); it is read once, from the start.
  Image = Data.define(:io, :filename, :content_type)

  Health = Data.define(:body, :status, :backend, :model_name, :model_version)
  # `receipt` is the "receipt" part of the body: merchant, fiscal_number, receipt_number, issued_at, total,
  # currency and items, as the service sent them.
  OcrResult = Data.define(:body, :receipt, :backend, :model_name, :model_version)
  # `results` is the "results" part of the body: one Hash per text, in the order of the texts, each with
  # "text" and three "candidates" ({ "category_slug", "score" }, best first).
  CategoriseResult = Data.define(:body, :results, :backend, :model_name, :model_version)

  class Error < StandardError
    # A short machine-readable name for the failure.
    def code = "ml_error"
    # Whether trying again later can help.
    def transient? = false
  end

  class ConnectionError < Error
    def code = "ml_unreachable"
    def transient? = true
  end

  class TimeoutError < Error
    def code = "ml_timeout"
    def transient? = true
  end

  class ResponseError < Error
    attr_reader :status, :service_code, :service_message

    def initialize(status:, service_code:, service_message:)
      @status = status
      @service_code = service_code
      @service_message = service_message
      super("the ML service answered #{status} #{service_code || 'without an error code'}: #{service_message}")
    end

    # The service's own code, or "http_<status>" when the answer had none.
    def code = service_code || "http_#{status}"
  end

  class ServerError < ResponseError
    def transient? = true
  end

  class BackendNotImplemented < ResponseError; end

  class InvalidResponse < Error
    def code = "invalid_response"
  end

  NETWORK_ERRORS = [
    SocketError, IOError, EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    Errno::ENETUNREACH, Errno::EPIPE, Errno::EADDRNOTAVAIL, OpenSSL::SSL::SSLError
  ].freeze
  TIMEOUT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, Errno::ETIMEDOUT ].freeze

  attr_reader :base_url, :open_timeout, :ocr_timeout, :categorise_timeout

  def initialize(base_url: nil, open_timeout: nil, ocr_timeout: nil, categorise_timeout: nil)
    @base_url = URI(base_url || ENV["ML_SERVICE_URL"].presence || DEFAULT_URL)
    @open_timeout = seconds(open_timeout, "ML_SERVICE_OPEN_TIMEOUT", DEFAULT_OPEN_TIMEOUT)
    @ocr_timeout = seconds(ocr_timeout, "ML_SERVICE_OCR_TIMEOUT", DEFAULT_OCR_TIMEOUT)
    @categorise_timeout = seconds(categorise_timeout, "ML_SERVICE_CATEGORISE_TIMEOUT", DEFAULT_CATEGORISE_TIMEOUT)
  end

  def health
    body = request(Net::HTTP::Get.new(url("/health")), read_timeout: HEALTH_TIMEOUT)
    require_keys(body, %w[status backend model_name model_version], "")
    Health.new(body:, **body.slice("status", "backend", "model_name", "model_version").symbolize_keys)
  end

  # Sends 1 to 3 photos of one receipt as multipart/form-data, one `images` part per photo, in order.
  def ocr(images)
    images = Array(images)
    raise ArgumentError, "send 1 to #{MAX_IMAGES} images, got #{images.size}" unless images.size.between?(1, MAX_IMAGES)

    boundary = "MlClient#{SecureRandom.hex(16)}"
    post = Net::HTTP::Post.new(url("/ocr"))
    post["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    post.body = multipart_body(images, boundary)

    body = request(post, read_timeout: ocr_timeout)
    require_keys(body, %w[receipt backend model_name model_version], "")
    receipt = body["receipt"]
    require_hash(receipt, "receipt")
    require_keys(receipt, %w[total currency items], "receipt.")
    require_list_of_hashes(receipt["items"], "receipt.items")
    receipt["items"].each_with_index { |item, index| require_keys(item, %w[name amount], "receipt.items[#{index}].") }

    OcrResult.new(body:, receipt:, **backend_info(body))
  end

  # Asks for category suggestions for item texts (1 to 200, none blank; the service checks the limits).
  def categorise(texts)
    post = Net::HTTP::Post.new(url("/categorise"))
    post["Content-Type"] = "application/json"
    post.body = JSON.generate({ texts: Array(texts) })

    body = request(post, read_timeout: categorise_timeout)
    require_keys(body, %w[results backend model_name model_version], "")
    require_list_of_hashes(body["results"], "results")
    body["results"].each_with_index do |result, index|
      require_keys(result, %w[text candidates], "results[#{index}].")
      require_list_of_hashes(result["candidates"], "results[#{index}].candidates")
      result["candidates"].each_with_index do |candidate, position|
        require_keys(candidate, %w[category_slug score], "results[#{index}].candidates[#{position}].")
      end
    end

    CategoriseResult.new(body:, results: body["results"], **backend_info(body))
  end

  private
    def seconds(given, variable, default)
      value = given || ENV[variable].presence || default
      number = Float(value, exception: false)
      raise ArgumentError, "#{variable} must be a positive number of seconds, got #{value.inspect}" unless number&.positive?

      number
    end

    def url(path)
      URI.join(base_url.to_s.chomp("/") + "/", path.delete_prefix("/"))
    end

    # Sends the request and returns the parsed JSON body of a 2xx answer.
    def request(http_request, read_timeout:)
      http_request["Accept"] = "application/json"
      uri = http_request.uri
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout:, read_timeout:,
        write_timeout: read_timeout) { |http| http.request(http_request) }
      handle(response)
    rescue *TIMEOUT_ERRORS => error
      raise TimeoutError, "the ML service at #{base_url} did not answer in time (#{error.class})"
    rescue *NETWORK_ERRORS, SystemCallError => error
      raise ConnectionError, "cannot reach the ML service at #{base_url} (#{error.class})"
    end

    def handle(response)
      status = response.code.to_i
      return parse(response.body) if status.between?(200, 299)

      detail = error_detail(response.body)
      error_class =
        case status
        when 501 then BackendNotImplemented
        when 500.. then ServerError
        else ResponseError
        end
      raise error_class.new(status:, service_code: detail[:code], service_message: detail[:message])
    end

    def parse(text)
      body = JSON.parse(text.to_s, freeze: true)
      raise InvalidResponse, "the ML service answer is not a JSON object" unless body.is_a?(Hash)

      body
    rescue JSON::ParserError
      raise InvalidResponse, "the ML service answer is not valid JSON"
    end

    # The service's { "error": { "code", "message" } }, or a neutral text when the body has another shape
    # (a proxy's HTML page, say). Nothing else of the body is kept.
    def error_detail(text)
      error = JSON.parse(text.to_s)
      error = error["error"] if error.is_a?(Hash)
      code = error["code"] if error.is_a?(Hash) && error["code"].is_a?(String)
      message = error["message"] if error.is_a?(Hash) && error["message"].is_a?(String)
      { code: code.presence, message: message.present? ? message.truncate(MAX_MESSAGE_LENGTH) : "no error details" }
    rescue JSON::ParserError
      { code: nil, message: "no error details" }
    end

    def backend_info(body)
      body.slice("backend", "model_name", "model_version").symbolize_keys
    end

    def require_hash(value, name)
      raise InvalidResponse, "the ML service answer has no object at #{name}" unless value.is_a?(Hash)
    end

    def require_keys(hash, keys, prefix)
      missing = keys.reject { |key| hash.key?(key) }
      raise InvalidResponse, "the ML service answer misses #{missing.map { |key| prefix + key }.join(', ')}" if missing.any?
    end

    def require_list_of_hashes(value, name)
      return if value.is_a?(Array) && value.all?(Hash)

      raise InvalidResponse, "the ML service answer has no list of objects at #{name}"
    end

    def multipart_body(images, boundary)
      body = "".b
      images.each do |image|
        io = image.io
        io.rewind if io.respond_to?(:rewind)
        filename = image.filename.to_s.gsub(/["\r\n\\]/, "_").presence || "image"
        body << "--#{boundary}\r\n".b
        body << %(Content-Disposition: form-data; name="images"; filename="#{filename}"\r\n).b
        body << "Content-Type: #{image.content_type}\r\n\r\n".b
        body << io.read.to_s.b << "\r\n".b
      end
      body << "--#{boundary}--\r\n".b
    end
end
