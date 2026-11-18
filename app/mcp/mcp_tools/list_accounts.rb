module McpTools
  # list_accounts: AccountBalancesQuery, as GET /api/v1/accounts.
  class ListAccounts < Base
    tool_name "list_accounts"
    title "List accounts"
    description <<~TEXT.squish
      Every account (cards, cash, savings, e-wallets) with its id, kind, currency, whether it is archived, and
      its balance: the sum of its booked transactions (drafts are not counted), in the account's own
      currency, as a decimal string. Balances of accounts in different currencies must never be added
      together: there are no exchange rates. Use an account id as the account_id argument of
      search_transactions.
    TEXT
    input_schema(type: "object", properties: {}, additionalProperties: false)
    output_schema OutputSchema.of("AccountList")
    annotations(**ANNOTATIONS, title: "List accounts")

    class << self
      private
        def answer
          json = { accounts: AccountBalancesQuery.new.call.map { |row| AccountSerializer.call(row) } }

          [ text(json), json ]
        end

        def text(json)
          return "There are no accounts yet." if json[:accounts].empty?

          lines = [ "Accounts with their booked balances, each in its own currency (open accounts first):" ]
          json[:accounts].each do |account|
            lines << "id #{account[:id]} | #{account[:name]} | #{account[:kind]} | balance #{money(account[:balance], account[:currency])}" \
              "#{' | archived' if account[:archived]}"
          end
          lines.join("\n")
        end
    end
  end
end
