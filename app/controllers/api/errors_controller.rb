module Api
  # The fallback of the API: every request under /api that no API route takes (config/routes.rb draws it
  # after them). It answers in the API's JSON error shape instead of Rails' HTML 404.
  #
  # It authenticates first, like every API path: without a valid token the answer is the usual 401, so a
  # caller without one cannot tell which paths exist. It skips the scope check, which is about methods that
  # change data: a read token sending POST to a GET-only path must learn that the method is wrong, not that
  # its token can only read.
  #
  # - 405 `method_not_allowed` with an `Allow` header when the path is routed for other methods;
  # - 404 `not_found` otherwise (an unknown path, a format suffix such as `.xml`, bare /api).
  #
  # Requests that cannot be decoded at all never reach a controller: ApiRequestErrors answers them.
  class ErrorsController < BaseController
    METHOD_ORDER = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

    skip_before_action :check_token_scope

    # The methods the API's routes answer, in a fixed order, HEAD included wherever GET is (the router
    # answers HEAD with the GET route). Only the routes whose path matches `path` when one is given, else
    # every API route's. `path` is a request's PATH_INFO, still percent-encoded, as the router matches it.
    def self.allowed_methods(path = nil)
      path &&= ActionDispatch::Journey::Router::Utils.normalize_path(path)
      verbs = Rails.application.routes.routes.flat_map do |route|
        controller = route.defaults[:controller].to_s
        next [] if !controller.start_with?("api/") || controller == "api/errors"
        next [] if path && !route.path.match?(path)

        route.verb.split("|")
      end
      verbs << "HEAD" if verbs.include?("GET")
      verbs.uniq.sort_by { |verb| METHOD_ORDER.index(verb) || METHOD_ORDER.size }
    end

    def fallback
      allowed = self.class.allowed_methods(request.path_info)
      if allowed.any?
        response.headers["Allow"] = allowed.join(", ")
        render_error :method_not_allowed, "method_not_allowed",
          "This address does not answer #{request.request_method}; it answers #{allowed.join(', ')}."
      else
        render_error :not_found, "not_found",
          "Nothing is at this address. The API's paths are described in its OpenAPI document (docs/openapi.yaml)."
      end
    end
  end
end
