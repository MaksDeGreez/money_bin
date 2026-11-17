module LegacyImport
  # What an import did, as counts and warnings only: no name, comment or amount ever goes in here, so the
  # report can be printed and kept.
  class Report
    ENTITIES = %i[accounts payees transactions].freeze
    OUTCOMES = %i[created updated unchanged].freeze
    # How the lines of the export found their categories. Each line is counted once, so the figures add up
    # to the number of lines; every outcome but the first makes its transaction needs_review.
    LINE_OUTCOMES = {
      mapped: "mapped to a category",
      mapped_to_uncategorised: "mapped to Uncategorised by the export",
      unmapped: "sent to Uncategorised (no mapping)",
      not_in_taxonomy: "sent to Uncategorised (names not in the taxonomy)",
      no_category: "without a category"
    }.freeze

    attr_reader :warnings, :lines, :statuses
    attr_accessor :dry_run, :payees_folded, :transfer_pairs, :pairs_recreated, :manifest_warnings, :date_from, :date_to

    def initialize
      @counts = ENTITIES.index_with { OUTCOMES.index_with { 0 } }
      @lines = LINE_OUTCOMES.keys.index_with { 0 }
      @statuses = Hash.new(0)
      @kept = Hash.new(0)
      @warnings = []
      @payees_folded = @transfer_pairs = @pairs_recreated = @manifest_warnings = 0
      @dry_run = false
    end

    def count(entity, outcome, by = 1)
      @counts.fetch(entity)[outcome] += by if @counts.fetch(entity).key?(outcome)
    end

    def counts(entity)
      @counts.fetch(entity)
    end

    # An unchanged record (its export row is the same as last time) that differs from the export today:
    # someone changed it in the app, and the import kept that change.
    def count_kept(entity)
      @kept[entity] += 1
    end

    def kept(entity)
      @kept[entity]
    end

    def count_line(outcome)
      @lines[outcome] += 1
    end

    def count_status(status)
      @statuses[status.to_s] += 1
    end

    def warn(text)
      @warnings << text
    end

    def to_s
      [
        "Legacy import#{' (dry run)' if dry_run}: export schema #{ExportReader::SCHEMA_VERSION}, " \
          "dates #{date_from || 'open'} to #{date_to || 'open'}, #{plural(manifest_warnings, 'manifest warning')}",
        entity_line("Accounts", :accounts) + kept_text(:accounts),
        entity_line("Payees", :payees) + ", #{payees_folded} folded into another payee",
        entity_line("Transactions", :transactions) + kept_text(:transactions) +
          ", #{transfer_pairs} transfer pairs (#{pairs_recreated} recreated)",
        "Lines: " + LINE_OUTCOMES.map { |key, text| "#{lines[key]} #{text}" }.join(", "),
        "Status: #{statuses['confirmed']} confirmed, #{statuses['needs_review']} needs_review",
        "Warnings: #{warnings.size}",
        *warnings.map { |warning| "  - #{warning}" },
        dry_run ? "Dry run: everything was rolled back, nothing was written." : "Done: the import was committed."
      ].join("\n")
    end

    private
      def plural(count, noun)
        "#{count} #{noun.pluralize(count)}"
      end

      def kept_text(entity)
        " (#{kept(entity)} with local edits kept)"
      end

      def entity_line(label, entity)
        counts = @counts.fetch(entity)
        "#{label}: #{counts[:created]} created, #{counts[:updated]} updated, #{counts[:unchanged]} unchanged"
      end
  end
end
