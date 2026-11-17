module LegacyImport
  # Imports an export of the previous version of the app (docs/import-contract.md):
  #
  #   report = LegacyImport::Runner.call("/path/to/export", dry_run: false, output: $stdout)
  #
  # 1. ExportReader and Verifier check the whole export; nothing is written when they find a problem.
  # 2. The loaders write accounts, payees and transactions through the models, in ONE database transaction.
  #    Any error rolls everything back. A dry run does all the work and then rolls back.
  # 3. The report (counts and warnings only) is printed to `output` and returned.
  #
  # Every failure is raised as LegacyImport::Error, whose message is safe to print. While it runs, Active
  # Record's SQL log is silenced: it would write names and amounts into the log file.
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
      dataset = Verifier.call(ExportReader.call(@dir))
      report = new_report(dataset)
      quietly { write(dataset, report) }
      @output.puts report
      report
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "unexpected #{error.class.name}#{where(error)}"
    end

    private
      def new_report(dataset)
        report = Report.new
        report.dry_run = @dry_run
        report.manifest_warnings = dataset.manifest["warnings"].size
        report.date_from, report.date_to = dataset.manifest.values_at("date_from", "date_to").map do |date|
          date if date.is_a?(String) && date.match?(Values::DATE)
        end
        dataset.warnings.each { |warning| report.warn(warning) }
        report
      end

      # A savepoint when a caller (a test) already has a transaction open, so a dry run rolls back only its
      # own work; a real transaction otherwise.
      def write(dataset, report)
        Transaction.transaction(requires_new: true) do
          accounts = AccountLoader.call(dataset.accounts, report)
          payees = PayeeLoader.call(dataset.payees, report)
          categories = CategoryMapper.new(dataset.categories, report)
          TransactionLoader.new(dataset.transactions, accounts:, payees:, categories:, report:).call
          raise ActiveRecord::Rollback if @dry_run
        end
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
