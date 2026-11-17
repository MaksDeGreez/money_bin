require "zlib"

# Tiny synthetic photos for receipt tests, built in memory: the repository holds no image files.
#
# Include it in a test case. It also deletes the files that the test stored. Active Storage writes uploads
# to tmp/storage (config/storage.yml, service :test), and the database rollback at the end of a test does
# not remove files. Every parallel worker shares that folder, but blob keys are random, so each test
# deletes only the files of the blobs in its own database. Nothing wipes the whole folder, so a test
# running in another worker is never disturbed.
module ReceiptImages
  PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

  def self.included(base)
    base.teardown { delete_stored_receipt_files }
  end

  # A valid 1x1 PNG of one colour. Different colours give different bytes, so different fingerprints.
  def png_bytes(red: 0, green: 0, blue: 0)
    header = [ 1, 1, 8, 2, 0, 0, 0 ].pack("NNCCCCC") # width, height, 8-bit RGB, no interlace
    pixels = Zlib::Deflate.deflate([ 0, red, green, blue ].pack("C4")) # filter byte, then one RGB pixel
    PNG_SIGNATURE + png_chunk("IHDR", header) + png_chunk("IDAT", pixels) + png_chunk("IEND", "".b)
  end

  # An Active Storage attachable for `bytes`.
  def image_upload(bytes = png_bytes, filename: "receipt.png", content_type: "image/png")
    { io: StringIO.new(bytes), filename:, content_type: }
  end

  private
    def png_chunk(type, data)
      [ data.bytesize ].pack("N") + type.b + data + [ Zlib.crc32(type + data) ].pack("N")
    end

    def delete_stored_receipt_files
      ActiveStorage::Blob.find_each { |blob| blob.service.delete(blob.key) }
    end
end
