class MlClient
  # The batch calls of the ML service (ml/README.md, "Batch mode"), with the client's own error classes:
  #
  #   client.ocr_batch_capability                     # => MlClient::BatchCapability (never raises for "off")
  #   client.estimate_ocr_batch(receipts: 120, images: 180)  # => MlClient::BatchEstimate
  #   client.create_ocr_batch([ MlClient::BatchReceipt.new(key:, images: [ MlClient::Image, ... ]) ])
  #                                                    # => MlClient::BatchStatus
  #   client.ocr_batch(id)                             # => MlClient::BatchStatus
  #   client.ocr_batch_results(id)                     # => MlClient::BatchResults
  #   client.delete_ocr_batch(id)                      # => MlClient::BatchDeletion
  #
  # Costs are BigDecimal (the service sends decimal strings), times are Time in the app's zone. A create request
  # waits up to ML_SERVICE_BATCH_TIMEOUT seconds (default 600): the service scales down and re-encodes every
  # photo and uploads the batch before it answers.
  module Batches
    DEFAULT_BATCH_TIMEOUT = 600
    STATUS_TIMEOUT = 90
    CAPABILITY_TIMEOUT = 15
    BATCH_ID_FORMAT = /\A[A-Za-z0-9_-]{1,128}\z/
    STATES = %w[running completed failed expired cancelled].freeze

    def ocr_batch_capability
      body = request(Net::HTTP::Get.new(url("/ocr/batches/capability")), read_timeout: CAPABILITY_TIMEOUT)
      require_keys(body, %w[available code message backend max_receipts max_upload_bytes retention_days], "")
      BatchCapability.new(body:, available: body["available"] == true, code: body["code"], message: body["message"],
        model_name: body["model_name"], model_version: body["model_version"], providers: Array(body["providers"]),
        max_receipts: body["max_receipts"].to_i, max_upload_bytes: body["max_upload_bytes"].to_i,
        retention_days: body["retention_days"].to_i)
    end

    def estimate_ocr_batch(receipts:, images:)
      post = Net::HTTP::Post.new(url("/ocr/batches/estimate"))
      post["Content-Type"] = "application/json"
      post.body = JSON.generate({ receipts:, images: })
      body = request(post, read_timeout: CAPABILITY_TIMEOUT)
      require_keys(body, %w[cost_usd cost_usd_max receipts images basis model_name], "")
      BatchEstimate.new(body:, cost_usd: money!(body["cost_usd"], "cost_usd"),
        cost_usd_max: money!(body["cost_usd_max"], "cost_usd_max"), receipts: body["receipts"], images: body["images"],
        basis: body["basis"], model_name: body["model_name"])
    end

    # Uploads the receipts' photos (each receipt 1 to 3, in order) with a manifest of their keys.
    def create_ocr_batch(receipts)
      receipts = Array(receipts)
      raise ArgumentError, "a batch needs at least one receipt" if receipts.empty?

      receipts.each do |receipt|
        unless receipt.images.size.between?(1, MAX_IMAGES)
          raise ArgumentError, "send 1 to #{MAX_IMAGES} images per receipt, got #{receipt.images.size}"
        end
      end
      boundary = "MlClient#{SecureRandom.hex(16)}"
      post = Net::HTTP::Post.new(url("/ocr/batches"))
      post["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      post.body = batch_multipart_body(receipts, boundary)
      batch_status(request(post, read_timeout: batch_timeout))
    end

    def ocr_batch(id)
      batch_status(request(Net::HTTP::Get.new(batch_url(id)), read_timeout: STATUS_TIMEOUT))
    end

    # The results of a completed batch: `results` is a list of { "key", "status" ("ok"/"error"), "ocr", "error" }.
    # `ocr_result(item)` turns an "ok" item into an MlClient::OcrResult, checked like the answer of `ocr`.
    def ocr_batch_results(id)
      body = request(Net::HTTP::Get.new(batch_url(id, "/results")), read_timeout: STATUS_TIMEOUT)
      require_keys(body, %w[batch results counts], "")
      require_hash(body["batch"], "batch")
      require_list_of_hashes(body["results"], "results")
      body["results"].each_with_index do |item, index|
        require_keys(item, %w[key status], "results[#{index}].")
        if item["status"] == "ok"
          require_hash(item["ocr"], "results[#{index}].ocr")
          check_ocr_body(item["ocr"], "results[#{index}].ocr.")
        else
          require_hash(item["error"], "results[#{index}].error")
          require_keys(item["error"], %w[code message retry_sync], "results[#{index}].error.")
        end
      end
      BatchResults.new(body:, batch: batch_status(body["batch"]), results: body["results"])
    end

    def delete_ocr_batch(id)
      body = request(Net::HTTP::Delete.new(batch_url(id)), read_timeout: STATUS_TIMEOUT)
      require_keys(body, %w[id deleted upstream_status upstream_provider], "")
      BatchDeletion.new(body:, id: body["id"], upstream_status: body["upstream_status"],
        upstream_provider: body["upstream_provider"])
    end

    # An "ok" item of ocr_batch_results as the OcrResult Receipts::ApplyOcr stores.
    def self.ocr_result(item)
      ocr = item.fetch("ocr")
      OcrResult.new(body: ocr, receipt: ocr["receipt"], backend: ocr["backend"], model_name: ocr["model_name"],
        model_version: ocr["model_version"])
    end

    private
      def batch_timeout
        seconds(nil, "ML_SERVICE_BATCH_TIMEOUT", DEFAULT_BATCH_TIMEOUT)
      end

      def batch_url(id, suffix = "")
        raise ArgumentError, "not a batch id: #{id.inspect}" unless id.is_a?(String) && id.match?(BATCH_ID_FORMAT)

        url("/ocr/batches/#{id}#{suffix}")
      end

      def check_ocr_body(body, prefix)
        require_keys(body, %w[receipt backend model_name model_version], prefix)
        require_hash(body["receipt"], "#{prefix}receipt")
        require_keys(body["receipt"], %w[total currency items], "#{prefix}receipt.")
        require_list_of_hashes(body["receipt"]["items"], "#{prefix}receipt.items")
        body["receipt"]["items"].each_with_index do |item, index|
          require_keys(item, %w[name amount], "#{prefix}receipt.items[#{index}].")
        end
      end

      def batch_status(body)
        require_keys(body, %w[id state requests cost_usd estimated_cost_usd created_at expires_at error], "")
        unless body["state"].in?(STATES) && body["id"].is_a?(String) && body["id"].match?(BATCH_ID_FORMAT)
          raise InvalidResponse, "the ML service answer has an unknown batch state or id"
        end

        requests = body["requests"].is_a?(Hash) ? body["requests"] : {}
        error = body["error"].is_a?(Hash) ? body["error"] : {}
        BatchStatus.new(body:, id: body["id"], state: body["state"], provider_status: body["provider_status"],
          provider: body["provider"], model_name: body["model_name"], requests_total: count(requests["total"]),
          requests_completed: count(requests["completed"]), requests_failed: count(requests["failed"]),
          cost_usd: money(body["cost_usd"]), estimated_cost_usd: money(body["estimated_cost_usd"]),
          created_at: time(body["created_at"]), expires_at: time(body["expires_at"]),
          finished_at: time(body["finished_at"]), error_code: error["code"], error_message: error["message"])
      end

      # A cost: a decimal string, as BigDecimal (never through Float), or nil. Anything else is unknown (nil).
      def money(value)
        return nil unless value.is_a?(String) && value.match?(/\A[0-9]+(\.[0-9]+)?\z/)

        BigDecimal(value)
      end

      def money!(value, name)
        money(value) || raise(InvalidResponse, "the ML service answer has no decimal at #{name}")
      end

      def count(value)
        value if value.is_a?(Integer) && !value.negative?
      end

      def time(value)
        Time.zone.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end

      # A `manifest` part (JSON: the keys and how many photos each has), then the photos, receipt by receipt.
      # The photos go without their file names: the service needs none.
      def batch_multipart_body(receipts, boundary)
        manifest = receipts.map { |receipt| { key: receipt.key, images: receipt.images.size } }
        body = "--#{boundary}\r\n".b
        body << %(Content-Disposition: form-data; name="manifest"\r\n\r\n).b
        body << JSON.generate(manifest).b << "\r\n".b
        receipts.each do |receipt|
          receipt.images.each do |image|
            io = image.io
            io.rewind if io.respond_to?(:rewind)
            body << "--#{boundary}\r\n".b
            body << %(Content-Disposition: form-data; name="images"; filename="image"\r\n).b
            body << "Content-Type: #{image.content_type}\r\n\r\n".b
            body << io.read.to_s.b << "\r\n".b
          end
        end
        body << "--#{boundary}--\r\n".b
      end
  end

  BatchReceipt = Data.define(:key, :images)
  BatchCapability = Data.define(:body, :available, :code, :message, :model_name, :model_version, :providers,
    :max_receipts, :max_upload_bytes, :retention_days)
  BatchEstimate = Data.define(:body, :cost_usd, :cost_usd_max, :receipts, :images, :basis, :model_name)
  BatchStatus = Data.define(:body, :id, :state, :provider_status, :provider, :model_name, :requests_total,
    :requests_completed, :requests_failed, :cost_usd, :estimated_cost_usd, :created_at, :expires_at, :finished_at,
    :error_code, :error_message)
  BatchResults = Data.define(:body, :batch, :results)
  BatchDeletion = Data.define(:body, :id, :upstream_status, :upstream_provider)
end
