require "json"

module ReceiptLoad
  # Reads and checks the whole receipts.jsonl of an ingest folder before anything is written
  # (tools/receipt_ingest/README.md is the format):
  #
  #   dataset = ReceiptLoad::Verifier.call("/path/to/ingest")
  #
  # - every line is a JSON object with the keys and types the loader needs; receipt ids are well formed
  #   (`rcpt_` and six or more digits) and unique, and so are the fingerprints of the lines to load;
  # - every image file is a regular file inside the folder (no absolute path, no `..`, no symlink out of
  #   it), with the recorded size and SHA-256, and the recorded `fingerprint` is Receipt.fingerprint of the
  #   images;
  # - the QR fields parse: `issued_at` an ISO 8601 time with an offset (at most microseconds, what the
  #   column keeps), `total` a decimal with two places; each may be null. A total too large for the column
  #   (decimal(15, 2)) is stored as nil with a warning: one misread QR code must not stop the whole load.
  #
  # Any problem raises Error with every problem found (ids and reasons only). Not problems, but counted as
  # skipped: a line without images, a line with more photos than a receipt may have (`too_many_parts`), and
  # a line flagged `processing_failed` or `raw_missing` whose files fail the check (the ingest tool says it
  # may leave such a line behind; the next ingest run repairs it).
  #
  # A `qr_conflict` line (two different QR codes in one receipt) keeps no QR value: it is not known which
  # code belongs to the receipt.
  class Verifier
    FILE_NAME = "receipts.jsonl"
    QR_FIELDS = {
      "issued_at" => :qr_issued_at, "total" => :qr_total,
      "fiscal_number" => :qr_fiscal_number, "receipt_number" => :qr_receipt_number
    }.freeze
    NO_QR = QR_FIELDS.values.index_with(nil).freeze
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})\z/
    MONEY = /\A\d+\.\d{2}\z/
    # Flags that say the ingest tool may have left the line's files behind.
    UNSURE_FLAGS = %w[processing_failed raw_missing].freeze
    CHUNK_SIZE = 1.megabyte

    def self.call(dir)
      new(dir).call
    end

    def initialize(dir)
      @dir = dir
      @problems = []
      @warnings = []
    end

    def call
      root = resolve_root
      lines = read_lines(root)
      check_unique(lines)
      @problems << "#{FILE_NAME} has no receipts" if lines.empty? && @problems.empty?
      raise Error, @problems if @problems.any?

      Dataset.new(lines:, warnings: @warnings)
    end

    private
      def resolve_root
        root = File.realpath(@dir.to_s)
        raise Error, "the ingest folder is not a folder" unless File.directory?(root)
        raise Error, "the ingest folder has no #{FILE_NAME}" unless File.file?(File.join(root, FILE_NAME))

        root
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        raise Error, "the ingest folder does not exist or cannot be read"
      end

      def read_lines(root)
        lines = []
        File.foreach(File.join(root, FILE_NAME), encoding: "UTF-8").with_index(1) do |text, number|
          next if text.strip.empty?

          line = parse_line(root, text, number)
          lines << line if line
        end
        lines
      rescue ArgumentError, Encoding::InvalidByteSequenceError
        raise Error, "#{FILE_NAME} is not valid UTF-8"
      end

      # A Dataset::Line, or nil after recording the problems of a line that cannot be used.
      def parse_line(root, text, number)
        row = JSON.parse(text)
        return problem("line #{number}: not a JSON object") unless row.is_a?(Hash)

        id = row["receipt_id"]
        return problem("line #{number}: receipt_id is not rcpt_ and six or more digits") unless id.is_a?(String) && id.match?(Receipt::INGEST_ID_FORMAT)

        build_line(root, row, number, id)
      rescue JSON::ParserError
        problem("line #{number}: not valid JSON")
      end

      def build_line(root, row, number, id)
        count = @problems.size
        batch = row["batch"]
        problem("#{id}: batch is not a text") unless batch.is_a?(String) && batch.strip.present?
        flags = row["flags"]
        problem("#{id}: flags is not a list of texts") unless flags.is_a?(Array) && flags.all?(String)
        fingerprint = row["fingerprint"]
        problem("#{id}: fingerprint is not a SHA-256") unless fingerprint.is_a?(String) && fingerprint.match?(Receipt::SHA256_FORMAT)
        payload = row["qr_payload"]
        problem("#{id}: qr_payload is not a text or null") unless payload.nil? || payload.is_a?(String)
        qr = parse_qr(id, row["qr_fields"])
        entries = image_entries(id, row["images"])
        return if @problems.size > count

        conflict = flags.include?("qr_conflict")
        line = Dataset::Line.new(
          number:, ingest_id: id, batch:, images: [], fingerprint:, skip_reason: nil,
          qr_payload: conflict ? nil : payload, qr: conflict ? NO_QR : qr
        )
        return skip(line, :no_images) if entries.empty?
        return skip(line, :too_many_parts) if entries.size > Receipt::MAX_IMAGES

        check_fingerprint(id, entries, fingerprint) && with_images(root, line, entries, flags)
      end

      def parse_qr(id, fields)
        return NO_QR if fields.nil?
        return problem("#{id}: qr_fields is not an object or null") || NO_QR unless fields.is_a?(Hash)
        return problem("#{id}: qr_fields does not have exactly the keys #{QR_FIELDS.keys.join(', ')}") || NO_QR unless fields.keys.sort == QR_FIELDS.keys.sort

        QR_FIELDS.to_h do |key, column|
          [ column, qr_value(id, key, fields[key]) ]
        end
      end

      def qr_value(id, key, value)
        return if value.nil?
        return problem("#{id}: qr_fields.#{key} is not a text or null") unless value.is_a?(String)

        case key
        when "issued_at"
          return problem("#{id}: qr_fields.issued_at is not an ISO 8601 time with an offset") unless value.match?(TIME)

          Time.iso8601(value).in_time_zone
        when "total"
          return problem("#{id}: qr_fields.total is not a decimal with two places") unless value.match?(MONEY)

          total = BigDecimal(value)
          return total if total < Transaction::AMOUNT_LIMIT

          @warnings << "#{id}: qr_fields.total is too large for the column, stored as nil"
          nil
        else
          value.presence || problem("#{id}: qr_fields.#{key} is empty")
        end
      rescue ArgumentError
        problem("#{id}: qr_fields.issued_at is not a valid time")
      end

      def image_entries(id, images)
        return problem("#{id}: images is not a list") || [] unless images.is_a?(Array)

        images.each_with_index.map do |entry, index|
          part = index + 1
          valid = entry.is_a?(Hash) && entry["file"].is_a?(String) && entry["sha256"].is_a?(String) &&
            entry["sha256"].match?(Receipt::SHA256_FORMAT) && entry["bytes"].is_a?(Integer) && entry["bytes"].positive?
          problem("#{id}: image #{part} needs file, sha256 and bytes") unless valid
          entry
        end
      end

      # The recorded fingerprint must follow the app's rule over the recorded image digests. The digests are
      # then checked against the files, so together the fingerprint is proven for the files themselves.
      def check_fingerprint(id, entries, fingerprint)
        digests = entries.map { |entry| entry["sha256"] }
        expected = digests.one? ? digests.first : Digest::SHA256.hexdigest(digests.sort.join)
        return true if expected == fingerprint

        problem("#{id}: fingerprint is not Receipt.fingerprint of its images")
        false
      end

      def with_images(root, line, entries, flags)
        failures = []
        images = entries.each_with_index.map do |entry, index|
          image = read_image(root, entry, index + 1)
          failures << "image #{index + 1} #{image}" if image.is_a?(String)
          image
        end
        return line.with(images:) if failures.empty?

        if flags.intersect?(UNSURE_FLAGS)
          skip(line, :files_unusable, "#{line.ingest_id}: skipped, flagged #{(flags & UNSURE_FLAGS).join(', ')} " \
            "and #{failures.first} (run the ingest tool again)")
        else
          failures.each { |failure| problem("#{line.ingest_id}: #{failure}") }
          nil
        end
      end

      # A Dataset::Image, or the reason (a String) it cannot be used.
      def read_image(root, entry, part)
        path = inside(root, entry["file"])
        return "is not a file inside the ingest folder" unless path

        sha256 = Digest::SHA256.new
        md5 = Digest::MD5.new
        File.open(path, "rb") do |file|
          while (chunk = file.read(CHUNK_SIZE))
            sha256 << chunk
            md5 << chunk
          end
        end
        return "has another size than recorded" unless File.size(path) == entry["bytes"]
        return "has another SHA-256 than recorded" unless sha256.hexdigest == entry["sha256"]

        Dataset::Image.new(
          part:, path:, filename: File.basename(path), byte_size: entry["bytes"], sha256: entry["sha256"],
          checksum: md5.base64digest, content_type: Marcel::MimeType.for(Pathname.new(path))
        )
      rescue SystemCallError, IOError
        "cannot be read"
      end

      # The real path of `file` when it is a regular file inside `root`, else nil.
      def inside(root, file)
        return if file.empty? || file.include?("\0") || file.start_with?("/", "~")

        path = File.realpath(File.expand_path(file, root))
        path if path.start_with?(root + File::SEPARATOR) && File.file?(path)
      rescue SystemCallError, ArgumentError
        nil
      end

      def check_unique(lines)
        lines.group_by(&:ingest_id).each do |id, same|
          problem("#{id}: the receipt id is on #{same.size} lines (#{same.map(&:number).join(', ')})") if same.size > 1
        end
        lines.reject(&:skipped?).group_by(&:fingerprint).each_value do |same|
          problem("#{same.map(&:ingest_id).join(', ')}: the same photos are on #{same.size} lines") if same.size > 1
        end
      end

      def skip(line, reason, warning = nil)
        @warnings << warning if warning
        line.with(skip_reason: reason)
      end

      # Records a problem and returns nil, so a caller can `return problem(...)`.
      def problem(text)
        @problems << text
        nil
      end
  end
end
