# Loads the receipt set made by the receipt ingest tool from the folder DIR (docs/domain.md, "Receipt load").
# The work is done by ReceiptLoad::Runner; this task only reads the arguments and sets the exit status:
# 1 when the verification fails or a receipt could not be written.
namespace :receipts do
  desc "Load the receipts of a receipt ingest folder DIR (DRY_RUN=1 does everything, prints the counts, then rolls back)"
  task :load, [ :dir ] => :environment do |_task, args|
    abort "Usage: bin/rails \"receipts:load[DIR]\" (DRY_RUN=1 for a dry run)" if args[:dir].blank?

    report = ReceiptLoad::Runner.call(args[:dir], dry_run: ENV["DRY_RUN"] == "1")
    exit 1 if report.failed?
  rescue ReceiptLoad::Error => error
    abort error.message
  end
end
