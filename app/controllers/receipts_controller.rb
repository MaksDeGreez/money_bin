# The receipts: the list with its filter, one receipt with its photos and its review form, the upload, OCR
# requests (docs/domain.md, "Who enqueues OCR"), saving and accepting a review and saving it as ground truth
# (Receipts::Review), and "Enter by hand" (Receipts::EnterByHand).
#
# The list filter lives in the URL (Receipt::Filter). A receipt page carries the same parameters, so its
# previous / next links walk the filtered list and "Back" returns to it.
#
# Opening the page of a receipt that was never read (`uploaded`) queues OCR, once
# (Receipts::RequestOcr.first_read). A prefetch is not an opening: Turbo's link prefetch and the browser's
# speculative loads send `Sec-Purpose: prefetch`, and a HEAD request shows nothing, so neither queues OCR.
class ReceiptsController < ApplicationController
  PREFETCH_HEADERS = %w[HTTP_SEC_PURPOSE HTTP_X_SEC_PURPOSE HTTP_PURPOSE].freeze
  GROUND_TRUTH_NOTICES = {
    created: "Saved as ground truth.", replaced: "Saved as ground truth: the earlier record is replaced.",
    unchanged: "Saved. The ground truth already said exactly this, so it is unchanged."
  }.freeze
  QUEUE_UNAVAILABLE = "OCR could not be queued: the job queue (Redis) cannot be reached. Try again later."

  before_action :set_filter, only: %i[ index show read_all update enter_by_hand ]
  before_action :set_receipt, only: %i[ show read update enter_by_hand ]

  def index
    @pagination = Pagination.new(@filter.scope, page: params[:page])
    @receipts = @pagination.records.with_attached_images.includes(:ledger_transaction, :ground_truths)
      .select("receipts.*", "(SELECT COUNT(*) FROM receipt_items WHERE receipt_items.receipt_id = receipts.id) AS items_count")
    @status_counts = @filter.status_counts
    @truth_counts = @filter.truth_counts
    @check_counts = @filter.check_counts
    @progress = @filter.labelling_progress
    @readable_count = Receipts::RequestOcr.readable(@filter.scope.unscope(:order)).count
    @batches = Receipt::Filter.batches
  end

  def show
    request_first_read unless prefetch? || request.head?
    flash.now[:alert] = @queue_unavailable if @queue_unavailable
    @previous_id, @next_id = @filter.neighbours(@receipt)
    # Right after "Save as ground truth": the next receipt to label, and how far labelling is in this list.
    if params[:labelled].present?
      @next_to_label_id = @filter.next_to_label(@receipt)
      @progress = @filter.labelling_progress
    end
    # The account chosen before a Save (the redirect carries it), so a later Accept books where the person said.
    @chosen_account = Account.active.find_by(id: params[:account]) if params[:account].present?
  end

  # Saves the review form ("Save"), or saves and books it ("Accept", "Accept again": intent=accept). A refusal
  # renders the page again with the person's values and the reasons, never a blank form.
  def update
    @review = Receipts::Review.new(@receipt, review_params, intent: params[:intent])
    if @review.call
      if @review.ground_truth
        # The account chosen on the form stays chosen, as after a Save.
        redirect_to receipt_path(@receipt, @filter.to_params.merge(labelled: 1, account: @review.account&.id).compact), status: :see_other,
          notice: GROUND_TRUTH_NOTICES.fetch(@review.ground_truth.status)
      elsif @review.transaction
        redirect_to transaction_path(@review.transaction, @filter.to_params.merge(accepted: 1)), status: :see_other,
          notice: "Accepted into the ledger."
      else
        redirect_to receipt_path(@receipt, @filter.to_params.merge(account: @review.account&.id).compact), status: :see_other,
          notice: "Saved."
      end
    else
      @previous_id, @next_id = @filter.neighbours(@receipt)
      render :show, status: (@review.conflict? ? :conflict : :unprocessable_content)
    end
  end

  # "Enter by hand": a failed or unread receipt opens in the review form, empty, for a person to type.
  def enter_by_hand
    Receipts::EnterByHand.call(@receipt)
    redirect_to receipt_path(@receipt, @filter.to_params), status: :see_other, notice: "Type the receipt in below."
  rescue Receipts::EnterByHand::NotAllowed => error
    redirect_to receipt_path(@receipt, @filter.to_params), status: :see_other, alert: "Not entered by hand: #{error.message}."
  end

  def new
    @receipt = Receipt.new
  end

  def create
    @receipt = Receipt.new(receipt_params)
    if @receipt.save
      queued = queue { Receipts::RequestOcr.first_read(@receipt) }
      if queued
        redirect_to @receipt, status: :see_other, notice: "Uploaded. OCR is queued; this page updates when it is done."
      else
        redirect_to @receipt, status: :see_other, alert: "Uploaded. #{@queue_unavailable}"
      end
    else
      @duplicate = Receipt.find_by(sha256: @receipt.sha256) if @receipt.errors.include?(:sha256) && @receipt.sha256.present?
      render :new, status: :unprocessable_content
    end
  end

  # "Read again": a failed receipt, an extracted one (its items are replaced), or one stuck in processing.
  # Never a reviewed one, and nothing while a request is already waiting.
  def read
    queued = @receipt.reviewed? ? [] : queue { Receipts::RequestOcr.read_again(@receipt) }
    if queued.nil?
      flash[:alert] = @queue_unavailable
    elsif queued.any?
      flash[:notice] = "Queued to read again. This page updates when it is done."
    elsif @receipt.reviewed?
      flash[:alert] = "This receipt is accepted into the ledger, so it is not read again."
    else
      flash[:alert] = "Not queued: the receipt is #{@receipt.reload.status}#{' and already queued' if @receipt.ocr_pending?}."
    end
    # Back to the page the button was on, with its filter; the receipt page itself when there is no usable
    # referrer (redirect_back_or_to never leaves the app).
    redirect_back_or_to receipt_path(@receipt), status: :see_other
  end

  # "Read all in this filter": every unread receipt the filter shows (all pages), and every failed one
  # without items, except those already queued.
  def read_all
    queued = queue { Receipts::RequestOcr.read_all(@filter.scope) }
    if queued.nil?
      flash[:alert] = @queue_unavailable
    elsif queued.any?
      flash[:notice] = "Queued #{helpers.pluralize(queued.size, 'receipt')} for OCR. The OCR model reads one receipt " \
        "at a time, so this can take a long while; the list updates as they finish."
    else
      flash[:alert] = "Nothing to queue: no receipt in this filter is waiting to be read."
    end
    redirect_to receipts_path(@filter.to_params), status: :see_other
  end

  private
    def set_filter
      @filter = Receipt::Filter.new(params.slice(*Receipt::Filter::KEYS).permit(*Receipt::Filter::KEYS).to_h)
    end

    def set_receipt
      @receipt = Receipt.with_attached_images.find(params[:id])
    end

    def receipt_params
      params.fetch(:receipt, {}).permit(:batch, images: [])
    end

    def review_params
      params.fetch(:receipt, {}).permit(*Receipts::Review.permitted_params)
    end

    def request_first_read
      return unless @receipt.uploaded?

      queue { Receipts::RequestOcr.first_read(@receipt) }
      @receipt.reload
    end

    # The ids queued, or nil when the queue cannot be reached (@queue_unavailable then holds the message,
    # with how many were queued before it stopped).
    def queue
      yield
    rescue Receipts::RequestOcr::QueueUnavailable => error
      @queue_unavailable = QUEUE_UNAVAILABLE
      @queue_unavailable += " #{helpers.pluralize(error.queued.size, 'receipt')} were queued before it stopped." if error.queued.any?
      nil
    end

    def prefetch?
      PREFETCH_HEADERS.any? { |header| request.get_header(header).to_s.downcase.include?("prefetch") }
    end
end
