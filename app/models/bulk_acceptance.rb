# "Accept every suggestion at or above a probability" for the transactions of a list filter (docs/domain.md,
# "Transaction suggestions", "The bulk action").
#
#   acceptance = BulkAcceptance.preview!(filter: Transaction::Filter.new(status: "needs_review"), threshold_percent: 90)
#   acceptance.counts_by_category  # => [[Category, 812], ...] for the person to look at
#   acceptance.confirm!            # => true once; then BulkAcceptanceJob applies it
#
# The preview is a snapshot, one BulkAcceptanceItem per transaction: its lock_version as previewed, its
# uncategorised lines whose stored suggestion reaches the threshold, that suggestion (category, probability,
# artefact). What the person confirms is exactly that list; the job then applies each item at most once
# (BulkAcceptanceItem#apply!), and an item whose transaction was edited meanwhile (a newer lock_version), or
# whose lines were categorised or got another suggestion, is skipped and counted, never overwritten.
#
# Statuses: previewed (waits for a person) → queued (confirmed) → running → done, or failed.
class BulkAcceptance < ApplicationRecord
  STATUSES = %w[previewed queued running done failed].freeze
  # How many items the job applies between two progress updates of the page.
  PROGRESS_EVERY = 50

  enum :status, STATUSES.index_by(&:itself), validate: true

  has_many :items, -> { order(:id) }, class_name: "BulkAcceptanceItem", inverse_of: :bulk_acceptance,
    dependent: :delete_all

  validates :threshold_percent, numericality: { only_integer: true, in: 1..100 }

  # Takes the snapshot of what accepting would do for `filter` (a Transaction::Filter) at `threshold_percent`.
  def self.preview!(filter:, threshold_percent:)
    transaction do
      acceptance = create!(filter: filter.to_params, threshold_percent:)
      rows = snapshot(filter.relation, threshold_percent / 100.0)
      now = Time.current
      BulkAcceptanceItem.insert_all!(rows.map { |row| row.merge(bulk_acceptance_id: acceptance.id, created_at: now, updated_at: now) }) if rows.any?
      acceptance.update!(total_count: rows.size)
      acceptance
    end
  end

  # One row per transaction of `relation` with uncategorised lines whose suggestion reaches `threshold`. A
  # transaction whose qualifying lines carry different suggestions (scored at different times) is left out: one
  # item takes one suggestion.
  def self.snapshot(relation, threshold)
    lines = TransactionLine.uncategorised.joins(:parent)
      .where(transaction_id: relation.unscope(:order).select(:id), transactions: { transfer_id: nil })
      .where.not(suggested_category_id: nil).where(suggestion_probability: threshold..)
      .order(:transaction_id, :id)
      .pluck(:transaction_id, :id, :suggested_category_id, :suggestion_probability, :suggestion_model_version,
        Arel.sql("transactions.lock_version"))
    lines.group_by(&:first).filter_map do |transaction_id, rows|
      next if rows.map { |row| row.values_at(2, 4) }.uniq.size > 1

      _id, _line, category_id, probability, version, lock_version = rows.first
      { transaction_id:, lock_version:, line_ids: rows.map(&:second), category_id:, probability:, model_version: version }
    end
  end

  # [[Category, transactions], ...], the largest first, then by name.
  def counts_by_category
    counts = items.unscope(:order).group(:category_id).count
    categories = Category.includes(:parent).where(id: counts.keys).index_by(&:id)
    counts.map { |id, count| [ categories.fetch(id), count ] }.sort_by { |category, count| [ -count, category.full_name ] }
  end

  # The artefacts whose suggestions the preview takes, with how many transactions each.
  def counts_by_model_version
    items.unscope(:order).group(:model_version).count
  end

  # previewed → queued, once (two clicks confirm once). Returns whether this call confirmed it.
  def confirm!
    with_lock do
      next false unless previewed?

      update!(status: "queued", confirmed_at: Time.current)
      true
    end
  end

  # The counters from the items, which are the record of what happened.
  def refresh_counts!
    counts = items.unscope(:order).group(:outcome).count
    update!(accepted_count: counts.fetch("accepted", 0), stale_count: counts.fetch("stale", 0),
      changed_count: counts.fetch("changed", 0))
  end

  def processed_count
    accepted_count + stale_count + changed_count
  end

  # failed → queued again ("Resume"): the items already handled keep their outcome. Returns whether it did.
  def resume!
    with_lock do
      next false unless failed?

      update!(status: "queued", error: nil, finished_at: nil)
      true
    end
  end

  def finished?
    done? || failed?
  end

  def broadcast_progress
    Turbo::StreamsChannel.broadcast_refresh_to(self, method: :morph, scroll: :preserve)
  rescue StandardError => error
    Rails.logger.warn("BulkAcceptance: could not refresh #{id}: #{error.class}")
  end
end
