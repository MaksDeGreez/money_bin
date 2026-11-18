# What the owner already called an item with the same name (docs/domain.md, "Label memory").
#
#   memory = LabelMemory.new
#   memory.lookup([ "Мол 900г", "Хліб" ])  # => { "мол900г" => LabelMemory::Suggestion, ... }
#
# Only labels a person gave count: items with `accepted_by_user` and a category (a suggestion taken with "Use"
# or "Accept suggestions" counts too: the person took it). The receipt being suggested for is left out
# (`except_receipt`): an item's own label is not a memory of it. Names are matched by ItemName.key. For each key the
# category given most often is suggested when it has a strict majority (more than half of the labels); a tie
# or a split vote suggests nothing, and the model decides.
#
# The confidence: with `labels` labels of which `agreeing` agree, (agreeing + 1) / (labels + 1.25). That is
# the mean of a Beta(1 + agreeing, 0.25 + labels - agreeing) posterior for "the next item with this name gets
# this category", starting from a weak prior that a name keeps its category (mean 0.8, worth 1.25 labels).
# One label gives 0.89, two that agree 0.92, four 0.95; a disagreement pulls it down fast (2 of 3: 0.71). So
# with the review form's default threshold (90%) one earlier label is not enough to accept in bulk, two are.
# It is the memory's own rule, not a measured precision; the evaluation measures it like a model's.
#
# Only `categories` (by default the item categoriser's candidates, Categories::ItemCandidates) can be
# suggested: a label outside them (Uncategorised) is not repeated.
class LabelMemory
  # The name a receipt records (`categoriser_model_name`) when the label memory filled its suggestions: for the
  # pre-fill rule of the ground truth, the memory is a categoriser like a model. Never starts with "source:".
  CATEGORISER_NAME = "label-memory".freeze
  PRIOR_AGREEING = 1.0
  PRIOR_DISAGREEING = 0.25

  Suggestion = Data.define(:category_id, :labels, :agreeing, :confidence)

  def self.confidence(agreeing, labels)
    (agreeing + PRIOR_AGREEING) / (labels + PRIOR_AGREEING + PRIOR_DISAGREEING)
  end

  def initialize(categories: Categories::ItemCandidates.all)
    @category_ids = categories.map(&:id)
  end

  # name keys => Suggestion, for the names that have one.
  def lookup(names, except_receipt: nil)
    keys = names.map { |name| ItemName.key(name) }.reject(&:empty?).uniq
    return {} if keys.empty? || @category_ids.empty?

    labels = ReceiptItem.where(accepted_by_user: true, name_key: keys, category_id: @category_ids)
    labels = labels.where.not(receipt_id: except_receipt.id) if except_receipt
    counts = labels.group(:name_key, :category_id).count
    counts.group_by { |(key, _category_id), _count| key }.filter_map do |key, rows|
      labels = rows.sum { |_pair, count| count }
      (_key, category_id), agreeing = rows.max_by { |(_key, id), count| [ count, -id ] }
      next unless agreeing * 2 > labels

      [ key, Suggestion.new(category_id:, labels:, agreeing:, confidence: self.class.confidence(agreeing, labels)) ]
    end.to_h
  end
end
