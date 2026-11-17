require "test_helper"

module LegacyImport
  class ExportReaderTest < ActiveSupport::TestCase
    def problems(dir)
      assert_raises(Error) { ExportReader.call(dir) }.problems
    end

    test "reads the fixture export" do
      export = ExportReader.call(LegacyExportFiles::FIXTURE)

      assert_equal 1, export.manifest["schema_version"]
      assert_equal [ 5, 7, 5, 11 ], ExportReader::FILES.map { |file| export.rows.fetch(file).size }
      first = export.rows.fetch("transactions.jsonl").first
      assert_equal [ "transactions.jsonl", 1, 1001 ], [ first.file, first.line, first.data["legacy_id"] ]
    end

    test "the folder and the manifest must exist" do
      assert_equal [ "the export folder does not exist or is not a folder" ], problems("/nonexistent/legacy_export")

      LegacyExportFiles.temp_copy do |dir|
        File.delete(File.join(dir, "MANIFEST.json"))
        assert_equal [ "MANIFEST.json is missing" ], problems(dir)
      end
    end

    test "the manifest must be a JSON object with every key and schema version 1" do
      LegacyExportFiles.temp_copy do |dir|
        File.write(File.join(dir, "MANIFEST.json"), "{ not json")
        assert_equal [ "MANIFEST.json is not valid JSON" ], problems(dir)

        File.write(File.join(dir, "MANIFEST.json"), "[]")
        assert_equal [ "MANIFEST.json is not a JSON object" ], problems(dir)

        File.write(File.join(dir, "MANIFEST.json"), '{"schema_version": 1}')
        assert_match(/MANIFEST.json has no exported_at, legacy_git_sha/, problems(dir).first)
      end

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit_manifest(dir) { |manifest| manifest["schema_version"] = 2 }
        assert_match(/schema_version must be 1/, problems(dir).first)

        LegacyExportFiles.edit_manifest(dir) do |manifest|
          manifest.merge!("schema_version" => 1, "counts" => [], "sha256" => "x", "warnings" => {})
        end
        assert_equal [
          "MANIFEST.json: counts must be a JSON object", "MANIFEST.json: sha256 must be a JSON object",
          "MANIFEST.json: warnings must be a JSON array"
        ], problems(dir)
      end
    end

    test "a wrong hash or a wrong count stops it" do
      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit_manifest(dir) do |manifest|
          manifest["sha256"]["payees.jsonl"] = "0" * 64
          manifest["counts"]["accounts.jsonl"] = 6
          manifest["sha256"]["categories.jsonl"] = "abc"
          manifest["counts"]["transactions.jsonl"] = "11"
        end

        assert_equal [
          "accounts.jsonl: has 5 lines but MANIFEST.json says 6",
          "MANIFEST.json: the sha256 of categories.jsonl is not 64 hex characters",
          "payees.jsonl: the SHA-256 does not match MANIFEST.json",
          "MANIFEST.json: the count of transactions.jsonl is not an integer"
        ], problems(dir)
      end
    end

    test "a file changed after the export stops it" do
      LegacyExportFiles.temp_copy do |dir|
        File.open(File.join(dir, "payees.jsonl"), "a") { |file| file.write(%({"legacy_id":99,"name":"Late Shop"}\n)) }

        assert_equal [
          "payees.jsonl: the SHA-256 does not match MANIFEST.json", "payees.jsonl: has 6 lines but MANIFEST.json says 5"
        ], problems(dir)
      end
    end

    test "every data file must be listed and present, and no other file may be listed" do
      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit_manifest(dir) do |manifest|
          manifest["counts"].delete("payees.jsonl")
          manifest["counts"]["budgets.jsonl"] = 1
          manifest["sha256"]["budgets.jsonl"] = "0" * 64
        end
        File.delete(File.join(dir, "categories.jsonl"))

        assert_equal [
          "MANIFEST.json lists a file this importer does not know (budgets.jsonl)",
          "categories.jsonl is listed in MANIFEST.json but missing",
          "payees.jsonl is not listed in MANIFEST.json counts and sha256"
        ], problems(dir)
      end
    end

    test "every line must be a JSON object, and the files UTF-8" do
      LegacyExportFiles.temp_copy do |dir|
        File.write(File.join(dir, "payees.jsonl"), %({"legacy_id":1,"name":"A"}\n{"legacy_id":2,\n[1]\n\n))
        File.binwrite(File.join(dir, "categories.jsonl"), "{\"legacy_id\":1,\"legacy_path\":\"\xFF\"}\n".b)
        LegacyExportFiles.rehash!(dir)

        assert_equal [ "categories.jsonl: is not valid UTF-8" ], problems(dir)

        File.write(File.join(dir, "categories.jsonl"), "")
        LegacyExportFiles.rehash!(dir)
        assert_equal [
          "payees.jsonl line 2: is not valid JSON", "payees.jsonl line 3: is not a JSON object",
          "payees.jsonl line 4: is empty"
        ], problems(dir)
      end
    end
  end
end
