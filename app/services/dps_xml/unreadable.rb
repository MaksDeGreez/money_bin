module DpsXml
  # A file the reader will not turn into a ground-truth document. `reason` is one of REASONS; the message is
  # built from it alone, never from the file, so it can be printed.
  class Unreadable < StandardError
    REASONS = {
      too_large: "larger than #{Reader::MAX_BYTES / 1.megabyte} MB",
      has_doctype: "has a document type declaration (refused: a receipt needs none, and entities could expand or read other files)",
      not_well_formed: "not well-formed XML",
      unknown_layout: "not a receipt layout the reader knows",
      not_a_sale: "a document of another kind (not a sale or a return receipt)"
    }.freeze

    attr_reader :reason

    def initialize(reason)
      @reason = REASONS.key?(reason) ? reason : raise(ArgumentError, "unknown reason #{reason.inspect}")
      super(REASONS.fetch(reason))
    end
  end
end
