module OcrBatches
  # One round of the poller (OcrBatchPollJob): every batch the app still follows (OcrBatch.followed) whose
  # `next_check_at` has come gets one OcrBatches::Check. A `pending` one is handed to OcrBatchSubmitJob instead.
  #
  #   OcrBatches::Poll.call  # => the number of batches checked
  #
  # A check that fails is recorded on its batch (`check_error_code`, `check_error_message`) and tried again later,
  # with the same growing wait; one batch's failure never stops the others. An error of the ML service is
  # expected (the service is down, batch mode was switched off); anything else is a bug and is also reported.
  #
  # A batch without a successful check for GIVE_UP_AFTER (the longest provider window is four days) is given up:
  # its waiting receipts are released, and it stays on the list only to be deleted upstream once that works.
  module Poll
    ERROR_WAIT = 5.minutes
    GIVE_UP_AFTER = 5.days

    module_function

    def call(client: MlClient.new, now: Time.current)
      submit = false
      checked = 0
      OcrBatch.followed.due(now).order(:next_check_at, :id).each do |batch|
        if batch.pending?
          submit = true
          next
        end
        checked += 1
        check(batch, client, now)
      end
      OcrBatchSubmitJob.perform_later if submit
      checked
    end

    def check(batch, client, now)
      Check.call(batch, client:, now:)
    rescue StandardError => error
      Rails.error.report(error, handled: true, source: "ocr_batches.poll") unless error.is_a?(MlClient::Error)
      code = error.respond_to?(:code) ? error.code : "internal_error"
      message = error.is_a?(MlClient::Error) ? error.message : "An error in the app (reported)."
      batch.reload.update_columns(check_error_code: code, check_error_message: message.truncate(ReceiptOcrJob::MAX_MESSAGE_LENGTH),
        checks: batch.checks + 1,
        next_check_at: now + [ Check.interval(batch.checks + 1), ERROR_WAIT ].max, updated_at: now)
      give_up(batch, message, now)
      LiveUpdate.changed(batch)
    end

    def give_up(batch, message, now)
      return unless %w[running applying].include?(batch.state)
      # `last_checked_at` is the last check that worked (a failed one leaves it).
      return if (batch.last_checked_at || batch.submitted_at || batch.created_at) > now - GIVE_UP_AFTER

      ApplyResults.follow_up(batch, now:)
      batch.release!("failed", "batch_abandoned", "The batch could not be followed for #{GIVE_UP_AFTER.inspect} " \
        "(last problem: #{message}); its waiting receipts were released. It is deleted at OpenRouter once that works.",
        now:)
    end
  end
end
