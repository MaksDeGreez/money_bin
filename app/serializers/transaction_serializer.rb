# The JSON of one transaction (docs/openapi.yaml, Transaction). Expects the associations in
# TransactionsQuery::PRELOADS to be loaded, so a page of rows costs no extra query per row.
module TransactionSerializer
  module_function

  def call(transaction)
    account = transaction.account
    {
      id: transaction.id,
      occurred_on: JsonFormat.date(transaction.occurred_on),
      occurred_at: JsonFormat.time(transaction.occurred_at),
      amount: JsonFormat.money(transaction.amount),
      currency: account.currency,
      original_amount: JsonFormat.money(transaction.original_amount),
      original_currency: transaction.original_currency,
      status: transaction.status,
      source: transaction.source,
      account: { id: account.id, name: account.name, currency: account.currency },
      payee: transaction.payee && { id: transaction.payee.id, name: transaction.payee.name },
      merchant: transaction.merchant,
      comment: transaction.comment,
      bank_description: transaction.bank_description,
      mcc: transaction.mcc,
      transfer_id: transaction.transfer_id,
      has_receipt: !transaction.receipt.nil?,
      receipt_id: transaction.receipt&.id,
      lines: transaction.lines.map { |line| line(line) }
    }
  end

  def line(line)
    {
      id: line.id,
      category: CategorySerializer.reference(line.category),
      amount: JsonFormat.money(line.amount),
      comment: line.comment
    }
  end
end
