module ReceiptLoad
  # A verified receipts.jsonl: typed lines the writer can use without checking them again. Built by Verifier.
  #
  # - `lines`: every line of the file, in file order. A line with a `skip_reason` is counted and not loaded.
  # - `warnings`: sentences about skipped lines (ids and reasons only).
  class Dataset < Data.define(:lines, :warnings)
    # One photo of a receipt, checked against the file on disk: `path` is the real path inside the ingest
    # folder, `checksum` the base64 MD5 Active Storage keeps for a blob, `content_type` read from the bytes.
    Image = Data.define(:part, :path, :filename, :byte_size, :sha256, :checksum, :content_type)

    # One receipt of the ingest set. `qr` holds the QR ground-truth columns (`qr_issued_at`, `qr_total` as a
    # BigDecimal, `qr_fiscal_number`, `qr_receipt_number`), each nil when the QR code did not give it.
    # `skip_reason` is nil for a line to load, or one of Report::SKIP_REASONS.
    Line = Data.define(:number, :ingest_id, :batch, :images, :fingerprint, :qr_payload, :qr, :skip_reason) do
      def skipped?
        !skip_reason.nil?
      end
    end

    # Every receipt id in the file, skipped lines included: a receipt whose line is still in the file has
    # not left the ingest set.
    def ingest_ids
      lines.map(&:ingest_id)
    end
  end
end
