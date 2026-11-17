# One signed-in browser. The browser holds a signed, HTTP-only cookie `session_id` with the row's id
# (see the Authentication concern). Signing out deletes the row, so an old cookie stops working.
class Session < ApplicationRecord
  COOKIE_NAME = :session_id

  belongs_to :user

  # The session that a request's signed cookie points at, or nil. Used by the Authentication concern, the
  # Action Cable connection and the route constraint in front of Sidekiq Web, so all three agree.
  def self.from_cookies(cookie_jar)
    id = cookie_jar.signed[COOKIE_NAME]
    find_by(id:) if id
  end
end
