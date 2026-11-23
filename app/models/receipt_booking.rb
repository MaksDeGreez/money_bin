require "digest"

# The record of how a receipt was booked (docs/domain.md, "Receipt bookings"; docs/decisions/0018). One row per
# booked receipt, written by Receipts::Accept, so that the booking can be undone later.
#
# - `mode` `linked`: the person chose a transaction already in the ledger (a bank row, usually) and Accept
#   replaced its lines with the receipt's items. `previous` holds that transaction as it was before the first
#   rebook (ReceiptBooking.snapshot), and `transaction_import_digest` its `import_digest` then.
# - `mode` `created`: Accept created a new expense. No `previous`: undoing it removes the transaction.
# - `lines_digest`: the lines Accept wrote (ReceiptBooking.lines_digest), refreshed by every "Accept again", so an
#   undo can tell whether somebody changed them since.
# - `assigned_payee`: the payee Accept set on the transaction (nil when it kept the transaction's own or the
#   merchant name was blank); `payee_created`: Accept created that payee.
#
# `previous` and `transaction_import_digest` are written at the first link only; "Accept again" keeps them. The
# row cascades with its receipt and with its transaction (an import that destroys and recreates the row takes
# the record with it, and the receipt returns to `extracted` through Transaction#release_receipt).
class ReceiptBooking < ApplicationRecord
  # The version of the `previous` document. A new transaction_lines column needs a decision on how an undo
  # restores it, so the column list is fixed here and a test compares it with the table.
  PREVIOUS_FORMAT = 1
  LINE_COLUMNS = %w[
    id transaction_id category_id amount legacy_category_path comment
    suggested_category_id suggestion_probability runner_up_category_id runner_up_probability suggestion_source
    suggestion_model_version suggested_at category_origin category_origin_probability category_origin_model_version
    created_at updated_at
  ].freeze
  MONEY_COLUMNS = %w[amount].freeze
  TIME_COLUMNS = %w[suggested_at created_at updated_at].freeze
  LINES_DIGEST_PREFIX = "receipt-booking-lines/1".freeze
  DIGEST_FORMAT = /\A[0-9a-f]{64}\z/

  enum :mode, { linked: "linked", created: "created" }, validate: true

  belongs_to :receipt, inverse_of: :booking
  belongs_to :ledger_transaction, class_name: "Transaction", foreign_key: :transaction_id, inverse_of: :receipt_booking
  belongs_to :assigned_payee, class_name: "Payee", optional: true

  validates :receipt_id, :transaction_id, uniqueness: true
  validates :lines_digest, format: { with: DIGEST_FORMAT }
  validate :previous_matches_mode
  validate :created_payee_is_assigned

  # The transaction's state, to put it back: the format version, the amount (decimal string), the status, the
  # payee and every column of every line, money as decimal strings and times in UTC with microseconds. Read
  # from the database, so the caller locks the transaction and its lines first.
  def self.snapshot(transaction)
    row = Transaction.where(id: transaction.id).pick(:amount, :status, :payee_id)
    raise ActiveRecord::RecordNotFound, "transaction #{transaction.id} is gone" unless row

    amount, status, payee_id = row
    lines = TransactionLine.where(transaction_id: transaction.id).order(:id).map { |line| snapshot_line(line) }
    { "format" => PREVIOUS_FORMAT, "amount" => JsonFormat.money(amount), "status" => status, "payee_id" => payee_id,
      "lines" => lines }
  end

  def self.snapshot_line(line)
    LINE_COLUMNS.index_with do |column|
      value = line.read_attribute(column)
      if value.nil? then nil
      elsif MONEY_COLUMNS.include?(column) then JsonFormat.money(value)
      elsif TIME_COLUMNS.include?(column) then value.utc.iso8601(6)
      else value
      end
    end
  end

  # SHA-256 of the transaction's stored lines in a canonical form: one "category id or nothing, tab, amount
  # with two places" per line, sorted, under a versioned prefix. The order of the lines and their ids do not
  # matter; a category or an amount does.
  def self.lines_digest(transaction_id)
    digest_lines(TransactionLine.where(transaction_id:).pluck(:category_id, :amount))
  end

  # The digest of [category_id, amount] pairs (amounts as BigDecimal).
  def self.digest_lines(pairs)
    lines = pairs.map { |category_id, amount| "#{category_id}\t#{JsonFormat.money(amount)}" }.sort
    Digest::SHA256.hexdigest([ LINES_DIGEST_PREFIX, *lines ].join("\n"))
  end

  private
    def previous_matches_mode
      if created?
        errors.add(:previous, "must be empty for a created transaction") unless previous.nil?
        errors.add(:transaction_import_digest, "must be empty for a created transaction") unless transaction_import_digest.nil?
      elsif linked?
        valid = previous.is_a?(Hash) && previous["format"].is_a?(Integer) && previous["amount"].is_a?(String) &&
          previous["status"].is_a?(String) && previous["lines"].is_a?(Array)
        errors.add(:previous, "must record the linked transaction's earlier state") unless valid
      end
    end

    def created_payee_is_assigned
      errors.add(:payee_created, "needs the assigned payee") if payee_created? && assigned_payee_id.nil?
    end
end
