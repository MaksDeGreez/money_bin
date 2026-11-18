require "test_helper"
require_relative "../../support/receipt_ingest_folder"

module ReceiptLoad
  class VerifierTest < ActiveSupport::TestCase
    include ReceiptIngestFolder

    def verify
      Verifier.call(ingest_dir)
    end

    def problems
      error = assert_raises(Error) { verify }
      error.problems
    end

    test "reads every line into typed values" do
      write_ingest([
        ingest_line(1, qr_fields: ingest_qr_fields),
        ingest_line(2, colours: [ 20, 21, 22 ], batch: "batch_02")
      ])

      dataset = verify

      first, second = dataset.lines
      assert_equal [ "rcpt_000001", "batch_01", 1 ], [ first.ingest_id, first.batch, first.images.size ]
      assert_equal BigDecimal("123.40"), first.qr[:qr_total]
      assert_equal Time.utc(2026, 9, 14, 7, 20), first.qr[:qr_issued_at]
      assert_equal [ "4000000009", "900001" ], first.qr.values_at(:qr_fiscal_number, :qr_receipt_number)
      assert_equal ReceiptIngestFolder::INVENTED_TAX_URL, first.qr_payload
      assert_equal [ 1, 2, 3 ], second.images.map(&:part)
      assert_equal %w[image/png], second.images.map(&:content_type).uniq
      assert_equal File.realpath(File.join(ingest_dir, "images/rcpt_000002_1.png")), second.images.first.path
      assert second.qr.values.all?(&:nil?)
      assert_empty dataset.warnings
    end

    test "the recorded checksum is the one Active Storage computes for the file" do
      write_ingest([ ingest_line(1) ])
      image = verify.lines.first.images.first

      blob = ActiveStorage::Blob.build_after_unfurling(io: File.open(image.path, "rb"), filename: image.filename)
      assert_equal blob.checksum, image.checksum
    end

    test "a folder without receipts.jsonl, a missing folder and an empty file are refused" do
      assert_match "has no receipts.jsonl", assert_raises(Error) { verify }.message
      assert_match "does not exist", assert_raises(Error) { Verifier.call(File.join(ingest_dir, "nope")) }.message

      write_ingest([])
      assert_equal [ "receipts.jsonl has no receipts" ], problems
    end

    test "lines that are not JSON objects or have a bad id are refused" do
      write_ingest([ "{not json", "[1, 2]", ingest_line(1).merge("receipt_id" => "rcpt_12"), ingest_line(2).merge("receipt_id" => 7) ])

      assert_equal [
        "line 1: not valid JSON", "line 2: not a JSON object",
        "line 3: receipt_id is not rcpt_ and six or more digits", "line 4: receipt_id is not rcpt_ and six or more digits"
      ], problems
    end

    test "required keys and their types are checked" do
      write_ingest([
        ingest_line(1).merge("batch" => " "), ingest_line(2).merge("flags" => "no_qr"),
        ingest_line(3).merge("fingerprint" => "ABC"), ingest_line(4).merge("qr_payload" => 5),
        ingest_line(5).merge("images" => {}), ingest_line(6).tap { |line| line["images"][0]["bytes"] = 1.5 }
      ])

      assert_equal [
        "rcpt_000001: batch is not a text", "rcpt_000002: flags is not a list of texts",
        "rcpt_000003: fingerprint is not a SHA-256", "rcpt_000004: qr_payload is not a text or null",
        "rcpt_000005: images is not a list", "rcpt_000006: image 1 needs file, sha256 and bytes"
      ], problems
    end

    test "ids must be unique, and so must the photos of the lines to load" do
      first = ingest_line(1)
      write_ingest([ first, first, ingest_line(2, colours: [ 1 ]).merge("receipt_id" => ingest_id(3)) ])

      assert_equal [ "rcpt_000001: the receipt id is on 2 lines (1, 2)", "rcpt_000001, rcpt_000001, rcpt_000003: the same photos are on 3 lines" ], problems
    end

    test "image files must be inside the folder, present, and have the recorded size and digest" do
      outside = File.join(Dir.mktmpdir("receipt-ingest-outside"), "photo.png")
      File.binwrite(outside, png_bytes(red: 99))
      File.symlink(outside, File.join(ingest_dir, "link.png"))
      lines = [
        ingest_line(1).tap { |line| line["images"][0]["file"] = "../#{File.basename(File.dirname(outside))}/photo.png" },
        ingest_line(2).tap { |line| line["images"][0]["file"] = outside },
        ingest_line(3).tap { |line| line["images"][0]["file"] = "link.png" },
        ingest_line(4).tap { |line| File.delete(File.join(ingest_dir, line["images"][0]["file"])) },
        ingest_line(5).tap { |line| line["images"][0]["bytes"] += 1 },
        ingest_line(6).tap { |line| File.binwrite(File.join(ingest_dir, line["images"][0]["file"]), png_bytes(red: 250)) },
        ingest_line(7).tap { |line| line["images"][0]["file"] = "images" },
        ingest_line(8).tap { |line| line["images"][0]["file"] = "~nobody-at-all/photo.png" }
      ]
      write_ingest(lines)

      assert_equal [
        "rcpt_000001: image 1 is not a file inside the ingest folder",
        "rcpt_000002: image 1 is not a file inside the ingest folder",
        "rcpt_000003: image 1 is not a file inside the ingest folder",
        "rcpt_000004: image 1 is not a file inside the ingest folder",
        "rcpt_000005: image 1 has another size than recorded",
        "rcpt_000006: image 1 has another SHA-256 than recorded",
        "rcpt_000007: image 1 is not a file inside the ingest folder",
        "rcpt_000008: image 1 is not a file inside the ingest folder"
      ], problems
    ensure
      FileUtils.remove_entry(File.dirname(outside)) if outside
    end

    test "the fingerprint must follow the app's rule over the image digests" do
      line = ingest_line(1, colours: [ 1, 2 ])
      line["fingerprint"] = Digest::SHA256.hexdigest(line["images"].map { |image| image["sha256"] }.join) # not sorted
      line["images"].reverse! if line["images"].map { |image| image["sha256"] }.then { |digests| digests == digests.sort }
      write_ingest([ line ])

      assert_equal [ "rcpt_000001: fingerprint is not Receipt.fingerprint of its images" ], problems
    end

    test "the fingerprint is the one Receipt.fingerprint gives for the files" do
      write_ingest([ ingest_line(1, colours: [ 1, 2, 3 ]) ])
      line = verify.lines.first

      assert_equal Receipt.fingerprint(line.images.map { |image| File.open(image.path, "rb") }), line.fingerprint
    end

    test "lines without images or with too many photos are skipped, not refused" do
      write_ingest([ ingest_line(1, colours: []), ingest_line(2, colours: [ 1, 2, 3, 4 ], flags: [ "too_many_parts" ]) ])

      assert_equal [ :no_images, :too_many_parts ], verify.lines.map(&:skip_reason)
    end

    test "a line flagged processing_failed or raw_missing whose files fail is skipped with a warning" do
      write_ingest([
        ingest_line(1, flags: [ "processing_failed" ]).tap { |line| File.delete(File.join(ingest_dir, line["images"][0]["file"])) },
        ingest_line(2, flags: [ "raw_missing" ]).tap { |line| line["images"][0]["bytes"] += 1 },
        ingest_line(3, flags: [ "raw_missing" ])
      ])

      dataset = verify

      assert_equal [ :files_unusable, :files_unusable, nil ], dataset.lines.map(&:skip_reason)
      assert_equal [
        "rcpt_000001: skipped, flagged processing_failed and image 1 is not a file inside the ingest folder (run the ingest tool again)",
        "rcpt_000002: skipped, flagged raw_missing and image 1 has another size than recorded (run the ingest tool again)"
      ], dataset.warnings
    end

    test "QR fields may be null and are parsed exactly" do
      write_ingest([
        ingest_line(1, qr_fields: ingest_qr_fields(issued_at: nil, total: nil), flags: [ "qr_fields_partial" ]),
        ingest_line(2, qr_fields: ingest_qr_fields(total: "0.10", issued_at: "2026-03-01T09:05:00Z"))
      ])

      first, second = verify.lines
      assert_equal({ qr_issued_at: nil, qr_total: nil, qr_fiscal_number: "4000000009", qr_receipt_number: "900001" }, first.qr)
      assert_equal BigDecimal("0.1"), second.qr[:qr_total]
      assert_kind_of BigDecimal, second.qr[:qr_total]
      assert_equal Time.utc(2026, 3, 1, 9, 5), second.qr[:qr_issued_at]
    end

    test "QR fields that do not parse are refused" do
      write_ingest([
        ingest_line(1, qr_fields: ingest_qr_fields(issued_at: "2026-09-14T10:20:00")),
        ingest_line(2, qr_fields: ingest_qr_fields(issued_at: "2026-13-40T10:20:00+03:00")),
        ingest_line(3, qr_fields: ingest_qr_fields(total: "12.345")),
        ingest_line(4, qr_fields: ingest_qr_fields(total: "12,30")),
        ingest_line(5, qr_fields: ingest_qr_fields(total: 12.3)),
        ingest_line(6, qr_fields: ingest_qr_fields(fiscal_number: "")),
        ingest_line(7, qr_fields: ingest_qr_fields.except("total")),
        ingest_line(8).merge("qr_fields" => []),
        ingest_line(9, qr_fields: ingest_qr_fields(issued_at: "2026-09-14T10:20:00.1234567+03:00"))
      ])

      assert_equal [
        "rcpt_000001: qr_fields.issued_at is not an ISO 8601 time with an offset",
        "rcpt_000002: qr_fields.issued_at is not a valid time",
        "rcpt_000003: qr_fields.total is not a decimal with two places",
        "rcpt_000004: qr_fields.total is not a decimal with two places",
        "rcpt_000005: qr_fields.total is not a text or null",
        "rcpt_000006: qr_fields.fiscal_number is empty",
        "rcpt_000007: qr_fields does not have exactly the keys issued_at, total, fiscal_number, receipt_number",
        "rcpt_000008: qr_fields is not an object or null",
        "rcpt_000009: qr_fields.issued_at is not an ISO 8601 time with an offset"
      ], problems
    end

    test "a QR total too large for the column is stored as nil with a warning, the load goes on" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields(total: "12345678901234.00")), ingest_line(2, qr_fields: ingest_qr_fields(total: "9999999999999.99")) ])

      dataset = verify

      assert_nil dataset.lines.first.qr[:qr_total]
      assert_equal "4000000009", dataset.lines.first.qr[:qr_fiscal_number]
      assert_equal BigDecimal("9999999999999.99"), dataset.lines.second.qr[:qr_total]
      assert_equal [ "rcpt_000001: qr_fields.total is too large for the column, stored as nil" ], dataset.warnings
    end

    test "a qr_conflict line keeps no QR value" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields, flags: [ "qr_conflict" ]) ])

      line = verify.lines.first
      assert_nil line.qr_payload
      assert line.qr.values.all?(&:nil?)
    end

    test "problems name ids and reasons, never a QR value, a raw photo name or a file name" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields(total: "12.345")).tap { |line| line["images"][0]["bytes"] += 1 } ])

      message = assert_raises(Error) { verify }.message
      [ "12.345", "2026-09-14", "4000000009", "900001", "IMG_", ".png", "cabinet" ].each do |secret|
        assert_not_includes message, secret
      end
      assert_includes message, "Nothing was written."
    end
  end
end
