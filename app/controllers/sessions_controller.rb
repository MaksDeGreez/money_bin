# Sign in and sign out (from the Rails 8 authentication generator).
#
# Failed and successful sign-ins count against a rate limit per IP address. The counter lives in the
# controller cache store: Redis in development and production (config/environments), so the limit holds
# across Puma workers and restarts; the null store in tests, where the limit is off unless a test turns it
# on (test/controllers/sessions_controller_test.rb).
#
# The limit counts per connection address (`remote_addr`), not per `remote_ip`: Rails trusts
# X-Forwarded-For from local addresses, so behind no proxy a client could name a new address on every
# attempt and never reach the limit. The app is served directly, never through a proxy.
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, by: -> { request.remote_addr },
             with: -> { redirect_to new_session_path, alert: "Too many attempts. Try again in a few minutes." }

  def new
    redirect_to root_path if authenticated?
  end

  def create
    if (user = User.authenticate_by(params.permit(:email_address, :password)))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Wrong e-mail address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other, notice: "Signed out."
  end
end
