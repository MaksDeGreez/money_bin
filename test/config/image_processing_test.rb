require "test_helper"
require_relative "../support/receipt_images"

# Active Storage reads image sizes and makes variants (resized copies) with libvips, through the
# ruby-vips gem. image_processing 2.x no longer pulls that gem in, so the Gemfile names it. Needs the
# libvips library: Homebrew `vips` on the owner's machine, the `libvips` package in GitHub CI.
class ImageProcessingTest < ActiveSupport::TestCase
  include ReceiptImages

  test "an uploaded image is analysed: its width and height are known" do
    blob = ActiveStorage::Blob.create_and_upload!(**image_upload)

    blob.analyze

    assert_equal 1, blob.metadata[:width]
    assert_equal 1, blob.metadata[:height]
  end

  test "a variant of an image can be made" do
    blob = ActiveStorage::Blob.create_and_upload!(**image_upload)

    variant = blob.variant(resize_to_fill: [ 3, 2 ], format: :png).processed
    bytes = variant.download

    assert bytes.start_with?(PNG_SIGNATURE)
    assert_equal [ 3, 2 ], bytes[16, 8].unpack("NN") # width and height from the IHDR chunk
  end
end
