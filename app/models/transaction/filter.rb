# The transactions list filter (/transactions), kept in the URL as GET parameters so a filtered list can be
# bookmarked, reloaded and linked to (the dashboard links to "needs review" and to the uncategorised spending of a
# period). It turns the parameters into TransactionsQuery's arguments; the reading itself is the query object's.
#
#   filter = Transaction::Filter.new(params.permit(*Transaction::Filter::KEYS))
#   filter.relation    # the matching transactions, newest first
#   filter.to_params   # { status: "needs_review" }, only the values that are set
#
# A value that is not one of the choices (an unknown status, a date that is not a date, an id that is not a
# number) is ignored, so an old or edited URL never fails.
class Transaction::Filter
  KEYS = %i[from to account_id category_id status source payee q uncategorised currency expense].freeze

  attr_reader(*KEYS)

  # The filter in request parameters: at the top level (the list), or nested under `key` (a form posted from the
  # list carries it as filter[...]). Anything else there is ignored.
  def self.from_params(params, key = nil)
    values = key ? params[key] : params
    new(values.respond_to?(:permit) ? values.permit(*KEYS).to_h : {})
  end

  def initialize(attributes = {})
    values = attributes.to_h.symbolize_keys
    @from = date(values[:from])
    @to = date(values[:to])
    @account_id = id(values[:account_id])
    @category_id = id(values[:category_id])
    @status = values[:status].to_s.presence_in(Transaction.statuses.keys)
    @source = values[:source].to_s.presence_in(Transaction.sources.keys)
    @payee = values[:payee].to_s.squish.first(200).presence
    @q = values[:q].to_s.squish.first(200).presence
    @uncategorised = values[:uncategorised].to_s == "1" || nil
    @expense = values[:expense].to_s == "1" || nil
    currency = values[:currency].to_s.strip.upcase
    @currency = currency if currency.match?(Account::CURRENCY_FORMAT)
  end

  def query
    TransactionsQuery.new(from:, to:, account_id:, category_id:, status:, source:, payee:, q:, uncategorised:, currency:, expense:)
  end

  # The matching transactions, newest first.
  def relation
    query.relation
  end

  def to_params
    { from: from&.iso8601, to: to&.iso8601, account_id:, category_id:, status:, source:, payee:, q:,
      uncategorised: (uncategorised ? "1" : nil), currency:, expense: (expense ? "1" : nil) }.compact
  end

  # The same filter with some values changed (nil removes one).
  def merge(changes)
    self.class.new(to_params.merge(changes.symbolize_keys).compact)
  end

  def any?
    to_params.any?
  end

  private
    def date(value)
      Date.iso8601(value.to_s) if value.present?
    rescue Date::Error
      nil
    end

    def id(value)
      number = Integer(value.to_s, 10, exception: false)
      number if number&.positive?
    end
end
