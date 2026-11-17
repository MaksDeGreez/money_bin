# Signing in and out in integration tests, without going through the sign-in form.
#
#   sign_in_as users(:owner)
#   get root_path
module SessionTestHelper
  # The password of the users(:owner) fixture. Test data only.
  OWNER_PASSWORD = "owner-fixture-password"

  def sign_in_as(user)
    Current.session = user.sessions.create!

    ActionDispatch::TestRequest.create.cookie_jar.tap do |cookie_jar|
      cookie_jar.signed[Session::COOKIE_NAME] = Current.session.id
      cookies[Session::COOKIE_NAME.to_s] = cookie_jar[Session::COOKIE_NAME]
    end
  end

  def sign_out
    Current.session&.destroy!
    cookies.delete(Session::COOKIE_NAME.to_s)
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include SessionTestHelper
end
