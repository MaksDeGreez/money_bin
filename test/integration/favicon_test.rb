require "test_helper"

class FaviconTest < ActionDispatch::IntegrationTest
  FILES = %w[favicon.ico favicon-96.png apple-touch-icon.png].freeze

  test "every icon referenced from the head exists in public" do
    FILES.each do |name|
      assert Rails.public_path.join(name).exist?, "public/#{name} is missing; run bin/favicon"
    end
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
