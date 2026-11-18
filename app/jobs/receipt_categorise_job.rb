# Asks for fresh category suggestions for a receipt's items, without reading it again
# ("Suggest categories again" on the receipt page; Receipts::SuggestCategories does the work).
#
#   ReceiptCategoriseJob.perform_later(receipt)
#
# Its queue, `receipt_categorise`, is worked by the OCR capsule's one thread, before `receipt_ocr`
# (config/sidekiq.yml): the local model categorises one receipt at a time, between two reads. The service
# records a failure of the ML service on the receipt instead of raising, so the job is not retried for it; a
# receipt that was deleted, accepted or read again meanwhile is left alone.
class ReceiptCategoriseJob < ApplicationJob
  QUEUE = :receipt_categorise
  queue_as QUEUE

  discard_on ActiveJob::DeserializationError

  def perform(receipt)
    Receipts::SuggestCategories.call(receipt)
  end
end
