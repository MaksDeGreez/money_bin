class ReceiptGroundTruth
  # A receipt's stored fields and items as a ground-truth document of the current schema version
  # (docs/domain.md, "Manual ground truth"):
  #
  #   ReceiptGroundTruth::Snapshot.document(receipt, categories: true)
  #
  # It reads the receipt as stored (call it on a receipt loaded after the save), never the form's text, so
  # what a record holds is what the receipt held at that moment. Money and quantities are written from the
  # stored decimals with exactly two and three places; a value with more places is a bug and raises rather
  # than being rounded. An empty text field is null (not known). `issued_at` is written in Kyiv time with its offset. `is_return` is null: the receipt
  # does not record returns. Categories are slugs; with `categories: false` every category is null (the record
  # then says they are not known). A card slip's category is the receipt's own; any other kind has none.
  module Snapshot
    class Unrepresentable < StandardError; end

    module_function

    def document(receipt, categories: true)
      slip = receipt.card_slip?
      Document.blank.merge(
        "kind" => receipt.kind,
        "merchant" => text(receipt.merchant_name),
        "fiscal_number" => text(receipt.fiscal_number),
        "receipt_number" => text(receipt.receipt_number),
        "issued_at" => receipt.issued_at&.in_time_zone&.iso8601,
        "total" => money(receipt.total),
        "currency" => text(receipt.currency),
        "card_last4" => text(receipt.card_last4),
        "is_return" => nil,
        "category_slug" => (receipt.category&.slug if categories && slip),
        "items" => receipt.items.sort_by(&:position).map { |item| item(item, categories) }
      )
    end

    # Whether the receipt gives every category the document would carry: each item's, and a slip's own.
    def categories_complete?(receipt)
      items = receipt.items.reject(&:marked_for_destruction?)
      return false if items.any? { |item| item.category_id.nil? }

      !receipt.card_slip? || receipt.category_id.present?
    end

    def item(item, categories)
      {
        "name" => item.name.to_s.strip,
        "quantity" => decimal(item.quantity, 3),
        "unit_price" => money(item.unit_price),
        "amount" => money(item.amount),
        "discount" => money(item.discount),
        "category_slug" => (item.category&.slug if categories)
      }
    end

    # A blank field is not known: the form sends "" for an empty text field.
    def text(value)
      value.to_s.strip.presence
    end

    def money(value)
      decimal(value, 2)
    end

    def decimal(value, places)
      return nil if value.nil?

      Document.decimal_string(value, places) || raise(Unrepresentable, "a stored value has more than #{places} places")
    end
  end
end
