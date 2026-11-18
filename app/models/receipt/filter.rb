# The receipts list filter: batch, status, kind, tax QR, "incomplete", ground truth, the check of a
# tax-service record and the OCR batch (`ocr_batch`: the receipts sent in one, linked from the batches page),
# kept in the URL as GET parameters, so a filtered list can be bookmarked, reloaded, and
# returned to from a receipt.
#
#   filter = Receipt::Filter.new(params.permit(*Receipt::Filter::KEYS))
#   filter.scope              # the matching receipts, newest first
#   filter.to_params          # { status: "failed", batch: "october" }, only the values that are set
#   filter.status_counts      # { "uploaded" => 12, ... } with every filter but the status applied
#   filter.neighbours(receipt) # [previous, next] receipt ids inside the filter, nil at either end
#   filter.next_to_review(receipt) # the next receipt of the filter still waiting for review, or nil
#   filter.next_to_label(receipt)  # the next receipt of the filter without manual ground truth, or nil
#   filter.truth_counts       # { "manual" => 3, ... } with every filter but the ground-truth one applied
#   filter.check_counts       # { "checked" => 1, "unchecked" => 2 } with every filter but the check applied
#   filter.labelling_progress # receipts in the list (any ground truth), those labelled by hand, and their items
#
# A value that is not one of the choices is ignored (the list shows everything for that filter), so an
# old or edited URL never fails.
class Receipt::Filter
  include ActiveModel::Model
  include ActiveModel::Attributes

  KEYS = %i[batch status kind qr incomplete truth check ocr_batch].freeze
  KINDS = { "fiscal" => "Fiscal receipt", "card_slip" => "Card slip", "unknown" => "Not known yet" }.freeze
  QR_CHOICES = { "with" => "Has tax-service QR data", "without" => "No tax-service QR data" }.freeze
  # Ground truth: `manual` and `unlabelled` split the list by a person's record (what is left to label);
  # `dps_xml` has a tax-service record; `none` has no record from any source.
  TRUTH_CHOICES = {
    "manual" => "Labelled by hand", "unlabelled" => "Not labelled by hand", "dps_xml" => "Has a tax-service record",
    "none" => "No ground truth"
  }.freeze
  CHECK_CHOICES = { "checked" => "Checked against the print", "unchecked" => "Not checked yet" }.freeze
  Progress = Data.define(:receipts, :labelled, :labelled_items)

  attribute :batch, :string
  attribute :status, :string
  attribute :kind, :string
  attribute :qr, :string
  attribute :incomplete, :boolean
  attribute :truth, :string
  attribute :check, :string
  attribute :ocr_batch, :integer

  def initialize(attributes = {})
    super(attributes.to_h.symbolize_keys.slice(*KEYS))
    self.batch = batch.presence
    self.status = nil unless Receipt.statuses.key?(status)
    self.kind = nil unless KINDS.key?(kind)
    self.qr = nil unless QR_CHOICES.key?(qr)
    self.incomplete = nil unless incomplete
    self.truth = nil unless TRUTH_CHOICES.key?(truth)
    self.check = nil unless CHECK_CHOICES.key?(check)
    self.ocr_batch = nil unless ocr_batch.to_i.positive?
  end

  # The matching receipts, newest first.
  def scope
    scope_without
  end

  # Every filter except the status: what the counts per status are taken over.
  def without_status
    scope_without(:status)
  end

  # Every filter except those named: what the counts of one filter are taken over.
  def scope_without(*keys)
    relation = Receipt.newest_first
    relation = relation.in_batch(batch) if batch
    relation = kind_scope(relation)
    relation = relation.with_tax_qr if qr == "with"
    relation = relation.without_tax_qr if qr == "without"
    relation = relation.incomplete_only if incomplete
    relation = relation.where(id: OcrBatchEntry.where(ocr_batch_id: ocr_batch).select(:receipt_id)) if ocr_batch
    relation = truth_scope(relation) unless keys.include?(:truth)
    relation = check_scope(relation) unless keys.include?(:check)
    relation = relation.where(status:) if status && !keys.include?(:status)
    relation
  end

  # Receipts per status under the other filters, every status present (zero when none).
  def status_counts
    counts = without_status.unscope(:order).group(:status).count
    Receipt.statuses.keys.index_with { |status| counts.fetch(status, 0) }
  end

  # The filter as URL parameters, only the values that are set.
  def to_params
    { batch:, status:, kind:, qr:, incomplete: (incomplete ? "1" : nil), truth:, check:, ocr_batch: }.compact
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

  # The id of the next receipt after `receipt`, in the filtered order, that still waits for a person
  # (`extracted`), wrapping around to the start; nil when there is none. `receipt` itself may have left the
  # filter (it was just accepted, so a status filter no longer matches it): its place is found in the list
  # without the status filter.
  def next_to_review(receipt)
    return nil if status && status != "extracted"

    rows = without_status.pluck(:id, :status)
    index = rows.index { |id, _| id == receipt.id }
    rows = rows[(index + 1)..] + rows[0...index] if index
    rows.find { |id, row_status| row_status == "extracted" && id != receipt.id }&.first
  end

  # The id of the next receipt after `receipt`, in the filtered order, that has no manual ground truth and
  # whose form is open (`extracted` or `reviewed`, no OCR queued or running), wrapping around; nil when there
  # is none. `receipt` itself may have left the filter (it was just labelled, so "Not labelled by hand" no
  # longer matches it): its place is found in the list without the ground-truth filter.
  def next_to_label(receipt)
    order = scope_without(:truth).pluck(:id)
    candidates = scope.without_ground_truth(:manual).where(status: Receipt::REVIEWABLE_STATUSES)
      .where("receipts.ocr_requested_at IS NULL OR receipts.ocr_requested_at <= ?", Receipt::OCR_REQUEST_LOST_AFTER.ago)
      .pluck(:id).to_set
    index = order.index(receipt.id)
    order = order[(index + 1)..] + order[0...index] if index
    order.find { |id| id != receipt.id && candidates.include?(id) }
  end

  # Receipts per ground-truth choice under the other filters.
  def truth_counts
    relation = scope_without(:truth).unscope(:order)
    TRUTH_CHOICES.keys.index_with { |choice| truth_scope(relation, choice).count }
  end

  # Receipts with a tax-service record per check state, under the other filters.
  def check_counts
    relation = scope_without(:check).unscope(:order)
    CHECK_CHOICES.keys.index_with { |choice| check_scope(relation, choice).count }
  end

  # How far labelling is in this list: its receipts, those with manual ground truth, and the items those
  # records hold. The ground-truth filter is left out, so "Not labelled by hand" still shows the progress
  # (under it, every receipt shown is unlabelled by definition).
  def labelling_progress
    relation = scope_without(:truth).unscope(:order)
    records = ReceiptGroundTruth.manual.where(receipt_id: relation.select(:id))
    Progress.new(receipts: relation.count, labelled: records.count,
      labelled_items: records.sum(Arel.sql("jsonb_array_length(document -> 'items')")).to_i)
  end

  # The batches that exist, for the batch select.
  def self.batches
    Receipt.where.not(batch: nil).distinct.order(:batch).pluck(:batch)
  end

  private
    def truth_scope(relation, choice = truth)
      case choice
      when "manual" then relation.with_ground_truth(:manual)
      when "unlabelled" then relation.without_ground_truth(:manual)
      when "dps_xml" then relation.with_ground_truth(:dps_xml)
      when "none" then relation.without_ground_truth
      else relation
      end
    end

    def check_scope(relation, choice = check)
      case choice
      when "checked" then relation.with_ground_truth(:dps_xml, checked: true)
      when "unchecked" then relation.with_ground_truth(:dps_xml, checked: false)
      else relation
      end
    end

    def kind_scope(relation)
      case kind
      when "unknown" then relation.kind_unknown
      when nil then relation
      else relation.where(kind:)
      end
    end
end
