module Transactions
  # "Accept suggestions at or above N %" for the transactions list's current filter (BulkAcceptance): POST makes the
  # preview (a snapshot of what would be accepted), the page shows it per category, PATCH confirms it and queues
  # BulkAcceptanceJob, whose progress the same page follows live. DELETE drops a preview nobody confirmed. A failed
  # run can be resumed (PATCH again); the items already handled are never applied twice.
  class BulkAcceptancesController < ApplicationController
    QUEUE_UNAVAILABLE = "The job queue (Redis) cannot be reached. Try again later.".freeze

    def create
      filter = Transaction::Filter.from_params(params, :filter)
      threshold = Integer(params[:threshold_percent].to_s, 10, exception: false)
      unless threshold&.between?(1, 100)
        redirect_to transactions_path(filter.to_params), status: :see_other, alert: "The threshold is a whole percent from 1 to 100."
        return
      end

      acceptance = BulkAcceptance.preview!(filter:, threshold_percent: threshold)
      redirect_to transactions_bulk_acceptance_path(acceptance), status: :see_other
    end

    def show
      @acceptance = BulkAcceptance.find(params[:id])
      @filter = Transaction::Filter.new(@acceptance.filter)
    end

    # Confirm a preview, or resume a failed run.
    def update
      acceptance = BulkAcceptance.find(params[:id])
      if acceptance.confirm! || acceptance.resume!
        if enqueue(acceptance)
          flash[:notice] = "Accepting #{helpers.pluralize(acceptance.total_count, 'transaction')}' suggestions; this page follows it."
        else
          acceptance.update!(status: "failed", error: "queue_unavailable")
          flash[:alert] = QUEUE_UNAVAILABLE
        end
      else
        flash[:alert] = "Already confirmed: it is applied once."
      end
      redirect_to transactions_bulk_acceptance_path(acceptance), status: :see_other
    end

    def destroy
      acceptance = BulkAcceptance.find(params[:id])
      filter = Transaction::Filter.new(acceptance.filter)
      deleted = acceptance.with_lock { acceptance.previewed? && acceptance.destroy }
      flash[:alert] = "Only a preview nobody confirmed can be dropped." unless deleted
      redirect_to transactions_path(filter.to_params), status: :see_other
    end

    private
      def enqueue(acceptance)
        BulkAcceptanceJob.new(acceptance).enqueue
      rescue StandardError => error
        Rails.logger.warn("BulkAcceptancesController: the queue cannot be reached (#{error.class})")
        false
      end
  end
end
