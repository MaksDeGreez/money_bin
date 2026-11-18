require "test_helper"
require_relative "../../support/dps_xml_files"

module DpsXml
  class ReaderTest < ActiveSupport::TestCase
    include DpsXmlFiles

    def read(xml)
      Reader.call(xml)
    end

    def assert_unreadable(reason, xml)
      error = assert_raises(Unreadable) { read(xml) }
      assert_equal reason, error.reason
      error
    end

    test "reads the documented receipt layout into a valid ground-truth document" do
      result = read(dps_xml)

      assert_equal "dps_check01.v1", result.format
      assert result.items_known
      assert_empty result.notes
      assert_equal(
        { "kind" => "fiscal", "merchant" => "Invented Trading LLC", "fiscal_number" => "4000000001",
          "receipt_number" => "A-1024", "issued_at" => "2026-10-03T18:40:12+03:00", "total" => "1250.40",
          "currency" => "UAH", "card_last4" => nil, "is_return" => false, "category_slug" => nil },
        result.document.except("items")
      )
      assert_equal(
        [ { "name" => "Invented rye bread", "quantity" => "2.000", "unit_price" => "20.20", "amount" => "40.40", "discount" => "0.00", "category_slug" => nil },
          { "name" => "Invented hard cheese 1 kg", "quantity" => "1.000", "unit_price" => "1010.00", "amount" => "960.00", "discount" => "50.00", "category_slug" => nil },
          { "name" => "Invented dish soap", "quantity" => "1.000", "unit_price" => "250.00", "amount" => "250.00", "discount" => "0.00", "category_slug" => nil } ],
        result.document["items"]
      )
      assert_empty ReceiptGroundTruth::Document.problems(result.document)
    end

    test "never keeps the cashier's name or other fields it does not use" do
      result = read(dps_xml)
      text = result.document.to_json
      [ "Invented Cashier Name", "1 Invented Street", "Invented card", "00000000-0000" ].each { |value| assert_not_includes text, value }
    end

    test "the point of sale is the merchant when the seller's name is missing" do
      assert_equal "Invented Shop No 1", read(dps_xml(head: { "ORGNM" => nil })).document["merchant"]
    end

    test "a winter date has the winter offset, and a time without seconds is read" do
      document = read(dps_xml(head: { "ORDERDATE" => "15012026", "ORDERTIME" => "0905" })).document
      assert_equal "2026-01-15T09:05:00+02:00", document["issued_at"]
    end

    test "reads Windows-1251 declared in the prolog, and a UTF-8 file with a byte-order mark" do
      row = dps_row(name: "Хліб житній")
      assert_equal "Хліб житній", read(dps_xml(rows: [ row ], encoding: "Windows-1251")).document["items"].first["name"]
      assert_equal "Хліб житній", read(dps_xml(rows: [ row ], bom: true)).document["items"].first["name"]
    end

    test "a decimal comma counts as a point, and short decimals are written out" do
      row = dps_row(quantity: "0,5", price: "81,8", cost: "40,9")
      document = read(dps_xml(total: "40,9", rows: [ row ])).document
      assert_equal "40.90", document["total"]
      assert_equal({ "quantity" => "0.500", "unit_price" => "81.80", "amount" => "40.90" },
        document["items"].first.slice("quantity", "unit_price", "amount"))
    end

    test "rows follow ROWNUM; without whole-number row numbers they keep the file's order" do
      rows = [ dps_row(2, name: "Second"), dps_row(1, name: "First") ]
      assert_equal %w[First Second], read(dps_xml(rows:)).document["items"].map { |item| item["name"] }

      unnumbered = rows.map { |row| row.sub(/ROWNUM="\d"/, 'ROWNUM="x"') }
      assert_equal %w[Second First], read(dps_xml(rows: unnumbered)).document["items"].map { |item| item["name"] }
    end

    test "a surcharge raises the amount, leaves the discount at zero and is counted" do
      result = read(dps_xml(rows: [ dps_row(cost: "100.00", discount: "-5.00") ]))
      assert_equal({ "amount" => "105.00", "discount" => "0.00" }, result.document["items"].first.slice("amount", "discount"))
      assert_equal 1, result.notes[:surcharge]
    end

    test "a value with more places than allowed is left out and counted, never rounded" do
      rows = [
        dps_row(1, quantity: "1.2345", price: "10.005", cost: "12.345"),
        dps_row(2, cost: "10.00", discount: "0.005"),
        dps_row(3, quantity: "0.000"),
        dps_row(4, quantity: "abc", cost: "1e3")
      ]
      result = read(dps_xml(total: "1250.404", rows:))
      first, second, third, fourth = result.document["items"]

      assert_nil result.document["total"]
      assert_equal [ nil, nil, nil ], first.values_at("quantity", "unit_price", "amount")
      assert_equal [ nil, nil ], second.values_at("amount", "discount")
      assert_nil third["quantity"]
      assert_equal [ nil, nil ], fourth.values_at("quantity", "amount")
      assert_equal({ dropped_total: 1, dropped_item_quantity: 3, dropped_item_unit_price: 1, dropped_item_amount: 3,
                     dropped_item_discount: 1 }, result.notes)
      assert_empty ReceiptGroundTruth::Document.problems(result.document)
    end

    test "a discount that cannot be read leaves the amount unknown; a row without a cost too" do
      rows = [ dps_row(1, discount: "five"), dps_row(2, cost: nil), dps_row(3, discount: "1" * 501), dps_row(4, discount: " ") ]
      first, second, third, fourth = read(dps_xml(rows:)).document["items"]
      assert_equal [ nil, nil ], first.values_at("amount", "discount")
      assert_equal [ nil, "0.00" ], second.values_at("amount", "discount")
      assert_equal [ nil, nil ], third.values_at("amount", "discount"), "a refused discount is not a missing one"
      assert_equal [ "40.40", "0.00" ], fourth.values_at("amount", "discount"), "a blank discount is no discount"
    end

    test "an impossible date or time is left out and counted" do
      result = read(dps_xml(head: { "ORDERDATE" => "31022026" }))
      assert_nil result.document["issued_at"]
      assert_equal 1, result.notes[:dropped_issued_at]
      assert_nil read(dps_xml(head: { "ORDERTIME" => "256000" })).document["issued_at"]
      assert_nil read(dps_xml(head: { "ORDERTIME" => nil })).document["issued_at"], "a date alone is no moment"
    end

    test "a row without a name makes the item list unknown, not shorter; it is counted" do
      [ [ dps_row(1, name: " "), dps_row(2) ], [ dps_row(1, name: ""), dps_row(2, name: " ") ] ].each do |rows|
        result = read(dps_xml(rows:))
        assert_not result.items_known
        assert_equal [], result.document["items"]
        assert_operator result.notes[:item_without_name], :>=, 1
        assert_equal "1250.40", result.document["total"], "the header is still ground truth"
      end
    end

    test "a number too large for the document is left out and counted" do
      result = read(dps_xml(total: "1" * 20, rows: [ dps_row(quantity: "1" * 12) ]))
      assert_nil result.document["total"]
      assert_nil result.document["items"].first["quantity"]
      assert_equal({ dropped_total: 1, dropped_item_quantity: 1 }, result.notes)
      assert_empty ReceiptGroundTruth::Document.problems(result.document)
    end

    test "a time inside the spring clock change does not exist and is left out, not moved" do
      result = read(dps_xml(head: { "ORDERDATE" => "29032026", "ORDERTIME" => "033000" }))
      assert_nil result.document["issued_at"]
      assert_equal 1, result.notes[:dropped_issued_at]
      assert_equal "2026-03-29T04:30:00+03:00", read(dps_xml(head: { "ORDERDATE" => "29032026", "ORDERTIME" => "043000" })).document["issued_at"]
    end

    test "no item lines is not an error: the result says the items are not known" do
      [ dps_xml(rows: nil), dps_xml(rows: []) ].each do |xml|
        result = read(xml)
        assert_not result.items_known
        assert_equal [], result.document["items"]
        assert_equal "1250.40", result.document["total"]
      end
    end

    test "a return receipt is flagged; a sale with no subtype is not known to be either" do
      assert read(dps_xml(head: { "DOCSUBTYPE" => "1" })).return_receipt?
      assert_nil read(dps_xml(head: { "DOCSUBTYPE" => nil })).document["is_return"]
    end

    test "another kind of document is not a receipt" do
      assert_unreadable(:not_a_sale, dps_xml(head: { "DOCTYPE" => "100" }))
      assert_unreadable(:not_a_sale, dps_xml(head: { "DOCSUBTYPE" => "5" }))
    end

    test "unknown elements, namespaces and letter case do not matter" do
      xml = dps_xml(extra: "<CHECKFUTURE><X>1</X></CHECKFUTURE>", rows: [ dps_row(extra: "<NEWFIELD>y</NEWFIELD>") ])
      assert_equal 1, read(xml).document["items"].size

      lower = <<~XML
        <?xml version="1.0"?>
        <d:check xmlns:d="urn:invented"><d:checkhead><d:cashregisternum>4000000002</d:cashregisternum></d:checkhead>
        <d:checkbody><d:row><d:name>Invented salt</d:name><d:cost>9.00</d:cost></d:row></d:checkbody></d:check>
      XML
      document = read(lower).document
      assert_equal "4000000002", document["fiscal_number"]
      assert_equal "9.00", document["items"].first["amount"]
    end

    test "a file that is not this layout is an unknown layout" do
      assert_unreadable(:unknown_layout, %(<?xml version="1.0"?><INVOICE><HEAD/></INVOICE>))
      assert_unreadable(:unknown_layout, %(<?xml version="1.0"?><CHECK><CHECKBODY/></CHECK>))
    end

    test "a file that is not well-formed XML is refused, not repaired" do
      assert_unreadable(:not_well_formed, "<CHECK><CHECKHEAD></CHECK>")
      assert_unreadable(:not_well_formed, "")
      assert_unreadable(:not_well_formed, "%PDF-1.4 not xml")
      assert_unreadable(:not_well_formed, %(<?xml version="1.0" encoding="UTF-8"?><CHECK><CHECKHEAD><ORGNM>\xFF\xFE</ORGNM></CHECKHEAD></CHECK>).b)
    end

    test "an entity expansion bomb is refused at once" do
      entities = (1..9).map { |level| %(<!ENTITY e#{level} "#{"&e#{level - 1};" * 10}">) }.join
      bomb = %(<?xml version="1.0"?><!DOCTYPE CHECK [<!ENTITY e0 "lol">#{entities}]><CHECK><CHECKHEAD/><N>&e9;</N></CHECK>)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_unreadable(:has_doctype, bomb)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    end

    test "an external entity is refused and never reads the other file" do
      Dir.mktmpdir do |dir|
        secret = File.join(dir, "secret.txt")
        File.write(secret, "INVENTED-SECRET-MARKER")
        xxe = %(<?xml version="1.0"?><!DOCTYPE CHECK [<!ENTITY x SYSTEM "file://#{secret}">]>) +
          %(<CHECK><CHECKHEAD><ORGNM>&x;</ORGNM></CHECKHEAD></CHECK>)
        error = assert_unreadable(:has_doctype, xxe)
        assert_not_includes error.message, "INVENTED-SECRET-MARKER"

        # Behind the declaration check, the parser itself loads no external entity either.
        parsed = Nokogiri::XML(xxe, nil, nil, Reader::PARSE_OPTIONS)
        assert_not_includes parsed.to_s, "INVENTED-SECRET-MARKER"
        assert_not_includes parsed.root.text, "INVENTED-SECRET-MARKER"
      end
    end

    test "a declaration in UTF-16 is refused too" do
      xml = %(<?xml version="1.0" encoding="UTF-16LE"?><!DOCTYPE CHECK [<!ENTITY x "y">]><CHECK><CHECKHEAD/></CHECK>)
      assert_unreadable(:has_doctype, xml.encode("UTF-16LE").b)
    end

    test "a file over the size limit is refused before it is parsed" do
      assert_unreadable(:too_large, dps_xml + (" " * Reader::MAX_BYTES))
    end

    test "text longer than a document allows is left out and counted" do
      result = read(dps_xml(head: { "ORGNM" => "x" * 501, "POINTNM" => nil }))
      assert_nil result.document["merchant"]
      assert_equal 1, result.notes[:dropped_merchant]
    end

    test "the refusal messages never carry the file's content" do
      Unreadable::REASONS.each_key do |reason|
        assert_not_includes Unreadable.new(reason).message, "Invented"
      end
      assert_raises(ArgumentError) { Unreadable.new(:other) }
    end
  end
end
