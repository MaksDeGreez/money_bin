require "digest"

module LegacyImport
  # Reads an export folder and checks it as a set of files, before anything looks at the rows:
  #
  # - MANIFEST.json is a JSON object with every manifest key, and `schema_version` is 1;
  # - the manifest lists exactly the four data files in both `counts` and `sha256`;
  # - each data file exists, is UTF-8, and its SHA-256 and its number of lines match the manifest;
  # - every line is one JSON object.
  #
  # Returns an Export with the parsed lines; raises Error with every problem found. It never writes.
  class ExportReader
    SCHEMA_VERSION = 1
    MANIFEST = "MANIFEST.json".freeze
    FILES = %w[accounts.jsonl categories.jsonl payees.jsonl transactions.jsonl].freeze
    MANIFEST_KEYS = %w[schema_version exported_at legacy_git_sha date_from date_to counts sha256 warnings].freeze
    SHA256_HEX = /\A[0-9a-f]{64}\z/
    ROW_PROBLEMS = { empty: "is empty", invalid: "is not valid JSON" }.freeze

    # One line of a data file: its file name, its line number (from 1) and the parsed JSON object.
    RawRow = Data.define(:file, :line, :data)
    # The manifest as parsed, and the rows of each data file (file name => [RawRow]).
    Export = Data.define(:manifest, :rows)

    def self.call(dir)
      new(dir).call
    end

    def initialize(dir)
      @dir = Pathname(dir.to_s)
    end

    def call
      raise Error, "the export folder does not exist or is not a folder" unless @dir.directory?

      manifest = read_manifest
      check_files(manifest)
      Export.new(manifest:, rows: read_rows)
    end

    private
      def read_manifest
        path = @dir.join(MANIFEST)
        raise Error, "#{MANIFEST} is missing" unless path.file?

        manifest = parse_json(path.binread)
        raise Error, "#{MANIFEST} is not valid JSON" if manifest == :invalid
        raise Error, "#{MANIFEST} is not a JSON object" unless manifest.is_a?(Hash)

        check_manifest(manifest)
        manifest
      end

      def check_manifest(manifest)
        missing = MANIFEST_KEYS - manifest.keys
        raise Error, "#{MANIFEST} has no #{missing.join(', ')}" if missing.any?
        unless manifest["schema_version"] == SCHEMA_VERSION
          raise Error, "#{MANIFEST}: schema_version must be #{SCHEMA_VERSION}; this importer reads only that version"
        end

        problems = %w[counts sha256].filter_map do |key|
          "#{MANIFEST}: #{key} must be a JSON object" unless manifest[key].is_a?(Hash)
        end
        problems << "#{MANIFEST}: warnings must be a JSON array" unless manifest["warnings"].is_a?(Array)
        raise Error, problems if problems.any?
      end

      def check_files(manifest)
        counts, hashes = manifest.values_at("counts", "sha256")
        problems = (counts.keys | hashes.keys).difference(FILES).map do |name|
          "#{MANIFEST} lists a file this importer does not know (#{Values.printable_id(name)})"
        end
        FILES.each { |file| problems.concat(file_problems(file, counts, hashes)) }
        raise Error, problems if problems.any?
      end

      def file_problems(file, counts, hashes)
        return [ "#{file} is not listed in #{MANIFEST} counts and sha256" ] unless counts.key?(file) && hashes.key?(file)

        path = @dir.join(file)
        return [ "#{file} is listed in #{MANIFEST} but missing" ] unless path.file?

        bytes = path.binread
        problems = []
        expected_hash = hashes[file]
        if !expected_hash.is_a?(String) || !expected_hash.downcase.match?(SHA256_HEX)
          problems << "#{MANIFEST}: the sha256 of #{file} is not 64 hex characters"
        elsif Digest::SHA256.hexdigest(bytes) != expected_hash.downcase
          problems << "#{file}: the SHA-256 does not match #{MANIFEST}"
        end
        expected_count = counts[file]
        if !expected_count.is_a?(Integer)
          problems << "#{MANIFEST}: the count of #{file} is not an integer"
        elsif line_count(bytes) != expected_count
          problems << "#{file}: has #{line_count(bytes)} lines but #{MANIFEST} says #{expected_count}"
        end
        problems << "#{file}: is not valid UTF-8" unless bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        problems
      end

      # Lines of a JSON Lines file: a final newline is optional and ends the last line, it does not start one.
      def line_count(bytes)
        bytes.count("\n") + (bytes.empty? || bytes.end_with?("\n") ? 0 : 1)
      end

      def read_rows
        problems = []
        rows = FILES.index_with do |file|
          text = @dir.join(file).read(encoding: Encoding::UTF_8)
          text.each_line.with_index(1).filter_map do |line, number|
            data = line.strip.empty? ? :empty : parse_json(line)
            next RawRow.new(file:, line: number, data:) if data.is_a?(Hash)

            problems << "#{file} line #{number}: #{ROW_PROBLEMS.fetch(data, 'is not a JSON object')}"
            nil
          end
        end
        raise Error, problems if problems.any?

        rows
      end

      # The parsed value, or :invalid. The parser's own message quotes the text around the error, so it is
      # never shown.
      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError, EncodingError
        :invalid
      end
  end
end
