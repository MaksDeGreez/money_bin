require "test_helper"

module Settings
  class ApiTokensControllerTest < ActionDispatch::IntegrationTest
    setup { @owner = users(:owner) }

    test "every action needs a signed-in session" do
      get settings_api_tokens_path
      assert_redirected_to new_session_path

      assert_no_difference -> { ApiToken.count } do
        post settings_api_tokens_path, params: { api_token: { name: "Agent", scope: "read" } }
      end
      assert_redirected_to new_session_path

      delete settings_api_token_path(api_tokens(:agent_read))
      assert_redirected_to new_session_path
      assert api_tokens(:agent_read).reload.active?
    end

    test "an API token does not open the settings page" do
      get settings_api_tokens_path, headers: bearer(plain_token(:agent_write))

      assert_redirected_to new_session_path
    end

    test "the list shows every token with its scope, dates and state, and no secret" do
      sign_in_as @owner

      get settings_api_tokens_path

      assert_response :success
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "header nav a[href=?]", settings_api_tokens_path
      assert_select "header nav a[href='/sidekiq'][data-turbo=false]"
      assert_select "form[action=?][data-turbo=false]", settings_api_tokens_path do
        assert_select "input[name='api_token[name]']"
        assert_select "input[type=radio][name='api_token[scope]'][value=read][checked]"
        assert_select "input[type=radio][name='api_token[scope]'][value=read_write]"
      end
      assert_select "tbody tr", 3
      assert_select "tr[id=?]", dom_id(api_tokens(:agent_write)) do
        assert_select "td", text: "Bookkeeping agent"
        assert_select ".badge", text: "read and write"
        assert_select ".badge", text: "Active"
        assert_select "time"
        assert_select "form[action=?] button", settings_api_token_path(api_tokens(:agent_write)), text: "Revoke"
        assert_select "form[data-turbo-confirm]"
      end
      assert_select "tr[id=?]", dom_id(api_tokens(:agent_read)) do
        assert_select "td", text: "Never"
      end
      assert_select "tr[id=?]", dom_id(api_tokens(:revoked)) do
        assert_select ".badge", text: "Revoked"
        assert_select "form", 0
      end
      ApiTokenTestHelper::PLAIN_TOKENS.each_value { |value| assert_not_includes response.body, value }
      assert_not_includes response.body, api_tokens(:agent_read).token_digest
    end

    test "an empty list says so" do
      ApiToken.delete_all
      sign_in_as @owner

      get settings_api_tokens_path

      assert_select "p", "No tokens yet."
    end

    test "creating a token shows the plain value exactly once, on a page that is not cached" do
      sign_in_as @owner

      assert_difference -> { ApiToken.count }, 1 do
        post settings_api_tokens_path, params: { api_token: { name: "Laptop agent", scope: "read_write" } }
      end

      assert_response :created
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_select "meta[name=turbo-cache-control][content=no-cache]"
      plain_token = css_select("input#plain_token").first["value"]
      api_token = ApiToken.find_active_by_plain_token(plain_token)
      assert_equal "Laptop agent", api_token.name
      assert api_token.read_write?
      assert_equal 1, response.body.scan(plain_token).size
      assert_select "[data-controller=clipboard] button[data-action='clipboard#copy']"
      assert_select ".callout", text: /You will not see it again/

      assert_nil flash[:notice]
      assert_not_includes session.to_hash.to_s, plain_token

      get settings_api_tokens_path
      assert_not_includes response.body, plain_token
      assert_select "td", text: "Laptop agent"
    end

    test "sending the same form again does not show the token again" do
      sign_in_as @owner
      post settings_api_tokens_path, params: { api_token: { name: "Laptop agent", scope: "read" } }
      plain_token = css_select("input#plain_token").first["value"]

      assert_no_difference -> { ApiToken.count } do
        post settings_api_tokens_path, params: { api_token: { name: "Laptop agent", scope: "read" } }
      end

      assert_response :unprocessable_content
      assert_not_includes response.body, plain_token
      assert_select "input#plain_token", 0
      assert_select ".field-error", "Name has already been taken"
    end

    test "a token with a bad scope or no name is refused with the form's messages" do
      sign_in_as @owner

      assert_no_difference -> { ApiToken.count } do
        post settings_api_tokens_path, params: { api_token: { name: "", scope: "admin" } }
      end

      assert_response :unprocessable_content
      assert_select "input[name='api_token[name]'][aria-invalid]"
      assert_select ".field-error", "Name can't be blank"
      assert_select ".field-error", "Scope is not included in the list"
    end

    test "a request without the token fields is a bad request" do
      sign_in_as @owner

      post settings_api_tokens_path, params: { name: "Agent" }

      assert_response :bad_request
    end

    test "revoking keeps the row and stops the token" do
      sign_in_as @owner
      api_token = api_tokens(:agent_write)

      assert_no_difference -> { ApiToken.count } do
        delete settings_api_token_path(api_token)
      end

      assert_redirected_to settings_api_tokens_path
      assert_response :see_other
      assert api_token.reload.revoked?
      assert_nil ApiToken.find_active_by_plain_token(plain_token(:agent_write))
      follow_redirect!
      assert_select ".callout", text: /Revoked “Bookkeeping agent”/
    end

    test "revoking an unknown token is a 404" do
      sign_in_as @owner

      delete settings_api_token_path(id: 0)

      assert_response :not_found
    end
  end
end
