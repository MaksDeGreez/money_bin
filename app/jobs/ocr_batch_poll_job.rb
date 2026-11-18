# Follows the OCR batches the app has sent (docs/domain.md, "OCR in a batch"): runs OcrBatches::Poll, then
# queues itself again for when the next batch is due (OcrBatch#next_check_at, between MIN_WAIT and MAX_WAIT),
# while any batch is followed (OcrBatch.followed). There is no webhook: the app has no public URL.
#
#   OcrBatchPollJob.ensure_scheduled   # start the chain unless it is alive (cheap: one query, one cache read)
#   OcrBatchPollJob.restart            # start a new chain now ("Check now")
#
# One chain at a time. The chain's token and next due time are kept in the cache (Redis, the same as the job
# queue): a job whose token is not the current one ends without queuing another, so starting a new chain
# retires the old one. A chain that died (the queue was emptied, the worker crashed, the cache was cleared)
# is noticed by `ensure_scheduled` once its due time is GRACE past: the batches page, the receipts list, a
# new batch and the worker's start call it. Two runs never overlap (OcrBatches::Exclusive), and every step of
# a batch is idempotent, so a duplicate run does no harm.
class OcrBatchPollJob < ApplicationJob
  queue_as :default
  CACHE_KEY = "ocr_batches/poll".freeze
  GRACE = 10.minutes
  MIN_WAIT = 30.seconds
  MAX_WAIT = 15.minutes

  def self.ensure_scheduled(now: Time.current, cache: Rails.cache)
    return false unless OcrBatch.followed.exists?

    chain = cache.read(CACHE_KEY)
    return false if chain.is_a?(Hash) && chain[:due_at].is_a?(Time) && chain[:due_at] + GRACE > now

    restart(now:, cache:)
  rescue StandardError => error
    Rails.logger.warn("OcrBatchPollJob: could not start polling (#{error.class})")
    false
  end

  def self.restart(now: Time.current, cache: Rails.cache)
    token = SecureRandom.hex(8)
    cache.write(CACHE_KEY, { token:, due_at: now })
    perform_later(token)
    true
  end

  def perform(token, cache: Rails.cache)
    chain = cache.read(CACHE_KEY)
    return if chain.is_a?(Hash) && chain[:token] != token

    OcrBatches::Exclusive.run(:poll) { OcrBatches::Poll.call }
    reschedule(token, cache)
  end

  private
    def reschedule(token, cache)
      now = Time.current
      due = OcrBatch.followed.minimum(:next_check_at)
      unless OcrBatch.followed.exists?
        cache.delete(CACHE_KEY)
        return
      end

      wait = ((due || now) - now).seconds.clamp(MIN_WAIT, MAX_WAIT)
      cache.write(CACHE_KEY, { token:, due_at: now + wait })
      self.class.set(wait:).perform_later(token)
    end
end
