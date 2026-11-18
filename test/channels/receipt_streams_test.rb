require "test_helper"

# The live receipt pages subscribe through Turbo::StreamsChannel. Only a signed-in browser connects at all
# (test/channels/application_cable/connection_test.rb); on top of that, a stream is reached only through a
# name the app signed when it rendered the page, so a connection cannot listen to a stream it picks itself.
class ReceiptStreamsTest < ActionCable::Channel::TestCase
  tests Turbo::StreamsChannel

  setup { stub_connection(current_session: users(:owner).sessions.create!, current_user: users(:owner)) }

  test "a receipt page's signed stream name subscribes to that receipt's stream" do
    receipt = receipts(:new_receipt)

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(receipt)

    assert subscription.confirmed?
    assert_has_stream receipt.to_gid_param
  end

  test "the list's signed stream name subscribes to the list stream" do
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(Receipts::LiveUpdate::STREAM)

    assert subscription.confirmed?
    assert_has_stream Receipts::LiveUpdate::STREAM.to_s
  end

  test "a stream name that the app did not sign is refused" do
    subscribe signed_stream_name: receipts(:new_receipt).to_gid_param

    assert subscription.rejected?
  end
end
