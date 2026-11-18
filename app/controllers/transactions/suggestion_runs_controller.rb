module Transactions
  # "Refresh suggestions" on the transactions list: queues TransactionSuggestionsJob, which scores every
  # uncategorised line whose suggestion is missing or from another artefact (Transactions::SuggestCategories). One
  # run at a time.
  class SuggestionRunsController < ApplicationController
    def create
      filter = Transaction::Filter.from_params(params, :filter)
      run = TransactionSuggestionRun.start
      if run.nil?
        flash[:alert] = "Suggestions are already being refreshed."
      elsif enqueue(run)
        flash[:notice] = "Refreshing suggestions. Reload the list to see the progress."
      else
        run.update!(status: "failed", error: "queue_unavailable", finished_at: Time.current)
        flash[:alert] = "The job queue (Redis) cannot be reached. Try again later."
      end
      redirect_to transactions_path(filter.to_params), status: :see_other
    end

    private
      def enqueue(run)
        TransactionSuggestionsJob.new(run).enqueue
      rescue StandardError => error
        Rails.logger.warn("SuggestionRunsController: the queue cannot be reached (#{error.class})")
        false
      end
  end
end
