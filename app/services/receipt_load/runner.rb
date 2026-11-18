module ReceiptLoad
  # Loads the receipt set made by the receipt ingest tool (tools/receipt_ingest/) into the app:
  #
  #   report = ReceiptLoad::Runner.call("/path/to/ingest", dry_run: false, output: $stdout)
  #
  # 1. Verifier checks the whole receipts.jsonl and every image file; nothing is written when it finds a
  #    problem.
  # 2. Writer removes the loaded receipts that left the ingest set, then writes each line as a Receipt, one
  #    database transaction per receipt (docs/domain.md, "Receipt load", says why not one for all).
  #    A receipt that fails is counted and the others go on. A dry run does everything inside one outer
  #    database transaction, with a savepoint per receipt, uploads no file and rolls back at the end.
  # 3. The report (counts and warnings with receipt ids only) is printed to `output` and returned.
  #
  # Verification failures and unexpected errors are raised as ReceiptLoad::Error, whose message is safe to
  # print. While it runs, Active Record's SQL log is silenced: it would write QR payloads, totals and dates
  # into the log file. A real run needs Redis: Active Storage analyses and purges photos in background jobs.
  class Runner
    def self.call(dir, dry_run: false, output: $stdout)
      new(dir, dry_run:, output:).call
    end

    def initialize(dir, dry_run: false, output: $stdout)
      @dir = dir
      @dry_run = dry_run
      @output = output
    end

    def call
      dataset = Verifier.call(@dir)
      check_job_queue unless @dry_run
      report = Report.new(dry_run: @dry_run, lines: dataset.lines.size)
      dataset.warnings.each { |warning| report.warn(warning) }
      quietly { @dry_run ? rolled_back { load(dataset, report) } : load(dataset, report) }
      @output.puts report
      report
    rescue Error
      raise
    rescue StandardError => error
      raise Error.new("unexpected #{error.class.name}#{where(error)}", nothing_written: @dry_run)
    end

    private
      def load(dataset, report)
        writer = Writer.new(report:, dry_run: @dry_run)
        # Retired receipts go first: a merge in the ingest set moves photos of a retired receipt into
        # another one, whose line can then take them in the same run.
        writer.retire(dataset.ingest_ids)
        dataset.lines.each do |line|
          next report.count(line.batch, :"skipped_#{line.skip_reason}") if line.skipped?

          begin
            writer.call(line)
          rescue StandardError => error
            report.count(line.batch, :failed)
            report.warn("#{line.ingest_id}: failed, #{describe(error)}")
          end
        end
      end

      def rolled_back
        Receipt.transaction(requires_new: true) do
          yield
          raise ActiveRecord::Rollback
        end
      end

      # Names what was refused, never the refused value.
      def describe(error)
        case error
        when ActiveRecord::RecordInvalid
          "refused: #{error.record.errors.attribute_names.join(', ')}"
        when Writer::FileChanged
          error.message
        else
          "#{error.class.name}#{where(error)}"
        end
      end

      # Attaching a photo enqueues Active Storage's analysis job after the commit; with Redis down that
      # enqueue would fail after the receipt was already committed. Checked once, before any write.
      def check_job_queue
        return unless ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::SidekiqAdapter)

        Sidekiq.redis { |connection| connection.call("PING") }
      rescue StandardError
        raise Error, "Redis is not reachable (Active Storage needs its job queue); start it with bin/services"
      end

      def quietly(&block)
        logger = ActiveRecord::Base.logger
        logger ? logger.silence(Logger::WARN, &block) : yield
      end

      # The first line of this app's code in the backtrace: it helps to find a bug and holds no data.
      def where(error)
        line = error.backtrace&.find { |frame| frame.include?("/app/") }
        line ? " at #{line.sub(Rails.root.to_s + '/', '').split(':in ').first}" : ""
      end
  end
end
