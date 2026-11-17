# Imports the history of the previous version of the app from an export folder (docs/import-contract.md).
# The work is done by LegacyImport::Runner; this task only reads the arguments and sets the exit status.
namespace :import do
  desc "Import an export of the previous app from DIR (DRY_RUN=1 does everything, prints the counts, then rolls back)"
  task :money_bin, [ :dir ] => :environment do |_task, args|
    abort "Usage: bin/rails \"import:money_bin[DIR]\" (DRY_RUN=1 for a dry run)" if args[:dir].blank?

    LegacyImport::Runner.call(args[:dir], dry_run: ENV["DRY_RUN"] == "1")
  rescue LegacyImport::Error => error
    abort error.message
  end
end
