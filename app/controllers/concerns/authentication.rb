# Browser sign-in (from the Rails 8 authentication generator). Every action requires a signed-in session
# unless the controller calls `allow_unauthenticated_access`.
#
# The browser holds a signed cookie with the id of a Session row. The cookie is HTTP-only (scripts cannot
# read it) and SameSite=Lax (other sites cannot send it with a form POST). It is not marked Secure here, so
# it works over plain HTTP on localhost; in production `force_ssl` marks every cookie Secure.
#
# API requests do not use this: Api::BaseController authenticates bearer tokens and never reads cookies.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= Session.from_cookies(cookies)
    end

    # Only a page can be returned to after signing in; a form post or a delete cannot be repeated as a GET.
    def request_authentication
      session[:return_to_after_authenticating] = request.url if request.get? || request.head?
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    # The connection's address, not remote_ip, which a client can set with X-Forwarded-For.
    #
    # The Rails session (CSRF token, flash) starts afresh on sign-in and on sign-out, so nothing set
    # before the change of identity is carried across it. The page to return to is the one thing kept.
    def start_new_session_for(user)
      return_to = session[:return_to_after_authenticating]
      reset_session
      session[:return_to_after_authenticating] = return_to if return_to

      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_addr).tap do |session|
        Current.session = session
        cookies.signed.permanent[Session::COOKIE_NAME] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(Session::COOKIE_NAME)
      reset_session
    end
end
