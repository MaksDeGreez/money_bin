# Authentication with a personal API token (ApiToken) in `Authorization: Bearer <token>`, and nothing
# else: no cookie, no session, no query parameter. Shared by the two interfaces for agents, the REST API
# (Api::BaseController) and the MCP server (McpController), so both refuse and accept exactly the same
# requests. Include it in an ActionController::API controller (which has no cookie support, so a
# signed-in browser gets no access) and add `before_action :authenticate_api_token`.
#
# - No bearer value: 401 `unauthorized`. An unknown, malformed or revoked token: 401 `invalid_token`
#   (one answer for all three, so a caller learns nothing about which). Both carry
#   `WWW-Authenticate: Bearer realm="Money Bin"`, the challenge HTTP clients and MCP clients understand.
# - On success Current.api_token is set (Current.user is its owner), and its last_used_at is recorded at
#   most once a minute (ApiToken#record_use!).
#
# Errors have the app's API shape: {"error": {"code": "...", "message": "..."}}.
module ApiTokenAuthentication
  REALM = "Money Bin".freeze

  private
    def authenticate_api_token
      plain_token = bearer_token
      if plain_token.nil?
        challenge
        render_api_error :unauthorized, "unauthorized", "Send a personal API token in the header: Authorization: Bearer <token>."
      elsif (api_token = ApiToken.find_active_by_plain_token(plain_token))
        api_token.record_use!
        Current.api_token = api_token
      else
        challenge error: "invalid_token"
        render_api_error :unauthorized, "invalid_token", "The API token is unknown or revoked."
      end
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

    def render_api_error(status, code, message)
      render json: { error: { code:, message: } }, status:
    end
end
