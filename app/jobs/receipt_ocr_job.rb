# Reads a receipt's photos with the ML service and stores the result (Receipts::ApplyOcr).
#
#   ReceiptOcrJob.perform_later(receipt)
#
# No model callback enqueues it: Receipts::RequestOcr does, when a receipt page is opened, after an upload,
# and for "Read again" and "Read all". It records the request in `ocr_requested_at`, and the job clears it
# when it starts.
#
# - It works on `uploaded` and `processing` (a retry, or a run that died) receipts, and on a `failed` or
#   `extracted` one only while a request to read it again is recorded. It moves the
#   receipt to `processing`, sends its photos in upload order, and Receipts::ApplyOcr moves it to
#   `extracted`, replacing its items.
# - It leaves other `extracted` receipts and every `reviewed` one alone: they already have a result, and a
#   person may be working on it. So running the job twice does the work once.
# - Once the result is stored, the items get their category suggestions (Receipts::SuggestCategories) in the
#   same job, so they arrive right after the items rather than behind every other queued read. A failure
#   there never fails the receipt: OCR's result stays, the receipt is `extracted` without suggestions and
#   records why (`categoriser_error`); "Suggest categories again" (ReceiptCategoriseJob) can ask later.
# - A receipt deleted before the job ran is discarded quietly.
# - Every change of status is pushed to the open pages (Receipts::LiveUpdate).
#
# Failures:
# - transient (the service cannot be reached, a timeout, a 5xx answer other than 501): retried with a
#   growing wait, ATTEMPTS runs in all; when they run out, the receipt becomes `failed`;
# - permanent (a 4xx or 501 answer, such as 413 image_too_large for a photo over the service's size limit,
#   an invalid answer, no photos, a photo file missing from storage): the receipt becomes `failed` at once.
# A failed receipt keeps the reason in `ocr_raw` as { "error" => { "code", "message" } }: a short code
# (the service's own code, or one of ml_unreachable, ml_timeout, invalid_response, no_images,
# image_missing) and a one-line message. Any other exception is a bug or an infrastructure problem: it is
# raised, Sidekiq's own retries apply, and the receipt stays `processing` until a run succeeds.
#
# The job has its own queue, `receipt_ocr`, worked by a Sidekiq capsule with one thread
# (config/sidekiq.yml): the local OCR model reads one receipt at a time, so parallel jobs would only wait
# for it and run into the client's timeout.
class ReceiptOcrJob < ApplicationJob
  QUEUE = :receipt_ocr
  queue_as QUEUE

  ATTEMPTS = 5
  STARTABLE_STATUSES = %w[uploaded processing].freeze
  # Read again only on request (`ocr_requested_at` set by Receipts::RequestOcr), never by a stray job.
  REQUESTED_STATUSES = %w[failed extracted].freeze
  # Receipt allows HEIF; the ML service only names HEIC, the same container.
  SERVICE_CONTENT_TYPES = { "image/heif" => "image/heic" }.freeze
  MAX_MESSAGE_LENGTH = 300

  # The receipt cannot be read: no photo is attached, or a photo's file is gone from storage.
  class Unprocessable < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  discard_on ActiveJob::DeserializationError
  # Declared before retry_on: Active Job tries the handlers declared last first, so the transient
  # subclasses of MlClient::Error reach retry_on.
  discard_on(MlClient::Error, Unprocessable) { |job, error| job.mark_failed(error) }
  retry_on(MlClient::ConnectionError, MlClient::TimeoutError, MlClient::ServerError,
    attempts: ATTEMPTS, wait: :polynomially_longer) { |job, error| job.mark_failed(error) }

  def perform(receipt)
    return unless start(receipt)

    result = MlClient.new.ocr(images_of(receipt))
    Receipts::ApplyOcr.call(receipt, result)
    suggest_categories(receipt)
  rescue Receipts::ApplyOcr::AlreadyReviewed
    # A person accepted the receipt while the service was reading it; their result wins.
  end

  # Stores the failure on the receipt, unless it was deleted or reviewed in the meantime.
  def mark_failed(error)
    receipt = Receipt.find_by(id: arguments.first&.id)
    return unless receipt

    receipt.with_lock do
      next if receipt.reviewed? || receipt.extracted?

      reason = { "code" => error.code, "message" => error.message.squish.truncate(MAX_MESSAGE_LENGTH) }
      # update_columns: a failure must be recorded even if some other validation of the receipt fails.
      receipt.update_columns(status: "failed", ocr_raw: { "error" => reason }, ocr_requested_at: nil, updated_at: Time.current)
    end
    Receipts::LiveUpdate.changed(receipt)
  end

  private
    # Errors of the ML service are recorded by the service itself; anything else is a bug, reported and recorded
    # here, never raised: a retry of this job would find the receipt read and do nothing.
    def suggest_categories(receipt)
      Receipts::SuggestCategories.call(receipt)
    rescue StandardError => error
      Rails.error.report(error, handled: true, source: "receipt_ocr_job.suggest_categories")
      receipt.update_columns(categoriser_error: "internal_error", categorised_at: Time.current)
    end

    def start(receipt)
      started = receipt.with_lock do
        unless startable?(receipt)
          # A request for a receipt that was accepted in the meantime: nothing is waiting any more.
          receipt.update_columns(ocr_requested_at: nil) if receipt.ocr_pending?
          next false
        end

        receipt.update_columns(status: "processing", ocr_requested_at: nil, updated_at: Time.current)
        true
      end
      Receipts::LiveUpdate.changed(receipt) if started
      started
    end

    # A `failed` or `extracted` receipt is read again only on a request that still waits
    # (Receipts::RequestOcr), never by a stray duplicate job: a failed receipt stays failed, and a read result
    # is not replaced unasked. A request older than a day counts as lost, as the page shows it: a job that
    # runs after that leaves the receipt alone, and the person can ask again.
    def startable?(receipt)
      STARTABLE_STATUSES.include?(receipt.status) ||
        (REQUESTED_STATUSES.include?(receipt.status) && receipt.ocr_request_waiting?)
    end

    # The photos in upload order, read into memory (at most three phone photos).
    def images_of(receipt)
      attachments = receipt.images_attachments.includes(:blob).order(:id).to_a
      raise Unprocessable.new("no_images", "the receipt has no photos") if attachments.empty?

      attachments.map do |attachment|
        blob = attachment.blob
        MlClient::Image.new(io: StringIO.new(blob.download), filename: blob.filename.to_s,
          content_type: SERVICE_CONTENT_TYPES.fetch(blob.content_type, blob.content_type))
      end
    rescue ActiveStorage::FileNotFoundError
      raise Unprocessable.new("image_missing", "a photo of the receipt is missing from storage")
    end
end
