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
# API's own reading of a body answers it as a 422 (Api::QueryParameters). Instrumentation also raises
# ActionDispatch::Http::MimeNegotiation::InvalidType for a Content-Type or Accept header that is not a media
# type, and Rails' request logger ActionDispatch::RemoteIp::IpSpoofAttackError for client IP headers that
# contradict each other.
#
# - A request that cannot be decoded is a 400 `bad_request`, without looking at the token: it reveals nothing,
#   and the request could not be read far enough to authenticate it fairly. So is one with an unreadable
#   media type header or contradictory client IP headers.
# - A method nobody knows is a 405 `method_not_allowed` with an `Allow` header naming the methods the area
#   answers at all (POST for /mcp, the API's methods for /api): never per path, so a caller without a token
#   learns nothing about which paths exist.
#
# The app inserts this twice (config/application.rb): right after ActionDispatch::DebugExceptions, so it sees
# the router's and the controllers' exceptions before Rails renders them as HTML (DebugExceptions renders in
# development and test before config.exceptions_app is consulted), and right before Rack::MethodOverride,
# which reads a POST's form body before Rails' own error pages are in the stack and lets multipart errors
# through and sits above Rails' request logger. Anything else, and every other path, passes through untouched.
# An answer to HEAD has no body.
#
# Only the exception's class is logged, never its message: that holds the undecodable query string.
#
# Not covered: requests Puma refuses itself before Rack sees them (a malformed request line, say), which get
# Puma's plain-text answer, and a Host header Rails' host check (config.hosts, development and production)
# refuses before this runs.
class ApiRequestErrors
  # /api and /mcp, anything below them, and the two with a suffix such as `.json`.
  AGENT_PATH = %r{\A/(?:api|mcp)(?:[/.]|\z)}

  BAD_REQUEST_MESSAGE = "The request could not be decoded: its path, query string or body is malformed " \
    "(text in an address must be percent-encoded UTF-8).".freeze
  BAD_HEADER_MESSAGE = "The request could not be read: a Content-Type or Accept header is not a media type, " \
    "or the client IP headers contradict each other.".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless AGENT_PATH.match?(env[Rack::PATH_INFO].to_s.b)

    begin
      @app.call(env)
    rescue ActionController::UnknownHttpMethod => error
      log(error)
      respond(405, "method_not_allowed", "The HTTP method is not one this server knows.", { "allow" => allowed_methods(env) })
    rescue ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError, Rack::BadRequest => error
      log(error)
      respond(400, "bad_request", BAD_REQUEST_MESSAGE, head: env[Rack::REQUEST_METHOD] == "HEAD")
    rescue ActionDispatch::Http::MimeNegotiation::InvalidType, ActionDispatch::RemoteIp::IpSpoofAttackError => error
      log(error)
      respond(400, "bad_request", BAD_HEADER_MESSAGE, head: env[Rack::REQUEST_METHOD] == "HEAD")
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

    def respond(status, code, message, headers = {}, head: false)
      body = JSON.generate({ error: { code:, message: } })
      headers = { "content-type" => "application/json; charset=utf-8", "content-length" => body.bytesize.to_s }.merge(headers)
      [ status, headers, head ? [] : [ body ] ]
    end

    def log(error)
      Rails.logger.info("ApiRequestErrors: answered #{error.class} with a JSON error")
    end
end
