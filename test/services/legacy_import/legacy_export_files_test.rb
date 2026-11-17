require "test_helper"
require "open3"

# The helper that builds broken variants of the fixture export, and the fixture itself.
class LegacyExportFilesTest < ActiveSupport::TestCase
  test "the fixture manifest has the right hashes and counts" do
    stored = LegacyExportFiles.manifest(LegacyExportFiles::FIXTURE)

    LegacyExportFiles.temp_copy do |dir|
      LegacyExportFiles.rehash!(dir)

      assert_equal stored, LegacyExportFiles.manifest(dir), "re-hash the fixture (see test/support/legacy_export_files.rb)"
    end
    assert_equal 15, stored["counts"]["transactions.jsonl"]
  end

  test "the fixture folder is not ignored by git" do
    _out, status = Open3.capture2e("git", "check-ignore", "-q", "--no-index",
      "test/fixtures/files/legacy_export/transactions.jsonl", chdir: Rails.root.to_s)

    assert_equal 1, status.exitstatus
  end

  test "temp_copy gives a copy and removes it afterwards" do
    kept = nil
    LegacyExportFiles.temp_copy do |dir|
      kept = dir
      assert_equal (LegacyExportFiles::DATA_FILES + [ "MANIFEST.json" ]).sort, Dir.children(dir).sort
    end

    assert_not File.exist?(kept)
  end

  test "edit rewrites the rows and the manifest" do
    LegacyExportFiles.temp_copy do |dir|
      LegacyExportFiles.edit(dir, "payees.jsonl") { |rows| rows << { "legacy_id" => 99, "name" => "Another Shop" } }
      bytes = File.binread(File.join(dir, "payees.jsonl"))
      manifest = LegacyExportFiles.manifest(dir)

      assert_equal 6, manifest["counts"]["payees.jsonl"]
      assert_equal Digest::SHA256.hexdigest(bytes), manifest["sha256"]["payees.jsonl"]
      assert_equal "Another Shop", LegacyExportFiles.rows(dir, "payees.jsonl").last["name"]

      LegacyExportFiles.edit(dir, "payees.jsonl") { |rows| rows.replace(rows.first(2)) }
      assert_equal 2, LegacyExportFiles.manifest(dir)["counts"]["payees.jsonl"]
    end
  end

  test "rehash leaves a missing file as the manifest has it and counts a last line without a newline" do
    LegacyExportFiles.temp_copy do |dir|
      File.delete(File.join(dir, "payees.jsonl"))
      File.write(File.join(dir, "accounts.jsonl"), File.read(File.join(dir, "accounts.jsonl")).chomp)
      LegacyExportFiles.rehash!(dir)
      manifest = LegacyExportFiles.manifest(dir)

      assert_equal 5, manifest["counts"]["payees.jsonl"]
      assert_equal 5, manifest["counts"]["accounts.jsonl"]
    end
  end

  test "edit_manifest changes the manifest only" do
    LegacyExportFiles.temp_copy do |dir|
      LegacyExportFiles.edit_manifest(dir) { |manifest| manifest["schema_version"] = 2 }

      assert_equal 2, LegacyExportFiles.manifest(dir)["schema_version"]
    end
  end
end
