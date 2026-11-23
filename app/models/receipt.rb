# A shop receipt: one to three photos of it, what the OCR service read from them, and its items.
#
# Life cycle (`status`): uploaded -> processing -> extracted -> reviewed, or failed when OCR gives up.
# `extracted` means the items are filled in and wait for a person; `reviewed` means the receipt was accepted
# into the ledger (Receipts::Accept), which links it to its transaction (`ledger_transaction`).
#
# ReceiptOcrJob and Receipts::ApplyOcr fill the OCR part (docs/domain.md, "OCR"). `ocr_raw` keeps the OCR
# service's full answer, or { "error" => { "code", "message" } } after a failure. `ocr_model_name`,
# `ocr_model_version` and `ocr_prompt_version` say which model and prompt produced the fields and items (they
# stay when "Enter by hand" keeps the items of an earlier read). They are not called `model_name`: every Active Record class and record already has a
# `model_name` method (ActiveModel::Naming), which would hide the column's value.
#
# What filled the review form, for ground truth (ReceiptGroundTruth::Prefill): `filled_from` is `dps_xml` once a
# person filled the fields and items from the receipt's tax-service record; `categoriser_model_name` names the
# categoriser whose suggestions the items (and a slip) carry. Whatever fills the suggestions sets it (nothing
# does yet). A new OCR result clears both: it replaces the fields and items.
#
# `currency` is what the OCR read from the receipt (nil when unknown). `batch` is a free label for a bulk
# upload ("october-shopping").
#
# `kind` says what the paper is: `fiscal` (a cash register receipt) or `card_slip` (a card terminal slip);
# nil until OCR reads it, and a person corrects it at review. `incomplete` marks a torn or cut-off receipt
# whose total or date cannot be read. `card_last4` is the card's last four digits on a slip.
#
# A card slip has no items: it is booked as one line, its `total` in its own `category`, which a person
# chooses at review (Receipts::Accept). `suggested_category` and `suggested_category_confidence` are the guess for
# a slip, from its payee's history or the transaction categoriser (Receipts::SuggestSlipCategory). Both must be
# categories, not groups.
#
# Review (docs/domain.md, "Review"): a person corrects the receipt and its items in the review form
# (Receipts::Review), which writes the items as nested attributes. `lock_version` turns on Active Record's
# optimistic locking: the form carries it, so a save from a page rendered before OCR read the receipt again
# or another tab saved it is refused. Every writer of the reviewable data writes the receipt row, so the
# version moves: Receipts::ApplyOcr, Receipts::Review, Receipts::EnterByHand, Receipts::Accept, and the
# unlink when its transaction is destroyed. Rails' `update_all` moves it too (Receipts::RequestOcr's claim),
# and attaching photos touches the row; `update_columns` (the OCR job's status changes) does not.
#
# QR ground truth: `qr_issued_at`, `qr_total`, `qr_fiscal_number` and `qr_receipt_number` are what the
# tax-service QR code on a fiscal receipt says. They are kept apart from the OCR columns of the same names
# (without `qr_`), which they are compared with, and only the receipt load writes them (ReceiptLoad); OCR
# never does. `qr_payload` is the QR text itself. `ingest_id` is the stable number the receipt ingest tool
# gave the receipt (`rcpt_000123`); nil for a receipt uploaded in the app.
#
# `sha256` is the fingerprint of the uploaded image bytes; it refuses the same photo twice.
# - one image: the SHA-256 of its bytes, as 64 lower-case hex characters;
# - several images: the SHA-256 of the per-image hex digests, sorted and joined together (no separator).
#   Sorting makes it independent of the upload order. A digest always has 64 characters, so the joined
#   text is unambiguous.
# Receipt.fingerprint computes it from uploaded files, IO objects or blobs. It is set automatically when
# images are attached and it is blank, and it identifies the original upload. Only the receipt load changes
# it, and only on a pristine receipt whose photos the ingest tool regrouped (ReceiptLoad::Writer).
#
# Photos can be attached as files, IO hashes, blobs, or signed blob ids (Strings), which Rails sends when
# the files were uploaded ahead of the form (direct upload). A signed id that is invalid or expired is a
# validation error on `images`, not an exception. The same photo cannot be attached twice to one receipt.
#
# The link to a transaction is named `ledger_transaction` because an association cannot be called
# `transaction` (see Transaction).
class Receipt < ApplicationRecord
  MAX_IMAGES = 3
  # The largest photo, in bytes: the ML service's default ML_MAX_IMAGE_BYTES (15 MB). Refusing it here
  # keeps an oversized photo from being stored only to fail later in the OCR job.
  MAX_IMAGE_BYTES = 15 * 1024 * 1024
  # Photo formats a phone or a scanner produces. SVG is left out on purpose: it is not a photo and can
  # carry scripts.
  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  INGEST_ID_FORMAT = /\Arcpt_[0-9]{6,}\z/
  CARD_LAST4_FORMAT = /\A[0-9]{4}\z/
  QR_FIELDS = %i[qr_issued_at qr_total qr_fiscal_number qr_receipt_number].freeze
  CHUNK_SIZE = 64.kilobytes
  # A request for OCR older than this counts as lost (the queue was emptied) and may be made again.
  OCR_REQUEST_LOST_AFTER = 24.hours
  # A receipt `processing` for longer than this counts as stuck (Sidekiq killed mid-job lost the job): "Read
  # again" is offered. One read takes minutes at most, retries included.
  OCR_STUCK_AFTER = 1.hour
  # The statuses a person reviews in the form: read and waiting (`extracted`), or accepted and changed again
  # (`reviewed`, booked once more by "Accept again").
  REVIEWABLE_STATUSES = %w[extracted reviewed].freeze

  enum :status, { uploaded: "uploaded", processing: "processing", extracted: "extracted", reviewed: "reviewed", failed: "failed" },
    validate: true
  enum :kind, { fiscal: "fiscal", card_slip: "card_slip" }, validate: { allow_nil: true }

  # Index filters. A receipt "with a tax QR" has at least one QR ground-truth value.
  scope :kind_unknown, -> { where(kind: nil) }
  scope :with_tax_qr, -> { where(QR_FIELDS.map { |field| arel_table[field].not_eq(nil) }.reduce(:or)) }
  scope :without_tax_qr, -> { where(QR_FIELDS.index_with(nil)) }
  scope :incomplete_only, -> { where(incomplete: true) }
  scope :in_batch, ->(batch) { where(batch:) }
  # Receipts with (or without) a ground-truth record of `source` (any source when nil); `checked:` true or
  # false narrows to records a person checked or did not.
  scope :with_ground_truth, ->(source = nil, checked: nil) { where(ground_truth_exists(source, checked:).exists) }
  scope :without_ground_truth, ->(source = nil) { where.not(ground_truth_exists(source).exists) }
  # Newest first: receipts uploaded in the app (no ingest number) by upload time, then loaded ones by
  # ingest number, highest first. The number is compared by length first: `rcpt_1000000` follows
  # `rcpt_999999`, which a plain text order would get wrong.
  scope :newest_first, -> {
    order(Arel.sql("length(receipts.ingest_id) DESC NULLS FIRST, receipts.ingest_id DESC NULLS FIRST"))
      .order(created_at: :desc, id: :desc)
  }

  belongs_to :ledger_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true, inverse_of: :receipt
  has_many :items, -> { order(:position) }, class_name: "ReceiptItem", inverse_of: :receipt, dependent: :destroy
  # What the receipt really says, per source (ReceiptGroundTruth). Only the ground-truth writers change it.
  has_many :ground_truths, class_name: "ReceiptGroundTruth", inverse_of: :receipt, dependent: :delete_all
  # How Receipts::Accept booked it (a transaction it created, or one the person linked), for an undo. The
  # database cascades it with the receipt and with the transaction.
  has_one :booking, class_name: "ReceiptBooking", inverse_of: :receipt
  belongs_to :category, optional: true
  belongs_to :suggested_category, class_name: "Category", optional: true
  # The open OCR batch the receipt waits in (docs/domain.md, "OCR in a batch"), and every batch it was ever in.
  belongs_to :ocr_batch, optional: true, inverse_of: :held_receipts
  has_many :ocr_batch_entries, inverse_of: :receipt, dependent: :nullify
  accepts_nested_attributes_for :items, allow_destroy: true
  # Resized copies for the pages, made once by Active Storage and kept (active_storage_variant_records).
  # Always JPEG, so a HEIC photo shows in every browser; metadata stripped. Served by
  # Receipts::PhotosController, never through Rails' own Active Storage routes (they are not drawn).
  has_many_attached :images do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 240, 240 ], format: :jpeg, saver: { quality: 80, strip: true }
    attachable.variant :page, resize_to_limit: [ 1600, 1600 ], format: :jpeg, saver: { quality: 85, strip: true }
    attachable.variant :full, format: :jpeg, saver: { quality: 90, strip: true }
  end

  normalizes :currency, with: ->(value) { value.strip.upcase.presence }
  normalizes :batch, with: ->(value) { value.strip.presence }

  before_validation :set_fingerprint, if: -> { sha256.blank? }

  validates :sha256, presence: true, format: { with: SHA256_FORMAT, allow_blank: true },
    uniqueness: { message: "matches a receipt that was already uploaded" }
  validates :currency, format: { with: Account::CURRENCY_FORMAT, message: "must be three letters (ISO 4217)" }, allow_nil: true
  validates :total, numericality: { greater_than: -Transaction::AMOUNT_LIMIT, less_than: Transaction::AMOUNT_LIMIT }, allow_nil: true
  validates :total, decimal_places: { maximum: Transaction::MONEY_DECIMAL_PLACES }
  validates :qr_total, numericality: { greater_than: -Transaction::AMOUNT_LIMIT, less_than: Transaction::AMOUNT_LIMIT }, allow_nil: true
  validates :qr_total, decimal_places: { maximum: Transaction::MONEY_DECIMAL_PLACES }
  validates :incomplete, inclusion: { in: [ true, false ] }
  validates :filled_from, inclusion: { in: %w[dps_xml], message: "must be dps_xml or empty" }, allow_nil: true
  validates :card_last4, format: { with: CARD_LAST4_FORMAT, message: "must be four digits" }, allow_nil: true
  validates :ingest_id, format: { with: INGEST_ID_FORMAT, message: "must be rcpt_ and at least six digits" },
    uniqueness: true, allow_nil: true
  validates :transaction_id, uniqueness: { message: "already has a receipt" }, allow_nil: true
  validate :ledger_transaction_exists, if: -> { transaction_id.present? && will_save_change_to_transaction_id? }
  validate :images_are_photos
  validates :suggested_category_confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate { category_is_a_leaf(:category) if category_id.present? && will_save_change_to_category_id? }
  validate do
    category_is_a_leaf(:suggested_category) if suggested_category_id.present? && will_save_change_to_suggested_category_id?
  end

  # The fingerprint of `sources`, in any order. Each source is an uploaded file
  # (ActionDispatch::Http::UploadedFile, Rack::Test::UploadedFile), an IO-like object (File, StringIO), an
  # Active Storage attachable hash ({ io:, filename: }) or an ActiveStorage::Blob. IO objects are rewound
  # after reading, so they can still be attached.
  def self.fingerprint(sources)
    digests = Array.wrap(sources).map { |source| image_digest(source) }
    raise ArgumentError, "a fingerprint needs at least one image" if digests.empty?

    digests.one? ? digests.first : Digest::SHA256.hexdigest(digests.sort.join)
  end

  # The SHA-256 hex digest of one image's bytes.
  def self.image_digest(source)
    digest = Digest::SHA256.new
    case source
    when ActiveStorage::Blob
      source.download { |chunk| digest << chunk }
    when Hash
      read_io(source[:io] || source["io"], digest)
    else
      read_io(source, digest)
    end
    digest.hexdigest
  end

  def self.read_io(io, digest)
    raise ArgumentError, "cannot read image bytes from #{io.class}" unless io.respond_to?(:read)

    io.rewind if io.respond_to?(:rewind)
    while (chunk = io.read(CHUNK_SIZE))
      digest << chunk
    end
    io.rewind if io.respond_to?(:rewind)
  end
  private_class_method :read_io

  # Resolves signed blob ids before Active Storage sees them: Rails would raise on an invalid one, and the
  # fingerprint needs the blob, not the id. Blank strings (an empty file field) are dropped, as Rails does.
  def images=(attachables)
    @invalid_image_ids = 0
    resolved = Array.wrap(attachables).flatten.compact_blank.filter_map do |attachable|
      next attachable unless attachable.is_a?(String)

      ActiveStorage::Blob.find_signed(attachable).tap { |blob| @invalid_image_ids += 1 if blob.nil? }
    end
    super(resolved)
  end

  # The ground-truth records of the receipt in the outer query (for EXISTS), as Arel.
  def self.ground_truth_exists(source, checked: nil)
    records = ReceiptGroundTruth.where(ReceiptGroundTruth.arel_table[:receipt_id].eq(arel_table[:id]))
    records = records.where(source:) if source
    records = checked ? records.checked : records.unchecked unless checked.nil?
    records.select(1).arel
  end
  # True when the tax-service QR code gave at least one ground-truth value.
  def tax_qr?
    QR_FIELDS.any? { |field| !self[field].nil? }
  end

  # The photos in upload order (the order the OCR job sends them in).
  def ordered_images
    images.attachments.sort_by(&:id)
  end

  # A request for OCR was recorded (Receipts::RequestOcr) and no job has started on it yet; the job clears
  # it when it starts. A waiting one (ocr_request_waiting?) also lets the job read a `failed` or `extracted`
  # receipt again.
  def ocr_pending?
    ocr_requested_at.present?
  end

  # A request is waiting and is not old enough to count as lost.
  def ocr_request_waiting?
    ocr_pending? && ocr_requested_at > OCR_REQUEST_LOST_AFTER.ago
  end

  # Being read for longer than a read takes: the job may have been lost (or a retry waits behind a long queue).
  def ocr_stuck?
    processing? && updated_at < OCR_STUCK_AFTER.ago
  end

  # OCR is queued or running: its result is about to replace the receipt's fields and items, so nobody edits it.
  def ocr_in_flight?
    processing? || ocr_request_waiting?
  end

  # A person may correct it in the review form now: it was read (or started by hand) or accepted, and no OCR
  # is queued or running.
  def reviewable?
    REVIEWABLE_STATUSES.include?(status) && !ocr_in_flight?
  end

  # What accepting books, as a BigDecimal: the total of a card slip (one line), the items' sum otherwise. nil
  # for a slip without a total.
  def booking_total
    card_slip? ? total : items_total
  end

  # The items in memory that the next save keeps (the review form marks removed rows for destruction).
  def kept_items
    items.reject(&:marked_for_destruction?)
  end

  # A person started the receipt by hand (Receipts::EnterByHand) instead of an OCR read.
  def entered_by_hand?
    ocr_raw.is_a?(Hash) && ocr_raw.key?("entered_by_hand")
  end

  # The reason of the last OCR failure, { "code" => ..., "message" => ... }, or nil.
  def ocr_error
    error = ocr_raw["error"] if ocr_raw.is_a?(Hash)
    error if error.is_a?(Hash)
  end

  # Nothing has happened to the receipt since it was stored: no OCR result, no items, no transaction, no
  # ground truth, and it is not waiting in an OCR batch (its photos are at the provider). Only such a receipt may
  # be changed or removed by the receipt load.
  def pristine?
    uploaded? && ocr_batch_id.nil? && transaction_id.nil? && !items.exists? && !ground_truths.exists?
  end

  # Waiting in an OCR batch (Receipt#ocr_batch): no read one at a time is queued for it meanwhile.
  def in_ocr_batch?
    ocr_batch_id.present?
  end

  # The sum of the item amounts, as a BigDecimal (items the review form marked for removal left out).
  def items_total
    kept_items.sum(BigDecimal("0")) { |item| item.amount || 0 }
  end

  # The printed total minus the items' sum, as a BigDecimal: positive when items are missing (OCR skipped an
  # unreadable line), negative when there are too many. nil when the total is unknown.
  def total_difference
    total - items_total if total
  end

  # False when the total is known and the items do not sum to it.
  def items_match_total?
    total_difference.nil? || total_difference.zero?
  end

  private
    # Only new attachments are fingerprinted: they are still in memory as the caller's files or IO objects.
    def set_fingerprint
      change = attachment_changes["images"]
      self.sha256 = self.class.fingerprint(change.attachables) if change && Array.wrap(change.attachables).any?
    end

    def ledger_transaction_exists
      errors.add(:ledger_transaction, "does not exist") if ledger_transaction.nil?
    end

    def category_is_a_leaf(name)
      category = public_send(name)
      if category.nil?
        errors.add(name, "does not exist")
      elsif category.group?
        errors.add(name, "must be a category, not a group")
      end
    end

    def images_are_photos
      attachments = images.attachments.to_a
      unless attachments.size.between?(1, MAX_IMAGES)
        errors.add(:images, "must be between 1 and #{MAX_IMAGES} photos (got #{attachments.size})")
      end

      if @invalid_image_ids.to_i.positive?
        errors.add(:images, "include #{@invalid_image_ids} upload id(s) that are not valid or have expired; upload the photo again")
      end

      checksums = attachments.filter_map { |attachment| attachment.blob.checksum }
      errors.add(:images, "must be different photos: the same photo is attached twice") if checksums.uniq.size < checksums.size

      attachments.each do |attachment|
        blob = attachment.blob
        if blob.byte_size.to_i > MAX_IMAGE_BYTES
          errors.add(:images, "must be at most #{MAX_IMAGE_BYTES / 1.megabyte} MB (#{MAX_IMAGE_BYTES} bytes) each; " \
            "#{blob.filename} has #{blob.byte_size} bytes")
        end
        next if IMAGE_CONTENT_TYPES.include?(blob.content_type)

        errors.add(:images, "must be photos (JPEG, PNG, WebP or HEIC); #{blob.filename} is #{blob.content_type.presence || 'unknown'}")
      end
    end
end
