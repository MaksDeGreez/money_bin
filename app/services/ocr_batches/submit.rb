module OcrBatches
  # Sends one `pending` batch to the ML service, which builds the provider batch and submits it
  # (docs/domain.md, "OCR in a batch"). OcrBatchSubmitJob calls it, one batch at a time.
  #
  #   OcrBatches::Submit.call(batch)  # => :submitted, :retry_later, :split, :failed, :unknown, :empty or :skipped
  #
  # 1. Claim: under the batch's row lock, `pending` -> `submitting` (`submit_started_at`). Anything else is
  #    left alone (:skipped), so a duplicate job does nothing.
  # 2. Each waiting entry is checked: a receipt that left the batch meanwhile (entered by hand, deleted) is
  #    `superseded`; one whose photo is gone from storage fails as a read one at a time would (`image_missing`).
  # 3. The photos go up with the entries' random keys; the answer makes the batch `running` with the provider's
  #    batch id, model, provider, expiry, counts and the estimated cost.
  #
  # When it does not work:
  # - nothing reached the provider (the service is down, 5xx other than the one below, rate limited): back to
  #   `pending`, tried again after RETRY_WAITS; when they run out, the batch fails and its receipts are released;
  # - too large (`batch_too_large`, `batch_upload_too_large`): the second half of its entries moves to a new
  #   `pending` batch and both are sent again (one receipt that is still too large fails);
  # - refused for good (4xx, 501: batch mode switched off, the account's privacy settings, inline images not
  #   allowed): the batch fails with the reason and its receipts are released;
  # - sent but the answer lost (a timeout, `openrouter_batch_submit_unknown`, an answer that cannot be read):
  #   the provider may have it, but the app cannot know its id. The batch becomes `unknown`, its receipts are
  #   released, and the batches page says to look for it in OpenRouter's logs and delete it there.
  class Submit
    RETRY_WAITS = [ 1.minute, 5.minutes, 15.minutes, 1.hour ].freeze
    SPLIT_CODES = %w[batch_too_large batch_upload_too_large].freeze
    UNKNOWN_CODES = %w[openrouter_batch_submit_unknown].freeze
    HELD_STATUSES = %w[uploaded failed].freeze
    SUPERSEDED_MESSAGE = "A person took the receipt over before the batch was sent."
    UNKNOWN_MESSAGE = "The batch was sent but its answer was lost, so OpenRouter may have accepted it without " \
      "the app knowing its id. Look in the Batches tab of OpenRouter's logs and delete it there if it is listed."

    def self.call(batch, client: MlClient.new, now: Time.current)
      new(batch, client:, now:).call
    end

    def initialize(batch, client:, now:)
      @batch = batch
      @client = client
      @now = now
    end

    def call
      return :skipped unless claim

      live = prepare
      return finish_empty if live.empty?

      status = @client.create_ocr_batch(live.map { |entry, images| MlClient::BatchReceipt.new(key: entry.custom_id, images:) })
      record(status, live.size)
      :submitted
    rescue MlClient::ResponseError => error
      refused(error, live)
    rescue MlClient::ConnectionError => error
      retry_later(error)
    rescue MlClient::TimeoutError, MlClient::InvalidResponse
      lost
    ensure
      LiveUpdate.changed(@batch)
    end

    private
      def claim
        @batch.with_lock do
          next false unless @batch.pending?

          @batch.update!(state: "submitting", submit_started_at: @now)
          true
        end
      end

      # [[entry, images]] for the entries whose receipt still waits in this batch.
      def prepare
        @batch.entries.where(state: "waiting").includes(:receipt).filter_map do |entry|
          Receipt.transaction do
            receipt = entry.receipt_id && Receipt.lock.find_by(id: entry.receipt_id)
            if receipt.nil? || receipt.ocr_batch_id != @batch.id || !HELD_STATUSES.include?(receipt.status)
              receipt.update_columns(ocr_batch_id: nil) if receipt&.ocr_batch_id == @batch.id
              entry.resolve!(:superseded, code: "superseded", message: SUPERSEDED_MESSAGE, now: @now)
              next
            end
            [ entry, ReceiptOcrJob.images_of(receipt) ]
          rescue ReceiptOcrJob::Unprocessable => error
            ReceiptFailure.record(receipt, error.code, error.message)
            entry.resolve!(:failed, code: error.code, message: error.message, now: @now)
            nil
          end
        end
      end

      def finish_empty
        @batch.update!(state: "finished", finished_at: @now, next_check_at: @now)
        :empty
      end

      def record(status, sent)
        @batch.update!(state: "running", provider_batch_id: status.id, provider_status: status.provider_status,
          model: status.model_name, provider: status.provider, submitted_at: @now, expires_at: status.expires_at,
          estimated_cost_usd: status.estimated_cost_usd, cost_usd: status.cost_usd,
          requests_total: status.requests_total || sent, requests_completed: status.requests_completed,
          requests_failed: status.requests_failed, checks: 0, next_check_at: @now + Check.interval(0),
          error_code: nil, error_message: nil, check_error_code: nil, check_error_message: nil)
      end

      def refused(error, live)
        return lost if UNKNOWN_CODES.include?(error.code)
        return split(live) if SPLIT_CODES.include?(error.code) && Array(live).size > 1
        return retry_later(error) if error.transient?

        @batch.release!("failed", error.code, error.service_message || error.message, now: @now)
        :failed
      end

      def retry_later(error)
        wait = RETRY_WAITS[@batch.submit_attempts]
        if wait.nil?
          @batch.release!("failed", error.code, "Sending the batch failed #{RETRY_WAITS.size + 1} times: #{error.message}",
            now: @now)
          return :failed
        end
        @batch.update!(state: "pending", submit_attempts: @batch.submit_attempts + 1, next_check_at: @now + wait,
          check_error_code: error.code, check_error_message: error.message.to_s.truncate(ReceiptOcrJob::MAX_MESSAGE_LENGTH))
        :retry_later
      end

      def lost
        @batch.release!("unknown", "submit_unknown", UNKNOWN_MESSAGE, now: @now)
        :unknown
      end

      # The second half of the entries goes to a new pending batch with its receipts' holds; both are sent again.
      def split(live)
        moving = live.map(&:first).drop(live.size / 2)
        OcrBatch.transaction do
          other = OcrBatch.create!(state: "pending", receipts_count: moving.size, next_check_at: @now)
          moving.each_with_index do |entry, index|
            entry.update_columns(ocr_batch_id: other.id, position: index + 1, updated_at: @now)
          end
          Receipt.where(id: moving.map(&:receipt_id), ocr_batch_id: @batch.id).update_all(ocr_batch_id: other.id)
          @batch.update!(state: "pending", receipts_count: @batch.entries.count, next_check_at: @now)
          LiveUpdate.changed(other)
        end
        :split
      end
  end
end
