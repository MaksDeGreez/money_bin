module Api
  module V1
    # GET /api/v1/transactions: the ledger, filtered, newest first, a page at a time (TransactionsQuery).
    # GET /api/v1/transactions/:id: one transaction.
    class TransactionsController < BaseController
      FILTERS = %i[from to account_id category_id status payee_id q source].freeze

      def index
        only_known_parameters(*FILTERS, :limit, :cursor)
        page = TransactionsQuery.new(**filters).page(limit: limit_parameter, cursor: cursor_parameter)

        render json: { transactions: page.records.map { |transaction| TransactionSerializer.call(transaction) },
          next_cursor: page.next_cursor }
      end

      def show
        only_known_parameters
        render json: TransactionSerializer.call(TransactionsQuery.find(path_id))
      end

      private
        def filters
          from, to = date_range_parameters
          {
            from:, to:,
            account_id: id_parameter(:account_id, Account),
            category_id: id_parameter(:category_id, Category),
            status: enum_parameter(:status, Transaction.statuses.values),
            payee_id: id_parameter(:payee_id, Payee),
            q: text_parameter(:q),
            source: enum_parameter(:source, Transaction.sources.values)
          }
        end
    end
  end
end
