# Every account with its balance: the sum of its booked transaction amounts (drafts left out, as in
# Account#balance), in the account's own currency. Two queries whatever the number of accounts.
#
# Order: open accounts first, then by name.
class AccountBalancesQuery
  Row = Data.define(:account, :balance)

  def call
    balances = Transaction.booked.group(:account_id).sum(:amount)
    Account.order(:archived, :name, :id).map do |account|
      Row.new(account:, balance: balances.fetch(account.id, BigDecimal("0")))
    end
  end
end
