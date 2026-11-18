# The MCP SDK answers a failure inside a tool or the transport with a JSON-RPC internal error that carries no
# message, so the client learns nothing about the app. The exception itself comes here, to the Rails log
# (git-ignored, on the owner's machine). The SDK's context (which holds the request and its arguments) is
# not logged. A client's own mistake (an unknown tool or method, invalid params) is one warning line; any
# other exception is an error with its backtrace.
MCP.configure do |config|
  config.exception_reporter = lambda do |exception, _context|
    if exception.is_a?(MCP::Server::RequestHandlerError) && exception.error_type != :internal_error
      Rails.logger.warn("MCP: #{exception.class}: #{exception.message}")
    else
      Rails.logger.error("MCP: #{exception.class}: #{exception.message}\n#{Array(exception.backtrace).first(10).join("\n")}")
    end
  end
end
