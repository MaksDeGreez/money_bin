module Api
  # The base of every REST API controller.
  #
  # Authentication: a personal API token in `Authorization: Bearer <token>` (ApiToken). Nothing else
  # counts: this is an ActionController::API, which has no cookie or session support, so a signed-in
  # browser gets no access here. Because no cookie is ever used, there is no cross-site request forgery
  # to guard against, and the API has no CSRF check.
  #
  # Scope: a `read` token may use the safe methods (GET, HEAD, OPTIONS); anything else needs `read_write`.
  #
  # Every error has one shape: {"error": {"code": "...", "message": "..."}}.
  # - 401 `unauthorized`: no bearer token; 401 `invalid_token`: an unknown, malformed or revoked token
  #   (one answer for all three, so a caller learns nothing about which). Both carry `WWW-Authenticate`.
  # - 403 `insufficient_scope`: a read token on a method that changes data.
  # - 404 `not_found` and 400 `bad_request` for the subclasses' missing records and required parameters.
  # - 422 `invalid_parameter` for a query parameter that is unknown, malformed or names nothing
  #   (Api::QueryParameters), and for a cursor the API did not hand out.
  #
  # On success Current.api_token is set (Current.user is its owner), and its last_used_at is recorded at
  # most once a minute (ApiToken#record_use!).
  class BaseController < ActionController::API
    include QueryParameters

    # The API reads no request bodies yet (Api::QueryParameters refuses one), so nothing is wrapped.
    wrap_parameters false

    REALM = "Money Bin".freeze

    before_action :authenticate_api_token
    before_action :check_token_scope

    rescue_from ActiveRecord::RecordNotFound do
      render_error :not_found, "not_found", "Nothing was found at this address."
    end

    rescue_from ActionController::ParameterMissing do |error|
      render_error :bad_request, "bad_request", "The parameter '#{error.param}' is missing."
    end

    rescue_from QueryParameters::InvalidParameter do |error|
      render_error :unprocessable_entity, "invalid_parameter", error.message
    end

    rescue_from KeysetCursor::Invalid do
      render_error :unprocessable_entity, "invalid_parameter",
        "The parameter 'cursor' is not one this API handed out; pass next_cursor from the previous page as it is."
    end

    private
      def authenticate_api_token
        plain_token = bearer_token
        if plain_token.nil?
          challenge
          render_error :unauthorized, "unauthorized", "Send a personal API token in the header: Authorization: Bearer <token>."
        elsif (api_token = ApiToken.find_active_by_plain_token(plain_token))
          api_token.record_use!
          Current.api_token = api_token
        else
          challenge error: "invalid_token"
          render_error :unauthorized, "invalid_token", "The API token is unknown or revoked."
        end
      end

      def check_token_scope
        return if Current.api_token.allows?(request.request_method)

        challenge error: "insufficient_scope"
        render_error :forbidden, "insufficient_scope",
          "This token can only read. #{request.request_method} requests need a token with the read_write scope."
      end

      # Whatever follows `Bearer ` in the Authorization header, or nil when there is no bearer value. The
      # scheme name is case-insensitive (RFC 7235). The value itself is checked by ApiToken.
      def bearer_token
        request.authorization.to_s[/\ABearer\s(.*)\z/im, 1]&.strip.presence
      end

      def challenge(error: nil)
        value = %(Bearer realm="#{REALM}")
        value += %(, error="#{error}") if error
        response.headers["WWW-Authenticate"] = value
      end

      # The `:id` of the URL, refused as not found unless it is a plain positive integer. Active Record would
      # read "12abc" as 12.
      def path_id
        id = params[:id].to_s
        raise ActiveRecord::RecordNotFound unless QueryParameters::ID_FORMAT.match?(id)

        id.to_i
      end

      def render_error(status, code, message)
        render json: { error: { code:, message: } }, status:
      end
  end
end
