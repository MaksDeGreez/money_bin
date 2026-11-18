module ApplicationCable
  # Only a signed-in browser may open a WebSocket: the same signed session cookie as for pages. The
  # connection is identified by its session, so signing out (or a new password, which ends every session)
  # closes the sockets of the ended sessions at once (Session.disconnect_sockets): a page left open stops
  # getting live updates, and its reconnect is refused.
  class Connection < ActionCable::Connection::Base
    identified_by :current_session, :current_user

    def connect
      self.current_session = Session.from_cookies(cookies) || reject_unauthorized_connection
      self.current_user = current_session.user
    end
  end
end
