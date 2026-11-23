module McpTools
  # get_receipt: ReceiptsQuery.find, as GET /api/v1/receipts/{id}.
  class GetReceipt < Base
    tool_name "get_receipt"
    title "Get a receipt"
    description <<~TEXT.squish
      One shop receipt with every item on it: name, quantity, unit price, discount, the amount paid for the
      item, and its category (the accepted one, or else the categoriser's suggestion with its confidence).
      Item amounts and the total are positive, as printed on the receipt, in the receipt's currency; a
      negative item is money given back (a bottle deposit). items_total is the sum of the item amounts and
      may differ from the printed total when OCR missed a line. A card slip (kind card_slip) has no items: it
      is booked as one line in its own category, given as category (accepted) or else suggested_category with
      its confidence; these three are null on any other receipt. Get ids from recent_receipts. Photos are not
      available through this server.
    TEXT
    input_schema(
      type: "object",
      properties: { id: ID_SCHEMA.merge(description: "The receipt id (from recent_receipts).") },
      required: %w[id],
      additionalProperties: false
    )
    output_schema OutputSchema.of("Receipt")
    annotations(**ANNOTATIONS, title: "Get a receipt")

    class << self
      private
        def answer(id:)
          id = QueryArguments.positive_integer(id) || raise(QueryArguments::Invalid.new(:id, "must be a positive integer id"))
          json = ReceiptSerializer.call(find(id))

          [ text(json), json ]
        end

        def find(id)
          ReceiptsQuery.find(id)
        rescue ActiveRecord::RecordNotFound
          raise Base::NotFound, "No receipt has id #{id}; recent_receipts lists the receipts with their ids."
        end

        def text(json)
          lines = [ [ "Receipt #{json[:id]}", json[:merchant] || "merchant not read", json[:issued_at] || "no time read",
            "total #{money(json[:total], json[:currency])}", json[:status], slip_category(json),
            json[:transaction_id] ? "booked as transaction #{json[:transaction_id]}" : "not booked" ].compact.join(" | ") ]
          if json[:kind] == "card_slip" && json[:items].empty?
            lines << "A card slip: no items, booked as one line of its total in the slip's category."
          else
            lines << "#{json[:items_count]} item(s), amounts in #{json[:currency] || 'the receipt currency'}, summing to #{json[:items_total]}:"
            json[:items].each { |item| lines << item_line(item) }
          end
          lines.join("\n")
        end

        def item_line(item)
          price = [ item[:quantity], item[:unit_price] ].all? ? "#{item[:quantity]} x #{item[:unit_price]}" : nil
          discount = item[:discount] == "0.00" ? nil : "discount #{item[:discount]}"
          category = if item[:category]
            item.dig(:category, :slug)
          elsif item[:suggested_category]
            "suggested #{item.dig(:suggested_category, :slug)} (confidence #{item[:confidence]})"
          else
            "no category"
          end
          "  #{item[:position]}. #{item[:name]} | #{[ price, discount ].compact.join(', ').presence || '-'} | paid #{item[:amount]} | #{category}"
        end
    end
  end
end
