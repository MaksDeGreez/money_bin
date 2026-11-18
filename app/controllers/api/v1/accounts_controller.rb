module Api
  module V1
    # GET /api/v1/accounts: every account with its booked balance (AccountBalancesQuery).
    class AccountsController < BaseController
      def index
        only_known_parameters
        render json: { accounts: AccountBalancesQuery.new.call.map { |row| AccountSerializer.call(row) } }
      end
    end
  end
end
