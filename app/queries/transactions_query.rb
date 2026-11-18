# Reads ledger transactions: filters, a stable newest-first order and keyset pagination. Used by the REST
# API (Api::V1::TransactionsController) and meant to be reused unchanged by the MCP server.
#
# It takes values that are already checked (Dates, Integers, enum strings) and knows nothing of HTTP:
# whoever calls it validates the input. Every filter is optional; together they narrow the list (AND).
#
# - `from` / `to`: dates on `occurred_on`, both inclusive;
# - `account_id`, `payee_id`, `status`, `source`: equality;
# - `category_id`: a category, or a group meaning any of its categories. A transaction matches when one of
#   its lines is in it, so a split transaction is found under each of its categories. Transfer legs have
#   no lines and never match;
# - `q`: text that appears, case-insensitively, in the payee name, the merchant, the comment or the bank
#   description. LIKE wildcards in it are taken literally;
# - `payee`: text that appears, case-insensitively, in the payee's name (the list's payee field);
# - `uncategorised`: true for the transactions with a line nobody has categorised yet (no category, or the
#   taxonomy's Uncategorised; TransactionLine.uncategorised). Transfer legs have no lines and never match;
# - `currency`: the account's currency.
#
# Order: `occurred_on` descending, then `id` descending, so rows of one day keep a fixed order and a
# cursor always points at one place.
class TransactionsQuery
  # What a page row needs, loaded in a fixed number of queries whatever the page size.
  PRELOADS = [ :account, :payee, :receipt, { lines: :category } ].freeze

  def self.find(id)
    Transaction.includes(PRELOADS).find(id)
  end

  def initialize(from: nil, to: nil, account_id: nil, category_id: nil, status: nil, payee_id: nil, q: nil, source: nil,
    payee: nil, uncategorised: nil, currency: nil)
    @from = from
    @to = to
    @account_id = account_id
    @category_id = category_id
    @status = status
    @payee_id = payee_id
    @q = q
    @source = source
    @payee = payee
    @uncategorised = uncategorised
    @currency = currency
  end

  # The filtered, ordered relation (no pagination, no preloads).
  def relation
    scope = Transaction.all
    scope = scope.where(occurred_on: @from..) if @from
    scope = scope.where(occurred_on: ..@to) if @to
    scope = scope.where(account_id: @account_id) if @account_id
    scope = scope.where(status: @status) if @status
    scope = scope.where(payee_id: @payee_id) if @payee_id
    scope = scope.where(source: @source) if @source
    scope = scope.where(in_category) if @category_id
    scope = scope.where(matching_text) if @q.present?
    scope = scope.where(payee_id: Payee.where(Payee.arel_table[:name].matches(like(@payee))).select(:id)) if @payee.present?
    scope = scope.where(TransactionLine.uncategorised.where("transaction_lines.transaction_id = transactions.id").arel.exists) if @uncategorised
    scope = scope.where(account_id: Account.where(currency: @currency).select(:id)) if @currency
    scope.order(occurred_on: :desc, id: :desc)
  end

  # One page of at most `limit` rows, starting after `cursor` (from the previous page's next_cursor).
  # Raises KeysetCursor::Invalid for a cursor this query did not make.
  def page(limit: KeysetCursor::DEFAULT_LIMIT, cursor: nil)
    scope = relation.includes(PRELOADS)
    scope = scope.where("(transactions.occurred_on, transactions.id) < (?, ?)", *decode(cursor)) if cursor
    rows = scope.limit(limit + 1).to_a
    return ResultPage.new(records: rows, next_cursor: nil) if rows.size <= limit

    rows = rows.first(limit)
    ResultPage.new(records: rows, next_cursor: KeysetCursor.encode(rows.last.occurred_on.iso8601, rows.last.id))
  end

  private
    # EXISTS (a line of this transaction in the category, or in any category of the group).
    def in_category
      categories = Category.where(id: @category_id).or(Category.where(parent_id: @category_id)).select(:id)
      TransactionLine.where("transaction_lines.transaction_id = transactions.id").where(category_id: categories).arel.exists
    end

    def like(text)
      "%#{Transaction.sanitize_sql_like(text)}%"
    end

    def matching_text
      pattern = like(@q)
      table = Transaction.arel_table
      payees = Payee.where(Payee.arel_table[:name].matches(pattern)).select(:id)
      table[:comment].matches(pattern)
        .or(table[:merchant].matches(pattern))
        .or(table[:bank_description].matches(pattern))
        .or(table[:payee_id].in(payees.arel))
    end

    def decode(cursor)
      date, id = KeysetCursor.decode(cursor, size: 2)
      raise KeysetCursor::Invalid unless date.is_a?(String) && date.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      [ Date.iso8601(date), KeysetCursor.id(id) ]
    rescue Date::Error
      raise KeysetCursor::Invalid
    end
end
