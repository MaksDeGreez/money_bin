module OcrBatches
  # "Read in a batch": claims the receipts of a list filter that "Read all in this filter" would queue (unread,
  # and failed without items to lose; Receipts::RequestOcr.readable) and creates `pending` batches for them.
  #
  #   OcrBatches::Create.call(filter.scope, capability: OcrBatches::Availability.current)  # => [OcrBatch, ...]
  #
  # - Once: in one database transaction the receipts' rows are locked and only those with no OCR request
  #   waiting and no batch (`ocr_batch_id` nil) are taken; each gets `ocr_batch_id`. A request one at a time
  #   (Receipts::RequestOcr) takes rows under the same lock and skips held ones, so a receipt is never in a
  #   batch and the synchronous queue at once, nor in two open batches.
  # - Split: in the list's order, at most `max_receipts` receipts (the service's limit, 100) and
  #   MAX_UPLOAD_BYTES of stored photos per batch; the service and OpenRouter refuse more (a batch that is
  #   still refused as too large is halved when it is sent: OcrBatches::Submit).
  # - Each receipt gets an entry with a fresh random key (OcrBatchEntry.new_custom_id).
  # - A receipt without photos is left out: nothing can read it, and a read one at a time records why.
  #
  # After the commit the batches are handed to OcrBatchSubmitJob (one at a time) and the poller is started.
  class Create
    # The stored photo bytes of one batch's upload to the ML service, which accepts up to 300 MB.
    MAX_UPLOAD_BYTES = 150.megabytes

    def self.call(relation, capability:, now: Time.current)
      new(relation, capability:, now:).call
    end

    def initialize(relation, capability:, now:)
      @relation = relation
      @capability = capability
      @now = now.floor(6)
    end

    def call
      raise ArgumentError, "batch mode is not available: #{@capability.code}" unless @capability.available

      batches = Receipt.transaction do
        ids = Receipts::RequestOcr.readable(@relation, :read_all, now: @now).lock.pluck(:id)
        sizes = photo_bytes(ids)
        chunks(ids.select { |id| sizes.key?(id) }, sizes).map { |chunk| create_batch(chunk) }
      end
      announce(batches)
      batches
    end

    private
      def max_receipts
        @capability.max_receipts.clamp(1, 100)
      end

      def max_bytes
        [ @capability.max_upload_bytes, MAX_UPLOAD_BYTES ].min.clamp(1, MAX_UPLOAD_BYTES)
      end

      # Stored bytes of each receipt's photos ({ receipt id => bytes }); receipts without photos are missing.
      def photo_bytes(ids)
        ActiveStorage::Attachment.where(record_type: "Receipt", name: "images", record_id: ids).joins(:blob)
          .group(:record_id).sum("active_storage_blobs.byte_size")
      end

      def chunks(ids, sizes)
        chunks = []
        current = []
        bytes = 0
        ids.each do |id|
          if current.any? && (current.size >= max_receipts || bytes + sizes[id] > max_bytes)
            chunks << current
            current = []
            bytes = 0
          end
          current << id
          bytes += sizes[id]
        end
        chunks << current if current.any?
        chunks
      end

      def create_batch(ids)
        batch = OcrBatch.create!(state: "pending", receipts_count: ids.size, next_check_at: @now)
        rows = ids.each_with_index.map do |id, index|
          { ocr_batch_id: batch.id, receipt_id: id, position: index + 1, custom_id: OcrBatchEntry.new_custom_id,
            state: "waiting", created_at: @now, updated_at: @now }
        end
        OcrBatchEntry.insert_all!(rows)
        Receipt.where(id: ids).update_all(ocr_batch_id: batch.id, ocr_requested_at: nil)
        batch
      end

      def announce(batches)
        return if batches.empty?

        Receipts::LiveUpdate.requested(batches.flat_map { |batch| batch.entries.pluck(:receipt_id) })
        batches.each { |batch| LiveUpdate.changed(batch) }
        begin
          OcrBatchSubmitJob.perform_later
        rescue StandardError => error
          # The poller hands pending batches to the submitter again; the batches page says they wait.
          Rails.logger.warn("OcrBatches::Create: the submit job could not be queued (#{error.class})")
        end
        OcrBatchPollJob.ensure_scheduled
      end
  end
end
