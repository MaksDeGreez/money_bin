require "test_helper"

# A page left open after its session ended must stop getting live updates: the session's Action Cable
# connections are closed (ApplicationCable::Connection is identified by the session).
class SessionSocketsTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  def internal_channel(session)
    identifier = [ session, session.user ].map { |record| record.to_gid_param }.join(":")
    "action_cable/#{identifier}"
  end

  test "signing out closes the session's sockets, without a reconnect" do
    sign_in_as users(:owner)
    session_record = Current.session

    assert_broadcast_on(internal_channel(session_record), { "type" => "disconnect", "reconnect" => false }) do
      delete session_path
    end
  end

  test "a new password closes the sockets of every other session" do
    kept = users(:owner).sessions.create!
    ended = users(:owner).sessions.create!
    Current.session = kept

    assert_broadcasts(internal_channel(ended), 1) do
      assert_no_broadcasts(internal_channel(kept)) do
        users(:owner).update!(password: "a-new-long-password-for-tests")
      end
    end
    assert_not Session.exists?(ended.id)
  ensure
    Current.reset
  end

  test "the disconnect is sent only once the ended sessions are gone from the database" do
    ended = users(:owner).sessions.create!
    Current.session = users(:owner).sessions.create!
    still_there = nil
    original = ActionCable.server.method(:remote_connections)
    watching = lambda do
      still_there = Session.exists?(ended.id)
      original.call
    end

    with_singleton_method(ActionCable.server, :remote_connections, watching) do
      User.transaction(requires_new: true) do
        users(:owner).update!(password: "a-new-long-password-for-tests")
        assert_nil still_there, "nothing is sent inside the transaction"
      end
    end

    assert_equal false, still_there
  ensure
    Current.reset
  end

  test "a cable that cannot be reached does not stop the sign-out" do
    sign_in_as users(:owner)

    with_singleton_method(ActionCable.server, :remote_connections, -> { raise RedisClient::CannotConnectError, "down" }) do
      delete session_path
    end

    assert_redirected_to new_session_path
    assert_not Session.exists?(Current.session&.id)
  end
end
