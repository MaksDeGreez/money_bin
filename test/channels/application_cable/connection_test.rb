require "test_helper"

module ApplicationCable
  class ConnectionTest < ActionCable::Connection::TestCase
    test "a signed-in browser connects as the owner" do
      session_record = users(:owner).sessions.create!
      cookies.signed[:session_id] = session_record.id

      connect

      assert_equal users(:owner), connection.current_user
    end

    test "a browser without a session is refused" do
      assert_reject_connection { connect }
    end

    test "a cookie for a session that has ended is refused" do
      session_record = users(:owner).sessions.create!
      cookies.signed[:session_id] = session_record.id
      session_record.destroy!

      assert_reject_connection { connect }
    end
  end
end
