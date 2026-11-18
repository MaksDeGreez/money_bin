require "tmpdir"

# Synthetic receipt files in the documented software cash register layout (DpsXml::Check01), written by
# hand for the tests: an invented shop, invented items and numbers. The repository holds no real receipt
# file.
#
#   xml = dps_xml(rows: [ dps_row(name: "Invented tea") ])
#   write_dps_file("rcpt_000041", xml)
#   GroundTruthImport::Runner.call(dps_dir, output: StringIO.new)
module DpsXmlFiles
  # The head of the default document; it agrees with the QR values of the `market_receipt` fixture.
  HEAD = {
    "DOCTYPE" => "0", "DOCSUBTYPE" => "0", "UID" => "00000000-0000-0000-0000-000000000000",
    "TIN" => "00000000", "ORGNM" => "Invented Trading LLC", "POINTNM" => "Invented Shop No 1",
    "POINTADDR" => "1 Invented Street", "ORDERDATE" => "03102026", "ORDERTIME" => "184012",
    "ORDERNUM" => "17", "CASHDESKNUM" => "1", "CASHREGISTERNUM" => "4000000001", "CASHIER" => "Invented Cashier Name",
    "VER" => "1", "ORDERTAXNUM" => "A-1024"
  }.freeze

  def self.included(base)
    base.teardown { FileUtils.remove_entry(@dps_dir) if @dps_dir && File.directory?(@dps_dir) }
  end

  def dps_dir
    @dps_dir ||= Dir.mktmpdir("dps-xml-test")
  end

  def write_dps_file(name, content)
    path = File.join(dps_dir, name.end_with?(".xml") || name.include?(".") ? name : "#{name}.xml")
    File.binwrite(path, content)
    path
  end

  def dps_row(number = 1, name: "Invented bread", quantity: "1.000", price: "40.40", cost: "40.40", discount: nil, extra: "")
    fields = { "NAME" => name, "UNITNM" => "pc", "AMOUNT" => quantity, "PRICE" => price, "COST" => cost,
               "DISCOUNTSUM" => discount }
    "<ROW ROWNUM=\"#{number}\"><CODE>#{number}</CODE>#{elements(fields)}<LETTERS>A</LETTERS>#{extra}</ROW>"
  end

  # The three rows of the market_receipt fixture's items (they sum to its total, 1250.40).
  def market_rows
    [
      dps_row(1, name: "Invented rye bread", quantity: "2.000", price: "20.20", cost: "40.40"),
      dps_row(2, name: "Invented hard cheese 1 kg", quantity: "1.000", price: "1010.00", cost: "1010.00", discount: "50.00"),
      dps_row(3, name: "Invented dish soap", quantity: "1.000", price: "250.00", cost: "250.00")
    ]
  end

  # A whole document. `head` overrides HEAD (a nil value drops the element); `rows: nil` leaves CHECKBODY out.
  def dps_xml(head: {}, total: "1250.40", rows: market_rows, encoding: "UTF-8", bom: false, extra: "")
    head_fields = HEAD.merge(head)
    body = rows.nil? ? "" : "<CHECKBODY>#{rows.join}</CHECKBODY>"
    xml = <<~XML
      <?xml version="1.0" encoding="#{encoding}"?>
      <CHECK xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="check01.xsd">
        <CHECKHEAD>#{elements(head_fields)}</CHECKHEAD>
        <CHECKTOTAL>#{elements('SUM' => total, 'RNDSUM' => '0.00', 'NORNDSUM' => total)}</CHECKTOTAL>
        <CHECKPAY><ROW ROWNUM="1"><PAYFORMCD>0</PAYFORMCD><PAYFORMNM>Invented card</PAYFORMNM><SUM>#{total}</SUM></ROW></CHECKPAY>
        <CHECKTAX><ROW ROWNUM="1"><TYPE>0</TYPE><LETTER>A</LETTER><PRC>20.00</PRC></ROW></CHECKTAX>
        #{body}
        #{extra}
      </CHECK>
    XML
    bytes = xml.encode(encoding == "UTF-8" ? "UTF-8" : encoding).b
    bom ? "\xEF\xBB\xBF".b + bytes : bytes
  end

  private
    def elements(fields)
      fields.compact.map { |name, value| "<#{name}>#{value.to_s.encode(xml: :text)}</#{name}>" }.join
    end
end
