require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @owner = users(:owner) }

  test "the sign-in page has the form and no reset or sign-up link" do
    get new_session_path

    assert_response :success
    assert_select "form[action=?][method=post]", session_path do
      assert_select "input[type=email][name=email_address][autocomplete=username]"
      assert_select "input[type=password][name=password][autocomplete=current-password]"
    end
    assert_select "a[href*=password]", 0
    assert_select "header form[action=?]", session_path, count: 0
  end

  # Browsers scope localhost cookies by host, not by port, so another local app on another port shares
  # them. The names must not be the Rails defaults that such an app would use too.
  test "the cookies have names of their own" do
    get root_path
    assert_match(/\A_money_bin_v2_session=/, response.headers["Set-Cookie"].to_s)

    post session_path, params: { email_address: @owner.email_address, password: SessionTestHelper::OWNER_PASSWORD }
    assert_match(/^money_bin_v2_session_id=/, Array(response.headers["Set-Cookie"]).join("\n"))
    assert_equal :money_bin_v2_session_id, Session::COOKIE_NAME
    assert_equal "_money_bin_v2_session", Rails.application.config.session_options[:key]
  end

  test "the sign-in page sends a signed-in owner home" do
    sign_in_as @owner

    get new_session_path

    assert_redirected_to root_path
  end

  test "signing in with the right password starts a session in a safe cookie" do
    assert_difference -> { @owner.sessions.count }, 1 do
      post session_path, params: { email_address: "OWNER@example.com ", password: SessionTestHelper::OWNER_PASSWORD }
    end

    assert_redirected_to root_path
    assert cookies[Session::COOKIE_NAME].present?
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/money_bin_v2_session_id=.*; httponly/i, set_cookie)
    assert_match(/money_bin_v2_session_id=.*; samesite=lax/i, set_cookie)

    follow_redirect!
    assert_response :success
  end

  test "signing in sends the owner back to the page they asked for" do
    get root_path(tab: "recent")
    assert_redirected_to new_session_path

    post session_path, params: { email_address: @owner.email_address, password: SessionTestHelper::OWNER_PASSWORD }

    assert_redirected_to root_url(tab: "recent")
  end

  test "a refused form post is not repeated after signing in" do
    post settings_api_tokens_path, params: { api_token: { name: "Agent", scope: "read" } }
    assert_redirected_to new_session_path

    post session_path, params: { email_address: @owner.email_address, password: SessionTestHelper::OWNER_PASSWORD }

    assert_redirected_to root_url
  end

  test "a wrong password or an unknown address starts no session" do
    [ [ @owner.email_address, "wrong-password-here" ], [ "nobody@example.com", SessionTestHelper::OWNER_PASSWORD ] ].each do |email, password|
      assert_no_difference -> { Session.count } do
        post session_path, params: { email_address: email, password: }
      end

      assert_redirected_to new_session_path
      assert_equal "Wrong e-mail address or password.", flash[:alert]
      assert_nil cookies[Session::COOKIE_NAME]
    end
  end

  test "sign-in attempts are rate limited per IP address" do
    store = ActiveSupport::Cache::MemoryStore.new
    increment = ->(*args, **options) { store.increment(*args, **options) }

    # The test environment uses the null store, which never counts. Count in memory for this test only.
    with_singleton_method(SessionsController.cache_store, :increment, increment) do
      10.times do
        post session_path, params: { email_address: @owner.email_address, password: "wrong-password-here" }
        assert_equal "Wrong e-mail address or password.", flash[:alert]
      end

      assert_no_difference -> { Session.count } do
        post session_path, params: { email_address: @owner.email_address, password: SessionTestHelper::OWNER_PASSWORD }
      end
      assert_redirected_to new_session_path
      assert_equal "Too many attempts. Try again in a few minutes.", flash[:alert]
    end
  end

  test "signing out ends the session, and the old cookie no longer works" do
    post session_path, params: { email_address: @owner.email_address, password: SessionTestHelper::OWNER_PASSWORD }
    old_cookie = cookies[Session::COOKIE_NAME]

    assert_difference -> { Session.count }, -1 do
      delete session_path
    end
    assert_redirected_to new_session_path
    assert_empty cookies[Session::COOKIE_NAME]

    cookies[Session::COOKIE_NAME] = old_cookie
    get root_path
    assert_redirected_to new_session_path
  end

  test "signing out needs a session" do
    delete session_path

    assert_redirected_to new_session_path
  end

  test "a forged session cookie is ignored" do
    session_record = @owner.sessions.create!
    cookies[Session::COOKIE_NAME] = session_record.id.to_s

    get root_path

    assert_redirected_to new_session_path
  end
end
