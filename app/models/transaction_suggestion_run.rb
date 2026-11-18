# One run of the job that scores every uncategorised transaction line with the transaction categoriser
# (Transactions::SuggestCategories): its progress, the artefact it used, and why it failed. The transactions list
# shows the latest one. At most one run waits or works at a time (TransactionSuggestionRun.start).
class TransactionSuggestionRun < ApplicationRecord
  STATUSES = %w[queued running done failed].freeze
  # A run that has not finished after this long is taken for dead (a killed worker), so a new one may start.
  LOST_AFTER = 1.hour

  enum :status, STATUSES.index_by(&:itself), validate: true

  scope :active, -> { where(status: %w[queued running]).where(updated_at: LOST_AFTER.ago..) }

  def self.latest
    order(:id).last
  end

  # A new queued run, or nil when one is already waiting or working. Under a table lock, so two clicks start one.
  def self.start
    transaction do
      connection.execute("LOCK TABLE #{quoted_table_name} IN SHARE ROW EXCLUSIVE MODE")
      create! unless active.exists?
    end
  end

  def finished?
    done? || failed?
  end
end
