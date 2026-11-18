# OCR batches (docs/domain.md, "OCR in a batch"): the list with each batch's state, counts, costs and times; one
# batch with what became of its receipts; and "Read in a batch" for the receipts of a list filter, with its
# confirmation (number, estimated cost, the wait, what the provider keeps).
#
# The receipts list asks for `offer` in a lazy Turbo Frame, so the list never waits for the ML service: the
# button appears only when the service says batch mode is available and the filter has receipts to send.
# Opening the batches page, and the offer, start the poller if it is not running (OcrBatchPollJob).
class OcrBatchesController < ApplicationController
  RELEASED_MESSAGE = "Released by hand: the waiting receipts were taken out of the batch, and its results are " \
    "not used. It is deleted at OpenRouter once it ends there."
  before_action :set_filter, only: %i[ offer new create ]
  before_action :set_batch, only: %i[ show check release ]

  def index
    OcrBatchPollJob.ensure_scheduled
    @pagination = Pagination.new(OcrBatch.newest_first, page: params[:page])
    @batches = @pagination.records
    @capability = OcrBatches::Availability.current
  end

  def show
    @entry_counts = @batch.entry_counts
    @problems = @batch.entries.where.not(state: %w[waiting applied]).includes(:receipt).limit(200)
  end

  # The "Read in a batch" button for the receipts list (a Turbo Frame), or nothing.
  def offer
    OcrBatchPollJob.ensure_scheduled
    @count = sendable.count
    @capability = OcrBatches::Availability.current if @count.positive?
    render layout: false
  end

  # The confirmation: how many receipts, how many batches, the estimated cost, the wait, the retention.
  def new
    @capability = OcrBatches::Availability.current(fresh: true)
    @count = sendable.count
    @images = ActiveStorage::Attachment.where(record_type: "Receipt", name: "images", record_id: sendable.select(:id)).count
    @batches_needed = (@count.to_f / @capability.max_receipts.clamp(1, 100)).ceil
    return unless @capability.available && @count.positive?

    @estimate = MlClient.new.estimate_ocr_batch(receipts: @count, images: @images)
  rescue MlClient::Error => error
    @estimate_error = error.message
  end

  def create
    capability = OcrBatches::Availability.current(fresh: true)
    unless capability.available
      redirect_to receipts_path(@filter.to_params), status: :see_other,
        alert: "Not sent: batch mode is not available (#{capability.message})"
      return
    end

    batches = OcrBatches::Create.call(@filter.scope, capability:)
    if batches.empty?
      redirect_to receipts_path(@filter.to_params), status: :see_other,
        alert: "Nothing to send: no receipt in this filter is waiting to be read."
    else
      receipts = batches.sum(&:receipts_count)
      redirect_to ocr_batches_path, status: :see_other,
        notice: "#{helpers.pluralize(receipts, 'receipt')} in #{helpers.pluralize(batches.size, 'batch')} will be " \
          "sent to be read. Results can take up to a day; the receipts update when they arrive."
    end
  end

  # "Check now": the batch is due at once, and a new polling chain starts.
  def check
    @batch.update_columns(next_check_at: Time.current) if OcrBatch.followed.exists?(@batch.id)
    OcrBatchPollJob.restart if OcrBatch.followed.exists?
    redirect_back_or_to ocr_batch_path(@batch), status: :see_other, notice: "Checking now. This page updates when it is done."
  end

  # "Release the receipts": the owner takes the waiting receipts out of a batch that is stuck (batch mode was
  # switched off, the service cannot follow it) or no longer wanted. They go back to what they were; the batch
  # fails, its results are not used, and it is deleted at OpenRouter once it ends there. Not while it is being
  # sent: whether OpenRouter has it is not known yet.
  def release
    released = @batch.with_lock do
      # Checked under the lock: the submitter claims a pending batch under the same lock.
      next false unless @batch.unfinished? && !@batch.submitting?

      @batch.release!("failed", "released_by_owner", RELEASED_MESSAGE)
      true
    end
    if released
      OcrBatches::ApplyResults.follow_up(@batch)
      OcrBatches::LiveUpdate.changed(@batch)
      OcrBatchPollJob.ensure_scheduled
      redirect_to ocr_batch_path(@batch), status: :see_other, notice: "The waiting receipts were released."
    else
      redirect_to ocr_batch_path(@batch), status: :see_other, alert: "Nothing to release: the batch is #{@batch.state}."
    end
  end

  private
    def set_filter
      @filter = Receipt::Filter.new(params.slice(*Receipt::Filter::KEYS).permit(*Receipt::Filter::KEYS).to_h)
    end

    def set_batch
      @batch = OcrBatch.find(params[:id])
    end

    # The receipts of the filter that "Read in a batch" would send: those "Read all" would queue, with photos.
    def sendable
      photos = ActiveStorage::Attachment.where(record_type: "Receipt", name: "images").select(:record_id)
      Receipts::RequestOcr.readable(@filter.scope.unscope(:order)).where(id: photos)
    end
end
