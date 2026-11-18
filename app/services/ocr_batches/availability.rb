module OcrBatches
  # Whether the ML service can read receipts in a batch now (its `/ocr/batches/capability`), kept for TTL so the
  # receipts list does not ask on every render. A service that cannot be reached counts as "not available" and
  # is not kept, so the next page asks again.
  #
  #   OcrBatches::Availability.current               # => MlClient::BatchCapability
  #   OcrBatches::Availability.current(fresh: true)  # asks the service now (the confirmation page)
  module Availability
    CACHE_KEY = "ocr_batches/capability".freeze
    TTL = 5.minutes

    module_function

    def current(fresh: false, client: MlClient.new, cache: Rails.cache)
      cache.delete(CACHE_KEY) if fresh
      capability = cache.read(CACHE_KEY)
      return capability if capability

      capability = client.ocr_batch_capability
      cache.write(CACHE_KEY, capability, expires_in: TTL)
      capability
    rescue MlClient::Error => error
      MlClient::BatchCapability.new(body: {}, available: false, code: error.code, message: error.message,
        model_name: nil, model_version: nil, providers: [], max_receipts: 0, max_upload_bytes: 0, retention_days: 30)
    end
  end
end
