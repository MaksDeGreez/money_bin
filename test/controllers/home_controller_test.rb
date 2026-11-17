require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "the root page shows the app name and what it does inside the layout" do
    get root_path

    assert_response :success
    assert_select "title", "Money Bin"
    assert_select "header a[href=?]", root_path, text: "Money Bin"
    assert_select "header [data-controller=theme] button[role=radio]", 3
    assert_select "main h1", "Money Bin"
    assert_select "main p", /receipt photos become categorised entries/
  end

  test "the health check answers" do
    get rails_health_check_path

    assert_response :success
  end
end
