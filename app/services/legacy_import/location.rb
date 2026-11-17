module LegacyImport
  # Where a problem is: a file, a line number and the row's legacy id (each optional).
  Location = Data.define(:file, :line, :legacy_id) do
    def self.of(row)
      new(file: row.file, line: row.line, legacy_id: row.legacy_id)
    end

    def to_s
      parts = [ file ]
      parts << "line #{line}" if line
      parts << "(legacy_id #{Values.printable_id(legacy_id)})" unless legacy_id.nil?
      parts.compact.join(" ")
    end
  end
end
