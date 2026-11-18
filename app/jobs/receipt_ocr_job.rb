# Reads a receipt's photos with the ML service and stores the result (Receipts::ApplyOcr).
#
#   ReceiptOcrJob.perform_later(receipt)
#
# Nothing enqueues it automatically: the upload flow calls perform_later after it saved the receipt.
#
# - It works on `uploaded`, `processing` (a retry, or a run that died) and `failed` (a manual retry)
#   receipts. It moves the receipt to `processing`, sends its photos in upload order, and
#   Receipts::ApplyOcr moves it to `extracted`.
# - It leaves `extracted` and `reviewed` receipts alone: they already have a result, and a person may be
#   working on it. So running the job twice does the work once.
# - A receipt deleted before the job ran is discarded quietly.
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
  STARTABLE_STATUSES = %w[uploaded processing failed].freeze
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
      receipt.update_columns(status: "failed", ocr_raw: { "error" => reason }, updated_at: Time.current)
    end
  end

  private
    def start(receipt)
      receipt.with_lock do
        next false unless STARTABLE_STATUSES.include?(receipt.status)

        receipt.update_columns(status: "processing", updated_at: Time.current) unless receipt.processing?
        true
      end
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
