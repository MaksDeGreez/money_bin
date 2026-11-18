# The receipts: the list with its filter, one receipt with its photos and stored data (read-only for now),
# the upload, and OCR requests (docs/domain.md, "Who enqueues OCR").
#
# The list filter lives in the URL (Receipt::Filter). A receipt page carries the same parameters, so its
# previous / next links walk the filtered list and "Back" returns to it.
#
# Opening the page of a receipt that was never read (`uploaded`) queues OCR, once
# (Receipts::RequestOcr.first_read). A prefetch is not an opening: Turbo's link prefetch and the browser's
# speculative loads send `Sec-Purpose: prefetch`, and a HEAD request shows nothing, so neither queues OCR.
class ReceiptsController < ApplicationController
  PREFETCH_HEADERS = %w[HTTP_SEC_PURPOSE HTTP_X_SEC_PURPOSE HTTP_PURPOSE].freeze
  QUEUE_UNAVAILABLE = "OCR could not be queued: the job queue (Redis) cannot be reached. Try again later."

  before_action :set_filter, only: %i[ index show read_all ]
  before_action :set_receipt, only: %i[ show read ]

  def index
    @pagination = Pagination.new(@filter.scope, page: params[:page])
    @receipts = @pagination.records.with_attached_images.includes(:ledger_transaction)
      .select("receipts.*", "(SELECT COUNT(*) FROM receipt_items WHERE receipt_items.receipt_id = receipts.id) AS items_count")
    @status_counts = @filter.status_counts
    @readable_count = Receipts::RequestOcr.readable(@filter.scope.unscope(:order)).count
    @batches = Receipt::Filter.batches
  end

  def show
    request_first_read unless prefetch? || request.head?
    flash.now[:alert] = QUEUE_UNAVAILABLE if @queue_unavailable
    @previous_id, @next_id = @filter.neighbours(@receipt)
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
        redirect_to @receipt, status: :see_other, alert: "Uploaded. #{QUEUE_UNAVAILABLE}"
      end
    else
      @duplicate = Receipt.find_by(sha256: @receipt.sha256) if @receipt.errors.include?(:sha256) && @receipt.sha256.present?
      render :new, status: :unprocessable_content
    end
  end

  # "Read again": a failed receipt, or an extracted one (its items are replaced). Never a reviewed one,
  # and nothing while a request is already waiting or the receipt is being read.
  def read
    queued = @receipt.reviewed? ? [] : queue { Receipts::RequestOcr.read_again(@receipt) }
    if queued.nil?
      flash[:alert] = QUEUE_UNAVAILABLE
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

  # "Read all in this filter": every uploaded or failed receipt the filter shows (all pages), except those
  # already queued.
  def read_all
    queued = queue { Receipts::RequestOcr.read_all(@filter.scope) }
    if queued.nil?
      flash[:alert] = QUEUE_UNAVAILABLE
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

    def request_first_read
      return unless @receipt.uploaded?

      queue { Receipts::RequestOcr.first_read(@receipt) }
      @receipt.reload
    end

    # The ids queued, or nil when the queue cannot be reached.
    def queue
      yield
    rescue Receipts::RequestOcr::QueueUnavailable
      @queue_unavailable = true
      nil
    end

    def prefetch?
      PREFETCH_HEADERS.any? { |header| request.get_header(header).to_s.downcase.include?("prefetch") }
    end
end
