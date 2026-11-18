require "test_helper"
require "rake"
require "tmpdir"

class GroundTruthExportTest < ActiveSupport::TestCase
  setup { @root = Dir.mktmpdir("ground-truth-export-test") }
  teardown { FileUtils.remove_entry(@root) if File.directory?(@root) }

  def export(dir = File.join(@root, "out"))
    @output = StringIO.new
    GroundTruthExport.call(dir, output: @output)
  end

  def lines
    File.readlines(File.join(@root, "out", GroundTruthExport::FILE_NAME)).map { |line| JSON.parse(line) }
  end

  test "writes one JSON line per record, money as decimal strings, with private modes" do
    assert_equal 2, export

    market, corner = lines
    assert_equal({ "receipt_id" => receipts(:market_receipt).id, "ingest_id" => "rcpt_000041", "source" => "dps_xml",
                   "source_format" => "dps_check01.v1", "prefilled_by" => nil, "prefill_kind" => nil,
                   "prefilled_model_version" => nil, "prefilled_prompt_version" => nil, "categories_prefilled_by" => nil,
                   "checked_at" => "2026-10-05T10:00:00+03:00", "check_outcome" => "matches", "qr_check" => "agrees",
                   "items_known" => true, "categories_known" => false, "schema_version" => 2, "stored_schema_version" => 1 },
      market.except("document", "saved_at"))
    assert_equal receipt_ground_truths(:market_dps).updated_at.to_i, Time.iso8601(market["saved_at"]).to_i
    assert_equal "1250.40", market["document"]["total"]
    assert_equal "960.00", market["document"]["items"][1]["amount"]
    assert_equal({ "ingest_id" => nil, "source" => "manual", "prefilled_by" => "stub-ocr", "checked_at" => nil, "qr_check" => "no_qr" },
      corner.slice("ingest_id", "source", "prefilled_by", "checked_at", "qr_check"))

    path = File.join(@root, "out", GroundTruthExport::FILE_NAME)
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o700, File.stat(File.join(@root, "out")).mode & 0o777
    assert_equal [ GroundTruthExport::FILE_NAME ], Dir.children(File.join(@root, "out")), "no temporary file is left"
    assert_equal "Ground-truth export: 2 records written to ground_truth.jsonl\n", @output.string
  end

  test "one shape: a version 1 record is written as version 2, its categories null and not known" do
    export
    lines.each do |line|
      assert_equal 2, line["schema_version"]
      assert_equal ReceiptGroundTruth::Document::KEYS.sort, line["document"].keys.sort
      assert line["document"]["items"].all? { |item| ReceiptGroundTruth::Document::ITEM_KEYS.sort == item.keys.sort }
      assert_empty ReceiptGroundTruth::Document.problems(line["document"], items_known: line["items_known"],
        categories_known: line["categories_known"])
    end
    assert_not receipt_ground_truths(:market_dps).reload.document.key?("category_slug"), "the stored record is not rewritten"
  end

  test "a manual record carries its categories, what pre-filled it and which categoriser suggested" do
    ReceiptGroundTruth.manual.delete_all
    document = ReceiptGroundTruth::Document.blank.merge("kind" => "fiscal", "total" => "60.00",
      "items" => [ { "name" => "Invented water", "quantity" => "2.000", "unit_price" => "30.00", "amount" => "60.00",
                     "discount" => "0.00", "category_slug" => "groceries/groceries" } ])
    receipts(:corner_receipt).ground_truths.create!(source: :manual, schema_version: 2, items_known: true, categories_known: true,
      prefilled_by: "stub-ocr", prefilled_model_version: "0.1.0", prefilled_prompt_version: "abc123",
      categories_prefilled_by: "invented-categoriser", document:)

    export
    corner = lines.find { |line| line["source"] == "manual" }
    assert_equal({ "prefilled_by" => "stub-ocr", "prefill_kind" => "model", "prefilled_model_version" => "0.1.0",
                   "prefilled_prompt_version" => "abc123", "categories_prefilled_by" => "invented-categoriser",
                   "categories_known" => true, "stored_schema_version" => 2 },
      corner.slice("prefilled_by", "prefill_kind", "prefilled_model_version", "prefilled_prompt_version",
        "categories_prefilled_by", "categories_known", "stored_schema_version"))
    assert_equal "groceries/groceries", corner["document"]["items"].first["category_slug"]
    assert_equal "60.00", corner["document"]["items"].first["amount"], "money stays a decimal string"
  end

  test "a record that the receipt's QR values now contradict is marked" do
    receipts(:market_receipt).update_columns(qr_total: BigDecimal("1.00"))
    export
    assert_equal "disagrees", lines.first["qr_check"]
  end

  test "writing again replaces the file" do
    export
    ReceiptGroundTruth.manual.delete_all
    assert_equal 1, export
    assert_equal 1, lines.size
  end

  test "refuses a folder inside a git repository" do
    Dir.mkdir(File.join(@root, ".git"))
    error = assert_raises(GroundTruthExport::Error) { export(File.join(@root, "nested", "out")) }
    assert_equal "The output folder is inside a git repository; choose one outside it.", error.message
    assert_not File.exist?(File.join(@root, "nested"))

    assert PrivateFolder.inside_git_repository?(Rails.root.join("tmp", "export").to_s)
  end

  test "a symbolic link from outside into a repository does not hide it" do
    checkout = File.join(@root, "checkout")
    FileUtils.mkdir_p(File.join(checkout, ".git"))
    FileUtils.mkdir_p(File.join(checkout, "nested", "deeper"))
    outside = Dir.mktmpdir("ground-truth-export-link")
    link = File.join(outside, "link")
    File.symlink(File.join(checkout, "nested"), link)

    assert PrivateFolder.inside_git_repository?(link)
    assert PrivateFolder.inside_git_repository?(File.join(link, "deeper", "not-yet"))
    assert_raises(GroundTruthExport::Error) { export(File.join(link, "out")) }
    assert_not PrivateFolder.inside_git_repository?(File.join(outside, "plain"))
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  test "the rake task needs a folder" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "receipts:export_ground_truth" }
    task = Rake::Task["receipts:export_ground_truth"]
    assert_raises(SystemExit) { capture_io { task.execute(Rake::TaskArguments.new([ :out_dir ], [])) } }
    assert_raises(SystemExit) { capture_io { task.execute(Rake::TaskArguments.new([ :out_dir ], [ Rails.root.join("tmp").to_s ])) } }

    out, = capture_io { task.execute(Rake::TaskArguments.new([ :out_dir ], [ File.join(@root, "out") ])) }
    assert_includes out, "2 records written"
  end
end
