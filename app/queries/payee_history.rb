# What the owner booked under a payee before: the first source of a card slip's category suggestion
# (docs/domain.md, "Card slip suggestions").
#
#   PayeeHistory.new.lookup("Example Market")  # => PayeeHistory::Suggestion, or nil
#
# The name is matched to a payee by the app's payee normalisation (Payee.normalize_name). Its history is its booked
# transactions that are not transfer legs, counted once per category they have a line in (only categories among
# `categories`, so never Uncategorised). The rule is the label memory's: the category of the most transactions,
# when it has a strict majority (a tie, a split transaction's two categories included, suggests nothing), with the confidence (agreeing + 1) / (transactions + 1.25) (LabelMemory.confidence);
# it suggests only from MIN_CONFIDENCE up ("consistent enough": one booking 0.89, two that agree 0.92, 3 of 4 0.76,
# 2 of 3 0.71 is not), and below that the model decides.
class PayeeHistory
  # The name a receipt records (`categoriser_model_name`) when its slip suggestion came from the payee's history.
  CATEGORISER_NAME = "payee-history".freeze
  MIN_CONFIDENCE = 0.75

  Suggestion = Data.define(:category_id, :transactions, :agreeing, :confidence)

  def initialize(categories: Categories::TransactionCandidates.all)
    @category_ids = categories.map(&:id)
  end

  def lookup(name, except_transaction_id: nil)
    payee = Payee.find_by(normalized_name: Payee.normalize_name(name)) if name.present?
    return nil unless payee

    lines = TransactionLine.joins(:parent).merge(Transaction.booked)
      .where(transactions: { payee_id: payee.id, transfer_id: nil }, category_id: @category_ids)
    lines = lines.where.not(transaction_id: except_transaction_id) if except_transaction_id
    counts = lines.group(:category_id).distinct.count(:transaction_id)
    return nil if counts.empty?

    total = lines.distinct.count(:transaction_id)
    (category_id, agreeing), runner_up = counts.sort_by { |id, count| [ -count, id ] }
    return nil if runner_up && runner_up.last == agreeing
    return nil unless agreeing * 2 > total

    confidence = LabelMemory.confidence(agreeing, total)
    return nil if confidence < MIN_CONFIDENCE

    Suggestion.new(category_id:, transactions: total, agreeing:, confidence:)
  end
end
