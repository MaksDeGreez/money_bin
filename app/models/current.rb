# Per-request state, reset after every request. A browser request sets `session`; an API request sets
# `api_token`. `user` is the owner either way.
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :api_token

  def user
    session&.user || api_token&.user
  end
end
