module Receipts
  # Serves a receipt's photos to the signed-in owner (docs/domain.md, "How photos are served").
  #
  #   GET /receipts/:receipt_id/photos/:id/:size   (receipt_photo_path(receipt, attachment, :thumb))
  #
  # `:id` is the photo's attachment, looked up among this receipt's photos only, so a photo of another
  # receipt (or any other attachment or blob) is a 404. Sizes:
  # - `thumb` (the list) and `page` (the receipt page): resized JPEG copies (Receipt's named variants),
  #   made on the first request and kept, so later requests only read a file;
  # - `full`: the photo as uploaded when it is a JPEG, PNG or WebP; any other photo (HEIC) as a full-size
  #   JPEG copy, so it opens in every browser.
  #
  # Rails' own Active Storage routes are not drawn: they skip sign-in. Without a session this answers as
  # every other page does (a redirect to sign in). The Content-Type comes from CONTENT_TYPES, never from
  # the stored blob. Answers: 404 for a missing receipt or photo, a stored file that is gone, or a blob that
  # is not a photo; 422 for a photo that cannot be decoded. Browsers may keep a copy for a day, privately
  # (Cache-Control: private): a photo of an attachment never changes, since a regrouped receipt gets new
  # attachments.
  class PhotosController < ApplicationController
    SERVED_AS_UPLOADED = { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp" }.freeze
    CONTENT_TYPES = { "jpg" => "image/jpeg", "png" => "image/png", "webp" => "image/webp" }.freeze
    MAX_AGE = 1.day

    def show
      attachment = Receipt.find(params[:receipt_id]).images_attachments.find(params[:id])
      blob = attachment.blob
      return head(:not_found) unless Receipt::IMAGE_CONTENT_TYPES.include?(blob.content_type)

      expires_in MAX_AGE, public: false
      return unless stale?(etag: [ attachment.id, params[:size], blob.checksum ], public: false)

      file, extension = representation(attachment, params[:size])
      deliver(file, extension, filename: "receipt-#{attachment.record_id}-#{attachment.id}-#{params[:size]}.#{extension}")
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    rescue ActiveStorage::InvariableError, ActiveStorage::IntegrityError, Vips::Error, ImageProcessing::Error => error
      Rails.logger.warn("Receipts::PhotosController: photo #{attachment&.id} cannot be shown: #{error.class}")
      head :unprocessable_content
    end

    private
      # The blob to send and its file extension.
      def representation(attachment, size)
        blob = attachment.blob
        if size == "full" && SERVED_AS_UPLOADED.key?(blob.content_type)
          [ blob, SERVED_AS_UPLOADED.fetch(blob.content_type) ]
        else
          [ attachment.variant(size.to_sym).processed.image.blob, "jpg" ]
        end
      end

      # Straight from the disk (Active Storage's Disk service, the only one this app uses); from memory
      # for any other service.
      def deliver(blob, extension, filename:)
        type = CONTENT_TYPES.fetch(extension)
        if blob.service.respond_to?(:path_for)
          path = blob.service.path_for(blob.key)
          raise ActiveStorage::FileNotFoundError unless File.file?(path)

          send_file path, type:, disposition: :inline, filename:
        else
          send_data blob.download, type:, disposition: :inline, filename:
        end
      end
  end
end
