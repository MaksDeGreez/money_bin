# The JSON of receipts (docs/openapi.yaml, ReceiptSummary and Receipt). Photos are never in it: the API
# does not serve them.
#
# A new receipt column is one line in `common` (and one property in both schemas of docs/openapi.yaml).
module ReceiptSerializer
  module_function

  # A row of the list: `items_count` comes from ReceiptsQuery#page's select.
  def summary(receipt)
    common(receipt).merge(items_count: receipt.items_count)
  end

  # The receipt with its items (ReceiptsQuery::PRELOADS loaded).
  def call(receipt)
    items = receipt.items.to_a
    common(receipt).merge(
      items_count: items.size,
      items_total: JsonFormat.money(items.sum(BigDecimal("0"), &:amount)),
      items: items.map { |item| item(item) }
    )
  end

  def common(receipt)
    {
      id: receipt.id,
      status: receipt.status,
      merchant: receipt.merchant_name,
      issued_at: JsonFormat.time(receipt.issued_at),
      issued_on: JsonFormat.date(receipt.issued_at&.in_time_zone&.to_date),
      total: JsonFormat.money(receipt.total),
      currency: receipt.currency,
      transaction_id: receipt.transaction_id
    }
  end

  def item(item)
    {
      id: item.id,
      position: item.position,
      name: item.name,
      quantity: JsonFormat.quantity(item.quantity),
      unit_price: JsonFormat.money(item.unit_price),
      amount: JsonFormat.money(item.amount),
      discount: JsonFormat.money(item.discount),
      category: CategorySerializer.reference(item.category),
      suggested_category: CategorySerializer.reference(item.suggested_category),
      confidence: item.confidence,
      accepted_by_user: item.accepted_by_user
    }
  end
end
