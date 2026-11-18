require "json"

# Writes the ground-truth records for the offline OCR evaluation (ml/evaluation/ reads files, not the
# database): one JSON line per ReceiptGroundTruth in OUT_DIR/ground_truth.jsonl.
#
#   GroundTruthExport.call("/path/outside/git", output: $stdout)  # => the number of records written
#
# Each line: `receipt_id`, `ingest_id`, `source`, `source_format`, `saved_at`, `prefilled_by`, `prefill_kind`
# (`model`, `hand`, `dps_xml`, or null for an imported record), `prefilled_model_version`,
# `prefilled_prompt_version`, `categories_prefilled_by`, `checked_at`, `check_outcome`, `qr_check`,
# `items_known`, `categories_known`, `schema_version`, `stored_schema_version` and `document` (money and
# quantities stay decimal strings, categories are `category_slug`s).
#
# One shape: every document is written as the current schema version (2, with categories), whatever version
# the record is stored in (`stored_schema_version`); a version 1 record has no categories, so its
# `category_slug`s are null and `categories_known` false.
#
# The pre-fill rule, for the evaluation: a record whose `prefilled_by` is a model's name is not test ground
# truth for that model (any version or prompt of it), and one whose `categories_prefilled_by` names a
# categoriser is not test ground truth for that categoriser's categories (`source:unknown`: for any
# categoriser). Imported records have neither. `qr_check` is the cross-check with the receipt's QR values made at export time
# (GroundTruthImport::CrossCheck: `agrees`, `disagrees`, `unverifiable` or `no_qr`), so a record that a later
# QR value contradicts is marked, and the evaluation can leave it out. The documents hold shop names and items, so the folder must be outside every git repository
# (the check the Python tools make: no `.git` in the folder or above it); it is created readable by the
# owner only, and the file is written with mode 0600 through a temporary file. Only the count is printed.
class GroundTruthExport
  FILE_NAME = "ground_truth.jsonl"
  FILE_MODE = 0o600
  DIR_MODE = 0o700

  class Error < StandardError; end

  def self.call(out_dir, output: $stdout)
    new(out_dir, output:).call
  end

  def initialize(out_dir, output: $stdout)
    @out_dir = out_dir.to_s
    @output = output
  end

  def call
    raise Error, "Usage: an output folder is needed" if @out_dir.blank?
    raise Error, "The output folder is inside a git repository; choose one outside it." if PrivateFolder.inside_git_repository?(@out_dir)

    FileUtils.mkdir_p(@out_dir, mode: DIR_MODE)
    count = write(File.join(@out_dir, FILE_NAME))
    @output.puts "Ground-truth export: #{count} records written to #{FILE_NAME}"
    count
  end

  private
    # Through a new temporary file (a random name, created exclusively, never through a link), renamed over
    # the old file at the end.
    def write(path)
      temporary = "#{path}.#{SecureRandom.hex(6)}.tmp"
      count = 0
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, FILE_MODE) do |file|
        file.chmod(FILE_MODE)
        records.each do |record|
          file.puts JSON.generate(line(record))
          count += 1
        end
      end
      File.rename(temporary, path)
      count
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def records
      ReceiptGroundTruth.joins(:receipt).includes(:receipt)
        .order(Receipt.arel_table[:ingest_id].asc.nulls_last, :receipt_id, :source)
    end

    def line(record)
      {
        "receipt_id" => record.receipt_id,
        "ingest_id" => record.receipt.ingest_id,
        "source" => record.source,
        "source_format" => record.source_format,
        "saved_at" => record.updated_at.in_time_zone.iso8601,
        "prefilled_by" => record.prefilled_by,
        "prefill_kind" => record.prefill_kind&.to_s,
        "prefilled_model_version" => record.prefilled_model_version,
        "prefilled_prompt_version" => record.prefilled_prompt_version,
        "categories_prefilled_by" => record.categories_prefilled_by,
        "checked_at" => record.checked_at&.iso8601,
        "check_outcome" => record.check_outcome,
        # Checked again now: QR values loaded or changed after the import show up here.
        "qr_check" => GroundTruthImport::CrossCheck.call(record.receipt, record.document).status.to_s,
        "items_known" => record.items_known,
        "categories_known" => record.categories_known,
        "schema_version" => ReceiptGroundTruth::SCHEMA_VERSION,
        "stored_schema_version" => record.schema_version,
        "document" => record.current_document
      }
    end
end
