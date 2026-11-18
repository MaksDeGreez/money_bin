module GroundTruthImport
  # What a ground-truth import did: counts per outcome, a few counts across the imported files, and warnings
  # that name receipt ids and kinds of problem only. Never a shop name, an item, an amount, a date, a file
  # name other than `rcpt_NNNNNN`, or anything else read from a file, so the report can be printed and kept.
  class Report
    OUTCOMES = {
      created: "created",
      replaced: "replaced (the file changed)",
      unchanged: "unchanged",
      conflict: "left alone (the file changed, the record was already checked by a person)",
      mismatch: "not imported (disagrees with the receipt's QR code)",
      receipt_not_loaded: "skipped (receipt not loaded)",
      unreadable: "skipped (unreadable)",
      not_a_receipt: "skipped (not a receipt)",
      failed: "failed"
    }.freeze

    attr_reader :warnings, :files, :ignored

    def initialize(dry_run: false, files: 0, ignored: 0)
      @dry_run = dry_run
      @files = files
      @ignored = ignored
      @counts = OUTCOMES.keys.index_with { 0 }
      @stored = Hash.new(0)
      @notes = Hash.new(0)
      @warnings = []
    end

    def dry_run?
      @dry_run
    end

    def [](outcome)
      @counts.fetch(outcome)
    end

    # How many stored files had `kind`: :verified, :unverifiable (the QR code has identifying values the
    # file lacks), :no_qr (the QR code has none), :without_items, :return_receipts.
    def stored(kind)
      @stored[kind]
    end

    # How often the reader met `kind` (DpsXml::Result#notes) over the stored files.
    def note(kind)
      @notes[kind]
    end

    def count(outcome, ingest_id = nil, warning = nil)
      @counts.fetch(outcome)
      @counts[outcome] += 1
      @warnings << "#{ingest_id}: #{warning}" if warning
    end

    # Adds what is known about a file whose record is stored: the cross-check and the reader's notes.
    def count_stored(result, check)
      @stored[check.status == :agrees ? :verified : check.status] += 1
      @stored[:without_items] += 1 unless result.items_known
      @stored[:return_receipts] += 1 if result.return_receipt?
      result.notes.each { |kind, count| @notes[kind] += count }
    end

    def warn(ingest_id, warning)
      @warnings << "#{ingest_id}: #{warning}"
    end

    def failed?
      self[:failed].positive?
    end

    def to_s
      [
        "Ground-truth import#{' (dry run)' if dry_run?}: #{@files} receipt files, #{@ignored} other entries ignored",
        "Files: #{@counts.map { |outcome, count| "#{count} #{OUTCOMES.fetch(outcome)}" }.join(', ')}",
        "Stored: #{stored(:verified)} agree with the QR code, #{stored(:unverifiable)} unverified (the file lacks the values " \
          "to compare), #{stored(:no_qr)} unverified (the QR code has too little to compare), " \
          "#{stored(:without_items)} without item lines, #{stored(:return_receipts)} return receipts",
        "Values left out or met: #{notes_text}",
        "Warnings: #{warnings.size}",
        *warnings.map { |warning| "  - #{warning}" },
        footer
      ].join("\n")
    end

    private
      def notes_text
        @notes.sort.map { |kind, count| "#{count} #{kind}" }.join(", ").presence || "none"
      end

      def footer
        if dry_run?
          "Dry run: everything was rolled back, nothing was written."
        elsif failed?
          "Done with failures: the other files were committed; run the import again after fixing the cause."
        else
          "Done: every file was committed."
        end
      end
  end
end
