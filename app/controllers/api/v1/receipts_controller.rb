module Api
  module V1
    # GET /api/v1/receipts: receipts, newest first, a page at a time (ReceiptsQuery).
    # GET /api/v1/receipts/:id: one receipt with its items. Photos are not served by the API.
    class ReceiptsController < BaseController
      def index
        only_known_parameters(:status, :limit, :cursor)
        query = ReceiptsQuery.new(status: enum_parameter(:status, Receipt.statuses.values))
        page = query.page(limit: limit_parameter, cursor: cursor_parameter)

        render json: { receipts: page.records.map { |receipt| ReceiptSerializer.summary(receipt) }, next_cursor: page.next_cursor }
      end

      def show
        only_known_parameters
        render json: ReceiptSerializer.call(ReceiptsQuery.find(path_id))
      end
    end
  end
end
