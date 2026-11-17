require "test_helper"

class FaviconTest < ActionDispatch::IntegrationTest
  FILES = %w[favicon.ico favicon-96.png apple-touch-icon.png].freeze

  test "every icon the head links to exists in public" do
    get new_session_path

    linked = css_select("link[rel='icon'], link[rel='apple-touch-icon']").map { |link| link["href"].delete_prefix("/") }
    assert_equal FILES.sort, linked.sort
    linked.each do |name|
      assert Rails.public_path.join(name).exist?, "public/#{name} is missing; run bin/favicon"
    end
  end

  test "the browser bar takes the page colour of each theme" do
    get new_session_path

    assert_select "meta[name='theme-color'][media='(prefers-color-scheme: light)'][content='#ffffff']"
    assert_select "meta[name='theme-color'][media='(prefers-color-scheme: dark)'][content='#121212']"
  end

  test "layout links the favicon set" do
    get new_session_path

    assert_response :success
    assert_select "link[rel='icon'][href='/favicon.ico']"
    assert_select "link[rel='icon'][href='/favicon-96.png'][type='image/png']"
    assert_select "link[rel='apple-touch-icon'][href='/apple-touch-icon.png']"
    assert_select "link[rel='manifest']", 0
  end

  test "favicon.ico is a multi-resolution icon" do
    header = Rails.public_path.join("favicon.ico").binread(6).unpack("vvv")
    assert_equal [ 0, 1, 3 ], header
  end
end
