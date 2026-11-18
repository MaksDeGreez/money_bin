require "nokogiri"

module DpsXml
  # Turns the bytes of one receipt file, as a person saved it from the tax service's receipt page, into a
  # ground-truth document (docs/domain.md, "Receipt ground truth"):
  #
  #   result = DpsXml::Reader.call(File.binread(path))  # => DpsXml::Result
  #
  # It only reads bytes it is given: it opens no file and sends no request. Safety first:
  # - a file over MAX_BYTES is refused before it is parsed;
  # - a file with a document type declaration (`<!DOCTYPE`, `<!ENTITY`) is refused: a receipt needs none, and
  #   entities are how an XML file expands to gigabytes or pulls in another file. libxml2 is also told not to
  #   substitute entities, not to load a DTD and not to use the network, so nothing slips past the check;
  # - the parse is strict: a file that is not well-formed is refused, not repaired.
  #
  # The format knowledge lives in one class per variant (FORMATS), each with `.match?(document)` (does the
  # root and structure look like mine?) and `#read` (=> Result). The first that matches reads the file;
  # none matching is `unknown_layout`. Adding or correcting a variant is a change to that class alone.
  # Every refusal raises Unreadable with a reason code.
  class Reader
    MAX_BYTES = 2.megabytes
    # Strict, no network, and none of NOENT (substitute entities), DTDLOAD, DTDATTR or HUGE.
    PARSE_OPTIONS = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET
    # A declaration in any of the encodings a file may use: ASCII-compatible ones and UTF-16 (a NUL byte
    # beside each character).
    DECLARATIONS = [ "<!DOCTYPE", "<!ENTITY", "<\0!\0D\0O\0C\0T\0Y\0P\0E", "\0<\0!\0D\0O\0C\0T\0Y\0P\0E",
      "<\0!\0E\0N\0T\0I\0T\0Y", "\0<\0!\0E\0N\0T\0I\0T\0Y" ].map(&:b).freeze

    def self.formats
      [ Check01 ]
    end

    def self.call(bytes)
      new(bytes).call
    end

    def initialize(bytes)
      @bytes = bytes.to_s.b
    end

    def call
      raise Unreadable, :too_large if @bytes.bytesize > MAX_BYTES
      raise Unreadable, :has_doctype if DECLARATIONS.any? { |declaration| @bytes.include?(declaration) }

      document = parse
      raise Unreadable, :has_doctype if document.internal_subset || document.external_subset

      document.remove_namespaces!
      format = self.class.formats.find { |candidate| candidate.match?(document) }
      raise Unreadable, :unknown_layout unless format

      format.new(document).read
    end

    private
      def parse
        document = Nokogiri::XML(@bytes, nil, nil, PARSE_OPTIONS)
        raise Unreadable, :not_well_formed if document.root.nil?

        document
      rescue Nokogiri::XML::SyntaxError, EncodingError, ArgumentError
        raise Unreadable, :not_well_formed
      end
  end
end
