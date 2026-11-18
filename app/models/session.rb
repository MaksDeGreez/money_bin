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

  # Closes the Action Cable connections (live page updates) of `sessions`, which are ending: pass the
  # loaded records (with their user) and delete the rows. The disconnect is sent once the deletion has
  # committed, so a browser that connects in between is refused by the cookie check instead of missing
  # the message. Works across processes through the cable's Redis adapter, so `bin/rails user:password`
  # reaches the web server too. A failure is logged, never raised: signing out must not fail because Redis
  # is down.
  def self.disconnect_sockets(sessions)
    sessions = sessions.to_a
    ActiveRecord.after_all_transactions_commit do
      sessions.each do |session|
        ActionCable.server.remote_connections.where(current_session: session, current_user: session.user).disconnect(reconnect: false)
      end
    rescue StandardError => error
      Rails.logger.warn("Session.disconnect_sockets: #{error.class}: #{error.message}")
    end
  end
end
