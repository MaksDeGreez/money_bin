module OcrBatches
  # Stores the results of a completed batch, entry by entry (docs/domain.md, "OCR in a batch").
  #
  #   OcrBatches::ApplyResults.call(batch, MlClient.new.ocr_batch_results(batch.provider_batch_id))
  #
  # Each waiting entry is resolved in its own database transaction, with the entry row and then the receipt row
  # locked, so a poll that runs twice, or dies half way, never applies a result twice and never loses one: an
  # entry is either still `waiting` (the next poll does it) or resolved, together with its receipt's change.
  #
  # For each entry:
  # - the receipt is no longer held by this batch, or is not `uploaded`/`failed` any more (a person entered it by
  #   hand, or it was deleted): `superseded`, the result is not used. The person's work wins;
  # - an answer: stored exactly as a read one at a time stores it (Receipts::ApplyOcr: fields, items, status
  #   `extracted`, `ocr_raw` with the model and prompt), the hold taken off: `applied`. Then the same follow-up
  #   step as after a read one at a time, the category suggestions (Receipts::SuggestCategories), runs through
  #   ReceiptCategoriseJob on the OCR capsule's queue, one receipt at a time, so thousands of results do not
  #   hold up the poller and a local categoriser reads one receipt at a time as it always does;
  # - an answer that needs the repair pass (`ocr_parse_failed` with `retry_sync`), while the batch has handed
  #   fewer than `handoff_limit` receipts over: `sync_queued`, the receipt is read again one at a time through
  #   the normal queue (Receipts::RequestOcr, after the commit). Above the limit something systematic is wrong
  #   (a model that cannot follow the schema), and reading hundreds again at full price is not done unasked:
  #   those fail like the next case;
  # - any other error, or no result for the key: the receipt is `failed` with the reason (as a read one at a
  #   time records it), `failed`. "Read again" or "Read all" can try it one at a time.
  # An unexpected error on one entry (a bug) is reported, the entry is `released` and the receipt left as it
  # was; the others go on.
  #
  # The follow-ups (the categorise job of an `applied` entry, the read one at a time of a `sync_queued` one) are
  # queued from the stored entries, not from this run's memory (`follow_up`), and each entry records that its
  # follow-up was queued (`followed_up_at`). A run that died between storing a result and queuing its
  # follow-up leaves the entry unmarked, and the next run (or the next check of the still `applying` batch)
  # queues it then: at least once, and a duplicate is harmless (the categoriser refreshes suggestions; the
  # read one at a time is queued once per receipt by Receipts::RequestOcr).
  class ApplyResults
    HELD_STATUSES = %w[uploaded failed].freeze
    SUPERSEDED_MESSAGE = "A person took the receipt over while it waited in the batch; the batch's result was not used."
    MISSING_MESSAGE = "The provider returned no result for this receipt."
    SYNC_HINT = " Reading it one at a time (Read again) may work."

    # The most receipts of one batch handed to the normal queue for a repair pass.
    def self.handoff_limit(receipts)
      [ 5, (receipts * 0.1).ceil ].max
    end

    def self.call(batch, results, now: Time.current)
      new(batch, results, now:).call
    end

    # Queues the follow-ups of the batch's resolved entries that have none yet, and marks each entry whose
    # follow-up was queued. Returns how many are still to do (a queue that cannot be reached leaves them).
    def self.follow_up(batch, now: Time.current)
      pending = batch.entries.where(state: OcrBatchEntry::FOLLOWED_UP_STATES, followed_up_at: nil).unscope(:order)
      suggest_categories(pending.where(state: "applied"), now)
      read_one_at_a_time(pending.where(state: "sync_queued"), now)
      pending.count
    end

    # One ReceiptCategoriseJob per receipt (the same Receipts::SuggestCategories step as after a read one at a
    # time), each entry marked once its job is queued. With suggestions switched off there is nothing to queue.
    def self.suggest_categories(entries, now)
      entries.order(:id).each do |entry|
        if ItemSuggestions.enabled? && (receipt = entry.receipt)
          ReceiptCategoriseJob.perform_later(receipt)
        end
        entry.update_columns(followed_up_at: now)
      end
    rescue StandardError => error
      # The rest stay unmarked and are queued by a later run.
      Rails.logger.warn("OcrBatches::ApplyResults: category suggestions could not be queued (#{error.class})")
    end

    # The receipts go to the normal queue in id order (the order every multi-row claim of these receipts locks
    # them in). RequestOcr skips one a person took over meanwhile, and queues each receipt once.
    def self.read_one_at_a_time(entries, now)
      ids = entries.pluck(:receipt_id).compact
      Receipts::RequestOcr.read_all(Receipt.where(id: ids).order(:id)) if ids.any?
      entries.update_all(followed_up_at: now)
    rescue Receipts::RequestOcr::QueueUnavailable
      # Unmarked: the next run queues them again (a receipt already queued is not queued twice).
      Rails.logger.warn("OcrBatches::ApplyResults: #{ids.size} receipt(s) could not be queued for a read one at a time")
    end

    def initialize(batch, results, now:)
      @batch = batch
      @results = results.results.index_by { |item| item["key"] }
      @now = now
    end

    # Returns the counts of the outcomes of this run.
    def call
      outcomes = Hash.new(0)
      @batch.entries.where(state: "waiting").to_a.each do |entry|
        outcomes[apply(entry)] += 1
      rescue StandardError => error
        Rails.error.report(error, handled: true, source: "ocr_batches.apply_results", context: { entry: entry.id })
        release(entry)
        outcomes[:released] += 1
      end
      self.class.follow_up(@batch, now: @now)
      outcomes
    end

    private
      def apply(entry)
        Receipt.transaction { decide(entry) }
      end

      def decide(entry)
        entry.lock!
        return :skipped unless entry.waiting?

        receipt = entry.receipt_id && Receipt.lock.find_by(id: entry.receipt_id)
        return supersede(entry, receipt) unless held?(receipt)

        item = @results[entry.custom_id]
        cost = cost_of(item)
        if item.nil?
          fail_receipt(entry, receipt, "batch_result_missing", MISSING_MESSAGE + SYNC_HINT, cost)
        elsif item["status"] == "ok"
          Receipts::ApplyOcr.call(receipt, MlClient::Batches.ocr_result(item))
          receipt.update_columns(ocr_batch_id: nil)
          entry.resolve!(:applied, cost_usd: cost, now: @now)
          :applied
        else
          failed(entry, receipt, item["error"], cost)
        end
      end

      def held?(receipt)
        receipt.present? && receipt.ocr_batch_id == @batch.id && HELD_STATUSES.include?(receipt.status)
      end

      def supersede(entry, receipt)
        receipt.update_columns(ocr_batch_id: nil) if receipt&.ocr_batch_id == @batch.id
        entry.resolve!(:superseded, code: "superseded", message: SUPERSEDED_MESSAGE, now: @now)
        :superseded
      end

      def failed(entry, receipt, error, cost)
        code = error["code"].to_s.presence || "batch_request_failed"
        message = error["message"].to_s
        if error["retry_sync"] == true && code == "ocr_parse_failed" && handoff_left?
          receipt.update_columns(ocr_batch_id: nil)
          entry.resolve!(:sync_queued, code:, message:, cost_usd: cost, now: @now)
          return :sync_queued
        end
        fail_receipt(entry, receipt, code, error["retry_sync"] == true ? message + SYNC_HINT : message, cost)
      end

      def fail_receipt(entry, receipt, code, message, cost)
        ReceiptFailure.record(receipt, code, message)
        entry.resolve!(:failed, code:, message:, cost_usd: cost, now: @now)
        :failed
      end

      # Counted from the stored entries, so a second run of the same results keeps to the same limit.
      def handoff_left?
        @batch.entries.where(state: "sync_queued").count < self.class.handoff_limit(@batch.receipts_count)
      end

      def cost_of(item)
        value = item&.dig("cost_usd")
        BigDecimal(value) if value.is_a?(String) && value.match?(/\A[0-9]+(\.[0-9]+)?\z/)
      end

      def release(entry)
        Receipt.transaction do
          entry.lock!
          next unless entry.waiting?

          Receipt.where(id: entry.receipt_id, ocr_batch_id: @batch.id).update_all(ocr_batch_id: nil)
          entry.resolve!(:released, code: "internal_error",
            message: "The result could not be stored (an error in the app, reported); the receipt is as it was.",
            now: @now)
        end
      end
  end
end
