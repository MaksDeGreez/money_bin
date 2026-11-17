# One signed-in browser. The browser holds a signed, HTTP-only cookie `money_bin_v2_session_id` with the
# row's id (see the Authentication concern). Signing out deletes the row, so an old cookie stops working.
class Session < ApplicationRecord
  # Not the generator's `session_id`: localhost cookies are shared by every app on the machine, whatever
  # the port, so another local app with the default name would overwrite this one.
  COOKIE_NAME = :money_bin_v2_session_id

  belongs_to :user

  # The session that a request's signed cookie points at, or nil. Used by the Authentication concern, the
  # Action Cable connection and the route constraint in front of Sidekiq Web, so all three agree.
  def self.from_cookies(cookie_jar)
    id = cookie_jar.signed[COOKIE_NAME]
    find_by(id:) if id
  end
end
