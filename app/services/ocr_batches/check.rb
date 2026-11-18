module OcrBatches
  # One step of a batch's life after it was sent, run by the poller when the batch is due (`next_check_at`):
  #
  #   OcrBatches::Check.call(batch)
  #
  # - `submitting` for longer than OcrBatch::SUBMIT_STALE_AFTER: the submission died mid-send; `unknown`, its
  #   receipts released.
  # - `running`: asks for the status (counts, cost so far, expiry). Still running: checked again after
  #   `interval(checks)`, a minute at first, growing to a quarter of an hour. Completed: `applying`, then the
  #   results are stored. Failed, expired, cancelled, or no longer known to OpenRouter: the receipts are
  #   released and the batch fails with the reason.
  # - `applying`: fetches the results and stores them (OcrBatches::ApplyResults); then `finished`, with the
  #   provider's actual cost.
  # - finished or failed, not deleted upstream yet: deletes it at OpenRouter at once (the provider keeps its
  #   copy only until then) and records what was deleted.
  #
  # A check that does not work (the service down, batch mode switched off in the service, OpenRouter rate
  # limiting) changes nothing but `check_error_code`/`check_error_message` and the time of the next check.
  class Check
    FIRST_INTERVAL = 1.minute
    MAX_INTERVAL = 15.minutes
    GROWTH = 1.5

    # The wait before the next check after `checks` checks: 1, 1.5, 2.25, ... minutes, at most 15.
    def self.interval(checks)
      [ FIRST_INTERVAL * (GROWTH**checks.clamp(0, 20)), MAX_INTERVAL ].min
    end

    def self.call(batch, client: MlClient.new, now: Time.current)
      new(batch, client:, now:).call
    end

    def initialize(batch, client:, now:)
      @batch = batch
      @client = client
      @now = now
    end

    def call
      case @batch.state
      when "submitting" then stale_submission
      when "running" then follow
      when "applying" then apply
      end
      # A batch that ended with stored results whose follow-ups could not be queued then (released, given up).
      ApplyResults.follow_up(@batch, now: @now) if %w[failed unknown].include?(@batch.reload.state)
      delete_upstream if @batch.reload.awaiting_deletion?
    ensure
      LiveUpdate.changed(@batch)
    end

    private
      # Only while no submission runs (the submitter holds its lock for as long as it sends, however long the
      # upload takes): a batch left `submitting` then belongs to a worker that died mid-send.
      def stale_submission
        return if @batch.submit_started_at && @batch.submit_started_at > @now - OcrBatch::SUBMIT_STALE_AFTER

        Exclusive.run(:submit) do
          @batch.with_lock do
            @batch.release!("unknown", "submit_unknown", Submit::UNKNOWN_MESSAGE, now: @now) if @batch.submitting?
          end
        end
      end

      def follow
        status = @client.ocr_batch(@batch.provider_batch_id)
        @batch.update!(progress(status).merge(next_check_at: @now + self.class.interval(@batch.checks + 1)))
        case status.state
        when "completed"
          @batch.update!(state: "applying")
          apply
        when "failed", "expired", "cancelled"
          @batch.release!("failed", status.error_code || "batch_#{status.state}",
            status.error_message || "The batch ended as #{status.state} at the provider.", now: @now)
        end
      rescue MlClient::ResponseError => error
        raise unless error.code == "batch_not_found"

        gone(error)
      end

      # Finished only once every entry is resolved and every follow-up queued (OcrBatch#settled?); until then
      # it stays `applying` and the next check does the rest. The cost is the completed batch's own: a cost
      # seen while it ran is not a final figure, so an unknown final cost stays unknown.
      def apply
        results = @client.ocr_batch_results(@batch.provider_batch_id)
        ApplyResults.call(@batch, results, now: @now)
        if @batch.settled?
          @batch.update!(progress(results.batch).merge(state: "finished", finished_at: @now, next_check_at: @now,
            cost_usd: results.batch.cost_usd))
        else
          @batch.update!(next_check_at: @now + self.class.interval(@batch.checks))
        end
      rescue MlClient::ResponseError => error
        raise unless error.code == "batch_not_found"

        # The results are gone (deleted, or older than 30 days): what was stored stays, the rest is released.
        gone(error)
      end

      def gone(error)
        @batch.release!("failed", error.code, "OpenRouter no longer has this batch (deleted, or older than 30 days).",
          now: @now)
        @batch.update!(deleted_upstream_at: @now, upstream_deletion: "gone")
      end

      def progress(status)
        {
          provider_status: status.provider_status, provider: status.provider || @batch.provider,
          model: status.model_name || @batch.model, requests_total: status.requests_total || @batch.requests_total,
          requests_completed: status.requests_completed, requests_failed: status.requests_failed,
          cost_usd: status.cost_usd || @batch.cost_usd, expires_at: status.expires_at || @batch.expires_at,
          last_checked_at: @now, checks: @batch.checks + 1, check_error_code: nil, check_error_message: nil
        }
      end

      def delete_upstream
        deletion = @client.delete_ocr_batch(@batch.provider_batch_id)
        upstream = deletion.upstream_status.presence_in(%w[deleted unsupported not_applicable]) || "not_applicable"
        @batch.update!(deleted_upstream_at: @now, upstream_deletion: upstream, check_error_code: nil, check_error_message: nil)
      rescue MlClient::ResponseError => error
        raise unless error.code == "batch_not_found"

        @batch.update!(deleted_upstream_at: @now, upstream_deletion: "gone")
      end
  end
end
