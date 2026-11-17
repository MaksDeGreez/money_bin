# A shop receipt: one to three photos of it, what the OCR service read from them, and its items.
#
# Life cycle (`status`): uploaded -> processing -> extracted -> reviewed, or failed when OCR gives up.
# `extracted` means the items are filled in and wait for a person; `reviewed` means the receipt was accepted
# into the ledger (Receipts::Accept), which links it to its transaction (`ledger_transaction`).
#
# ReceiptOcrJob and Receipts::ApplyOcr fill the OCR part (docs/domain.md, "OCR"). `ocr_raw` keeps the OCR
# service's full answer, or { "error" => { "code", "message" } } after a failure. `ocr_model_name` and `ocr_model_version` say which model
# produced it. They are not called `model_name`: every Active Record class and record already has a
# `model_name` method (ActiveModel::Naming), which would hide the column's value.
#
# `currency` is what the OCR read from the receipt (nil when unknown). `batch` is a free label for a bulk
# upload ("october-shopping").
#
# `sha256` is the fingerprint of the uploaded image bytes; it refuses the same photo twice.
# - one image: the SHA-256 of its bytes, as 64 lower-case hex characters;
# - several images: the SHA-256 of the per-image hex digests, sorted and joined together (no separator).
#   Sorting makes it independent of the upload order. A digest always has 64 characters, so the joined
#   text is unambiguous.
# Receipt.fingerprint computes it from uploaded files, IO objects or blobs. It is set automatically when
# images are attached and it is blank, and it is never recomputed: it identifies the original upload.
#
# Photos can be attached as files, IO hashes, blobs, or signed blob ids (Strings), which Rails sends when
# the files were uploaded ahead of the form (direct upload). A signed id that is invalid or expired is a
# validation error on `images`, not an exception. The same photo cannot be attached twice to one receipt.
#
# The link to a transaction is named `ledger_transaction` because an association cannot be called
# `transaction` (see Transaction).
class Receipt < ApplicationRecord
  MAX_IMAGES = 3
  # Photo formats a phone or a scanner produces. SVG is left out on purpose: it is not a photo and can
  # carry scripts.
  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  CHUNK_SIZE = 64.kilobytes

  enum :status, { uploaded: "uploaded", processing: "processing", extracted: "extracted", reviewed: "reviewed", failed: "failed" },
    validate: true

  belongs_to :ledger_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true, inverse_of: :receipt
  has_many :items, -> { order(:position) }, class_name: "ReceiptItem", inverse_of: :receipt, dependent: :destroy
  has_many_attached :images

  normalizes :currency, with: ->(value) { value.strip.upcase.presence }
  normalizes :batch, with: ->(value) { value.strip.presence }

  before_validation :set_fingerprint, if: -> { sha256.blank? }

  validates :sha256, presence: true, format: { with: SHA256_FORMAT, allow_blank: true },
    uniqueness: { message: "matches a receipt that was already uploaded" }
  validates :currency, format: { with: Account::CURRENCY_FORMAT, message: "must be three letters (ISO 4217)" }, allow_nil: true
  validates :total, numericality: { greater_than: -Transaction::AMOUNT_LIMIT, less_than: Transaction::AMOUNT_LIMIT }, allow_nil: true
  validates :total, decimal_places: { maximum: Transaction::MONEY_DECIMAL_PLACES }
  validates :transaction_id, uniqueness: { message: "already has a receipt" }, allow_nil: true
  validate :ledger_transaction_exists, if: -> { transaction_id.present? && will_save_change_to_transaction_id? }
  validate :images_are_photos

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

  # The sum of the item amounts, as a BigDecimal.
  def items_total
    items.sum(BigDecimal("0")) { |item| item.amount || 0 }
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
        content_type = attachment.blob.content_type
        next if IMAGE_CONTENT_TYPES.include?(content_type)

        errors.add(:images, "must be photos (JPEG, PNG, WebP or HEIC); #{attachment.blob.filename} is #{content_type.presence || 'unknown'}")
      end
    end
end
