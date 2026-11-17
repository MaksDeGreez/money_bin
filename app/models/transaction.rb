# One movement of money on one account. The amount is signed and in the account currency: an expense is
# negative, an income positive, never zero. So an account balance is a plain SUM(amount).
#
# Categories live on lines (TransactionLine), not here. A transaction that is not a transfer leg has at
# least one line, and its lines sum exactly to its amount. Lines are written through the transaction
# (nested attributes), which checks the sum; a line saved on its own cannot break it (see TransactionLine).
#
# A transfer between two own accounts is two transactions, one per account, that share a `transfer_id`
# (see Transaction::Transferable). Transfer legs have no lines.
#
# Dates: `occurred_on` is the Kyiv calendar date that every list and report uses. `occurred_at` is the
# exact moment when a source knows it (a bank feed, a receipt), else nil. Neither is derived from the other.
#
# `original_amount` in `original_currency` is the operation amount when it was in another currency than
# the account's (a USD purchase paid from a UAH card). Both or neither; same sign as `amount`.
#
# `source` says where the row came from; with `external_id` (that source's own id for it) it makes imports
# idempotent. `status` is the review state: `confirmed` by default, `needs_review` when something still
# needs a person (an uncategorised line), `draft` for a row that is still being prepared.
#
# Naming: Active Record has a `transaction` method, so no association may be called `transaction`
# (`belongs_to :transaction` raises ArgumentError). Lines point back with `parent`, a receipt with
# `ledger_transaction`. The model itself can still be called Transaction.
class Transaction < ApplicationRecord
  # decimal(15, 2) holds magnitudes below 10^13.
  AMOUNT_LIMIT = 10**13
  MCC_FORMAT = /\A\d{4}\z/

  include Transferable

  enum :source, { legacy: "legacy", receipt: "receipt", manual: "manual", api: "api", bank: "bank" },
    prefix: :from, validate: true
  enum :status, { draft: "draft", needs_review: "needs_review", confirmed: "confirmed" }, validate: true

  # Declared before `has_many :lines` so the flag is already on when its `dependent: :destroy` runs.
  around_save :managing_lines
  around_destroy :managing_lines

  belongs_to :account
  belongs_to :payee, optional: true
  has_many :lines, -> { order(:id) }, class_name: "TransactionLine", foreign_key: :transaction_id, inverse_of: :parent,
    dependent: :destroy

  accepts_nested_attributes_for :lines, allow_destroy: true

  scope :between, ->(from, to) { where(occurred_on: from..to) }
  scope :recent, -> { order(occurred_on: :desc, id: :desc) }
  scope :transfer_legs, -> { where.not(transfer_id: nil) }
  scope :expenses, -> { where(transfer_id: nil).where(amount: ...0) }
  scope :incomes, -> { where(transfer_id: nil).where(arel_table[:amount].gt(0)) }

  normalizes :original_currency, with: ->(value) { value.strip.upcase.presence }
  normalizes :mcc, :external_id, with: ->(value) { value.strip.presence }

  validates :occurred_on, presence: true
  validates :amount, presence: true, numericality: { other_than: 0, greater_than: -AMOUNT_LIMIT, less_than: AMOUNT_LIMIT }
  validates :mcc, format: { with: MCC_FORMAT, message: "must be exactly four digits" }, allow_nil: true
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true
  validate :payee_exists, if: -> { payee_id.present? && will_save_change_to_payee_id? }
  validate :original_amount_is_consistent
  validate :lines_add_up, unless: :transfer_leg?

  def transfer_leg?
    transfer_id.present?
  end

  def expense?
    !transfer_leg? && amount.present? && amount.negative?
  end

  def income?
    !transfer_leg? && amount.present? && amount.positive?
  end

  # The lines that will remain after the next save.
  def kept_lines
    lines.reject(&:marked_for_destruction?)
  end

  # True while this transaction validates, saves or destroys itself. Lines touched then are covered by
  # lines_add_up, so TransactionLine skips the checks it runs when a line is saved on its own.
  def managing_lines?
    @managing_lines == true
  end

  # Autosaved lines are written with `validate: false`; they are validated here, during the parent's
  # validation, which runs before (outside) the save callbacks. So the flag has to cover it too.
  def valid?(context = nil)
    managing_lines { super }
  end

  private
    def managing_lines
      was_managing, @managing_lines = @managing_lines, true
      yield
    ensure
      @managing_lines = was_managing
    end

    # The payee is optional, so belongs_to does not check it; a made-up id would otherwise surface as
    # ActiveRecord::InvalidForeignKey.
    def payee_exists
      errors.add(:payee, "does not exist") if payee.nil?
    end

    # Mirrors the check constraint transactions_original_amount_consistent, plus the rule the database
    # cannot see: the original currency differs from the account's (else it would just be the amount).
    def original_amount_is_consistent
      return if original_amount.nil? && original_currency.nil?

      if original_amount.nil? || original_currency.nil?
        errors.add(:base, "Original amount and original currency must be set together")
        return
      end

      if !original_currency.match?(Account::CURRENCY_FORMAT)
        errors.add(:original_currency, "must be three letters (ISO 4217)")
      elsif account && original_currency == account.currency
        errors.add(:original_currency, "must differ from the account currency")
      end

      if original_amount.zero?
        errors.add(:original_amount, "must be other than 0")
      elsif original_amount.abs >= AMOUNT_LIMIT
        errors.add(:original_amount, "must be less than #{AMOUNT_LIMIT} in magnitude")
      elsif amount.present? && amount.nonzero? && original_amount.positive? != amount.positive?
        errors.add(:original_amount, "must have the same sign as the amount")
      end
    end

    # Lines may have either sign (a receipt can hold a small refund, such as a bottle deposit); only the
    # exact sum matters. Amounts are BigDecimal, so the comparison is exact.
    def lines_add_up
      kept = kept_lines

      if kept.empty?
        errors.add(:lines, "must have at least one line")
      elsif amount.present? && kept.sum(BigDecimal("0")) { |line| line.amount || 0 } != amount
        errors.add(:lines, :unbalanced, message: "must add up to the transaction amount")
      end
    end
end
