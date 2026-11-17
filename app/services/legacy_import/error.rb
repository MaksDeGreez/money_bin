module LegacyImport
  # Every reason the history import stops. `problems` is a list of sentences built by the importer itself,
  # never from a value of the export or from an exception message, so it can be printed safely: it names
  # files, line numbers, legacy ids, field names and kinds of problem, but no name, comment or amount.
  class Error < StandardError
    # How many problems the message lists; the rest are only counted.
    SHOWN = 50

    attr_reader :problems

    def initialize(problems)
      @problems = Array(problems)
      super(build_message)
    end

    private
      def build_message
        shown = problems.first(SHOWN).map { |problem| "  - #{problem}" }
        hidden = problems.size - shown.size
        shown << "  ... and #{hidden} more" if hidden.positive?
        heading = problems.one? ? "The import stopped (1 problem)." : "The import stopped (#{problems.size} problems)."
        [ heading, *shown, "Nothing was written." ].join("\n")
      end
  end
end
