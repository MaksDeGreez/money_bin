# Scores every uncategorised transaction line with the transaction categoriser ("Refresh suggestions" on the
# transactions list; Transactions::SuggestCategories does the work and records the run).
#
#   run = TransactionSuggestionRun.start and TransactionSuggestionsJob.perform_later(run)
#
# The default queue: the transaction categoriser runs in the ML service apart from the OCR model's worker thread.
# A failure of the service is recorded on the run, not raised, so the job is not retried for it.
class TransactionSuggestionsJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(run)
    return if run.finished?

    Transactions::SuggestCategories.call(run)
  end
end
