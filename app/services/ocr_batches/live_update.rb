module OcrBatches
  # Refreshes the batches page and a batch's own page (Turbo refresh, morph, scroll kept) after the surrounding
  # transaction commits, as Receipts::LiveUpdate does for receipts. A failed broadcast is logged, never raised.
  module LiveUpdate
    STREAM = :ocr_batches

    module_function

    def changed(batch)
      Receipts::LiveUpdate.after_commit { broadcast([ batch, STREAM ]) }
    end

    def broadcast(streams)
      streams.each do |stream|
        Turbo::StreamsChannel.broadcast_refresh_to(stream, **Receipts::LiveUpdate::REFRESH_OPTIONS)
      rescue StandardError => error
        Rails.logger.warn("OcrBatches::LiveUpdate: could not refresh #{stream.to_param}: #{error.class}")
        Rails.error.report(error, handled: true, source: "ocr_batches.live_update")
      end
    end
  end
end
