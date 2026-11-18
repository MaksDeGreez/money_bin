# The JSON of one AccountBalancesQuery::Row (docs/openapi.yaml, Account).
module AccountSerializer
  module_function

  def call(row)
    account = row.account
    {
      id: account.id,
      name: account.name,
      kind: account.kind,
      currency: account.currency,
      archived: account.archived,
      balance: JsonFormat.money(row.balance)
    }
  end
end
