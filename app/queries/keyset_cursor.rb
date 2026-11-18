# An opaque position in a list that is read page by page (keyset pagination).
#
# A list ordered by a sort key and the row id, newest first, is cut after the last row of a page; the
# cursor holds that row's key and id, and the next page starts strictly after them. Unlike an offset, a
# position does not move when rows are added in front of it, and reading page N costs the same as page 1
# (an index range scan, not a skip over N pages).
#
# The cursor is the URL-safe Base64 of a JSON array of those values. It is opaque to clients (they pass it
# back as they got it), not secret: it says nothing a client could not read from the page it came from.
# Each query decodes the values into its own types and refuses anything else with Invalid.
module KeysetCursor
  class Invalid < StandardError
    def initialize(message = "The cursor is not one this API handed out.")
      super
    end
  end

  # Rows per page when the caller does not say, and the most a caller may ask for.
  DEFAULT_LIMIT = 50
  MAX_LIMIT = 200

  # Far more than any cursor this app makes; a longer value is refused before it is decoded.
  MAX_LENGTH = 200
  FORMAT = /\A[A-Za-z0-9_-]+\z/

  def self.encode(*values)
    Base64.urlsafe_encode64(JSON.generate(values), padding: false)
  end

  # The array of values inside `cursor`, which must hold exactly `size` of them. Raises Invalid otherwise.
  def self.decode(cursor, size:)
    raise Invalid unless cursor.is_a?(String) && cursor.length <= MAX_LENGTH && FORMAT.match?(cursor)

    values = JSON.parse(Base64.urlsafe_decode64(cursor))
    raise Invalid unless values.is_a?(Array) && values.size == size

    values
  rescue ArgumentError, JSON::ParserError
    raise Invalid
  end

  # A row id read back from a cursor: a positive Integer, nothing else.
  def self.id(value)
    raise Invalid unless value.is_a?(Integer) && value.positive?

    value
  end
end
