module McpTools
  # search_transactions: TransactionsQuery, as GET /api/v1/transactions.
  class SearchTransactions < Base
    # Fewer than the REST API's 50: a page goes into the model's context, and 20 rows are about 15 KB.
    DEFAULT_LIMIT = 20

    tool_name "search_transactions"
    title "Search transactions"
    description <<~TEXT.squish
      Finds ledger transactions, newest first, a page at a time. Every argument is optional and they combine
      (all must match). Each transaction has its date, its amount in its account's currency (negative for
      money spent, positive for money received), its status, its account, payee, merchant and comment, and
      its category lines (a split transaction has one line per category, and the lines sum to the amount).
      The list includes drafts (status "draft": proposals that balances and summaries do not count) and both
      legs of transfers between own accounts (they have a transfer_id and no category lines); filter by
      status or use spending_summary for totals instead of adding up pages. Amounts are decimal strings;
      never add amounts of different currencies. Paging: a result holds at most `limit` transactions; when
      next_cursor is not null, call again with the same arguments plus that cursor.
    TEXT
    input_schema(
      type: "object",
      properties: {
        from: DATE_SCHEMA.merge(description: "Only transactions on or after this day, YYYY-MM-DD."),
        to: DATE_SCHEMA.merge(description: "Only transactions on or before this day, YYYY-MM-DD; not before from."),
        account_id: ID_SCHEMA.merge(description: "Only this account (an id from list_accounts)."),
        category: {
          type: %w[string integer],
          description: "Only transactions with a line in this category, or in any category of this group: a slug from " \
            "list_categories (\"groceries\" is the whole group, \"groceries/groceries\" one category) or its numeric id."
        },
        status: {
          type: "string", enum: Transaction.statuses.values,
          description: "Only this status: draft (a proposal, not counted), needs_review (counted, to be checked), confirmed."
        },
        payee_id: ID_SCHEMA.merge(description: "Only this payee (a payee.id from an earlier result). To search by name, use text."),
        text: {
          type: "string", minLength: 1, maxLength: QueryArguments::TEXT_MAX_LENGTH,
          description: "Words to find, case-insensitively, in the payee name, merchant, comment or bank description."
        },
        limit: LIMIT_SCHEMA.merge(description: "How many transactions per page, 1 to #{KeysetCursor::MAX_LIMIT}; #{DEFAULT_LIMIT} by default."),
        cursor: CURSOR_SCHEMA
      },
      additionalProperties: false
    )
    output_schema OutputSchema.of("TransactionPage")
    annotations(**ANNOTATIONS, title: "Search transactions")

    class << self
      private
        def answer(from: nil, to: nil, account_id: nil, category: nil, status: nil, payee_id: nil, text: nil, limit: nil, cursor: nil)
          from, to = QueryArguments.date_range(optional_date(:from, from), optional_date(:to, to))
          query = TransactionsQuery.new(
            from:, to:,
            account_id: account_id.nil? ? nil : QueryArguments.id(:account_id, account_id, Account),
            category_id: category.nil? ? nil : QueryArguments.category(:category, category),
            status: status.nil? ? nil : QueryArguments.enum(:status, status, Transaction.statuses.values),
            payee_id: payee_id.nil? ? nil : QueryArguments.id(:payee_id, payee_id, Payee),
            q: text.nil? ? nil : QueryArguments.text(:text, text)
          )
          page = query.page(limit: page_limit(limit, default: DEFAULT_LIMIT), cursor: cursor(cursor))
          json = { transactions: page.records.map { |transaction| TransactionSerializer.call(transaction) }, next_cursor: page.next_cursor }

          [ text_of(json), json ]
        end

        def text_of(json)
          return "No transaction matches. #{more_pages_note(nil)}" if json[:transactions].empty?

          lines = [ "#{json[:transactions].size} transaction(s), newest first (negative = money spent):" ]
          lines.concat(json[:transactions].map { |transaction| line(transaction) })
          lines << more_pages_note(json[:next_cursor])
          lines.join("\n")
        end

        def line(transaction)
          who = transaction.dig(:payee, :name) || transaction[:merchant] || transaction[:comment] || transaction[:bank_description] || "-"
          categories = transaction[:lines].map { |line| "#{line.dig(:category, :slug) || 'no category'} #{line[:amount]}" }
          kind = transaction[:transfer_id] ? "transfer between own accounts" : categories.join(", ").presence || "no lines"
          [ transaction[:occurred_on], money(transaction[:amount], transaction[:currency]), who,
            "account #{transaction.dig(:account, :name)} (id #{transaction.dig(:account, :id)})", kind,
            transaction[:status], "id #{transaction[:id]}" ].join(" | ")
        end
    end
  end
end
