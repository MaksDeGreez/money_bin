module DpsXml
  # The common part of a format variant: finding elements without caring about letter case or namespaces,
  # and reading text, decimals and Kyiv times the way the ground truth needs them. A subclass sets NAME and
  # implements `.match?(document)` and `#read` (=> Result); see Reader.
  #
  # Values are never rounded: a number that is not an exact decimal with at most 2 places (money) or 3 (a
  # quantity) is left out and counted in `notes` as `dropped_<field>`. A decimal comma counts as a point.
  class Format
    DECIMAL = /\A[+-]?\d+(?:[.,]\d+)?\z/
    KYIV = "Europe/Kyiv"

    def self.match?(_document)
      raise NotImplementedError
    end

    # The first child element of `node` named `name` (any letter case), or nil.
    def self.child(node, name)
      node&.element_children&.find { |element| element.name.casecmp?(name) }
    end

    def initialize(document)
      @document = document
      @notes = Hash.new(0)
    end

    def read
      raise NotImplementedError
    end

    private
      def child(node, name)
        self.class.child(node, name)
      end

      def children(node, name)
        node ? node.element_children.select { |element| element.name.casecmp?(name) } : []
      end

      # True when the element is missing or holds only white space: "not given", unlike a value that was
      # given but refused (which `text` and `number` also return as nil).
      def blank?(node, name)
        child(node, name)&.text.to_s.strip.empty?
      end

      # The element's text with white space squeezed, or nil when it is missing or blank. Text longer than a
      # document allows is left out and counted.
      def text(node, name, field = name.downcase)
        value = child(node, name)&.text.to_s.squish.presence
        return value if value.nil? || value.length <= ReceiptGroundTruth::Document::TEXT_LIMIT

        note(:"dropped_#{field}")
      end

      # The element's number as a BigDecimal; nil when missing, and nil and counted when it is not a decimal.
      def number(node, name, field)
        value = text(node, name, field)
        return nil if value.nil?
        return note(:"dropped_#{field}") unless DECIMAL.match?(value)

        BigDecimal(value.tr(",", "."))
      end

      # A BigDecimal as a decimal string with `places` places; nil and counted when it has more.
      def decimal_string(value, places, field)
        return nil if value.nil?

        ReceiptGroundTruth::Document.decimal_string(value, places) || note(:"dropped_#{field}")
      end

      def money(node, name, field)
        decimal_string(number(node, name, field), Transaction::MONEY_DECIMAL_PLACES, field)
      end

      # A date `ddmmyyyy` and a time `hhmmss` (or `hhmm`) on the receipt, read as Kyiv time, as ISO 8601 with
      # the offset. nil when either is missing; nil and counted when either does not make a real moment.
      def kyiv_time(date, time, field)
        return nil if date.nil? || time.nil?

        day = /\A(\d{2})(\d{2})(\d{4})\z/.match(date)
        clock = /\A(\d{2})(\d{2})(\d{2})?\z/.match(time)
        return note(:"dropped_#{field}") unless day && clock

        dd, mm, yyyy = day.captures.map(&:to_i)
        hours, minutes, seconds = clock.captures.map(&:to_i)
        return note(:"dropped_#{field}") unless Date.valid_date?(yyyy, mm, dd) && hours < 24 && minutes < 60 && seconds < 60

        ActiveSupport::TimeZone[KYIV].local(yyyy, mm, dd, hours, minutes, seconds).iso8601
      end

      # Counts `kind` and returns nil, so a dropped value reads `return note(...)`.
      def note(kind)
        @notes[kind] += 1
        nil
      end

      def result(document, items_known:)
        Result.new(document:, items_known:, format: self.class::NAME, notes: @notes.to_h.freeze)
      end
  end
end
