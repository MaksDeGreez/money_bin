require "test_helper"
require "rake"
require_relative "../../support/receipt_ingest_folder"

module ReceiptLoad
  class RunnerTest < ActiveSupport::TestCase
    include ReceiptIngestFolder
    include ActiveJob::TestHelper

    # The fixture receipts are not in the test folders; a fixture with an ingest id would count as a receipt
    # that left the ingest set in every test. The retirement rules have tests of their own below.
    setup { Receipt.where.not(ingest_id: nil).update_all(ingest_id: nil) }

    def load_receipts(dry_run: false)
      @output = StringIO.new
      Runner.call(ingest_dir, dry_run:, output: @output)
    end

    def loaded(number)
      Receipt.find_by!(ingest_id: ingest_id(number))
    end

    def photo_bytes(receipt)
      receipt.images_attachments.includes(:blob).order(:id).map { |attachment| attachment.blob.download }
    end

    def file_bytes(line)
      line["images"].map { |image| File.binread(File.join(ingest_dir, image["file"])) }
    end

    def counts(report, *outcomes)
      outcomes.index_with { |outcome| report[outcome] }
    end

    # Every receipt and attachment row as stored, to prove nothing was written.
    def snapshot
      [ Receipt.order(:id).map(&:attributes), ActiveStorage::Attachment.order(:id).map(&:attributes),
        ActiveStorage::Blob.order(:id).map(&:attributes) ]
    end

    # A receipt uploaded in the app (no ingest id) with the photos of `line`.
    def app_upload(line, **attributes)
      Receipt.create!(images: file_bytes(line).map { |bytes| image_upload(bytes) }, **attributes)
    end

    test "creates one receipt per line with its photos in part order, the ingest fields and nothing else" do
      lines = [ ingest_line(1, colours: [ 30, 31, 32 ], qr_fields: ingest_qr_fields), ingest_line(2, batch: "batch_02") ]
      write_ingest(lines)

      report = load_receipts

      assert_equal({ created: 2, unchanged: 0, failed: 0 }, counts(report, :created, :unchanged, :failed))
      first = loaded(1)
      assert first.uploaded?
      assert_equal lines[0]["fingerprint"], first.sha256
      assert_equal file_bytes(lines[0]), photo_bytes(first)
      assert_equal %w[rcpt_000001_1.png rcpt_000001_2.png rcpt_000001_3.png], first.images_attachments.order(:id).map { |a| a.blob.filename.to_s }
      assert_equal "batch_01", first.batch
      assert_equal ReceiptIngestFolder::INVENTED_TAX_URL, first.qr_payload
      assert_equal [ Time.utc(2026, 9, 14, 7, 20), BigDecimal("123.40"), "4000000009", "900001" ],
        [ first.qr_issued_at, first.qr_total, first.qr_fiscal_number, first.qr_receipt_number ]
      assert first.tax_qr?
      assert_nil first.kind, "a tax QR does not set the kind: OCR and the review do"
      assert_not first.incomplete?
      assert_equal [ nil, nil, nil, nil, nil ], [ first.ocr_raw, first.issued_at, first.total, first.fiscal_number, first.card_last4 ]
      assert_empty first.items

      second = loaded(2)
      assert_equal "batch_02", second.batch
      assert_not second.tax_qr?
      assert_nil second.qr_payload
    end

    test "enqueues no OCR: loading only stores the receipts" do
      write_ingest([ ingest_line(1) ])

      assert_no_enqueued_jobs(only: ReceiptOcrJob) { load_receipts }
      assert loaded(1).uploaded?
    end

    test "a second run of the same folder writes nothing" do
      write_ingest([ ingest_line(1, colours: [ 1, 2 ], qr_fields: ingest_qr_fields), ingest_line(2) ])
      load_receipts
      before = snapshot

      report = load_receipts

      assert_equal({ created: 0, updated: 0, unchanged: 2 }, counts(report, :created, :updated, :unchanged))
      assert_equal before, snapshot
    end

    test "a dry run does the same work, uploads nothing and rolls back" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields), ingest_line(2, colours: []) ])
      before = snapshot

      report = with_singleton_method(ActiveStorage::Blob.service, :upload, ->(*, **) { flunk "a dry run uploads nothing" }) do
        load_receipts(dry_run: true)
      end

      assert_equal({ created: 1, skipped_no_images: 1 }, counts(report, :created, :skipped_no_images), @output.string)
      assert_equal before, snapshot
      assert_includes @output.string, "Receipt load (dry run): 2 lines in receipts.jsonl"
      assert_includes @output.string, "Dry run: everything was rolled back, nothing was written."
    end

    test "a dry run reports the same outcomes as the real run that follows" do
      write_ingest([ ingest_line(1), ingest_line(2, colours: [ 1 ]).merge("receipt_id" => ingest_id(2)).tap { |line| line["images"] = [] } ])

      dry = load_receipts(dry_run: true)
      real = load_receipts

      assert_equal Report::OUTCOMES.keys.map { |outcome| dry[outcome] }, Report::OUTCOMES.keys.map { |outcome| real[outcome] }
    end

    test "lines without images or with too many photos are counted and not loaded" do
      write_ingest([ ingest_line(1, colours: []), ingest_line(2, colours: [ 1, 2, 3, 4 ], flags: [ "too_many_parts" ]), ingest_line(3) ])

      report = load_receipts

      assert_equal({ skipped_no_images: 1, skipped_too_many_parts: 1, created: 1 },
        counts(report, :skipped_no_images, :skipped_too_many_parts, :created))
      assert_equal [ ingest_id(3) ], Receipt.where.not(ingest_id: nil).pluck(:ingest_id)
      assert_includes @output.string, "batch_01: 1 created, 1 skipped (no images), 1 skipped (more than 3 photos)"
    end

    test "a receipt uploaded in the app with the same photos gets the ingest fields and keeps everything else" do
      line = ingest_line(1, qr_fields: ingest_qr_fields)
      write_ingest([ line ])
      receipt = app_upload(line, batch: "phone", status: :extracted, kind: :card_slip, incomplete: true, total: BigDecimal("99.90"),
        card_last4: "4242", ocr_raw: { "receipt" => {} })
      receipt.items.create!(position: 1, name: "Tea", amount: BigDecimal("99.90"))

      report = load_receipts

      assert_equal 1, report[:updated]
      receipt.reload
      assert_equal [ ingest_id(1), "batch_01", BigDecimal("123.40") ], [ receipt.ingest_id, receipt.batch, receipt.qr_total ]
      assert_equal [ "extracted", "card_slip", true, BigDecimal("99.90"), "4242", { "receipt" => {} } ],
        [ receipt.status, receipt.kind, receipt.incomplete, receipt.total, receipt.card_last4, receipt.ocr_raw ]
      assert_equal [ "Tea" ], receipt.items.map(&:name)
    end

    test "changed ingest fields are written again on a receipt that was already worked on" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields) ])
      load_receipts
      receipt = loaded(1)
      receipt.update!(status: :reviewed, kind: :fiscal, total: BigDecimal("123.40"), issued_at: Time.utc(2026, 9, 14, 7, 20))

      write_ingest([ ingest_line(1, batch: "batch_renamed", qr_fields: ingest_qr_fields(total: nil), flags: [ "qr_fields_partial" ]) ])
      report = load_receipts

      assert_equal 1, report[:updated]
      receipt.reload
      assert_equal [ "batch_renamed", nil ], [ receipt.batch, receipt.qr_total ]
      assert_equal [ "reviewed", "fiscal", BigDecimal("123.40") ], [ receipt.status, receipt.kind, receipt.total ]
    end

    test "a qr_conflict line stores no QR value" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields, flags: [ "qr_conflict" ]) ])

      load_receipts

      assert_nil loaded(1).qr_payload
      assert_not loaded(1).tax_qr?
    end

    test "a pristine receipt whose photos were regrouped gets the new photos and fingerprint" do
      write_ingest([ ingest_line(1, colours: [ 1 ]) ])
      load_receipts
      receipt = loaded(1)
      old_blob_ids = receipt.images_attachments.pluck(:blob_id)

      FileUtils.rm_rf(File.join(ingest_dir, "images"))
      line = ingest_line(1, colours: [ 1, 2 ])
      write_ingest([ line ])
      report = nil
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { report = load_receipts }

      assert_equal 1, report[:regrouped]
      receipt.reload
      assert_equal line["fingerprint"], receipt.sha256
      assert_equal file_bytes(line), photo_bytes(receipt)
      assert_not ActiveStorage::Blob.exists?(id: old_blob_ids), "the old photos are purged"
      assert_equal({ unchanged: 1 }, counts(load_receipts, :unchanged))
    end

    test "a regrouped receipt that is no longer pristine is left alone" do
      write_ingest([ ingest_line(1, colours: [ 1 ]) ])
      load_receipts
      receipt = loaded(1)
      receipt.update!(status: :extracted)
      before = snapshot

      write_ingest([ ingest_line(1, colours: [ 1, 2 ]) ])
      report = load_receipts

      assert_equal 1, report[:conflict]
      assert_equal before, snapshot
      assert_match(/rcpt_000001: left alone, its photos changed, but receipt \d+ is extracted/, @output.string)
    end

    test "a receipt with ground truth is kept when it leaves the ingest set, and its photos are not regrouped" do
      write_ingest([ ingest_line(1, colours: [ 1 ]), ingest_line(2) ])
      load_receipts
      [ loaded(1), loaded(2) ].each do |receipt|
        receipt.ground_truths.create!(source: :manual, schema_version: 2, items_known: false,
          prefilled_by: ReceiptGroundTruth::PREFILLED_BY_HAND,
          document: ReceiptGroundTruth::Document.blank)
      end

      write_ingest([ ingest_line(1, colours: [ 1, 2 ]) ]) # 1 regrouped, 2 left the set
      report = load_receipts

      assert_equal({ conflict: 1, retired_kept: 1, retired_deleted: 0 }, counts(report, :conflict, :retired_kept, :retired_deleted))
      assert_equal 1, loaded(1).images.count
      assert loaded(2)
      assert_match(/rcpt_000001: left alone, its photos changed, but receipt \d+ is uploaded or has items, a transaction or ground truth/, @output.string)
    end

    test "a receipt whose acceptance was undone is not pristine: kept, its photos not regrouped" do
      write_ingest([ ingest_line(1, colours: [ 1 ]), ingest_line(2) ])
      load_receipts
      receipt = loaded(1)
      receipt.update_columns(status: "extracted", currency: "UAH", issued_at: Time.utc(2026, 10, 8, 9))
      receipt.items.create!(position: 1, name: "Bread", amount: "40.00")
      Receipts::Accept.call(receipt.reload, account: accounts(:card_uah))
      receipt.reload
      Receipts::UndoAccept.call(receipt, lock_version: receipt.lock_version, transaction_lock_version: receipt.ledger_transaction.lock_version)
      assert receipt.reload.extracted?
      assert_not receipt.pristine?

      write_ingest([ ingest_line(1, colours: [ 1, 2 ]) ]) # regrouped
      assert_equal 1, load_receipts[:conflict]
      write_ingest([ ingest_line(2) ]) # 1 left the set
      assert_equal 1, load_receipts[:retired_kept]

      assert_equal 1, receipt.reload.images.count
      assert_equal [ "Bread" ], receipt.items.pluck(:name)
      assert_empty enqueued_jobs.select { |job| job["job_class"] == "ReceiptOcrJob" }, "nothing queues OCR"
    end

    test "a regrouped receipt that OCR picks up between the check and the lock is left alone, uploads deleted" do
      write_ingest([ ingest_line(1, colours: [ 1 ]) ])
      load_receipts
      receipt = loaded(1)
      write_ingest([ ingest_line(1, colours: [ 1, 2 ]) ])
      blobs = ActiveStorage::Blob.count

      calls = 0
      pristine = Receipt.instance_method(:pristine?)
      Receipt.define_method(:pristine?) { (calls += 1) == 1 ? pristine.bind_call(self) : false }
      begin
        report = load_receipts
      ensure
        Receipt.define_method(:pristine?, pristine)
      end

      assert_equal 1, report[:conflict]
      assert_equal blobs, ActiveStorage::Blob.count
      assert_equal 1, receipt.reload.images.count
    end

    test "a line that matches one receipt by id and another by photos is a conflict" do
      first = ingest_line(1)
      second = ingest_line(2)
      write_ingest([ first, second ])
      load_receipts
      before = loaded(1).attributes

      # Receipt 2 is worked on, so it stays; its photos now come with line 1.
      loaded(2).update!(status: :extracted)
      write_ingest([ first.merge("fingerprint" => second["fingerprint"], "images" => second["images"]), ingest_line(2, colours: [ 2, 9 ]) ])
      report = load_receipts

      assert_equal 2, report[:conflict]
      assert_match(/rcpt_000001: left alone, matches receipt \d+ by id and receipt \d+ by its photos/, @output.string)
      assert_equal before, loaded(1).attributes
    end

    test "a merge in the ingest set is taken in one run when the retired receipt is pristine" do
      first = ingest_line(1, colours: [ 1 ])
      second = ingest_line(2, colours: [ 2 ])
      write_ingest([ first, second ])
      load_receipts

      merged = ingest_line(1, colours: [ 1, 2 ])
      write_ingest([ merged ])
      report = load_receipts

      assert_equal({ retired_deleted: 1, regrouped: 1, conflict: 0 }, counts(report, :retired_deleted, :regrouped, :conflict))
      assert_equal merged["fingerprint"], loaded(1).sha256
      assert_not Receipt.exists?(ingest_id: ingest_id(2))
    end

    test "photos already loaded under another id are a conflict" do
      line = ingest_line(1)
      write_ingest([ line ])
      load_receipts
      loaded(1).update!(status: :extracted)

      write_ingest([ line.merge("receipt_id" => ingest_id(5)) ])
      report = load_receipts

      assert_equal({ conflict: 1, retired_kept: 1 }, counts(report, :conflict, :retired_kept))
      assert_includes @output.string, "rcpt_000005: left alone, its photos are already loaded as rcpt_000001"
      assert_not Receipt.exists?(ingest_id: ingest_id(5))
    end

    test "a loaded receipt that left the ingest set is deleted while pristine, otherwise kept and reported" do
      write_ingest([ ingest_line(1), ingest_line(2), ingest_line(3), ingest_line(4, colours: []) ])
      load_receipts
      loaded(2).update!(status: :extracted)
      app_receipt = Receipt.create!(images: [ image_upload(png_bytes(red: 200)) ])

      write_ingest([ ingest_line(4, colours: []) ]) # 4 stays in the file (skipped); 1, 2 and 3 left it
      report = load_receipts

      assert_equal({ retired_deleted: 2, retired_kept: 1 }, counts(report, :retired_deleted, :retired_kept))
      assert_not Receipt.exists?(ingest_id: [ ingest_id(1), ingest_id(3) ])
      assert Receipt.exists?(ingest_id: ingest_id(2))
      assert Receipt.exists?(app_receipt.id), "a receipt uploaded in the app is never retired"
      assert_match(/rcpt_000002: left the ingest set, kept because it is extracted/, @output.string)
    end

    test "a photo file missing from storage is uploaded again" do
      line = ingest_line(1, colours: [ 1, 2 ])
      write_ingest([ line ])
      load_receipts
      blob = loaded(1).images.first.blob
      blob.service.delete(blob.key)

      dry = load_receipts(dry_run: true)
      assert_equal 1, dry[:repaired]
      assert_not blob.service.exist?(blob.key), "a dry run uploads nothing"

      report = load_receipts

      assert_equal 1, report[:repaired]
      assert_equal file_bytes(line), photo_bytes(loaded(1))
    end

    test "a receipt the model refuses fails alone, leaves no upload behind, and the others load" do
      line = ingest_line(1)
      text = write_ingest_image("images/rcpt_000001_1.png", "not a photo at all\n")
      line["images"] = [ text ]
      line["fingerprint"] = text["sha256"]
      write_ingest([ line, ingest_line(2) ])
      blobs = ActiveStorage::Blob.count
      service = ActiveStorage::Blob.service
      upload = service.method(:upload)
      keys = []

      report = with_singleton_method(service, :upload, ->(key, io, **options) { keys << key; upload.call(key, io, **options) }) do
        load_receipts
      end

      assert report.failed?, @output.string
      assert_equal({ failed: 1, created: 1 }, counts(report, :failed, :created))
      assert_equal blobs + 1, ActiveStorage::Blob.count
      assert_equal [ false, true ], keys.map { |key| ActiveStorage::Blob.exists?(key:) }
      assert_equal [ false, true ], keys.map { |key| service.exist?(key) }, "the refused receipt's file is deleted"
      assert_includes @output.string, "rcpt_000001: failed, refused: images"
      assert_includes @output.string, "Done with failures"
    end

    test "a photo that changes after the check fails its receipt" do
      write_ingest([ ingest_line(1) ])
      dataset = Verifier.call(ingest_dir)
      File.binwrite(dataset.lines.first.images.first.path, png_bytes(red: 222))
      blobs = ActiveStorage::Blob.count

      error = assert_raises(Writer::FileChanged) { Writer.new(report: Report.new).call(dataset.lines.first) }

      assert_equal "image 1 changed after it was checked", error.message
      assert_equal blobs, ActiveStorage::Blob.count
    end

    test "a failed upload leaves no blob row and no file behind" do
      write_ingest([ ingest_line(1, colours: [ 1, 2, 3 ]) ])
      blobs = ActiveStorage::Blob.count
      service = ActiveStorage::Blob.service
      upload = service.method(:upload)
      keys = []
      calls = 0
      failing = lambda do |key, io, **options|
        calls += 1
        keys << key
        upload.call(key, io, **options)
        raise Errno::ENOSPC if calls == 2
      end

      report = with_singleton_method(service, :upload, failing) { load_receipts }

      assert_equal 1, report[:failed]
      assert_includes @output.string, "rcpt_000001: failed, Errno::ENOSPC"
      assert_equal blobs, ActiveStorage::Blob.count
      assert_equal 2, calls
      assert keys.none? { |key| service.exist?(key) }, "the uploaded files are deleted"
      assert_not Receipt.exists?(ingest_id: ingest_id(1))
    end

    test "a receipt that another load moved between the match and the lock is left alone" do
      line = ingest_line(1)
      write_ingest([ line ])
      load_receipts
      stale = loaded(1)
      other = Digest::SHA256.hexdigest("regrouped elsewhere")
      stale.class.where(id: stale.id).update_all(sha256: other, qr_total: nil)

      writer = Writer.new(report: report = Report.new)
      with_singleton_method(Receipt, :find_by, ->(conditions) { conditions.key?(:ingest_id) ? stale : nil }) do
        writer.call(Verifier.call(ingest_dir).lines.first.with(qr: Verifier::NO_QR.merge(qr_total: BigDecimal("9.99"))))
      end

      assert_equal 1, report[:conflict]
      assert_match(/rcpt_000001: left alone, receipt \d+ changed while it was being loaded/, report.warnings.join)
      assert_equal [ other, nil ], Receipt.where(id: stale.id).pick(:sha256, :qr_total)
    end

    test "the output holds counts and ids, never a QR value, a raw photo name, a total or a date" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields), ingest_line(2, qr_fields: ingest_qr_fields, flags: [ "qr_conflict" ]) ])

      load_receipts

      [ "cabinet", "123.40", "2026", "4000000009", "900001", "IMG_", ".png" ].each do |secret|
        assert_not_includes @output.string, secret
      end
      assert_includes @output.string, "Receipts: 2 created"
    end

    test "the SQL log is silenced while the load runs, so no QR value reaches the log file" do
      write_ingest([ ingest_line(1, qr_fields: ingest_qr_fields) ])
      log = StringIO.new
      logger = ActiveSupport::Logger.new(log, level: :debug)
      original = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = logger
      begin
        load_receipts
        Receipt.where(qr_receipt_number: "900001").to_a
      ensure
        ActiveRecord::Base.logger = original
      end

      assert_includes log.string, "SELECT", "the logger works outside the load"
      [ "cabinet", "4000000009", "123.4", "2026-09-14" ].each { |secret| assert_not_includes log.string.sub(/.*900001.*/, ""), secret }
      assert_equal 1, log.string.scan("900001").size, "only the query made after the load is logged"
    end

    test "an unexpected error is reported by class and place only" do
      write_ingest([ ingest_line(1) ])

      error = with_singleton_method(Writer, :new, ->(**) { raise KeyError, "secret 123.40" }) do
        assert_raises(Error) { load_receipts }
      end

      assert_match(/unexpected KeyError/, error.message)
      assert_not_includes error.message, "123.40"
      assert_includes error.message, "Receipts loaded before the stop are kept"
    end

    test "a real run stops before writing when Redis is not reachable" do
      write_ingest([ ingest_line(1) ])
      sidekiq = ActiveJob::QueueAdapters::SidekiqAdapter.new

      error = with_singleton_method(ActiveJob::Base, :queue_adapter, -> { sidekiq }) do
        with_singleton_method(Sidekiq, :redis, ->(*) { raise RedisClient::CannotConnectError, "refused" }) do
          assert_raises(Error) { load_receipts }
        end
      end

      assert_match "Redis is not reachable", error.message
      assert_not Receipt.exists?(ingest_id: ingest_id(1))
    end

    test "the rake task loads, supports a dry run and exits non-zero on failure" do
      Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "receipts:load" }
      task = Rake::Task["receipts:load"]
      arguments = ->(dir) { Rake::TaskArguments.new([ :dir ], [ dir ]) }
      write_ingest([ ingest_line(1) ])

      ENV["DRY_RUN"] = "1"
      stdout, = capture_io { task.execute(arguments.call(ingest_dir)) }
      assert_includes stdout, "Dry run"
      assert_not Receipt.exists?(ingest_id: ingest_id(1))

      ENV.delete("DRY_RUN")
      stdout, = capture_io { task.execute(arguments.call(ingest_dir)) }
      assert_includes stdout, "Done: every receipt was committed."
      assert Receipt.exists?(ingest_id: ingest_id(1))

      write_ingest([ "{broken" ])
      _stdout, stderr = capture_io do
        assert_raises(SystemExit) { task.execute(arguments.call(ingest_dir)) }
      end
      assert_includes stderr, "line 1: not valid JSON"

      line = ingest_line(2)
      text = write_ingest_image("images/rcpt_000002_1.png", "not a photo\n")
      write_ingest([ line.merge("images" => [ text ], "fingerprint" => text["sha256"]) ])
      capture_io do
        exit_error = assert_raises(SystemExit) { task.execute(arguments.call(ingest_dir)) }
        assert_equal 1, exit_error.status
      end

      assert_raises(SystemExit) { capture_io { task.execute(arguments.call("")) } }
    ensure
      ENV.delete("DRY_RUN")
    end
  end
end
