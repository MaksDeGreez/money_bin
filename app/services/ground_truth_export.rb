require "json"

# Writes the ground-truth records for the offline OCR evaluation (ml/evaluation/ reads files, not the
# database): one JSON line per ReceiptGroundTruth in OUT_DIR/ground_truth.jsonl.
#
#   GroundTruthExport.call("/path/outside/git", output: $stdout)  # => the number of records written
#
# Each line: `receipt_id`, `ingest_id`, `source`, `source_format`, `prefilled_by`, `checked_at`,
# `check_outcome`, `items_known`, `schema_version` and `document` (money and quantities stay decimal
# strings). The documents hold shop names and items, so the folder must be outside every git repository
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

  # Whether `path` (which may not exist yet) is inside a git working tree. `.git` is a folder in a normal
  # checkout and a file in a linked worktree.
  def self.inside_git_repository?(path)
    Pathname(File.expand_path(path)).ascend.any? { |folder| folder.join(".git").exist? }
  end

  def initialize(out_dir, output: $stdout)
    @out_dir = out_dir.to_s
    @output = output
  end

  def call
    raise Error, "Usage: an output folder is needed" if @out_dir.blank?
    raise Error, "The output folder is inside a git repository; choose one outside it." if self.class.inside_git_repository?(@out_dir)

    FileUtils.mkdir_p(@out_dir, mode: DIR_MODE)
    count = write(File.join(@out_dir, FILE_NAME))
    @output.puts "Ground-truth export: #{count} records written to #{FILE_NAME}"
    count
  end

  private
    def write(path)
      temporary = "#{path}.tmp"
      count = 0
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, FILE_MODE) do |file|
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
        "prefilled_by" => record.prefilled_by,
        "checked_at" => record.checked_at&.iso8601,
        "check_outcome" => record.check_outcome,
        "items_known" => record.items_known,
        "schema_version" => record.schema_version,
        "document" => record.document
      }
    end
end
