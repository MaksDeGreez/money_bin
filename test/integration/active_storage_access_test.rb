require "test_helper"
require_relative "../support/receipt_images"

# Receipt photos are private. Rails' own Active Storage routes (direct uploads, the disk service, blob and
# representation links) do not go through ApplicationController, so they would skip sign-in. The app does
# not draw them (config.active_storage.draw_routes = false); a page that uploads or shows a photo will be a
# controller of the app, behind the Authentication concern.
class ActiveStorageAccessTest < ActionDispatch::IntegrationTest
  include ReceiptImages

  test "a signed-out visitor cannot create a blob, upload a file or read one" do
    get new_session_path
    assert_response :success

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post "/rails/active_storage/direct_uploads", params: {
        blob: { filename: "x.png", byte_size: 4, checksum: Digest::MD5.base64digest("abcd"), content_type: "image/png" }
      }, as: :json
    end
    assert_response :not_found

    put "/rails/active_storage/disk/#{disk_upload_token}", params: "abcd", headers: { "Content-Type" => "image/png" }
    assert_response :not_found

    blob = stored_blob
    blob_paths(blob).each do |path|
      get path
      assert_response :not_found, "#{path} should not exist"
    end
  end

  test "a signed-in owner cannot use them either: no page relies on them" do
    sign_in_as users(:owner)

    blob_paths(stored_blob).each do |path|
      get path
      assert_response :not_found, "#{path} should not exist"
    end
  end

  test "no Active Storage route is drawn" do
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

    assert_empty paths.grep(%r{active_storage})
  end

  test "files are still stored and read from Ruby code" do
    receipt = receipts(:new_receipt)
    receipt.images.attach(image_upload)

    assert_equal png_bytes, receipt.images.last.download
  end

  private
    def stored_blob
      ActiveStorage::Blob.create_and_upload!(**image_upload)
    end

    def blob_paths(blob)
      variation = ActiveStorage::Variation.encode(resize_to_limit: [ 10, 10 ])
      disk_key = ActiveStorage.verifier.generate(
        { key: blob.key, disposition: "inline", content_type: blob.content_type, service_name: blob.service_name },
        expires_in: 5.minutes, purpose: :blob_key
      )
      [
        "/rails/active_storage/blobs/redirect/#{blob.signed_id}/receipt.png",
        "/rails/active_storage/blobs/proxy/#{blob.signed_id}/receipt.png",
        "/rails/active_storage/blobs/#{blob.signed_id}/receipt.png",
        "/rails/active_storage/representations/redirect/#{blob.signed_id}/#{variation}/receipt.png",
        "/rails/active_storage/representations/proxy/#{blob.signed_id}/#{variation}/receipt.png",
        "/rails/active_storage/disk/#{disk_key}/receipt.png"
      ]
    end

    def disk_upload_token
      blob = ActiveStorage::Blob.create_before_direct_upload!(
        filename: "x.png", byte_size: 4, checksum: Digest::MD5.base64digest("abcd"), content_type: "image/png"
      )
      ActiveStorage.verifier.generate(
        { key: blob.key, content_type: "image/png", content_length: 4, checksum: blob.checksum,
          service_name: blob.service_name },
        expires_in: 5.minutes, purpose: :blob_token
      )
    end
end
