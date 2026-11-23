# The other side of a transaction: a shop, a service or a person. A transaction has at most one payee.
#
# Bank feeds and receipts spell the same name in different ways ("EXAMPLE  MARKET", "Example Market").
# `normalized_name` is the key that makes those one payee. It is set whenever `name` is assigned and is
# unique. The normalisation is deliberately light (see Payee.normalize_name): Unicode NFKC, squished
# whitespace, Unicode-aware lower case. Punctuation is kept, so "Example Market" and "Example-Market" stay
# two payees; merging those is a job for a person or a later rule, not for this key.
class Payee < ApplicationRecord
  has_many :transactions, dependent: :restrict_with_error
  # A payee a receipt booking says it assigned stays while the record does: an undo may need it.
  has_many :receipt_bookings, foreign_key: :assigned_payee_id, inverse_of: :assigned_payee, dependent: :restrict_with_error

  normalizes :name, with: ->(value) { value.squish }

  validates :name, presence: true
  validates :normalized_name, presence: true, uniqueness: true

  # "  ＥＸＡＭＰＬＥ Market " => "example market". Works for Cyrillic and other scripts too.
  def self.normalize_name(name)
    name.to_s.unicode_normalize(:nfkc).squish.downcase
  end

  # The payee whose normalised name matches `name`, created with `name` when there is none.
  # Safe against a parallel insert of the same name (the unique index decides, then we read the winner).
  def self.find_or_create_by_name!(name)
    normalized = normalize_name(name)
    raise ArgumentError, "a payee name cannot be blank" if normalized.empty?

    # The savepoint keeps a caller's open transaction usable after a unique-index violation.
    find_by(normalized_name: normalized) || transaction(requires_new: true) { create!(name:) }
  rescue ActiveRecord::RecordNotUnique
    find_by!(normalized_name: normalized)
  end

  # The key follows the name on every assignment, so it is right even on a save that skips validation.
  def name=(value)
    super
    self.normalized_name = self.class.normalize_name(name).presence
  end
end
