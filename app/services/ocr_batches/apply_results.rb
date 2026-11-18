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

    def initialize(batch, results, now:)
      @batch = batch
      @results = results.results.index_by { |item| item["key"] }
      @now = now
    end

    # Returns the counts of the outcomes of this run.
    def call
      outcomes = Hash.new(0)
      applied = []
      sync = []
      @batch.entries.where(state: "waiting").to_a.each do |entry|
        outcome = apply(entry)
        outcomes[outcome] += 1
        applied << entry.receipt_id if outcome == :applied
        sync << entry.receipt_id if outcome == :sync_queued
      rescue StandardError => error
        Rails.error.report(error, handled: true, source: "ocr_batches.apply_results", context: { entry: entry.id })
        release(entry)
        outcomes[:released] += 1
      end
      suggest_categories(applied)
      read_one_at_a_time(sync)
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

      def suggest_categories(ids)
        return if ids.empty? || !ItemSuggestions.enabled?

        Receipt.where(id: ids).find_each { |receipt| ReceiptCategoriseJob.perform_later(receipt) }
      rescue StandardError => error
        # The receipts keep their items without suggestions; "Suggest categories again" fills them later.
        Rails.logger.warn("OcrBatches::ApplyResults: category suggestions could not be queued (#{error.class})")
      end

      def read_one_at_a_time(ids)
        Receipts::RequestOcr.read_all(Receipt.where(id: ids)) if ids.any?
      rescue Receipts::RequestOcr::QueueUnavailable
        # Left `uploaded`/`failed` and out of the batch: "Read all in this filter" picks them up.
        Rails.logger.warn("OcrBatches::ApplyResults: #{ids.size} receipt(s) could not be queued for a read one at a time")
      end
  end
end
