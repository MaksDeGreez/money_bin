require "test_helper"
require_relative "../../support/receipt_images"

module Receipts
  class PhotosControllerTest < ActionDispatch::IntegrationTest
    include ReceiptImages

    JPEG_SIGNATURE = "\xFF\xD8\xFF".b

    setup do
      sign_in_as users(:owner)
      @receipt = Receipt.create!(images: [ image_upload(png_bytes(red: 200), filename: "one.png") ])
      @photo = @receipt.images.attachments.sole
    end

    test "a signed-out browser gets the sign-in redirect, never the photo" do
      sign_out

      %i[thumb page full].each do |size|
        get receipt_photo_path(@receipt, @photo, size)
        assert_redirected_to new_session_path
        assert_not response.body.b.include?(png_bytes(red: 200)), size
      end
      assert_equal 0, ActiveStorage::VariantRecord.count, "no copy is made for a signed-out request"
    end

    test "the thumbnail and the reading size are JPEG copies, made once and reused" do
      %i[thumb page].each do |size|
        get receipt_photo_path(@receipt, @photo, size)

        assert_response :success
        assert_equal "image/jpeg", response.media_type
        assert response.body.b.start_with?(JPEG_SIGNATURE), size
        assert_match(/\Ainline; filename="receipt-#{@receipt.id}-#{@photo.id}-#{size}.jpg"/, response.headers["Content-Disposition"])
      end

      assert_no_difference -> { ActiveStorage::VariantRecord.count } do
        assert_no_difference -> { ActiveStorage::Blob.count } do
          get receipt_photo_path(@receipt, @photo, :thumb)
          get receipt_photo_path(@receipt, @photo, :page)
        end
      end
      assert_equal 2, ActiveStorage::VariantRecord.where(blob_id: @photo.blob_id).count
    end

    test "photos are cached by the browser only, and revalidate with their ETag" do
      get receipt_photo_path(@receipt, @photo, :thumb)

      cache_control = response.headers["Cache-Control"]
      assert_includes cache_control, "private"
      assert_includes cache_control, "max-age=86400"
      assert_not_includes cache_control, "public"
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]

      get receipt_photo_path(@receipt, @photo, :thumb), headers: { "If-None-Match" => response.headers["ETag"] }
      assert_response :not_modified
    end

    test "the full size of a JPEG, PNG or WebP photo is the photo as uploaded" do
      get receipt_photo_path(@receipt, @photo, :full)

      assert_response :success
      assert_equal "image/png", response.media_type
      assert_equal png_bytes(red: 200), response.body.b
      assert_equal 0, ActiveStorage::VariantRecord.count
    end

    test "the full size of a HEIC photo is a JPEG copy, so every browser shows it" do
      # The bytes stay a PNG: libvips reads a file by its content, and the test needs no HEIC encoder.
      @photo.blob.update_columns(content_type: "image/heic")

      get receipt_photo_path(@receipt, @photo, :full)

      assert_response :success
      assert_equal "image/jpeg", response.media_type
      assert response.body.b.start_with?(JPEG_SIGNATURE)
    end

    test "the Content-Type comes from the allow-list, never from the stored blob" do
      @photo.blob.update_columns(content_type: "text/html")

      get receipt_photo_path(@receipt, @photo, :full)

      assert_response :not_found, "a blob that is not a photo is not served at all"
      assert_empty response.body
    end

    test "a photo of another receipt is a 404, whatever its id" do
      other = Receipt.create!(images: [ image_upload(png_bytes(red: 99)) ])

      get receipt_photo_path(@receipt, other.images.attachments.sole, :page)
      assert_response :not_found

      get receipt_photo_path(other, @photo, :page)
      assert_response :not_found
    end

    test "an attachment of another kind of record is not reachable" do
      foreign = ActiveStorage::Attachment.create!(name: "images", record: users(:owner),
        blob: ActiveStorage::Blob.create_and_upload!(**image_upload(png_bytes(red: 5))))

      get receipt_photo_path(@receipt, foreign, :full)

      assert_response :not_found
    end

    test "a missing receipt, a photo whose file is gone and an unknown size are 404s" do
      get receipt_photo_path(receipt_id: 0, id: @photo.id, size: :page)
      assert_response :not_found

      fixture = receipts(:market_receipt) # its blob row has no file
      %i[thumb page full].each do |size|
        get receipt_photo_path(fixture, active_storage_attachments(:market_photo), size)
        assert_response :not_found, size
      end

      get "/receipts/#{@receipt.id}/photos/#{@photo.id}/huge"
      assert_response :not_found
    end

    test "a photo that cannot be decoded is a 422, not an error page" do
      broken = Receipt.create!(images: [ image_upload("not really a png".b, filename: "broken.png") ])

      get receipt_photo_path(broken, broken.images.attachments.sole, :thumb)

      assert_response :unprocessable_content
    end

    test "the receipt load's ids are not a way in: the attachment id must be a number" do
      get "/receipts/#{@receipt.id}/photos/#{@photo.blob.signed_id}/full"

      assert_response :not_found
    end
  end
end
