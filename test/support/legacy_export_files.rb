require "digest"
require "fileutils"
require "json"
require "tmpdir"

# Builds and edits export folders for the history importer tests (docs/import-contract.md), so a test can
# make a broken variant of the fixture export in a temporary folder instead of keeping many fixture folders.
#
#   LegacyExportFiles.temp_copy do |dir|
#     LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows.first["kind"] = "piggy bank" }
#     # MANIFEST.json now has the new hash and count of accounts.jsonl
#   end
#
# It needs only the Ruby standard library, so it can also re-hash the fixture after a change to it:
#
#   ruby -r ./test/support/legacy_export_files -e 'LegacyExportFiles.rehash!("test/fixtures/files/legacy_export")'
module LegacyExportFiles
  FIXTURE = File.expand_path("../fixtures/files/legacy_export", __dir__)
  MANIFEST = "MANIFEST.json".freeze
  DATA_FILES = %w[accounts.jsonl categories.jsonl payees.jsonl transactions.jsonl].freeze

  module_function

  # Yields a temporary copy of the fixture export (or of `source`) and removes it afterwards.
  def temp_copy(source = FIXTURE)
    Dir.mktmpdir("legacy_export") do |dir|
      FileUtils.cp_r(File.join(source, "."), dir)
      yield dir
    end
  end

  def rows(dir, file)
    File.readlines(File.join(dir, file), chomp: true).map { |line| JSON.parse(line) }
  end

  # Writes `rows` as JSON Lines (one compact object per line, a final newline) and re-hashes the manifest.
  def write_rows(dir, file, rows)
    File.write(File.join(dir, file), rows.map { |row| "#{JSON.generate(row)}\n" }.join)
    rehash!(dir)
  end

  # Yields the rows of `file` (an Array of Hashes) to change in place, then writes them. The block's return
  # value is ignored: remove rows with `reject!`, `select!` or `replace`.
  def edit(dir, file)
    list = rows(dir, file)
    yield list
    write_rows(dir, file, list)
  end

  def manifest(dir)
    JSON.parse(File.read(File.join(dir, MANIFEST)))
  end

  def write_manifest(dir, manifest)
    File.write(File.join(dir, MANIFEST), "#{JSON.pretty_generate(manifest)}\n")
  end

  # Yields the manifest to change in place, then writes it.
  def edit_manifest(dir)
    data = manifest(dir)
    yield data
    write_manifest(dir, data)
  end

  # Sets `counts` and `sha256` in MANIFEST.json to the data files as they are now. A data file that is not
  # there is left as the manifest has it, so a test can still make a "listed but missing" export.
  def rehash!(dir)
    edit_manifest(dir) do |data|
      DATA_FILES.each do |file|
        path = File.join(dir, file)
        next unless File.file?(path)

        bytes = File.binread(path)
        data["counts"][file] = bytes.count("\n") + (bytes.empty? || bytes.end_with?("\n") ? 0 : 1)
        data["sha256"][file] = Digest::SHA256.hexdigest(bytes)
      end
    end
  end
end
