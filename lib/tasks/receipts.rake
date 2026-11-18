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

# Imports item-level ground truth from receipt files a person saved by hand from the tax service's receipt
# page (docs/domain.md, "Receipt ground truth"). Reads local files only; never fetches anything. The work is
# done by GroundTruthImport::Runner; exit status 1 when a file could not be written.
namespace :receipts do
  desc "Import receipt ground truth from the saved receipt files rcpt_NNNNNN.xml in DIR (DRY_RUN=1 rolls back)"
  task :import_ground_truth_xml, [ :dir ] => :environment do |_task, args|
    abort "Usage: bin/rails \"receipts:import_ground_truth_xml[DIR]\" (DRY_RUN=1 for a dry run)" if args[:dir].blank?

    report = GroundTruthImport::Runner.call(args[:dir], dry_run: ENV["DRY_RUN"] == "1")
    exit 1 if report.failed?
  rescue GroundTruthImport::Error => error
    abort error.message
  end

  desc "Write the receipt ground-truth records to OUT_DIR/ground_truth.jsonl for the OCR evaluation (outside git)"
  task :export_ground_truth, [ :out_dir ] => :environment do |_task, args|
    abort "Usage: bin/rails \"receipts:export_ground_truth[OUT_DIR]\"" if args[:out_dir].blank?

    GroundTruthExport.call(args[:out_dir])
  rescue GroundTruthExport::Error => error
    abort error.message
  end
end
