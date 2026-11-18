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
  # Returns the outcome, or nil when the item is gone (its transaction was deleted meanwhile: the foreign key
  # removes the item with it).
  def apply!
    transaction do
      lock!
      next outcome if outcome

      update!(outcome: decide)
      outcome
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private
    # The suggestion the person confirmed in the preview must still be the one each line stores: Categorise
    # checks that under the transaction's and the lines' row locks (a refresh by a new artefact meanwhile makes
    # it another suggestion, `changed`).
    def decide
      choices = line_ids.map do |line_id|
        Transactions::Categorise::Choice.new(line_id:, category_id:, origin: "bulk", shown_category_id: category_id,
          shown_model_version: model_version)
      end
      case Transactions::Categorise.call(transaction_id, lock_version:, choices:).status
      when :categorised then "accepted"
      when :stale then "stale"
      else "changed"
      end
    end
end
