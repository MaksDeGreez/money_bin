# A transfer moves money between two own accounts. It is stored as two transactions (legs), one on each
# account, that share a `transfer_id`:
#
# - exactly two legs, on two different accounts, with opposite signs (one out, one in);
# - legs have no lines (a transfer is not spending or income);
# - when both accounts use the same currency, the two amounts net to exactly zero. A bank fee is never
#   hidden inside a leg: it is a separate expense transaction;
# - when the currencies differ, the two amounts may be anything (the exchange rate is implied);
# - both legs have the same status, so a draft transfer changes no balance and a booked one changes both.
#   `update_status!` changes the status of both legs together.
#
# Where each rule lives:
# - the unique index index_transactions_one_leg_per_side allows one negative and one positive leg per
#   transfer_id, so the database itself refuses a third leg or two legs of the same sign;
# - saving a leg checks it against its saved counterpart, so a single save cannot break an existing pair;
# - a lone leg is valid on its own (the first leg of a pair is always saved alone). Writers create both legs
#   in one database transaction: Transaction.transfer! does that, and an importer that writes legs itself
#   calls Transaction.transfer_problems(transfer_id) after the second one;
# - destroying one leg destroys the other.
#
# A leg cannot leave its transfer (`transfer_id` cannot change once set), because the other leg would be
# left alone. Amounts of a same-currency pair cannot be changed one leg at a time; destroy the pair and
# create it again.
module Transaction::Transferable
  extend ActiveSupport::Concern

  included do
    after_destroy :destroy_counterpart

    validate :transfer_leg_rules, if: :transfer_leg?
    validate :transfer_id_fixed, on: :update
  end

  class_methods do
    # Creates both legs in one database transaction and returns them as [out_leg, in_leg].
    #
    # `amount` is the positive amount that leaves `from`, in its currency; the out leg stores it negative.
    # `to_amount` is the positive amount that arrives on `to`, in its currency. It defaults to `amount` when
    # both accounts use the same currency and is required when they do not. Each amount is an Integer, a
    # BigDecimal or a plain decimal String ("1250.50") with at most two decimal places. Anything else raises
    # ArgumentError instead of being rounded or guessed at: a Float (0.105 is not exact), a Rational
    # (10/3 has no exact decimal), more than two places, text such as "1,5" or "1e3".
    def transfer!(from:, to:, amount:, occurred_on:, to_amount: nil, occurred_at: nil, comment: nil, payee: nil,
                  source: :manual, status: :confirmed)
      raise ArgumentError, "a transfer needs two different accounts" if from == to

      to_amount = amount if to_amount.nil? && from.currency == to.currency
      raise ArgumentError, "to_amount is required when the accounts use different currencies" if to_amount.nil?

      amount = transfer_amount(:amount, amount)
      to_amount = transfer_amount(:to_amount, to_amount)

      shared = { transfer_id: SecureRandom.uuid, occurred_on:, occurred_at:, comment:, payee:, source:, status: }
      transaction do
        [ create!(shared.merge(account: from, amount: -amount)), create!(shared.merge(account: to, amount: to_amount)) ]
      end
    end

    TRANSFER_AMOUNT_TEXT = /\A\d+(?:\.\d+)?\z/

    # `value` as a positive BigDecimal with at most two decimal places, or ArgumentError.
    def transfer_amount(name, value)
      number =
        case value
        when Integer, BigDecimal then BigDecimal(value)
        when String then BigDecimal(value) if value.match?(TRANSFER_AMOUNT_TEXT)
        end
      unless number&.finite? && number.positive? && DecimalPlacesValidator.fits?(number, Transaction::MONEY_DECIMAL_PLACES)
        raise ArgumentError, "#{name} must be a positive Integer, BigDecimal or decimal String with at most " \
          "#{Transaction::MONEY_DECIMAL_PLACES} decimal places, got #{value.inspect}"
      end
      number
    end
    private :transfer_amount

    # Everything wrong with the transfer `transfer_id` as it is stored now, as sentences. An empty list
    # means the pair is valid.
    def transfer_problems(transfer_id)
      legs = where(transfer_id:).includes(:account, :lines).order(:id).to_a
      problems = []
      problems << "a transfer needs exactly two legs, found #{legs.size}" unless legs.size == 2
      problems << "a transfer leg cannot have lines" if legs.any? { |leg| leg.lines.any? }
      problems.concat(pair_problems(*legs)) if legs.size == 2
      problems
    end

    # The rules between two legs (the counting and the lines are checked by the callers).
    def pair_problems(leg, other)
      problems = []
      problems << "the two legs must be on different accounts" if leg.account_id == other.account_id
      problems << "the two legs must have the same status" if leg.status != other.status
      return problems if leg.amount.blank? || other.amount.blank?

      if leg.amount.positive? == other.amount.positive?
        problems << "the two legs must have opposite signs"
      elsif leg.account&.currency == other.account&.currency && leg.amount + other.amount != 0
        problems << "the two legs must net to zero when both accounts use the same currency " \
          "(a fee is a separate expense)"
      end
      problems
    end
  end

  # The other leg of this transfer, or nil.
  def counterpart
    return unless transfer_leg?

    self.class.where(transfer_id:).where.not(id:).first
  end

  # Transaction.transfer_problems for this leg's transfer; empty for a transaction that is not a leg.
  def transfer_problems
    transfer_leg? ? self.class.transfer_problems(transfer_id) : []
  end

  # Sets `status` and saves, like update!(status:). For a transfer leg it sets the counterpart's status too,
  # in one database transaction: a single leg cannot change its status (the legs must match). A stale copy
  # raises ActiveRecord::StaleObjectError and an invalid status ActiveRecord::RecordInvalid; then neither
  # leg changes in the database.
  def update_status!(status)
    return update!(status:) unless transfer_leg?

    self.class.transaction do
      other = counterpart
      other&.status = status
      self.status = status
      # This leg is saved first, while the stored counterpart still has the old status, so it is checked
      # against the counterpart in memory. The counterpart's own save then sees this leg already stored.
      @counterpart_in_memory = other
      save!
      @counterpart_in_memory = nil
      other&.save!
    end
    true
  ensure
    @counterpart_in_memory = nil
  end

  private
    def transfer_leg_rules
      errors.add(:lines, "must be empty for a transfer leg") if kept_lines.any?

      others = self.class.where(transfer_id:).where.not(id:).includes(:account).to_a
      if others.size > 1
        errors.add(:transfer_id, "already has two legs")
      elsif others.one?
        other = others.first.id == @counterpart_in_memory&.id ? @counterpart_in_memory : others.first
        self.class.pair_problems(self, other).each { |problem| errors.add(:base, problem.upcase_first) }
      end
    end

    def transfer_id_fixed
      return unless transfer_id_changed? && transfer_id_was.present?

      errors.add(:transfer_id, "cannot change once set: the other leg would be left alone")
    end

    # Ends after one hop: by the time the counterpart looks for its own counterpart, this row is gone.
    def destroy_counterpart
      counterpart&.destroy!
    end
end
