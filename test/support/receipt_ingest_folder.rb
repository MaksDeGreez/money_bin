require "tmpdir"
require_relative "receipt_images"

# A synthetic receipt ingest folder (tools/receipt_ingest/README.md, "receipts.jsonl"), built in a temporary
# folder for each test: generated 1x1 PNG photos and a receipts.jsonl that describes them. The repository
# holds no image file and no real receipt.
#
#   line = ingest_line(1, colours: [ 10, 11 ], qr_fields: ingest_qr_fields)
#   write_ingest([ line ])
#   ReceiptLoad::Runner.call(ingest_dir, output: StringIO.new)
module ReceiptIngestFolder
  INVENTED_TAX_URL = "https://cabinet.tax.gov.ua/cashregs/check?id=900001&fn=4000000009&sm=123.40&date=20260914&time=1020"

  def self.included(base)
    base.include ReceiptImages
    base.teardown { FileUtils.remove_entry(@ingest_dir) if @ingest_dir && File.directory?(@ingest_dir) }
  end

  def ingest_dir
    @ingest_dir ||= Dir.mktmpdir("receipt-ingest-test")
  end

  def ingest_id(number)
    format("rcpt_%06d", number)
  end

  # Writes one photo per colour as images/<id>_<part>.png and returns the line's Hash. Each colour is a red
  # value, so different colours give different photos.
  def ingest_line(number, colours: [ number ], batch: "batch_01", qr_fields: nil, qr_payload: nil, flags: [])
    id = ingest_id(number)
    images = colours.each_with_index.map do |red, index|
      write_ingest_image("images/#{id}_#{index + 1}.png", png_bytes(red:, green: 7, blue: 3))
    end
    digests = images.map { |image| image["sha256"] }
    {
      "receipt_id" => id, "batch" => batch, "seq_in_batch" => number, "raw_files" => colours.map { |red| "#{batch}/IMG_#{red}.HEIC" },
      "captured_at" => "2026-09-14T10:20:00.000+03:00", "images" => images,
      "fingerprint" => digests.one? ? digests.first : Digest::SHA256.hexdigest(digests.sort.join),
      "qr_payload" => qr_payload || (qr_fields ? INVENTED_TAX_URL : nil), "qr" => nil, "qr_fields" => qr_fields,
      "flags" => flags.presence || (qr_fields || qr_payload ? [] : [ "no_qr" ])
    }
  end

  def ingest_qr_fields(**overrides)
    { "issued_at" => "2026-09-14T10:20:00+03:00", "total" => "123.40", "fiscal_number" => "4000000009",
      "receipt_number" => "900001" }.merge(overrides.stringify_keys)
  end

  def write_ingest_image(file, bytes)
    path = File.join(ingest_dir, file)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    { "file" => file, "sha256" => Digest::SHA256.hexdigest(bytes), "width" => 1, "height" => 1, "bytes" => bytes.bytesize }
  end

  # `lines` are Hashes (written as JSON) or Strings (written as they are).
  def write_ingest(lines)
    text = lines.map { |line| line.is_a?(String) ? line : JSON.generate(line) }.join("\n")
    File.write(File.join(ingest_dir, "receipts.jsonl"), text + "\n")
  end
end
