require "test_helper"
require "rake"
require_relative "../../support/dps_xml_files"

module GroundTruthImport
  class RunnerTest < ActiveSupport::TestCase
    include DpsXmlFiles

    # market_receipt (rcpt_000041) has a dps_xml record in the fixtures; most tests start without it.
    MARKET = "rcpt_000041"
    # Values from the files that must never reach the output.
    FILE_VALUES = [ "Invented", "1250.40", "1250", "960.00", "40.40", "4000000001", "A-1024", "03102026", "184012", "2026-10-03",
                    "18:40", "dish soap" ].freeze

    setup { receipt_ground_truths(:market_dps).delete }

    def import(dry_run: false, dir: dps_dir)
      @output = StringIO.new
      Runner.call(dir, dry_run:, output: @output)
    end

    def output
      @output.string
    end

    def market
      receipts(:market_receipt)
    end

    def record
      market.ground_truths.find_by(source: :dps_xml)
    end

    def counts(report, *outcomes)
      outcomes.index_with { |outcome| report[outcome] }
    end

    def assert_no_file_values
      FILE_VALUES.each { |value| assert_not_includes output, value }
    end

    # A receipt with an ingest id, no QR values and nothing else.
    def receipt_without_qr(ingest_id)
      receipts(:new_receipt).tap { |receipt| receipt.update_columns(ingest_id:) }
    end

    test "imports a file whose receipt is loaded and agrees with its QR code" do
      write_dps_file(MARKET, dps_xml)

      report = import

      assert_equal({ created: 1, unchanged: 0, mismatch: 0, failed: 0 }, counts(report, :created, :unchanged, :mismatch, :failed))
      assert_equal 1, report.stored(:verified)
      assert record.dps_xml?
      assert record.items_known
      assert_equal "dps_check01.v1", record.source_format
      assert_equal Digest::SHA256.hexdigest(File.binread(File.join(dps_dir, "#{MARKET}.xml"))), record.source_sha256
      assert_nil record.prefilled_by
      assert_not record.checked?
      assert_equal "960.00", record.document["items"][1]["amount"]
      assert_includes output, "1 created"
      assert_no_file_values
    end

    test "never changes the receipt, its items, its transaction or anything else of the ledger" do
      write_dps_file(MARKET, dps_xml)
      snapshot = -> {
        [ market.reload.attributes, market.items.map(&:attributes), Transaction.order(:id).map(&:attributes),
          TransactionLine.order(:id).map(&:attributes), Payee.count ]
      }
      before = snapshot.call

      import

      assert_equal before, snapshot.call
    end

    test "a file whose receipt is not loaded is skipped with a warning" do
      write_dps_file("rcpt_009999", dps_xml)

      report = import

      assert_equal 1, report[:receipt_not_loaded]
      assert_includes report.warnings, "rcpt_009999: skipped, no receipt with this ingest id is loaded"
      assert_equal 0, ReceiptGroundTruth.dps_xml.count
    end

    test "a file that disagrees with the QR code is not imported; the warning names the fields, never the values" do
      write_dps_file(MARKET, dps_xml(total: "1250.50", head: { "ORDERTIME" => "184100", "ORDERTAXNUM" => "A-1025" }))

      report = import

      assert_equal 1, report[:mismatch]
      assert_nil record
      warning = report.warnings.sole
      assert_match(/\Arcpt_000041: not imported, the file disagrees with the receipt's QR code on receipt_number, total, issued_at/, warning)
      assert_no_file_values
      assert_not_includes output, "1250.50"
      assert_not_includes output, "A-1025"
    end

    test "every QR field is compared: a different register number alone keeps the file out" do
      write_dps_file(MARKET, dps_xml(head: { "CASHREGISTERNUM" => "4000000002" }))

      report = import

      assert_equal 1, report[:mismatch]
      assert_match(/QR code on fiscal_number \(/, report.warnings.sole)
      assert_nil record
    end

    test "a file without identifying values is imported unverified, with a warning, when the QR code has them" do
      write_dps_file(MARKET, dps_xml(head: { "ORDERTAXNUM" => nil, "ORDERTIME" => nil }))

      report = import

      assert_equal({ created: 1, verified: 0, unverifiable: 1 },
        { created: report[:created], verified: report.stored(:verified), unverifiable: report.stored(:unverifiable) })
      assert_match(/\Arcpt_000041: imported unverified, the file lacks the values to compare/, report.warnings.sole)
      assert record
      assert_includes output, "1 unverified (the file lacks the values to compare)"
    end

    test "agreeing on the register number alone does not verify a file" do
      write_dps_file(MARKET, dps_xml(head: { "ORDERTAXNUM" => nil, "ORDERTIME" => nil }, total: nil))

      report = import

      assert_equal [ 0, 1 ], [ report.stored(:verified), report.stored(:unverifiable) ]
      assert_equal "unverifiable", GroundTruthImport::CrossCheck.call(market, record.document).status.to_s
    end

    test "a receipt whose QR code has only the register number is imported unverified" do
      market.update_columns(qr_receipt_number: nil, qr_total: nil)
      write_dps_file(MARKET, dps_xml)

      report = import

      assert_equal 1, report[:created]
      assert_equal 1, report.stored(:no_qr)
      assert_empty report.warnings
    end

    test "a file that now disagrees leaves the earlier record and says so" do
      write_dps_file(MARKET, dps_xml)
      import
      market.update_columns(qr_total: BigDecimal("1.00"))

      report = import

      assert_equal 1, report[:mismatch]
      assert_match(/the record stored earlier is kept and the export marks it\z/, report.warnings.sole)
      assert record
    end

    test "the time is compared to the minute in Kyiv time, and a missing value on either side is not compared" do
      write_dps_file(MARKET, dps_xml(head: { "ORDERTIME" => "184059", "CASHREGISTERNUM" => nil }))
      market.update_columns(qr_receipt_number: nil)

      report = import

      assert_equal 1, report[:created]
      assert_equal 1, report.stored(:verified)
    end

    test "a receipt without QR values is imported unverified" do
      receipt = receipt_without_qr("rcpt_000077")
      write_dps_file("rcpt_000077", dps_xml(total: "9.99", rows: nil))

      report = import

      assert_equal 1, report[:created]
      assert_equal({ no_qr: 1, without_items: 1 }, { no_qr: report.stored(:no_qr), without_items: report.stored(:without_items) })
      truth = receipt.ground_truths.sole
      assert_not truth.items_known
      assert_equal [], truth.document["items"]
      assert_includes output, "1 unverified (the QR code has too little to compare)"
    end

    test "the same file again changes nothing; a changed file replaces the record" do
      write_dps_file(MARKET, dps_xml)
      import
      first = record

      assert_equal 1, import[:unchanged]
      assert_equal first.updated_at, record.updated_at

      write_dps_file(MARKET, dps_xml(rows: market_rows.first(2)))
      report = import
      assert_equal 1, report[:replaced]
      assert_equal first.id, record.id
      assert_equal 2, record.items.size
      assert_not_equal first.source_sha256, record.source_sha256
    end

    test "a changed file never replaces a record a person has already checked" do
      write_dps_file(MARKET, dps_xml)
      import
      record.record_check!(matches: true)
      before = record.attributes

      write_dps_file(MARKET, dps_xml(rows: market_rows.first(1)))
      report = import

      assert_equal 1, report[:conflict]
      assert_includes report.warnings, "rcpt_000041: left alone, the file changed but a person already checked the record"
      assert_equal before, record.attributes
    end

    test "new records are written in schema version 2, with no categories" do
      write_dps_file(MARKET, dps_xml)
      import
      assert_equal 2, record.schema_version
      assert_not record.categories_known
      assert_nil record.document["category_slug"]
      assert record.document["items"].all? { |item| item.key?("category_slug") && item["category_slug"].nil? }
    end

    test "a checked record stored in schema version 1 stays as it is when its file is unchanged, never a conflict" do
      write_dps_file(MARKET, dps_xml)
      import
      v1 = record.document.except("category_slug").merge("items" => record.document["items"].map { |item| item.except("category_slug") })
      record.update_columns(schema_version: 1, document: v1)
      record.record_check!(matches: true)
      before = record.reload.attributes

      report = import

      assert_equal({ unchanged: 1, conflict: 0, replaced: 0 }, counts(report, :unchanged, :conflict, :replaced))
      assert_equal before, record.reload.attributes
    end

    test "a record read by an older format variant is read again" do
      write_dps_file(MARKET, dps_xml)
      import
      record.update_columns(source_format: "dps_check01.v0")

      assert_equal 1, import[:replaced]
      assert_equal "dps_check01.v1", record.source_format
    end

    test "a return receipt is imported and counted as one" do
      write_dps_file(MARKET, dps_xml(head: { "DOCSUBTYPE" => "1" }))

      report = import

      assert_equal 1, report.stored(:return_receipts)
      assert record.document["is_return"]
    end

    test "a bad file is counted and the others go on" do
      receipt_without_qr("rcpt_000077")
      write_dps_file("rcpt_000001", "<CHECK><CHECKHEAD>")
      write_dps_file("rcpt_000002", %(<?xml version="1.0"?><INVOICE/>))
      write_dps_file("rcpt_000003", %(<?xml version="1.0"?><!DOCTYPE CHECK [<!ENTITY x "y">]><CHECK><CHECKHEAD/></CHECK>))
      write_dps_file("rcpt_000004", dps_xml(head: { "DOCTYPE" => "100" }))
      write_dps_file(MARKET, dps_xml)
      write_dps_file("rcpt_000077", dps_xml(total: "1250.405"))

      report = import

      assert_equal({ created: 2, unreadable: 2, not_a_receipt: 2 }, counts(report, :created, :unreadable, :not_a_receipt))
      assert_includes report.warnings, "rcpt_000001: skipped, not well-formed XML"
      assert_includes report.warnings, "rcpt_000002: skipped, not a receipt layout the reader knows"
      assert_equal 1, report.note(:dropped_total)
      assert_includes output, "1 dropped_total"
      assert_no_file_values
    end

    test "an unexpected error in one file is counted as failed and the others go on" do
      write_dps_file(MARKET, dps_xml)
      receipt_without_qr("rcpt_000077")
      write_dps_file("rcpt_000077", dps_xml)
      calls = 0
      reader = DpsXml::Reader.method(:call)
      failing = ->(bytes) { (calls += 1) == 1 ? raise(IOError, "Invented secret") : reader.call(bytes) }

      report = with_singleton_method(DpsXml::Reader, :call, failing) { import }

      assert_equal({ failed: 1, created: 1 }, counts(report, :failed, :created))
      assert report.failed?
      assert_match(/\Arcpt_000041: failed, IOError/, report.warnings.sole)
      assert_not_includes output, "Invented secret"
    end

    test "other names, folders and symbolic links are counted and ignored; nothing is written in the folder" do
      write_dps_file(MARKET, dps_xml)
      write_dps_file("notes.txt", "x")
      write_dps_file("rcpt_12.xml", dps_xml)
      write_dps_file("RCPT_000042.XML", dps_xml)
      Dir.mkdir(File.join(dps_dir, "rcpt_000099.xml"))
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "target.xml"), dps_xml)
        File.symlink(File.join(outside, "target.xml"), File.join(dps_dir, "rcpt_000098.xml"))
        listing = -> { Dir.children(dps_dir).sort.map { |name| [ name, File.lstat(File.join(dps_dir, name)).mtime ] } }
        before = listing.call

        report = import

        assert_equal 1, report.files
        assert_equal 5, report.ignored
        assert_equal 1, report[:created]
        assert_equal before, listing.call
      end
    end

    test "a too large file is refused from its size" do
      write_dps_file(MARKET, dps_xml + (" " * DpsXml::Reader::MAX_BYTES))

      assert_equal 1, import[:unreadable]
      assert_nil record
    end

    test "a dry run does everything and rolls back" do
      write_dps_file(MARKET, dps_xml)

      report = import(dry_run: true)

      assert_equal 1, report[:created]
      assert_nil record
      assert_includes output, "Dry run: everything was rolled back"
    end

    test "the SQL log is silenced while the import runs, so no document reaches the log file" do
      write_dps_file(MARKET, dps_xml)
      log = StringIO.new
      original = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = ActiveSupport::Logger.new(log, level: :debug)
      begin
        import
        Receipt.where(ingest_id: "rcpt_000777").to_a
      ensure
        ActiveRecord::Base.logger = original
      end

      assert_includes log.string, "rcpt_000777", "the logger works outside the import"
      [ "Invented", "960.00", "dish soap" ].each { |value| assert_not_includes log.string, value }
    end

    test "the folder must be outside every git repository" do
      error = assert_raises(Error) { import(dir: Rails.root.join("test").to_s) }
      assert_equal "The ground-truth folder is inside a git repository; receipt files belong outside it.", error.message
    end

    test "the folder must exist" do
      error = assert_raises(Error) { import(dir: File.join(dps_dir, "missing")) }
      assert_equal "The ground-truth folder does not exist or cannot be read.", error.message
      file = write_dps_file("plain.txt", "x")
      assert_raises(Error) { import(dir: file) }
    end

    test "the rake task needs a folder and reports through the runner" do
      Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "receipts:import_ground_truth_xml" }
      task = Rake::Task["receipts:import_ground_truth_xml"]
      assert_raises(SystemExit) { capture_io { task.execute(Rake::TaskArguments.new([ :dir ], [])) } }

      write_dps_file(MARKET, dps_xml)
      out, = capture_io { task.execute(Rake::TaskArguments.new([ :dir ], [ dps_dir ])) }
      assert_includes out, "1 created"
      assert record
    end
  end
end
