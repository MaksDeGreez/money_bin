require "test_helper"
require "turbo/broadcastable/test_helper"

module Receipts
  class LiveUpdateTest < ActiveSupport::TestCase
    include Turbo::Broadcastable::TestHelper

    test "a changed receipt refreshes its page and the list, by morphing with the scroll kept" do
      receipt = receipts(:failed_receipt)

      LiveUpdate.changed(receipt)

      [ receipt, LiveUpdate::STREAM ].each do |stream|
        refresh = capture_turbo_stream_broadcasts(stream).sole
        assert_equal [ "refresh", "morph", "preserve" ], %w[action method scroll].map { |name| refresh[name] }, stream
      end
    end

    test "a request for one receipt refreshes its page; a request for many only the list" do
      receipt = receipts(:new_receipt)

      LiveUpdate.requested([ receipt.id, receipts(:failed_receipt).id ])
      assert_no_turbo_stream_broadcasts receipt
      assert_turbo_stream_broadcasts LiveUpdate::STREAM, count: 1

      LiveUpdate.requested([ receipt.id ])
      assert_turbo_stream_broadcasts receipt, count: 1
      assert_turbo_stream_broadcasts LiveUpdate::STREAM, count: 2
    end

    test "a receipt deleted in the meantime only refreshes the list" do
      receipt = receipts(:new_receipt)
      id = receipt.id
      receipt.destroy!

      assert_nothing_raised { LiveUpdate.requested([ id ]) }
      assert_turbo_stream_broadcasts LiveUpdate::STREAM, count: 1
    end

    test "nothing is sent before the surrounding database transaction commits" do
      receipt = receipts(:failed_receipt)

      Receipt.transaction(requires_new: true) do
        LiveUpdate.changed(receipt)
        assert_no_turbo_stream_broadcasts receipt
      end
      assert_turbo_stream_broadcasts receipt, count: 1
    end

    test "a broadcast that fails is reported and swallowed, and the other streams still get theirs" do
      reported = []
      subscriber = Object.new.tap { |object| object.define_singleton_method(:report) { |error, **| reported << error } }
      Rails.error.subscribe(subscriber)
      receipt = receipts(:failed_receipt)
      original = Turbo::StreamsChannel.method(:broadcast_refresh_to)
      failing_for_receipt = lambda do |stream, **options|
        raise RedisClient::CannotConnectError, "down" if stream == receipt

        original.call(stream, **options)
      end

      with_singleton_method(Turbo::StreamsChannel, :broadcast_refresh_to, failing_for_receipt) do
        assert_nothing_raised { LiveUpdate.changed(receipt) }
      end

      assert_equal [ RedisClient::CannotConnectError ], reported.map(&:class)
      assert_turbo_stream_broadcasts LiveUpdate::STREAM, count: 1
    ensure
      Rails.error.unsubscribe(subscriber)
    end
  end
end
