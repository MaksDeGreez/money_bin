module ReceiptLoad
  # Writes one verified line of receipts.jsonl as a Receipt, and removes loaded receipts that left the
  # ingest set. Each receipt is its own database transaction (a savepoint inside a dry run). The outcome is
  # counted in the report; an exception is left to the caller, which counts the receipt as failed.
  #
  # Finding the receipt of a line: by `ingest_id` first, then by `sha256` (the line's fingerprint).
  #
  # - none: a new receipt (`uploaded`) with the images in part order, the ingest fields and `sha256` = the
  #   fingerprint;
  # - found with the same `sha256`: only the ingest fields (`ingest_id` when blank, `batch`, `qr_payload`,
  #   the `qr_*` columns) are written, and only when they differ. OCR fields, `kind`, `incomplete`, items,
  #   status and the transaction are never touched. A photo whose file is missing from storage is uploaded
  #   again;
  # - found by `ingest_id` with another `sha256` (the ingest tool regrouped its photos): the photos and the
  #   `sha256` are replaced, under a row lock, only while the receipt is pristine (Receipt#pristine?);
  #   otherwise it is a conflict and left alone;
  # - a line that matches two different receipts (one by id, another by fingerprint), or whose photos
  #   belong to a receipt with another `ingest_id`: a conflict, left alone.
  #
  # Photo files are uploaded before the database transaction that attaches them, so a committed receipt
  # always has its files; uploads of a receipt that is then not written are deleted again. A dry run uploads
  # nothing: it creates blob rows only, and the caller rolls them back.
  class Writer
    # A loaded photo whose bytes changed between the check and the upload.
    class FileChanged < StandardError; end

    def initialize(report:, dry_run: false)
      @report = report
      @dry_run = dry_run
    end

    def call(line)
      by_id = Receipt.find_by(ingest_id: line.ingest_id)
      by_sha = Receipt.find_by(sha256: line.fingerprint)

      if by_id && by_sha && by_id != by_sha
        conflict(line, "matches receipt #{by_id.id} by id and receipt #{by_sha.id} by its photos")
      elsif by_id
        by_id.sha256 == line.fingerprint ? update(by_id, line) : regroup(by_id, line)
      elsif by_sha&.ingest_id.present?
        conflict(line, "its photos are already loaded as #{by_sha.ingest_id} (receipt #{by_sha.id})")
      elsif by_sha
        update(by_sha, line)
      else
        create(line)
      end
    end

    # Loaded receipts whose `ingest_id` is not in `ingest_ids` (merged, excluded or regrouped by the ingest
    # tool): deleted while pristine, otherwise kept with a warning. Yields each receipt and its outcome.
    def retire(ingest_ids)
      Receipt.where.not(ingest_id: nil).where.not(ingest_id: ingest_ids).order(:ingest_id).each do |receipt|
        batch = receipt.batch
        outcome = transaction do
          receipt.with_lock do
            next :retired_kept unless receipt.pristine?

            receipt.destroy!
            :retired_deleted
          end
        end
        @report.warn("#{receipt.ingest_id}: left the ingest set, kept because it is #{receipt.status} or has items or a transaction (receipt #{receipt.id})") if outcome == :retired_kept
        @report.count(batch, outcome)
      end
    end

    private
      def create(line)
        with_uploads(line) do |blobs|
          transaction { Receipt.create!(images: blobs, sha256: line.fingerprint, **ingest_attributes(line)) }
        end
        @report.count(line.batch, :created)
      end

      def update(receipt, line)
        changed = transaction do
          receipt.with_lock do
            # The match was made before the lock: another load may have regrouped the receipt since.
            next :moved unless same_receipt?(receipt, line)

            attributes = ingest_attributes(line)
            attributes.delete(:ingest_id) if receipt.ingest_id.present?
            receipt.assign_attributes(attributes)
            receipt.changed?.tap { |changes| receipt.save! if changes }
          end
        end
        return conflict(line, "receipt #{receipt.id} changed while it was being loaded") if changed == :moved

        repaired = repair_files(receipt, line)
        @report.count(line.batch, changed ? :updated : (repaired ? :repaired : :unchanged))
      end

      def same_receipt?(receipt, line)
        receipt.sha256 == line.fingerprint && [ nil, line.ingest_id ].include?(receipt.ingest_id)
      end

      def regroup(receipt, line)
        busy = "its photos changed, but receipt #{receipt.id} is #{receipt.status} or has items or a transaction"
        return conflict(line, busy) unless receipt.pristine?

        written = with_uploads(line) do |blobs|
          transaction do
            receipt.with_lock do
              # Checked again under the lock: OCR or another load may have got to it since.
              next false unless receipt.pristine? && receipt.ingest_id == line.ingest_id

              receipt.images = blobs
              receipt.assign_attributes(sha256: line.fingerprint, **ingest_attributes(line))
              receipt.save!
            end
          end
        end
        written ? @report.count(line.batch, :regrouped) : conflict(line, busy)
      end

      # Uploads a missing photo file again (nothing in a dry run). True when a file was missing.
      def repair_files(receipt, line)
        missing = receipt.images_attachments.includes(:blob).map(&:blob).reject { |blob| blob.service.exist?(blob.key) }
        missing.each do |blob|
          image = line.images.find { |candidate| candidate.checksum == blob.checksum }
          raise FileChanged, "no image of the line has the bytes of a stored photo" unless image
          next if @dry_run

          upload(blob, image)
        end
        missing.any?
      end

      # Yields the line's images as blobs, uploaded first (rows only in a dry run), and returns what the
      # block returns. Each blob row is kept for clean-up before its file is uploaded, so when an upload
      # fails, the block raises or the block returns false, every row and file made here is deleted again.
      def with_uploads(line)
        blobs = []
        kept = false
        line.images.each do |image|
          blobs << blob_row(image)
          upload(blobs.last, image) unless @dry_run
        end
        kept = yield(blobs)
      ensure
        purge(blobs) unless kept
      end

      # The blob row with the size, checksum and content type from the check. Marked identified, as an
      # upload with a known content type would be, so attaching it never reads the file.
      def blob_row(image)
        ActiveStorage::Blob.create!(filename: image.filename, byte_size: image.byte_size, checksum: image.checksum,
          content_type: image.content_type, metadata: { identified: true })
      end

      # The storage service compares the stored bytes with the blob's checksum and deletes the file when
      # they differ, so a photo that changed after the check is never stored.
      def upload(blob, image)
        File.open(image.path, "rb") { |io| blob.upload_without_unfurling(io) }
      rescue ActiveStorage::IntegrityError
        raise FileChanged, "image #{image.part} changed after it was checked"
      end

      def purge(blobs)
        return if @dry_run

        blobs.each { |blob| blob.purge if blob.persisted? }
      end

      def conflict(line, reason)
        @report.warn("#{line.ingest_id}: left alone, #{reason}")
        @report.count(line.batch, :conflict)
      end

      def ingest_attributes(line)
        { ingest_id: line.ingest_id, batch: line.batch, qr_payload: line.qr_payload, **line.qr }
      end

      def transaction(&)
        Receipt.transaction(requires_new: true, &)
      end
  end
end
