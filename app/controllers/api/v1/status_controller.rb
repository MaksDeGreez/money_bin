module Api
  module V1
    # GET /api/v1/status: a cheap call that tells an agent its token works and what it may do.
    class StatusController < BaseController
      def show
        only_known_parameters
        render json: { status: "ok", token: { name: Current.api_token.name, scope: Current.api_token.scope } }
      end
    end
  end
end
