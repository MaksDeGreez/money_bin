# The receipts list filter: batch, status, kind, tax QR and "incomplete", kept in the URL as GET
# parameters, so a filtered list can be bookmarked, reloaded, and returned to from a receipt.
#
#   filter = Receipt::Filter.new(params.permit(*Receipt::Filter::KEYS))
#   filter.scope              # the matching receipts, newest first
#   filter.to_params          # { status: "failed", batch: "october" }, only the values that are set
#   filter.status_counts      # { "uploaded" => 12, ... } with every filter but the status applied
#   filter.neighbours(receipt) # [previous, next] receipt ids inside the filter, nil at either end
#
# A value that is not one of the choices is ignored (the list shows everything for that filter), so an
# old or edited URL never fails.
class Receipt::Filter
  include ActiveModel::Model
  include ActiveModel::Attributes

  KEYS = %i[batch status kind qr incomplete].freeze
  KINDS = { "fiscal" => "Fiscal receipt", "card_slip" => "Card slip", "unknown" => "Not known yet" }.freeze
  QR_CHOICES = { "with" => "Has tax-service QR data", "without" => "No tax-service QR data" }.freeze

  attribute :batch, :string
  attribute :status, :string
  attribute :kind, :string
  attribute :qr, :string
  attribute :incomplete, :boolean

  def initialize(attributes = {})
    super(attributes.to_h.symbolize_keys.slice(*KEYS))
    self.batch = batch.presence
    self.status = nil unless Receipt.statuses.key?(status)
    self.kind = nil unless KINDS.key?(kind)
    self.qr = nil unless QR_CHOICES.key?(qr)
    self.incomplete = nil unless incomplete
  end

  # The matching receipts, newest first.
  def scope
    without_status.then { |relation| status ? relation.where(status:) : relation }
  end

  # Every filter except the status: what the counts per status are taken over.
  def without_status
    relation = Receipt.newest_first
    relation = relation.in_batch(batch) if batch
    relation = kind_scope(relation)
    relation = relation.with_tax_qr if qr == "with"
    relation = relation.without_tax_qr if qr == "without"
    relation = relation.incomplete_only if incomplete
    relation
  end

  # Receipts per status under the other filters, every status present (zero when none).
  def status_counts
    counts = without_status.unscope(:order).group(:status).count
    Receipt.statuses.keys.index_with { |status| counts.fetch(status, 0) }
  end

  # The filter as URL parameters, only the values that are set.
  def to_params
    { batch:, status:, kind:, qr:, incomplete: (incomplete ? "1" : nil) }.compact
  end

  # The same filter with some values changed (nil removes one).
  def merge(changes)
    self.class.new(to_params.merge(changes).compact)
  end

  def any?
    to_params.any?
  end

  # The ids before and after `receipt` in the filtered order, or nil at either end and when the receipt is
  # not in the filter (any more). Plucks the ids of the whole filter: a few thousand integers at most.
  def neighbours(receipt)
    ids = scope.pluck(:id)
    index = ids.index(receipt.id)
    return [ nil, nil ] unless index

    [ (ids[index - 1] if index.positive?), ids[index + 1] ]
  end

  # The batches that exist, for the batch select.
  def self.batches
    Receipt.where.not(batch: nil).distinct.order(:batch).pluck(:batch)
  end

  private
    def kind_scope(relation)
      case kind
      when "unknown" then relation.kind_unknown
      when nil then relation
      else relation.where(kind:)
      end
    end
end
