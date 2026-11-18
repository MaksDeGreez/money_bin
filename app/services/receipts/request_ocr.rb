module Receipts
  # Queues ReceiptOcrJob for receipts, at most once per receipt while a request is waiting
  # (docs/domain.md, "Who enqueues OCR").
  #
  #   Receipts::RequestOcr.first_read(receipt)   # opening a receipt page, or after an upload: `uploaded` only
  #   Receipts::RequestOcr.read_again(receipt)   # "Read again": `failed`, `extracted` (replaces its items), or
  #                                              # `processing` for longer than Receipt::OCR_STUCK_AFTER
  #   Receipts::RequestOcr.read_all(relation)    # "Read all in this filter": its `uploaded` receipts, and its
  #                                              # `failed` ones that have no items to lose
  #
  # Each returns the ids it queued (empty when there was nothing to do). A `reviewed` receipt is never
  # queued: a person accepted it into the ledger, and a new OCR result must not change it.
  #
  # Once only: the receipts are claimed by setting `ocr_requested_at`, under a row lock, only where it is
  # nil, and the job clears it when it starts. A second request while the first one waits finds it set and
  # queues nothing, also when both arrive at the same moment (the second waits for the lock, then sees the
  # first one's value). The job is queued after the claim is committed; if the queue cannot be reached
  # the claims of the jobs that were not queued are taken back and QueueUnavailable is raised, so a receipt
  # never looks queued when it is not.
  #
  # A request older than STALE_AFTER (Receipt::OCR_REQUEST_LOST_AFTER) counts as lost (the queue was emptied by hand, Redis lost its data)
  # and may be made again. A duplicate job is harmless: the OCR queue runs one job at a time, and the second
  # finds the receipt read and does nothing.
  class RequestOcr
    STALE_AFTER = Receipt::OCR_REQUEST_LOST_AFTER

    # Some jobs could not be queued; `queued` were.
    class QueueUnavailable < StandardError
      attr_reader :queued

      def initialize(message, queued: [])
        @queued = queued
        super(message)
      end
    end

    def self.first_read(receipt)
      new(Receipt.where(id: receipt.id), :first_read).call
    end

    def self.read_again(receipt)
      new(Receipt.where(id: receipt.id), :read_again).call
    end

    def self.read_all(relation)
      new(relation, :read_all).call
    end

    # The receipts of `relation` that a request of `kind` would queue now.
    def self.readable(relation, kind = :read_all, now: Time.current)
      candidates =
        case kind
        when :first_read then relation.where(status: "uploaded")
        when :read_again
          relation.where(status: %w[failed extracted])
            .or(relation.where(status: "processing", updated_at: ...(now - Receipt::OCR_STUCK_AFTER)))
        when :read_all
          relation.where(status: "uploaded")
            .or(relation.where(status: "failed").where.not(id: ReceiptItem.select(:receipt_id)))
        else raise ArgumentError, "unknown request #{kind.inspect}"
        end
      candidates.where("receipts.ocr_requested_at IS NULL OR receipts.ocr_requested_at < ?", now - STALE_AFTER)
    end

    def initialize(relation, kind)
      @relation = relation
      @kind = kind
    end

    def call
      # Whole microseconds, what the column keeps, so `release` finds the value again.
      now = Time.current.floor(6)
      ids = claim(now)
      return ids if ids.empty?

      queued, failed = enqueue(ids)
      release(failed, now) if failed.any?
      LiveUpdate.requested(queued) if queued.any?
      if failed.any?
        raise QueueUnavailable.new("#{failed.size} of #{ids.size} OCR job(s) could not be queued", queued:)
      end

      queued
    end

    private
      def claim(now)
        Receipt.transaction do
          ids = self.class.readable(@relation, @kind, now:).lock.pluck(:id)
          # updated_at stays: it dates the receipt's own state (Receipt#ocr_stuck? reads it).
          Receipt.where(id: ids).update_all(ocr_requested_at: now) if ids.any?
          ids
        end
      end

      # One push per job, in the claimed order, so "Read all" works through a list in the order it is shown.
      # Not ActiveJob.perform_all_later: Sidekiq's bulk push does not mark its jobs as enqueued, so a
      # successful push would look failed. Returns [queued ids, failed ids]; after the first error (Redis
      # gone) the rest are not tried.
      def enqueue(ids)
        receipts = Receipt.where(id: ids).index_by(&:id).values_at(*ids).compact
        queued = []
        receipts.each do |receipt|
          break unless ReceiptOcrJob.new(receipt).enqueue

          queued << receipt.id
        rescue StandardError => error
          Rails.logger.warn("Receipts::RequestOcr: the OCR queue cannot be reached (#{error.class})")
          break
        end
        [ queued, receipts.map(&:id) - queued ]
      end

      # Takes the claim back, unless a job already started and cleared it.
      def release(ids, now)
        Receipt.where(id: ids, ocr_requested_at: now).update_all(ocr_requested_at: nil)
      end
  end
end
