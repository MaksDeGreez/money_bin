module ReceiptLoad
  # What a receipt load did, as counts per outcome (in total and per batch, by the batch folder name, which the
  # ingest tool prints too) and warnings that name receipt ids only: never a QR payload, a raw photo name, a
  # total or a date, so the report can be printed and kept.
  class Report
    # What happened to a line of receipts.jsonl, or to a loaded receipt whose line has left the file.
    OUTCOMES = {
      created: "created",
      updated: "updated (ingest fields)",
      repaired: "repaired (photo files restored)",
      regrouped: "regrouped (photos replaced)",
      unchanged: "unchanged",
      conflict: "left alone (conflict)",
      failed: "failed",
      skipped_no_images: "skipped (no images)",
      skipped_too_many_parts: "skipped (more than #{Receipt::MAX_IMAGES} photos)",
      skipped_files_unusable: "skipped (files not usable)",
      retired_deleted: "deleted (left the ingest)",
      retired_kept: "kept (left the ingest, already worked on)"
    }.freeze
    SKIP_REASONS = %i[no_images too_many_parts files_unusable].freeze
    # The label of a loaded receipt whose batch was cleared in the app.
    NO_BATCH = "(no batch)"

    attr_reader :warnings, :lines

    def initialize(dry_run: false, lines: 0)
      @dry_run = dry_run
      @lines = lines
      @totals = OUTCOMES.keys.index_with { 0 }
      @batches = Hash.new { |hash, batch| hash[batch] = OUTCOMES.keys.index_with { 0 } }
      @warnings = []
    end

    def dry_run?
      @dry_run
    end

    def count(batch, outcome)
      @totals.fetch(outcome)
      @totals[outcome] += 1
      @batches[batch.presence || NO_BATCH][outcome] += 1
    end

    def [](outcome)
      @totals.fetch(outcome)
    end

    def warn(text)
      @warnings << text
    end

    # True when a receipt could not be written: the task then exits with status 1.
    def failed?
      self[:failed].positive?
    end

    def to_s
      [
        "Receipt load#{' (dry run)' if dry_run?}: #{@lines} lines in #{Verifier::FILE_NAME}",
        "Receipts: #{outcome_text(@totals, all: true)}",
        "Per batch:",
        *@batches.keys.sort.map { |batch| "  #{batch}: #{outcome_text(@batches[batch])}" },
        "Warnings: #{warnings.size}",
        *warnings.map { |warning| "  - #{warning}" },
        footer
      ].join("\n")
    end

    private
      # Every outcome for the totals; only those that happened for a batch.
      def outcome_text(counts, all: false)
        shown = all ? counts : counts.select { |_outcome, count| count.positive? }
        shown.map { |outcome, count| "#{count} #{OUTCOMES.fetch(outcome)}" }.join(", ").presence || "nothing"
      end

      def footer
        if dry_run?
          "Dry run: everything was rolled back, nothing was written."
        elsif failed?
          "Done with failures: the other receipts were committed; run the load again after fixing the cause."
        else
          "Done: every receipt was committed."
        end
      end
  end
end
