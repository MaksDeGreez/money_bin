module ApplicationCable
  # Only a signed-in browser may open a WebSocket: the same signed session cookie as for pages.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = Session.from_cookies(cookies)&.user || reject_unauthorized_connection
    end
  end
end
