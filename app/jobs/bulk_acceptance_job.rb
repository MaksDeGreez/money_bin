# Applies a confirmed bulk acceptance (BulkAcceptance): every item without an outcome, in order, each at most once
# (BulkAcceptanceItem#apply!). The page follows it live (Turbo refreshes every BulkAcceptance::PROGRESS_EVERY
# items).
#
#   BulkAcceptanceJob.perform_later(acceptance)  # after acceptance.confirm!
#
# Safe to run twice or to resume after a crash: the items already handled keep their outcome and are skipped, and an
# item is categorised and marked in one database transaction. Only a confirmed (queued) or interrupted (running)
# acceptance is worked; a preview nobody confirmed never is. An unexpected error marks the acceptance `failed`
# (reported, not retried by Sidekiq); "Resume" on its page queues it again and it carries on where it stopped.
class BulkAcceptanceJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(acceptance)
    return unless start(acceptance)

    acceptance.items.where(outcome: nil).each_slice(BulkAcceptance::PROGRESS_EVERY) do |items|
      items.each(&:apply!)
      acceptance.refresh_counts!
      acceptance.broadcast_progress
    end
    acceptance.refresh_counts!
    acceptance.update!(status: "done", finished_at: Time.current)
    acceptance.broadcast_progress
  rescue StandardError => error
    Rails.error.report(error, handled: true, source: "bulk_acceptance_job")
    acceptance.refresh_counts!
    acceptance.update!(status: "failed", error: error.class.name, finished_at: Time.current)
    acceptance.broadcast_progress
  end

  private
    def start(acceptance)
      acceptance.with_lock do
        next false unless acceptance.queued? || acceptance.running?

        acceptance.update!(status: "running", started_at: acceptance.started_at || Time.current)
        true
      end
    end
end
