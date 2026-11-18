# Sends pending OCR batches to the ML service, one batch per run (OcrBatches::Submit), then queues itself again
# while another pending batch is due. One run at a time across processes (OcrBatches::Exclusive): each batch
# uploads up to 150 MB of photos, and OpenRouter limits how many batches an account runs at once, so batches go
# out one after the other. A duplicate job finds the lock taken, or no pending batch, and does nothing.
#
#   OcrBatchSubmitJob.perform_later
#
# Queued by OcrBatches::Create and by the poller when a pending batch is due (after a retry wait, or when a
# queued job was lost). It never retries a submission itself: OcrBatches::Submit decides, and a raised error
# (a bug) leaves the batch `submitting`, which the poller turns into `unknown` once it is stale.
class OcrBatchSubmitJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform
    OcrBatches::Exclusive.run(:submit) do
      batch = OcrBatch.pending.due.order(:id).first
      next unless batch

      OcrBatches::Submit.call(batch)
      self.class.perform_later if OcrBatch.pending.due.exists?
    end
    OcrBatchPollJob.ensure_scheduled
  end
end
