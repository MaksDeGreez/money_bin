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
# idempotent. `source_system` is the system a row first came from (a bank feed, an older budgeting app),
# set by importers; it is free text and may be nil. `status` says whether the money is booked:
# - `draft`: a proposal (from an AI agent, or waiting for a receipt) that nobody has accepted yet. It is not
#   counted in balances or reports, but every other rule (the line sum, the transfer rules) still applies;
# - `needs_review`: booked and counted, but a person should still look (an uncategorised line);
# - `confirmed` (the default): booked, counted and complete.
# `booked` is the scope of the counted rows; `draft` (from the enum) is its opposite. Balances and the
# `expenses` / `incomes` scopes use only booked rows.
#
# Concurrent writers: `lock_version` turns on Active Record's optimistic locking. Saving or destroying a stale
# copy raises ActiveRecord::StaleObjectError. A save that changes only lines still bumps the version (it
# touches `updated_at`), so two stale copies can never both write lines (docs/domain.md, "Concurrent writers").
#
# Naming: Active Record has a `transaction` method, so no association may be called `transaction`
# (`belongs_to :transaction` raises ArgumentError). Lines point back with `parent`, a receipt with
# `ledger_transaction`. The model itself can still be called Transaction.
class Transaction < ApplicationRecord
  # decimal(15, 2) holds magnitudes below 10^13.
  AMOUNT_LIMIT = 10**13
  # Money has at most two decimal places; more is refused, never rounded (DecimalPlacesValidator).
  MONEY_DECIMAL_PLACES = 2
  MCC_FORMAT = /\A\d{4}\z/
  # The statuses whose money counts in balances and reports. A draft is only a proposal.
  BOOKED_STATUSES = %w[needs_review confirmed].freeze

  include Transferable

  enum :source, { legacy: "legacy", receipt: "receipt", manual: "manual", api: "api", bank: "bank" },
    prefix: :from, validate: true
  enum :status, { draft: "draft", needs_review: "needs_review", confirmed: "confirmed" }, validate: true

  # Declared before `has_many :lines` so the flag is already on when its `dependent: :destroy` runs.
  around_save :managing_lines
  around_destroy :managing_lines
  before_save :touch_when_only_lines_change, if: :persisted?

  belongs_to :account
  belongs_to :payee, optional: true
  has_many :lines, -> { order(:id) }, class_name: "TransactionLine", foreign_key: :transaction_id, inverse_of: :parent,
    dependent: :destroy
  # The receipt this transaction was booked from, if any. Destroying the transaction keeps the receipt and
  # sends it back to review (release_receipt).
  has_one :receipt, foreign_key: :transaction_id, inverse_of: :ledger_transaction
  before_destroy :release_receipt
  # The record of the receipt booking on this transaction (ReceiptBooking); the database deletes it with the row.
  has_one :receipt_booking, foreign_key: :transaction_id, inverse_of: :ledger_transaction

  accepts_nested_attributes_for :lines, allow_destroy: true

  scope :between, ->(from, to) { where(occurred_on: from..to) }
  scope :recent, -> { order(occurred_on: :desc, id: :desc) }
  scope :booked, -> { where(status: BOOKED_STATUSES) }
  scope :transfer_legs, -> { where.not(transfer_id: nil) }
  # For reports, so booked rows only: a draft expense is not money spent yet.
  scope :expenses, -> { booked.where(transfer_id: nil).where(amount: ...0) }
  scope :incomes, -> { booked.where(transfer_id: nil).where(arel_table[:amount].gt(0)) }

  normalizes :original_currency, with: ->(value) { value.strip.upcase.presence }
  normalizes :mcc, :external_id, with: ->(value) { value.strip.presence }

  validates :occurred_on, presence: true
  validates :amount, presence: true, numericality: { other_than: 0, greater_than: -AMOUNT_LIMIT, less_than: AMOUNT_LIMIT }
  validates :amount, :original_amount, decimal_places: { maximum: MONEY_DECIMAL_PLACES }
  validates :mcc, format: { with: MCC_FORMAT, message: "must be exactly four digits" }, allow_nil: true
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true
  validate :payee_exists, if: -> { payee_id.present? && will_save_change_to_payee_id? }
  validate :original_amount_is_consistent
  validate :account_currency_fixed, on: :update, if: :will_save_change_to_account_id?
  validate :lines_add_up, unless: :transfer_leg?

  def transfer_leg?
    transfer_id.present?
  end

  # True when the money counts in balances and reports (needs_review or confirmed), false for a draft.
  def booked?
    BOOKED_STATUSES.include?(status)
  end

  # The status this transaction should have once its lines are as they are in memory, for a change that only
  # categorises lines (Transactions::Categorise). A `needs_review` transaction becomes `confirmed` when no kept line
  # is uncategorised any more (no category, or Uncategorised) and nothing else still needs a look (a receipt whose
  # items do not sum to its printed total: Receipts::Accept.review_reasons). A draft stays a draft (categorising
  # books nothing) and a confirmed one stays confirmed.
  def status_after_categorising
    return status unless needs_review?
    return status if kept_lines.any?(&:uncategorised?)

    lines = kept_lines.map { |line| { category_id: line.category_id } }
    return status if receipt && Receipts::Accept.review_reasons(receipt, lines).any?

    "confirmed"
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

  # True when the next save writes a line: a new one, a changed one or one marked for destruction. Only lines
  # already in memory can change, so this never loads the association.
  def lines_changing?
    association(:lines).target.any? do |line|
      line.new_record? || line.marked_for_destruction? || line.has_changes_to_save?
    end
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

    # A `reviewed` receipt means "booked into the ledger". Without its transaction it is not, so it goes back
    # to `extracted` and can be accepted again; its items stay. Runs in the destroy's database transaction,
    # so a failed destroy changes nothing. update_columns: the unlink must not depend on the receipt's other
    # validations. It moves the receipt's lock_version, so a review form rendered while it was booked
    # ("Accept again") is refused instead of booking it anew unseen.
    def release_receipt
      receipt = Receipt.lock.find_by(transaction_id: id)
      return unless receipt

      status = receipt.reviewed? ? "extracted" : receipt.status
      receipt.update_columns(transaction_id: nil, status:, lock_version: receipt.lock_version + 1, updated_at: Time.current)
    end

    # A save that changes only lines would not write the transaction row, so it would not check or bump
    # lock_version. Touching updated_at makes it write the row, so a stale copy fails here.
    def touch_when_only_lines_change
      self.updated_at = Time.current if lines_changing? && !has_changes_to_save?
    end

    # The payee is optional, so belongs_to does not check it; a made-up id would otherwise surface as
    # ActiveRecord::InvalidForeignKey.
    def payee_exists
      errors.add(:payee, "does not exist") if payee.nil?
    end

    # The amount is in the account currency, so moving it to an account in another currency would keep the
    # number and change its meaning (UAH -100 would become USD -100). Same-currency moves are fine.
    def account_currency_fixed
      old_currency = Account.where(id: account_id_in_database).pick(:currency)
      return if account.nil? || old_currency.nil? || old_currency == account.currency

      errors.add(:account, "cannot change to an account in another currency (#{old_currency} to #{account.currency}): " \
        "the amount would keep its number and change its meaning; enter it again on the new account")
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
