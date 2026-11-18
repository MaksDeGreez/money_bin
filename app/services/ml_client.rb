require "net/http"
require "securerandom"

# HTTP client for the Python ML service in ml/ (its contract is ml/README.md).
#
#   client = MlClient.new
#   client.health                                       # => MlClient::Health
#   client.ocr([ MlClient::Image.new(io:, filename:, content_type:) ])  # => MlClient::OcrResult
#   client.categorise([ "Мол 900г" ], categories: Categories::ItemCandidates.payload, merchant: "Shop")
#                                                       # => MlClient::CategoriseResult
#   client.categorise_transactions([ { merchant: "Shop", amount: "-12.50", currency: "UAH" } ],
#     categories: Categories::TransactionCandidates.payload)  # => MlClient::TransactionCategorisation
#   client.transaction_categoriser                     # => MlClient::TransactionModel (which artefact answers)
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
#                          `code` and its message. Permanent: the same photos get the same answer, e.g.
#                          413 image_too_large or 415 unsupported_media_type.
#   - ServerError          a 5xx answer other than 501. Transient.
#   - BackendNotImplemented the selected backend is only a placeholder (501).
# - InvalidResponse        a 2xx answer that is not JSON or misses a required key.
#
# Exception messages never quote the response body, only the service's own error message.
#
# Timeouts are in seconds. Each has a default and an environment variable (see .env.example):
# ML_SERVICE_OPEN_TIMEOUT for opening the connection, ML_SERVICE_OCR_TIMEOUT for reading an OCR answer (a
# real model can take a while) and ML_SERVICE_CATEGORISE_TIMEOUT for a categorisation answer (one receipt's
# items: a local model takes under a second per item, but it may first finish another receipt's OCR).
class MlClient
  DEFAULT_URL = "http://127.0.0.1:8100".freeze
  DEFAULT_OPEN_TIMEOUT = 2
  DEFAULT_OCR_TIMEOUT = 120
  DEFAULT_CATEGORISE_TIMEOUT = 120
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
  # "text" and 1 to 3 "candidates" ({ "category_slug", "score" }, best first; every slug is one of the
  # categories sent). `calibrated` says whether the best score was calibrated on labelled items;
  # `score_kind` where the scores come from (ml/README.md, "How confidence is computed").
  CategoriseResult = Data.define(:body, :results, :backend, :model_name, :model_version, :calibrated, :score_kind,
    :prompt_version)
  # The transaction categoriser's answer: `results` in the order of the transactions sent, each a Hash with 1 to
  # 3 "candidates" ({ "category_slug", "probability" }, best first, every slug one of the categories sent),
  # "source" (model, history or mix), "history" (payee, mcc or nil) and "history_weight".
  TransactionCategorisation = Data.define(:body, :results, :model_name, :model_version, :fitted_at)
  TransactionModel = Data.define(:body, :model_name, :model_version, :fitted_at)
  TRANSACTION_SOURCES = %w[model history mix].freeze

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

  # Transaction data may go to an ML service on this machine only (ML_SERVICE_URL on a loopback host); nothing is
  # sent otherwise. Permanent.
  class NotLocal < Error
    def code = "ml_not_local"
  end

  # Batch mode: the /ocr/batches calls (MlClient::Batches).
  include Batches

  NETWORK_ERRORS = [
    SocketError, IOError, EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    Errno::ENETUNREACH, Errno::EPIPE, Errno::EADDRNOTAVAIL, OpenSSL::SSL::SSLError
  ].freeze
  TIMEOUT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, Errno::ETIMEDOUT ].freeze

  # The hosts a request with transaction data may go to: this machine.
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  # The ML service's limit on one /categorise/transaction request (ml/README.md).
  MAX_TRANSACTIONS = 500
  MONEY_STRING = /\A-?\d{1,13}(?:\.\d{1,2})?\z/

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

  # Asks for category suggestions for the items of ONE receipt: `texts` (1 to 200, none blank), `categories` the
  # candidate list ({ slug:, name:, description:, group: }, Categories::ItemCandidates.payload) and the shop's
  # name as context for a local model (a hosted categoriser never sends it on). The answer may only name the
  # slugs sent: any other slug, a missing item or a score outside 0..1 is an InvalidResponse.
  def categorise(texts, categories:, merchant: nil)
    texts = Array(texts)
    slugs = categories.map { |category| (category[:slug] || category["slug"]).to_s }.to_set
    post = Net::HTTP::Post.new(url("/categorise"))
    post["Content-Type"] = "application/json"
    post.body = JSON.generate({ texts:, categories:, merchant: merchant.presence })

    body = request(post, read_timeout: categorise_timeout)
    require_keys(body, %w[results backend model_name model_version calibrated score_kind prompt_version], "")
    require_list_of_hashes(body["results"], "results")
    if body["results"].size != texts.size
      raise InvalidResponse, "the ML service answered #{body['results'].size} results for #{texts.size} texts"
    end
    body["results"].each_with_index { |result, index| check_result(result, index, slugs) }

    CategoriseResult.new(body:, results: body["results"], calibrated: body["calibrated"] == true,
      score_kind: body["score_kind"], prompt_version: body["prompt_version"], **backend_info(body))
  end

  # Asks the local transaction categoriser for the three best categories of each transaction (1 to
  # MAX_TRANSACTIONS). Each transaction is a Hash of payee, comment, bank_description, merchant, mcc, amount (a
  # decimal String, signed; never a Float), currency and account_kind, any of them nil; `categories` the
  # candidate list (Categories::TransactionCandidates.payload). The answer may only name the slugs sent: any
  # other slug, a missing result or a probability outside 0..1 is an InvalidResponse. The service runs the model
  # on this machine; nothing of the transactions goes further. A service URL that is not on this machine raises
  # NotLocal before anything is sent.
  def categorise_transactions(transactions, categories:)
    raise NotLocal, "transaction data is sent only to an ML service on this machine, not to #{base_url.host}" unless local?

    transactions = Array(transactions)
    raise ArgumentError, "send 1 to #{MAX_TRANSACTIONS} transactions, got #{transactions.size}" unless transactions.size.between?(1, MAX_TRANSACTIONS)

    transactions.each do |transaction|
      amount = transaction[:amount]
      raise ArgumentError, "an amount must be a decimal String, got #{amount.class}" unless amount.nil? || (amount.is_a?(String) && amount.match?(MONEY_STRING))
    end
    slugs = categories.map { |category| (category[:slug] || category["slug"]).to_s }.to_set
    post = Net::HTTP::Post.new(url("/categorise/transaction"))
    post["Content-Type"] = "application/json"
    post.body = JSON.generate({ categories:, transactions: })

    body = request(post, read_timeout: categorise_timeout)
    require_keys(body, %w[results model_name model_version fitted_at], "")
    require_list_of_hashes(body["results"], "results")
    if body["results"].size != transactions.size
      raise InvalidResponse, "the ML service answered #{body['results'].size} results for #{transactions.size} transactions"
    end
    body["results"].each_with_index { |result, index| check_transaction_result(result, index, slugs) }

    TransactionCategorisation.new(body:, results: body["results"], model_name: body["model_name"],
      model_version: body["model_version"], fitted_at: body["fitted_at"])
  end

  # Which artefact the transaction categoriser serves (it loads the artefact, not the sentence encoder). Asked of a
  # service on this machine only, like the categorising (NotLocal otherwise).
  def transaction_categoriser
    raise NotLocal, "the transaction categoriser is asked only on this machine, not at #{base_url.host}" unless local?

    body = request(Net::HTTP::Get.new(url("/categorise/transaction")), read_timeout: categorise_timeout)
    require_keys(body, %w[model_name model_version fitted_at], "")
    TransactionModel.new(body:, model_name: body["model_name"], model_version: body["model_version"], fitted_at: body["fitted_at"])
  end

  # True when the service URL points at this machine (a loopback host).
  def local?
    LOCAL_HOSTS.include?(base_url.hostname.to_s.downcase)
  end

  private
    def check_transaction_result(result, index, slugs)
      require_keys(result, %w[candidates source history], "results[#{index}].")
      require_list_of_hashes(result["candidates"], "results[#{index}].candidates")
      raise InvalidResponse, "the ML service answer has no candidate at results[#{index}]" if result["candidates"].empty?
      raise InvalidResponse, "the ML service answer has an unknown source at results[#{index}]" unless TRANSACTION_SOURCES.include?(result["source"])

      result["candidates"].each_with_index do |candidate, position|
        name = "results[#{index}].candidates[#{position}]"
        require_keys(candidate, %w[category_slug probability], "#{name}.")
        raise InvalidResponse, "the ML service answer names a category it was not given at #{name}" unless slugs.include?(candidate["category_slug"])

        probability = candidate["probability"]
        raise InvalidResponse, "the ML service answer has a probability outside 0..1 at #{name}" unless probability.is_a?(Numeric) && probability.between?(0, 1)
      end
    end

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

    def check_result(result, index, slugs)
      require_keys(result, %w[text candidates], "results[#{index}].")
      require_list_of_hashes(result["candidates"], "results[#{index}].candidates")
      raise InvalidResponse, "the ML service answer has no candidate at results[#{index}]" if result["candidates"].empty?

      result["candidates"].each_with_index do |candidate, position|
        name = "results[#{index}].candidates[#{position}]"
        require_keys(candidate, %w[category_slug score], "#{name}.")
        raise InvalidResponse, "the ML service answer names a category it was not given at #{name}" unless slugs.include?(candidate["category_slug"])

        score = candidate["score"]
        raise InvalidResponse, "the ML service answer has a score outside 0..1 at #{name}" unless score.is_a?(Numeric) && score.between?(0, 1)
      end
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
