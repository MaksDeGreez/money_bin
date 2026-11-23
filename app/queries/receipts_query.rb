# Reads receipts, newest first, with keyset pagination (see KeysetCursor). Used by the REST API and meant
# to be reused unchanged by the MCP server.
#
# "Newest" is the time on the receipt (`issued_at`), or the upload time while OCR has not read one: the
# receipt an owner calls "my last receipt" is the last purchase, and a photo just uploaded is new too.
# The id breaks ties. The sort key is an expression covered by the index
# index_receipts_on_sort_time_and_id.
class ReceiptsQuery
  # Rails stores created_at as UTC without a time zone; AT TIME ZONE 'UTC' makes it comparable with
  # issued_at (timestamptz) and keeps the expression immutable, so it can be indexed.
  SORT_TIME = "COALESCE(receipts.issued_at, receipts.created_at AT TIME ZONE 'UTC')".freeze
  # A card slip's own category and suggestion (ReceiptSerializer#common), on the list and the detail.
  SLIP_PRELOADS = %i[category suggested_category].freeze
  PRELOADS = [ *SLIP_PRELOADS, { items: %i[category suggested_category] } ].freeze

  def self.find(id)
    Receipt.includes(PRELOADS).find(id)
  end

  def initialize(status: nil)
    @status = status
  end

  def relation
    scope = Receipt.all
    scope = scope.where(status: @status) if @status
    scope.order(Arel.sql("#{SORT_TIME} DESC, receipts.id DESC"))
  end

  # One page of at most `limit` receipts after `cursor`, each with `items_count` counted in the same
  # query, then a slip's categories (`category`, `suggested_category`) preloaded for the rows returned:
  # one more query when a receipt on the page refers to a category (the preloader loads both
  # associations' categories together), none otherwise.
  # Raises KeysetCursor::Invalid for a cursor this query did not make.
  def page(limit: KeysetCursor::DEFAULT_LIMIT, cursor: nil)
    scope = relation
      .select("receipts.*", "#{SORT_TIME} AS sort_time",
        "(SELECT COUNT(*) FROM receipt_items WHERE receipt_items.receipt_id = receipts.id) AS items_count")
    scope = scope.where("(#{SORT_TIME}, receipts.id) < (?, ?)", *decode(cursor)) if cursor
    rows = scope.limit(limit + 1).to_a
    more = rows.size > limit
    rows = preload_slip_categories(rows.first(limit))
    return ResultPage.new(records: rows, next_cursor: nil) unless more

    ResultPage.new(records: rows, next_cursor: KeysetCursor.encode(rows.last.sort_time.utc.iso8601(6), rows.last.id))
  end

  private
    # After the extra row that tells whether a next page exists is dropped, so it costs no query.
    def preload_slip_categories(rows)
      ActiveRecord::Associations::Preloader.new(records: rows, associations: SLIP_PRELOADS).call
      rows
    end

    def decode(cursor)
      time, id = KeysetCursor.decode(cursor, size: 2)
      raise KeysetCursor::Invalid unless time.is_a?(String)

      [ Time.iso8601(time), KeysetCursor.id(id) ]
    rescue ArgumentError
      raise KeysetCursor::Invalid
    end
end
