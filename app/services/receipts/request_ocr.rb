module Receipts
  # Queues ReceiptOcrJob for receipts, at most once per receipt while a request is waiting
  # (docs/domain.md, "Who enqueues OCR").
  #
  #   Receipts::RequestOcr.first_read(receipt)   # opening a receipt page, or after an upload: `uploaded` only
  #   Receipts::RequestOcr.read_again(receipt)   # "Read again": `failed`, or `extracted` (replaces its items)
  #   Receipts::RequestOcr.read_all(relation)    # "Read all in this filter": its `uploaded` and `failed` receipts
  #
  # Each returns the ids it queued (empty when there was nothing to do). A `reviewed` receipt is never
  # queued: a person accepted it into the ledger, and a new OCR result must not change it.
  #
  # Once only: the receipts are claimed by setting `ocr_requested_at`, under a row lock, only where it is
  # nil, and the job clears it when it starts. A second request while the first one waits finds it set and
  # queues nothing, also when both arrive at the same moment (the second waits for the lock, then sees the
  # first one's value). The job is queued after the claim is committed; if the queue cannot be reached
  # the claim is taken back and QueueUnavailable is raised, so the receipt does not look queued.
  #
  # A request older than STALE_AFTER counts as lost (the queue was emptied by hand, Redis lost its data)
  # and may be made again. A duplicate job is harmless: the OCR queue runs one job at a time, and the second
  # finds the receipt read and does nothing.
  class RequestOcr
    STALE_AFTER = 24.hours
    FIRST_READ_STATUSES = %w[uploaded].freeze
    READ_AGAIN_STATUSES = %w[failed extracted].freeze

    class QueueUnavailable < StandardError; end

    def self.first_read(receipt)
      new(Receipt.where(id: receipt.id), FIRST_READ_STATUSES).call
    end

    def self.read_again(receipt)
      new(Receipt.where(id: receipt.id), READ_AGAIN_STATUSES).call
    end

    def self.read_all(relation)
      new(relation, Receipt::OCR_READABLE_STATUSES).call
    end

    # The receipts of `relation` that a request would queue now.
    def self.readable(relation, statuses = Receipt::OCR_READABLE_STATUSES, now: Time.current)
      relation.where(status: statuses).where(
        "receipts.ocr_requested_at IS NULL OR receipts.ocr_requested_at < ?", now - STALE_AFTER
      )
    end

    def initialize(relation, statuses)
      @relation = relation
      @statuses = statuses
    end

    def call
      # Whole microseconds, what the column keeps, so `release` finds the value again.
      now = Time.current.floor(6)
      ids = claim(now)
      return ids if ids.empty?

      enqueue(ids, now)
      LiveUpdate.requested(ids)
      ids
    end

    private
      def claim(now)
        Receipt.transaction do
          ids = self.class.readable(@relation, @statuses, now:).lock.pluck(:id)
          Receipt.where(id: ids).update_all(ocr_requested_at: now, updated_at: now) if ids.any?
          ids
        end
      end

      # In the claimed order, so "Read all" works through a list in the order it is shown.
      def enqueue(ids, now)
        receipts = Receipt.where(id: ids).index_by(&:id).values_at(*ids)
        jobs = receipts.map { |receipt| ReceiptOcrJob.new(receipt) }
        ActiveJob.perform_all_later(jobs)
        failed = jobs.count { |job| !job.successfully_enqueued? }
        raise QueueUnavailable, "#{failed} of #{jobs.size} OCR job(s) could not be queued" if failed.positive?
      rescue StandardError => error
        release(ids, now)
        raise if error.is_a?(QueueUnavailable)

        raise QueueUnavailable, "the OCR queue cannot be reached (#{error.class})"
      end

      # Takes the claim back, unless a job already started and cleared it.
      def release(ids, now)
        Receipt.where(id: ids, ocr_requested_at: now).update_all(ocr_requested_at: nil)
      end
  end
end
