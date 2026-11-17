require "test_helper"

# The Content Security Policy (config/initializers/content_security_policy.rb): scripts and styles only
# from this app, inline ones only with the page's nonce, fonts from the one font host the layout loads.
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "the sign-in page sends a strict policy" do
    get new_session_path

    policy = csp_directives
    assert_equal [ "'self'" ], policy["default-src"]
    assert_equal [ "'none'" ], policy["object-src"]
    assert_equal [ "'self'" ], policy["base-uri"]
    assert_equal [ "'self'" ], policy["form-action"]
    assert_equal [ "'none'" ], policy["frame-ancestors"]
    assert_equal [ "'self'", "'nonce-#{nonce}'" ], policy["script-src"]
    assert_includes policy["style-src"], "https://fonts.googleapis.com"
    assert_includes policy["font-src"], "https://fonts.gstatic.com"
    assert_no_match(/unsafe-inline|unsafe-eval/, policy["script-src"].join(" "))
  end

  test "every script on a page carries the nonce, signed out and signed in" do
    get new_session_path
    assert_scripts_carry_nonce

    sign_in_as users(:owner)
    get root_path
    assert_response :success
    assert_scripts_carry_nonce
  end

  test "the head has the nonce for Turbo and the inline theme script" do
    get new_session_path

    assert_select "meta[name=csp-nonce][content=?]", nonce
    assert_select "script[nonce=?]", nonce, text: /localStorage\.getItem\("theme"\)/
  end

  # Signing in and out resets the session, and with it the nonce. Turbo would keep the old page's policy
  # and block the new page's inline script, so these two forms load a whole new page.
  test "the sign-in and sign-out forms are not submitted by Turbo" do
    get new_session_path
    assert_select "form[action=?][data-turbo=false]", session_path

    sign_in_as users(:owner)
    get root_path
    assert_select "header form[action=?][data-turbo=false]", session_path
  end

  private
    def csp_directives
      header = response.headers["Content-Security-Policy"]
      assert header.present?, "no Content-Security-Policy header"

      header.split(";").to_h do |directive|
        name, *values = directive.split
        [ name, values ]
      end
    end

    def nonce
      csp_directives["script-src"].join(" ")[/'nonce-([^']+)'/, 1].tap { |value| assert value.present? }
    end

    def assert_scripts_carry_nonce
      scripts = css_select("script")
      assert_not_empty scripts
      scripts.each { |script| assert_equal nonce, script["nonce"], "a script without the nonce: #{script.to_html[0, 120]}" }
    end
end
