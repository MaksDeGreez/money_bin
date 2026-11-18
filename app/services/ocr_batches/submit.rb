module OcrBatches
  # Sends one `pending` batch to the ML service, which builds the provider batch and submits it
  # (docs/domain.md, "OCR in a batch"). OcrBatchSubmitJob calls it, one batch at a time.
  #
  #   OcrBatches::Submit.call(batch)  # => :submitted, :retry_later, :split, :failed, :unknown, :empty, :stale
  #                                   #    or :skipped
  #
  # 1. Claim: under the batch's row lock, `pending` -> `submitting` (`submit_started_at`). Anything else is
  #    left alone (:skipped), so a duplicate job does nothing.
  # 2. Each waiting entry is checked: a receipt that left the batch meanwhile (entered by hand, deleted) is
  #    `superseded`; one whose photo is gone from storage fails as a read one at a time would (`image_missing`).
  # 3. The photos go up with the entries' random keys; the answer makes the batch `running` with the provider's
  #    batch id, model, provider, expiry, counts and the estimated cost.
  #
  # When it does not work. The rule: try again only when nothing can have reached the provider, since sending a
  # batch twice pays for it twice and leaves a copy the app cannot delete.
  # - nothing was sent: the service could not be reached at all (the connection was refused or never opened),
  #   or it answered with a code that says nothing went out (RETRYABLE_CODES: OpenRouter unreachable, rate
  #   limited, its model list unreadable). Back to `pending`, tried again after RETRY_WAITS; when they run out,
  #   the batch fails and its receipts are released;
  # - too large (`batch_too_large`, `batch_upload_too_large`): the second half of its entries moves to a new
  #   `pending` batch and both are sent again (one receipt that is still too large fails);
  # - one photo too large for the provider's inline limit (`batch_image_too_large`): that receipt fails, the
  #   rest are sent again;
  # - refused for good (4xx, 501: batch mode switched off, the account's privacy settings, inline images not
  #   allowed): the batch fails with the reason and its receipts are released;
  # - anything else (a connection cut after the upload began, a read timeout, any other 5xx, an answer that
  #   cannot be read, `openrouter_batch_submit_unknown`): the provider may have it, but the app cannot know its
  #   id. The batch becomes `unknown`, its receipts are released, and the batches page says to look for it in
  #   OpenRouter's logs and delete it there.
  #
  # Every change after the claim happens under the batch's row lock and only while it is still `submitting`: the
  # poller gives up on a submission that looks dead (OcrBatches::Check), and a late answer then only records the
  # provider's id, so the batch is deleted upstream (:stale).
  class Submit
    RETRY_WAITS = [ 1.minute, 5.minutes, 15.minutes, 1.hour ].freeze
    SPLIT_CODES = %w[batch_too_large batch_upload_too_large].freeze
    RETRYABLE_CODES = %w[openrouter_unreachable openrouter_rate_limited openrouter_catalogue_unavailable].freeze
    # Failures of the Rails client that happen before a request is written: nothing reached the service.
    NOT_SENT = [ Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL, SocketError,
      Net::OpenTimeout ].freeze
    HELD_STATUSES = %w[uploaded failed].freeze
    IMAGE_KEY = /key ([A-Za-z0-9_-]{16,64})/
    SUPERSEDED_MESSAGE = "A person took the receipt over before the batch was sent."
    UNKNOWN_MESSAGE = "The batch was sent but its answer was lost, so OpenRouter may have accepted it without " \
      "the app knowing its id. Look in the Batches tab of OpenRouter's logs and delete it there if it is listed."
    LATE_MESSAGE = "The batch reached OpenRouter after it was given up for lost; its receipts were released and " \
      "its results are not used. It is deleted at OpenRouter once it ends."

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
      record(status)
    rescue MlClient::ResponseError => error
      refused(error, live)
    rescue MlClient::ConnectionError, MlClient::TimeoutError => error
      not_sent?(error) ? retry_later(error) : lost
    rescue MlClient::InvalidResponse
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

      # Runs the block under the batch's row lock while the batch is still `submitting`; :stale otherwise.
      def while_submitting
        @batch.with_lock { @batch.submitting? ? yield : :stale }
      end

      def not_sent?(error)
        NOT_SENT.any? { |kind| error.cause.is_a?(kind) }
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
            fail_entry(entry, receipt, error.code, error.message)
            nil
          end
        end
      end

      def fail_entry(entry, receipt, code, message)
        ReceiptFailure.record(receipt, code, message)
        entry.resolve!(:failed, code:, message:, now: @now)
      end

      def finish_empty
        while_submitting do
          @batch.update!(state: "finished", finished_at: @now, next_check_at: @now)
          :empty
        end
      end

      def record(status)
        outcome = while_submitting do
          @batch.update!(provider_fields(status).merge(state: "running", checks: 0, next_check_at: @now + Check.interval(0),
            error_code: nil, error_message: nil, check_error_code: nil, check_error_message: nil))
          :submitted
        end
        return outcome unless outcome == :stale

        # Given up for lost meanwhile (its receipts are released): keep the id, so it is deleted upstream.
        @batch.with_lock do
          @batch.update!(provider_fields(status).merge(state: "failed", error_code: "submit_late", error_message: LATE_MESSAGE,
            next_check_at: @now))
        end
        :stale
      end

      def provider_fields(status)
        { provider_batch_id: status.id, provider_status: status.provider_status, model: status.model_name,
          provider: status.provider, submitted_at: @now, expires_at: status.expires_at,
          estimated_cost_usd: status.estimated_cost_usd, cost_usd: status.cost_usd,
          requests_total: status.requests_total, requests_completed: status.requests_completed,
          requests_failed: status.requests_failed }
      end

      def refused(error, live)
        return split(live) if SPLIT_CODES.include?(error.code) && Array(live).size > 1
        return drop_photo(error, live) if error.code == "batch_image_too_large"
        return retry_later(error) if RETRYABLE_CODES.include?(error.code)
        # Any other 5xx (501 aside: a setting, nothing sent) may come after the upload.
        return lost if error.status >= 500 && error.status != 501

        give_up(error.code, error.service_message || error.message)
      end

      def give_up(code, message)
        while_submitting do
          @batch.release!("failed", code, message, now: @now)
          :failed
        end
      end

      def retry_later(error)
        wait = RETRY_WAITS[@batch.submit_attempts]
        return give_up(error.code, "Sending the batch failed #{RETRY_WAITS.size + 1} times: #{error.message}") if wait.nil?

        while_submitting do
          @batch.update!(state: "pending", submit_attempts: @batch.submit_attempts + 1, next_check_at: @now + wait,
            check_error_code: error.code, check_error_message: error.message.to_s.truncate(ReceiptOcrJob::MAX_MESSAGE_LENGTH))
          :retry_later
        end
      end

      def lost
        while_submitting do
          @batch.release!("unknown", "submit_unknown", UNKNOWN_MESSAGE, now: @now)
          :unknown
        end
      end

      # One receipt's photo is over the provider's inline limit: that receipt fails, the others are sent again.
      def drop_photo(error, live)
        key = error.service_message.to_s[IMAGE_KEY, 1]
        entry, = Array(live).find { |candidate, _images| candidate.custom_id == key }
        return give_up(error.code, error.service_message || error.message) unless entry

        while_submitting do
          Receipt.transaction do
            receipt = Receipt.lock.find(entry.receipt_id)
            fail_entry(entry, receipt, error.code, "A photo is larger than the batch provider takes inline; read this " \
              "receipt one at a time instead.")
          end
          @batch.update!(state: "pending", next_check_at: @now)
          :retry_later
        end
      end

      # The second half of the entries goes to a new pending batch with its receipts' holds; both are sent again.
      def split(live)
        moving = live.map(&:first).drop(live.size / 2)
        while_submitting do
          other = OcrBatch.create!(state: "pending", receipts_count: moving.size, next_check_at: @now)
          moving.each_with_index do |entry, index|
            entry.update_columns(ocr_batch_id: other.id, position: index + 1, updated_at: @now)
          end
          Receipt.where(id: moving.map(&:receipt_id), ocr_batch_id: @batch.id).update_all(ocr_batch_id: other.id)
          @batch.update!(state: "pending", receipts_count: @batch.entries.count, next_check_at: @now)
          LiveUpdate.changed(other)
          :split
        end
      end
  end
end
