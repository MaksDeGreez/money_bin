require "test_helper"

# The Sidekiq dashboard is mounted at /sidekiq behind a route constraint that checks the signed session
# cookie (config/routes.rb).
class SidekiqWebTest < ActionDispatch::IntegrationTest
  test "a signed-in owner sees the dashboard" do
    sign_in_as users(:owner)

    get "/sidekiq"

    assert_response :success
    assert_includes response.body, "Dashboard"
  end

  test "a signed-out visitor gets a plain 404" do
    get "/sidekiq"

    # In development and tests the 404 page is Rails' debug page, which lists every route; in production
    # it is public/404.html. Either way the dashboard itself is not served.
    assert_response :not_found
    assert_not_includes response.body, "Dashboard"
  end

  test "a cookie for a session that has ended gets a 404" do
    sign_in_as users(:owner)
    Session.delete_all

    get "/sidekiq/queues"

    assert_response :not_found
  end

  test "an API token does not open it" do
    get "/sidekiq", headers: bearer(plain_token(:agent_write))

    assert_response :not_found
  end
end
