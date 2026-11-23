# One category share of a transaction (the split). An ordinary purchase has one line; a supermarket receipt
# may have several (groceries, household, ...). Reports sum lines, so split and unsplit transactions take
# the same path. A line with no category is "not categorised yet".
#
# The lines of a transaction must sum to its amount. Through the parent (nested attributes) the parent
# checks that. A line saved on its own may change its category or comment freely. When it changes an amount
# (or is new), it locks the transaction row and checks the sum against what is stored: the transaction's
# saved amount and the saved sibling lines, never a copy in memory that may hold unsaved or stale values.
# Such a save also bumps the transaction's lock_version, so a stale copy of the transaction cannot write
# lines over it. A line cannot be destroyed on its own at all (remove it through the parent with `_destroy`
# and a matching amount change).
#
# Lines do not need the sign of their transaction: a receipt can hold an opposite-sign item (a bottle
# deposit returned). Only non-zero and the exact sum are required.
#
# `legacy_category_path` keeps the category path of the old app ("Food / Snacks") when the history
# importer brings the line in, so the original label is never lost.
#
# The transaction categoriser's suggestion for a line that is not categorised yet (no category, or the taxonomy's
# Uncategorised) is stored on the line: the best category and its probability, the runner-up, where it came from
# (`suggestion_source`: model, history or mix), which artefact made it (`suggestion_model_version`) and when.
# Filling it (Transactions::SuggestCategories) writes those columns only, never the category, the amount or the
# transaction's lock_version: a suggestion is not an edit.
#
# `category_origin` says how a person set the category through the transaction list or page
# (Transactions::Categorise): `person` (chosen by hand, also every correction made with "Change", which never
# records a taken suggestion), `suggestion` (the suggestion taken, one line at a time) or `bulk` (taken by a bulk
# acceptance), with the taken suggestion's probability and artefact. Nil means set elsewhere (the history
# import, a receipt, manual entry). A retraining tells its own accepted output from a person's labels by it
# (docs/decisions/0006-transaction-categoriser.md, "Serving").
#
# `belongs_to :transaction` would clash with the Active Record `transaction` method, so the association is
# named `parent`.
class TransactionLine < ApplicationRecord
  belongs_to :parent, class_name: "Transaction", foreign_key: :transaction_id, inverse_of: :lines
  belongs_to :category, optional: true
  belongs_to :suggested_category, class_name: "Category", optional: true
  belongs_to :runner_up_category, class_name: "Category", optional: true

  CATEGORY_ORIGINS = %w[person suggestion bulk].freeze
  SUGGESTION_SOURCES = %w[model history mix].freeze

  # Lines nobody has categorised yet: no category, or the taxonomy's Uncategorised.
  scope :uncategorised, -> {
    where(category_id: nil).or(where(category_id: Category.where(slug: Category::UNCATEGORISED_SLUG).select(:id)))
  }

  before_destroy :forbid_standalone_destroy
  after_save :bump_parent_lock_version, if: :standalone_amount_write?

  normalizes :legacy_category_path, with: ->(value) { value.strip.presence }

  validates :amount, presence: true,
    numericality: { other_than: 0, greater_than: -Transaction::AMOUNT_LIMIT, less_than: Transaction::AMOUNT_LIMIT },
    decimal_places: { maximum: Transaction::MONEY_DECIMAL_PLACES }
  validate :parent_is_not_a_transfer_leg
  validate :standalone_change_keeps_sum
  validate :category_is_a_leaf, if: -> { category_id.present? && will_save_change_to_category_id? }
  validates :category_origin, inclusion: { in: CATEGORY_ORIGINS }, allow_nil: true
  validates :suggestion_source, inclusion: { in: SUGGESTION_SOURCES }, allow_nil: true
  validates :suggestion_probability, :runner_up_probability, :category_origin_probability,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :category, presence: { message: "must be set when its origin is" }, if: -> { category_origin.present? }
  validates :category_origin_probability, :category_origin_model_version, presence: true,
    if: -> { category_origin.in?(%w[suggestion bulk]) }

  # True when nobody has categorised the line yet (no category, or Uncategorised).
  def uncategorised?
    category_id.nil? || category&.slug == Category::UNCATEGORISED_SLUG
  end

  def suggestion?
    suggested_category_id.present?
  end

  private
    def managed_by_parent?
      parent&.managing_lines?
    end

    # Checks the copy in memory; a standalone amount write checks the stored row as well.
    def parent_is_not_a_transfer_leg
      errors.add(:parent, "is a transfer leg, which cannot have lines") if parent&.transfer_leg?
    end

    # Runs inside the save's database transaction, so the row lock is held until commit: a parallel save of
    # the transaction or of another line waits for this one.
    def standalone_change_keeps_sum
      return if managed_by_parent? || parent.nil? || amount.blank?

      if persisted? && transaction_id_changed?
        errors.add(:parent, "cannot change: the old transaction's lines would no longer add up")
      elsif new_record? || amount_changed?
        check_sum_against_stored_parent
      end
    end

    def check_sum_against_stored_parent
      if parent.new_record?
        errors.add(:parent, "must be saved first: add new lines through the transaction")
        return
      end

      stored_amount, transfer_id = Transaction.where(id: transaction_id).lock.pick(:amount, :transfer_id)
      return if stored_amount.nil? # the transaction is gone; the foreign key refuses the line

      if transfer_id
        errors.add(:parent, "is a transfer leg, which cannot have lines") unless errors.include?(:parent)
      elsif TransactionLine.where(transaction_id:).where.not(id:).sum(:amount) + amount != stored_amount
        errors.add(:amount, "must keep the lines adding up to the transaction amount")
      end
    end

    def standalone_amount_write?
      !managed_by_parent? && (previously_new_record? || saved_change_to_amount?)
    end

    # A copy of the transaction read before this save holds old lines; bumping the version makes its next
    # save fail with ActiveRecord::StaleObjectError instead of checking the sum against those old lines.
    def bump_parent_lock_version
      Transaction.where(id: transaction_id).update_all([ "lock_version = lock_version + 1, updated_at = ?", Time.current ])
    end

    def category_is_a_leaf
      if category.nil?
        errors.add(:category, "does not exist")
      elsif category.group?
        errors.add(:category, "must be a category, not a group")
      end
    end

    def forbid_standalone_destroy
      return if managed_by_parent?

      errors.add(:base, "cannot be removed on its own: remove it through its transaction and adjust the amount")
      throw :abort
    end
end
