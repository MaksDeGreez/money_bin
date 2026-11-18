# One transaction of a bulk acceptance as it was previewed (BulkAcceptance): its lock_version, the uncategorised
# lines to categorise, and the suggestion to take (category, probability, artefact). `outcome` is nil until the job
# handles it, then `accepted`, `stale` (the transaction was edited after the preview) or `changed` (a line has a
# category by now, or a different suggestion).
class BulkAcceptanceItem < ApplicationRecord
  OUTCOMES = %w[accepted stale changed].freeze

  belongs_to :bulk_acceptance, inverse_of: :items
  belongs_to :ledger_transaction, class_name: "Transaction", foreign_key: :transaction_id
  belongs_to :category

  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :probability, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :line_ids, presence: true

  # Applies this item at most once: under the item's row lock, an item that already has an outcome is left alone
  # (a retried or doubled job), and the categorising and the outcome are written in one database transaction.
  # Returns the outcome.
  def apply!
    transaction do
      lock!
      next outcome if outcome

      update!(outcome: decide)
      outcome
    end
  end

  private
    def decide
      return "changed" unless suggestion_unchanged?

      choices = line_ids.map do |line_id|
        Transactions::Categorise::Choice.new(line_id:, category_id:, origin: "bulk", probability:, model_version:)
      end
      case Transactions::Categorise.call(transaction_id, lock_version:, choices:).status
      when :categorised then "accepted"
      when :stale then "stale"
      else "changed"
      end
    end

    # The lines still carry the suggestion the person saw in the preview (a refresh by a new artefact meanwhile
    # would make it another suggestion than the one confirmed).
    def suggestion_unchanged?
      lines = TransactionLine.where(id: line_ids, transaction_id:).pluck(:suggested_category_id, :suggestion_model_version)
      lines.size == line_ids.size && lines.all? { |category, version| category == category_id && version == model_version }
    end
end
