# Answers requests to the REST API (/api) and the MCP server (/mcp) that Rails cannot even decode with the
# agents' JSON error shape, {"error": {"code": "...", "message": "..."}}, instead of Rails' HTML error page.
#
# These requests fail before any controller's rescue_from can see them: the router raises
# ActionController::BadRequest for a path parameter that decodes to invalid UTF-8 (`/api/v1/transactions/%FF`)
# and ActionController::UnknownHttpMethod for a method it does not know; ActionController::Instrumentation
# raises ActionController::BadRequest for an undecodable query string (`?q=%ff`, `?limit=%`, `?a=2&a[b]=1`)
# before the action runs; Rack's own parsers raise errors marked Rack::BadRequest (a multipart body with a
# boundary that is too long, say). ActionDispatch::Http::Parameters::ParseError (a JSON body that does not
# parse) is caught here too, should code outside a controller's rescue read such a body as parameters; the
# API's own reading of a body answers it as a 422 (Api::QueryParameters).
#
# - A request that cannot be decoded is a 400 `bad_request`, without looking at the token: it reveals nothing,
#   and the request could not be read far enough to authenticate it fairly.
# - A method nobody knows is a 405 `method_not_allowed` with an `Allow` header naming the methods the area
#   answers at all (POST for /mcp, the API's methods for /api): never per path, so a caller without a token
#   learns nothing about which paths exist.
#
# The app inserts this twice (config/application.rb): right after ActionDispatch::DebugExceptions, so it sees
# the router's and the controllers' exceptions before Rails renders them as HTML (DebugExceptions renders in
# development and test before config.exceptions_app is consulted), and right before Rack::MethodOverride,
# which reads a POST's form body before Rails' own error pages are in the stack and lets multipart errors
# through. Anything else, and every other path, passes through untouched.
#
# Only the exception's class is logged, never its message: that holds the undecodable query string.
#
# Not covered: requests Puma refuses itself before Rack sees them (a malformed request line, say), which get
# Puma's plain-text answer.
class ApiRequestErrors
  # /api and /mcp, anything below them, and the two with a suffix such as `.json`.
  AGENT_PATH = %r{\A/(?:api|mcp)(?:[/.]|\z)}

  BAD_REQUEST_MESSAGE = "The request could not be decoded: its path, query string or body is malformed " \
    "(text in an address must be percent-encoded UTF-8).".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless AGENT_PATH.match?(env[Rack::PATH_INFO].to_s.b)

    begin
      @app.call(env)
    rescue ActionController::UnknownHttpMethod => error
      log(error)
      respond(405, "method_not_allowed", "The HTTP method is not one this server knows.", "allow" => allowed_methods(env))
    rescue ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError, Rack::BadRequest => error
      log(error)
      respond(400, "bad_request", BAD_REQUEST_MESSAGE)
    end
  end

  private
    def allowed_methods(env)
      if env[Rack::PATH_INFO].to_s.b.start_with?("/mcp")
        McpController::ALLOWED_METHODS
      else
        Api::ErrorsController.allowed_methods
      end.join(", ")
    end

    def respond(status, code, message, headers = {})
      body = JSON.generate({ error: { code:, message: } })
      [ status, { "content-type" => "application/json; charset=utf-8", "content-length" => body.bytesize.to_s }.merge(headers), [ body ] ]
    end

    def log(error)
      Rails.logger.info("ApiRequestErrors: answered #{error.class} with a JSON error")
    end
end
