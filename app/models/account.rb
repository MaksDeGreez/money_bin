# A place where money is kept: a cash wallet, a bank card, a savings account. Every account holds one
# currency (an ISO 4217 code such as UAH or USD). There is no currencies table: the code is enough.
#
# The balance is the plain sum of the account's booked transaction amounts (drafts are proposals and do not
# count), because expenses are negative and incomes positive. For that sum to stay meaningful, the currency
# cannot change once the account has transactions, and an account with transactions cannot be destroyed
# (archive it instead).
#
# `external_id` is the identifier a bank or an importer uses for the account. It is optional and unique.
class Account < ApplicationRecord
  # Three upper-case letters (ISO 4217). Used by every currency column in the app.
  CURRENCY_FORMAT = /\A[A-Z]{3}\z/

  enum :kind, { cash: "cash", debit: "debit", credit: "credit", savings: "savings", ewallet: "ewallet", business: "business" },
    validate: true

  has_many :transactions, dependent: :restrict_with_error

  scope :active, -> { where(archived: false) }

  normalizes :name, with: ->(value) { value.squish }
  normalizes :currency, with: ->(value) { value.strip.upcase }
  normalizes :external_id, with: ->(value) { value.strip.presence }

  validates :name, presence: true, uniqueness: true
  validates :currency, presence: true, format: { with: CURRENCY_FORMAT, message: "must be three letters (ISO 4217)" }
  validates :archived, inclusion: { in: [ true, false ] }
  validates :external_id, uniqueness: true, allow_nil: true
  validate :currency_fixed_once_used, on: :update

  # The sum of the booked transaction amounts (drafts left out), as a BigDecimal in the account currency.
  def balance
    transactions.booked.sum(:amount)
  end

  private
    def currency_fixed_once_used
      errors.add(:currency, "cannot change once the account has transactions") if currency_changed? && transactions.exists?
    end
end
