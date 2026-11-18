module DpsXml
  # The receipt document of a software cash register as the tax service publicly documents it (the
  # `check01.xsd` layout). **Implemented from the documentation and not yet confirmed against a real saved
  # file**: docs/decisions/0009-receipt-ground-truth.md lists what is a guess.
  #
  #   <CHECK>
  #     <CHECKHEAD>   DOCTYPE (0: a sale document), DOCSUBTYPE (0: sale, 1: return), ORGNM (seller), POINTNM
  #                   (point of sale), ORDERDATE (ddmmyyyy), ORDERTIME (hhmmss), CASHREGISTERNUM (the
  #                   register's fiscal number), ORDERTAXNUM (the receipt's fiscal number), CASHIER, ...
  #     <CHECKTOTAL>  SUM (to pay), RNDSUM, NORNDSUM, DISCOUNTSUM, ...
  #     <CHECKPAY>    ROW: PAYFORMCD, PAYFORMNM, SUM, ...
  #     <CHECKTAX>    ROW: tax rates and sums
  #     <CHECKBODY>   ROW ROWNUM="n": NAME, AMOUNT (quantity), PRICE, COST (before the discount),
  #                   DISCOUNTSUM, UNITNM, CODE, BARCODE, ...
  #   </CHECK>
  #
  # Money is in hryvnias with decimals (the documented type), so `currency` is UAH: a cash register in
  # Ukraine reports in hryvnias. An item's `amount` is COST minus DISCOUNTSUM; a negative DISCOUNTSUM is a
  # surcharge, which raises the amount and leaves `discount` at 0.00 (counted as `surcharge`). Elements it
  # does not use are ignored. It never reads CASHIER or any other person's name field beyond the seller.
  class Check01 < Format
    NAME = "dps_check01.v1"
    SALE_DOCTYPE = "0"
    SUBTYPES = { "0" => false, "1" => true }.freeze

    def self.match?(document)
      root = document.root
      root.name.casecmp?("CHECK") && child(root, "CHECKHEAD").present?
    end

    def read
      root = @document.root
      head = child(root, "CHECKHEAD")
      is_return = sale_kind(head)
      rows = children(child(root, "CHECKBODY"), "ROW")

      document = ReceiptGroundTruth::Document.blank.merge(
        "kind" => "fiscal",
        "merchant" => text(head, "ORGNM", "merchant") || text(head, "POINTNM", "merchant"),
        "fiscal_number" => text(head, "CASHREGISTERNUM", "fiscal_number"),
        "receipt_number" => text(head, "ORDERTAXNUM", "receipt_number"),
        "issued_at" => kyiv_time(text(head, "ORDERDATE", "issued_at"), text(head, "ORDERTIME", "issued_at"), "issued_at"),
        "total" => money(child(root, "CHECKTOTAL"), "SUM", "total"),
        "currency" => "UAH",
        "is_return" => is_return,
        "items" => ordered(rows).filter_map { |row| item(row) }
      )
      result(document, items_known: rows.any?)
    end

    private
      # false for a sale, true for a return; nil when the file does not say. Any other kind of document (a
      # cash deposit, a cancellation, a shift report) is not a receipt.
      def sale_kind(head)
        doctype = text(head, "DOCTYPE")
        raise Unreadable, :not_a_sale unless doctype.nil? || doctype == SALE_DOCTYPE

        subtype = text(head, "DOCSUBTYPE")
        return nil if subtype.nil?

        SUBTYPES.fetch(subtype) { raise Unreadable, :not_a_sale }
      end

      # By ROWNUM when every row has a whole-number one, else in document order.
      def ordered(rows)
        numbers = rows.map { |row| row["ROWNUM"] || row["rownum"] }
        return rows unless numbers.all? { |number| number.to_s.match?(/\A\d+\z/) }

        rows.each_with_index.sort_by { |row, index| [ numbers[index].to_i, index ] }.map(&:first)
      end

      def item(row)
        name = text(row, "NAME", "item_name")
        return note(:item_without_name) if name.nil?

        cost = number(row, "COST", "item_amount")
        # No DISCOUNTSUM means no discount; one that cannot be read leaves the discount and the amount unknown.
        discount = blank?(row, "DISCOUNTSUM") ? BigDecimal("0") : number(row, "DISCOUNTSUM", "item_discount")
        note(:surcharge) if discount&.negative?

        {
          "name" => name,
          "quantity" => quantity(row),
          "unit_price" => money(row, "PRICE", "item_unit_price"),
          "amount" => (decimal_string(cost - discount, 2, "item_amount") if cost && discount),
          "discount" => (decimal_string(discount.negative? ? BigDecimal("0") : discount, 2, "item_discount") if discount)
        }
      end

      # A quantity must be above zero; anything else is left out and counted.
      def quantity(row)
        value = number(row, "AMOUNT", "item_quantity")
        return nil if value.nil?
        return note(:dropped_item_quantity) unless value.positive?

        decimal_string(value, ReceiptItem::QUANTITY_DECIMAL_PLACES, "item_quantity")
      end
  end
end
