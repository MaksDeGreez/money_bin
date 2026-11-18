# An expense entered by hand, without a receipt (`/transactions/new`, docs/domain.md, "Manual entry").
#
#   expense = ManualExpense.new(account_id: 1, payee_name: "Corner Shop", occurred_on: "2026-10-08",
#                               rows: [{ name: "Bread", amount: "40,40", category_id: 3 }])
#   expense.save  # => true, and expense.transaction is the booked Transaction
#
# One expense transaction with `source: manual`: amount = minus the rows' sum, lines = the row amounts summed
# per category (CategoryLines, the rule receipt acceptance books by). `needs_review` when a line has no
# category, `confirmed` otherwise. The rows themselves are not stored: without a receipt there is nothing
# to hang items on, so only the lines remain.
#
# Amounts go through MoneyInput (a comma is a decimal separator) and are validated as typed: more than two
# decimal places is an error, never rounded. A row may be negative (a deposit returned) or zero, but the
# rows must sum above zero: this form books expenses only. Incomes and transfers are not entered here.
#
# The payee (optional) is found by its normalised name or created, inside the same database transaction as
# the transaction, so a failure leaves neither behind.
class ManualExpense
  include ActiveModel::Model
  include ActiveModel::Attributes

  TIME_FORMAT = /\A([01]\d|2[0-3]):([0-5]\d)\z/

  # One typed row: a name for the person's memory, an amount and a category.
  class Row
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :name, :string
    attribute :amount, :string
    attribute :category_id, :string

    validate :amount_is_money
    validate :category_is_a_category

    def blank?
      name.blank? && amount.blank? && category_id.blank?
    end

    # The exact amount, a BigDecimal (valid rows only).
    def decimal_amount
      BigDecimal(MoneyInput.normalize(amount))
    end

    def category
      @category ||= Category.find_by(id: category_id) if category_id.present?
    end

    # For CategoryLines.
    def entry
      CategoryLines::Entry.new(category_id: category&.id, amount: decimal_amount)
    end

    private
      def amount_is_money
        normalized = MoneyInput.normalize(amount)
        if normalized.blank?
          errors.add(:amount, normalized.nil? ? MoneyInput::MESSAGE : "can't be blank")
        elsif !DecimalPlacesValidator.fits?(normalized, Transaction::MONEY_DECIMAL_PLACES)
          errors.add(:amount, "must have at most #{Transaction::MONEY_DECIMAL_PLACES} decimal places (it is never rounded)")
        elsif BigDecimal(normalized).abs >= Transaction::AMOUNT_LIMIT
          errors.add(:amount, "is too large")
        end
      end

      def category_is_a_category
        return if category_id.blank?

        if category.nil?
          errors.add(:category_id, "does not exist")
        elsif category.group?
          errors.add(:category_id, "must be a category, not a group")
        end
      end
  end

  attribute :account_id, :integer
  attribute :payee_name, :string
  attribute :occurred_on, :string
  attribute :occurred_time, :string

  attr_reader :rows, :transaction

  validate :account_is_active
  validate :date_is_valid
  validate :time_is_valid
  validate :rows_are_valid

  def initialize(attributes = {})
    attributes = attributes.to_h.with_indifferent_access
    rows = attributes.delete(:rows)
    super(attributes.slice(*self.class.attribute_names))
    self.rows = rows
  end

  # Rows from the form: an Array or a Hash of index => attributes. Rows left completely blank are dropped.
  def rows=(rows)
    rows = rows.values if rows.respond_to?(:values) && !rows.is_a?(Array)
    @rows = Array(rows).map { |row| Row.new(row.to_h.with_indifferent_access.slice(:name, :amount, :category_id)) }.reject(&:blank?)
  end

  def account
    @account ||= Account.active.find_by(id: account_id) if account_id
  end

  def date
    Date.iso8601(occurred_on) if occurred_on.present?
  rescue Date::Error
    nil
  end

  # The moment in Kyiv time (config.time_zone), or nil without a time.
  def occurred_at
    return if date.nil? || occurred_time.blank? || !occurred_time.strip.match?(TIME_FORMAT)

    hour, minute = occurred_time.strip.split(":").map(&:to_i)
    Time.zone.local(date.year, date.month, date.day, hour, minute)
  end

  def total
    CategoryLines.total(rows.map(&:entry))
  end

  def save
    return false unless valid?

    lines = CategoryLines.build(rows.map(&:entry), sign: -1)
    Transaction.transaction do
      @transaction = Transaction.create!(
        account:, amount: -total, occurred_on: date, occurred_at:, payee:, source: :manual,
        status: CategoryLines.uncategorised?(lines) ? :needs_review : :confirmed, lines_attributes: lines
      )
    end
    true
  rescue ActiveRecord::RecordInvalid => error
    @transaction = nil
    error.record.errors.full_messages.each { |message| errors.add(:base, message) }
    false
  end

  private
    def payee
      Payee.find_or_create_by_name!(payee_name) unless Payee.normalize_name(payee_name).empty?
    end

    def account_is_active
      errors.add(:account_id, "must be one of your accounts that is not archived") if account.nil?
    end

    def date_is_valid
      errors.add(:occurred_on, "must be a date") if date.nil?
    end

    def time_is_valid
      return if occurred_time.blank? || occurred_time.strip.match?(TIME_FORMAT)

      errors.add(:occurred_time, "must be a time such as 18:40")
    end

    def rows_are_valid
      if rows.empty?
        errors.add(:base, "Add at least one row with an amount")
        return
      end

      if rows.map(&:valid?).include?(false)
        errors.add(:rows, "need a fix: they are marked below")
        return
      end

      errors.add(:base, "The rows sum to #{total.to_s('F')}: this form books expenses, so the rows must sum above zero") unless total.positive?
    end
end
