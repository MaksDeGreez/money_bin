module McpTools
  # recent_receipts: ReceiptsQuery#page, as GET /api/v1/receipts.
  class RecentReceipts < Base
    DEFAULT_LIMIT = 10

    tool_name "recent_receipts"
    title "Recent receipts"
    description <<~TEXT.squish
      The latest shop receipts (photographed and read by OCR), newest purchase first: id, merchant, time on
      the receipt, total and currency, status, how many items, and the transaction it was booked as. Items
      are not included: call get_receipt with an id for them (for "what did I buy on my last receipt", take
      the first receipt here, then get_receipt). Receipt totals are positive (what the receipt says was
      paid), unlike expenses in the ledger. A receipt OCR has not read yet has no merchant, time or total and
      sorts by its upload time. Paging: when next_cursor is not null, call again with the same arguments
      plus that cursor.
    TEXT
    input_schema(
      type: "object",
      properties: {
        status: {
          type: "string", enum: Receipt.statuses.values,
          description: "Only this status: uploaded, processing (OCR running), extracted (read, waiting for a person), " \
            "reviewed (checked by a person), failed (OCR could not read it)."
        },
        limit: LIMIT_SCHEMA.merge(description: "How many receipts per page, 1 to #{KeysetCursor::MAX_LIMIT}; #{DEFAULT_LIMIT} by default."),
        cursor: CURSOR_SCHEMA
      },
      additionalProperties: false
    )
    output_schema OutputSchema.of("ReceiptPage")
    annotations(**ANNOTATIONS, title: "Recent receipts")

    class << self
      private
        def answer(status: nil, limit: nil, cursor: nil)
          status = status.nil? ? nil : QueryArguments.enum(:status, status, Receipt.statuses.values)
          page = ReceiptsQuery.new(status:).page(limit: page_limit(limit, default: DEFAULT_LIMIT), cursor: cursor(cursor))
          json = { receipts: page.records.map { |receipt| ReceiptSerializer.summary(receipt) }, next_cursor: page.next_cursor }

          [ text(json), json ]
        end

        def text(json)
          return "No receipt matches. #{more_pages_note(nil)}" if json[:receipts].empty?

          lines = [ "#{json[:receipts].size} receipt(s), newest first:" ]
          json[:receipts].each do |receipt|
            lines << [ "id #{receipt[:id]}", receipt[:issued_at] || "no time read yet", receipt[:merchant] || "merchant not read",
              "total #{money(receipt[:total], receipt[:currency])}", "#{receipt[:items_count]} item(s)", receipt[:status],
              receipt[:transaction_id] ? "booked as transaction #{receipt[:transaction_id]}" : "not booked" ].join(" | ")
          end
          lines << more_pages_note(json[:next_cursor])
          lines.join("\n")
        end
    end
  end
end
