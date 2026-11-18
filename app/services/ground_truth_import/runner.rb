module GroundTruthImport
  # Imports item-level ground truth from receipt files a person saved by hand from the tax service's receipt
  # page, one file per receipt, named after the receipt's ingest number (docs/domain.md, "Receipt ground
  # truth"):
  #
  #   report = GroundTruthImport::Runner.call("/path/to/dps_xml", dry_run: false, output: $stdout)
  #
  # For each `rcpt_NNNNNN.xml` in the folder (other entries are counted and ignored; nothing is written
  # there, the folder must be outside every git repository, and nothing is fetched from anywhere):
  # 1. DpsXml::Reader turns it into a ground-truth document; a file it refuses is counted with a warning;
  # 2. the receipt is found by `ingest_id`; a file whose receipt is not loaded is skipped with a warning;
  # 3. CrossCheck compares it with the receipt's QR ground truth; a disagreement means the wrong file was
  #    saved under this number, so it is not imported (the warning names the fields, never the values). A
  #    file that cannot be checked is imported and counted as unverified: with a warning when the QR code
  #    has identifying values that the file lacks (most likely a tag the reader does not know);
  # 4. the receipt's `dps_xml` ReceiptGroundTruth is created, left alone (same file digest and the same
  #    format variant), or replaced (the file or the variant changed), unless a person has already checked
  #    it: then the change is a counted conflict and the record stays.
  #
  # One database transaction per file, and nothing in one file stops the others. A dry run does everything
  # inside one outer transaction and rolls it back. The receipt, its items, its transaction and its OCR and
  # QR columns are never written. Active Record's SQL log is silenced while it runs: it would carry the
  # documents into the log file.
  class Runner
    FILE_NAME = /\A(rcpt_\d{6,})\.xml\z/

    def self.call(dir, dry_run: false, output: $stdout)
      new(dir, dry_run:, output:).call
    end

    def initialize(dir, dry_run: false, output: $stdout)
      @dir = dir
      @dry_run = dry_run
      @output = output
    end

    def call
      files, ignored = list(resolve_root)
      report = Report.new(dry_run: @dry_run, files: files.size, ignored:)
      quietly { @dry_run ? rolled_back { import_all(files, report) } : import_all(files, report) }
      @output.puts report
      report
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "The ground-truth import stopped: unexpected #{error.class.name}#{where(error)}."
    end

    private
      def resolve_root
        root = File.realpath(@dir.to_s)
        raise Error, "The ground-truth folder is not a folder." unless File.directory?(root)
        if PrivateFolder.inside_git_repository?(root)
          raise Error, "The ground-truth folder is inside a git repository; receipt files belong outside it."
        end

        root
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        raise Error, "The ground-truth folder does not exist or cannot be read."
      end

      # The receipt files as [ingest_id, path], sorted, and how many other entries there are. A symbolic
      # link or a folder with a receipt file's name counts as another entry: only plain files are read.
      def list(root)
        files = []
        ignored = 0
        Dir.children(root).sort.each do |name|
          path = File.join(root, name)
          match = FILE_NAME.match(name)
          if match && File.lstat(path).file?
            files << [ match[1], path ]
          else
            ignored += 1
          end
        end
        [ files, ignored ]
      end

      def import_all(files, report)
        files.each do |ingest_id, path|
          import(ingest_id, path, report)
        rescue DpsXml::Unreadable => error
          outcome = %i[unknown_layout not_a_sale].include?(error.reason) ? :not_a_receipt : :unreadable
          report.count(outcome, ingest_id, "skipped, #{error.message}")
        rescue StandardError => error
          report.count(:failed, ingest_id, "failed, #{describe(error)}")
        end
      end

      def import(ingest_id, path, report)
        bytes = read(path)
        result = DpsXml::Reader.call(bytes)
        receipt = Receipt.find_by(ingest_id:)
        return report.count(:receipt_not_loaded, ingest_id, "skipped, no receipt with this ingest id is loaded") unless receipt

        check = CrossCheck.call(receipt, result.document)
        return refuse(receipt, ingest_id, check, report) unless check.stored?

        outcome = store(receipt, result, Digest::SHA256.hexdigest(bytes))
        if outcome == :conflict
          report.count(:conflict, ingest_id, "left alone, the file changed but a person already checked the record")
        else
          report.count(outcome)
          report.count_stored(result, check)
          if check.status == :unverifiable
            report.warn(ingest_id, "imported unverified, the file lacks the values to compare with the receipt's QR " \
              "code (its fiscal number, or the total and the time)")
          end
        end
      end

      # A file that disagrees with the QR code is not imported. A record stored from an earlier version of it
      # stays (the import never deletes); the export marks it with its current check.
      def refuse(receipt, ingest_id, check, report)
        kept = receipt.ground_truths.dps_xml.exists? ? "; the record stored earlier is kept and the export marks it" : ""
        report.count(:mismatch, ingest_id, "not imported, the file disagrees with the receipt's QR code on " \
          "#{check.disagreeing.join(', ')} (another receipt's file saved under this number?)#{kept}")
      end

      # The file's bytes; a file over the reader's limit is refused from its size, before it is read.
      def read(path)
        raise DpsXml::Unreadable, :too_large if File.size(path) > DpsXml::Reader::MAX_BYTES

        File.binread(path)
      end

      def store(receipt, result, digest)
        ReceiptGroundTruth.transaction(requires_new: true) do
          record = ReceiptGroundTruth.lock.find_by(receipt_id: receipt.id, source: :dps_xml)
          attributes = {
            document: result.document, items_known: result.items_known, schema_version: ReceiptGroundTruth::SCHEMA_VERSION,
            source_sha256: digest, source_format: result.format
          }
          if record.nil?
            ReceiptGroundTruth.create!(receipt:, source: :dps_xml, **attributes)
            :created
          elsif record.source_sha256 == digest && record.source_format == result.format &&
              record.schema_version == ReceiptGroundTruth::SCHEMA_VERSION
            :unchanged
          elsif record.checked?
            :conflict
          else
            record.update!(attributes)
            :replaced
          end
        end
      end

      def rolled_back
        ReceiptGroundTruth.transaction(requires_new: true) do
          yield
          raise ActiveRecord::Rollback
        end
      end

      # Names what was refused, never the refused value.
      def describe(error)
        case error
        when ActiveRecord::RecordInvalid
          "refused: #{error.record.errors.attribute_names.join(', ')}"
        else
          "#{error.class.name}#{where(error)}"
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
