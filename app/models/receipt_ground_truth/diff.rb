class ReceiptGroundTruth
  # The differences between two version 2 documents, for people: which header fields differ, and the items
  # paired by their place in the list (item 1 with item 1), each with the keys that differ.
  #
  #   diff = ReceiptGroundTruth::Diff.new(saved_document, new_document)
  #   diff.fields         # => ["total", "merchant"]
  #   diff.items          # => [#<Row old: {...}, new: {...}, keys: ["amount"]>, ...]
  #   diff.items_changed  # rows present on both sides that differ
  #   diff.items_added / diff.items_removed
  #   diff.any?
  #
  # `ignore` leaves keys out (the check of an imported record against the receipt ignores categories: the
  # file has none). Values are compared as stored: decimal strings with one spelling per value, so equal
  # strings are equal values; times are compared as moments, so the same time with another offset is equal.
  class Diff
    HEADER_KEYS = (Document::KEYS - %w[items]).freeze
    Row = Data.define(:old, :new, :keys) do
      def added? = old.nil?
      def removed? = new.nil?
      def changed? = !added? && !removed? && keys.any?
      def same? = !added? && !removed? && keys.empty?
    end

    attr_reader :fields, :items

    def initialize(old_document, new_document, ignore: [])
      @old = old_document || {}
      @new = new_document || {}
      @ignore = ignore.map(&:to_s)
      @fields = (HEADER_KEYS - @ignore).reject { |key| same?(key, @old[key], @new[key]) }
      @items = item_rows
    end

    def items_changed = @items.count(&:changed?)
    def items_added = @items.count(&:added?)
    def items_removed = @items.count(&:removed?)

    def any?
      @fields.any? || @items.any? { |row| !row.same? }
    end

    private
      def item_rows
        old_items = Array(@old["items"])
        new_items = Array(@new["items"])
        Array.new([ old_items.size, new_items.size ].max) do |index|
          old_item = old_items[index]
          new_item = new_items[index]
          keys = if old_item && new_item
            (Document::ITEM_KEYS - @ignore).reject { |key| old_item[key] == new_item[key] }
          else
            []
          end
          Row.new(old: old_item, new: new_item, keys:)
        end
      end

      def same?(key, old_value, new_value)
        return old_value == new_value unless key == "issued_at" && old_value && new_value

        Time.iso8601(old_value) == Time.iso8601(new_value)
      rescue ArgumentError
        old_value == new_value
      end
  end
end
