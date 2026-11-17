require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "the root page shows the app name and what it does inside the layout" do
    sign_in_as users(:owner)

    get root_path

    assert_response :success
    assert_select "title", "Money Bin"
    assert_select "header a[href=?]", root_path, text: "Money Bin"
    assert_select "header [data-controller=theme] button[role=radio]", 3
    assert_select "main h1", "Money Bin"
    assert_select "main p", /receipt photos become categorised entries/
  end

  test "the top bar shows who is signed in and a sign-out button" do
    sign_in_as users(:owner)

    get root_path

    assert_select "header", text: /owner@example\.com/
    assert_select "header form[action=?][method=post] input[name=_method][value=delete]", session_path
    assert_select "header form[action=?] button", session_path, text: "Sign out", count: 1
  end

  test "a signed-out visitor is sent to the sign-in page" do
    get root_path

    assert_redirected_to new_session_path
  end

  test "the health check answers without a session" do
    get rails_health_check_path

    assert_response :success
  end
end
