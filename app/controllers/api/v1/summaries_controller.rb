module Api
  module V1
    # GET /api/v1/summary?from=...&to=...[&currency=...]: expenses and incomes by category, group and month,
    # per currency, booked transactions only, transfers left out (SpendingSummaryQuery).
    class SummariesController < BaseController
      def show
        only_known_parameters(:from, :to, :currency)
        from, to = date_range_parameters(required: true)
        summary = SpendingSummaryQuery.new(from:, to:, currency: currency_parameter(:currency)).call

        render json: SpendingSummarySerializer.call(summary)
      end
    end
  end
end
