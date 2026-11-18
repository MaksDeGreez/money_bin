module Receipts
  # Pushes a receipt's new state to the pages that show it, through Turbo Streams over Action Cable
  # (docs/domain.md, "Live updates"). The OCR job and the services that change a receipt call it
  # explicitly: they write with `update_columns` in places, which runs no model callback.
  #
  #   Receipts::LiveUpdate.changed(receipt)   # the status or the OCR result changed
  #   Receipts::LiveUpdate.requested(ids)     # OCR was queued for these receipts
  #
  # Each sends a Turbo "refresh" (morph, scroll kept) to the receipt's own stream (its page,
  # `turbo_stream_from receipt`) and to STREAM (the list). The page fetches itself again, with its own
  # filter, and morphs: the status badge, the data column, the list rows and the counts per status change,
  # nothing else moves. A refresh rather than a "replace" with rendered partials, because Action Cable does
  # not promise the order of messages: a job that fails within milliseconds of starting (a placeholder
  # backend answers 501 at once) sent "Reading" and "failed" so close together that "Reading" could arrive
  # last and stay. A refresh always shows what the database holds, whatever the order, and Turbo merges
  # refreshes that arrive close together into one request.
  #
  # Stream names are signed, and ApplicationCable::Connection admits only a signed-in browser.
  #
  # A broadcast is a courtesy to an open page, never part of the write: it runs after the surrounding
  # database transaction commits, and a failure (Redis down) is logged and reported, then swallowed, so a
  # job does not fail or retry over a lost page update.
  module LiveUpdate
    STREAM = :receipts
    REFRESH_OPTIONS = { method: :morph, scroll: :preserve }.freeze

    module_function

    def changed(receipt)
      after_commit { broadcast([ receipt ]) }
    end

    # Many receipts (Read all) refresh only the list, to keep the request short.
    def requested(ids)
      after_commit { broadcast(ids.one? ? Receipt.where(id: ids).to_a : []) }
    end

    def after_commit(&block)
      ActiveRecord.after_all_transactions_commit(&block)
    end

    def broadcast(receipts)
      [ *receipts, STREAM ].each do |stream|
        Turbo::StreamsChannel.broadcast_refresh_to(stream, **REFRESH_OPTIONS)
      rescue StandardError => error
        Rails.logger.warn("Receipts::LiveUpdate: could not refresh #{stream.to_param}: #{error.class}: #{error.message}")
        Rails.error.report(error, handled: true, source: "receipts.live_update", context: { stream: stream.to_param })
      end
    end
  end
end
