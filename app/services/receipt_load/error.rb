module ReceiptLoad
  # Every reason the receipt load stops. `problems` is a list of sentences built by the loader itself, never
  # from a value of receipts.jsonl or from an exception message, so it can be printed safely: it names line
  # numbers, receipt ids (`rcpt_000123`), image parts and kinds of problem, but never a QR payload, a raw
  # photo name, a total or a date.
  class Error < StandardError
    # How many problems the message lists; the rest are only counted.
    SHOWN = 50

    attr_reader :problems

    # `nothing_written` is false when the load stopped after it had begun to write: receipts already
    # committed stay (each receipt is its own database transaction).
    def initialize(problems, nothing_written: true)
      @problems = Array(problems)
      @nothing_written = nothing_written
      super(build_message)
    end

    private
      def build_message
        shown = problems.first(SHOWN).map { |problem| "  - #{problem}" }
        hidden = problems.size - shown.size
        shown << "  ... and #{hidden} more" if hidden.positive?
        heading = problems.one? ? "The receipt load stopped (1 problem)." : "The receipt load stopped (#{problems.size} problems)."
        footer = @nothing_written ? "Nothing was written." : "Receipts loaded before the stop are kept; run the load again."
        [ heading, *shown, footer ].join("\n")
      end
  end
end
