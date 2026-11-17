require "test_helper"

class AccountTest < ActiveSupport::TestCase
  def build_account(**attributes)
    Account.new({ name: "Travel card", kind: :debit, currency: "EUR" }.merge(attributes))
  end

  # One violating statement per savepoint: after a failed statement PostgreSQL rejects everything else in the
  # same transaction, so a second assertion would prove nothing.
  def assert_violates(constraint, error = ActiveRecord::StatementInvalid, &block)
    exception = assert_raises(error) { Account.transaction(requires_new: true, &block) }
    assert_includes exception.message, constraint
  end

  test "a new account is valid and not archived" do
    account = build_account

    assert account.save
    assert_not account.archived?
  end

  test "name is required and unique" do
    assert_not build_account(name: " ").valid?

    account = build_account(name: "Cash wallet")
    assert_not account.valid?
    assert_includes account.errors[:name], "has already been taken"
  end

  test "name is squished" do
    assert_equal "Travel card", build_account(name: "  Travel   card ").name
  end

  test "kind must be one of the listed kinds" do
    assert build_account(kind: :business).valid?
    assert_not build_account(kind: nil).valid?

    account = build_account(kind: "piggy_bank")
    assert_not account.valid?
    assert_includes account.errors[:kind], "is not included in the list"
  end

  test "kinds are stored as readable strings" do
    assert_equal "debit", Account.where(id: accounts(:card_uah)).pick(:kind)
    assert_equal %w[cash debit credit savings ewallet business], Account.kinds.values
  end

  test "currency must be three upper-case letters and is upper-cased" do
    assert_equal "USD", build_account(currency: " usd ").currency

    [ nil, "US", "USDT", "U5D", "€" ].each do |currency|
      assert_not build_account(currency:).valid?, currency.inspect
    end
  end

  test "external id is optional and unique when present" do
    assert build_account(external_id: nil).valid?
    assert_nil build_account(external_id: "  ").external_id

    account = build_account(external_id: "example-bank-card-0001")
    assert_not account.valid?
    assert_includes account.errors[:external_id], "has already been taken"
  end

  test "many accounts may have no external id" do
    assert build_account(external_id: nil).save
    assert build_account(name: "Another card", external_id: nil).save
  end

  test "active leaves archived accounts out" do
    assert_includes Account.active, accounts(:cash_uah)
    assert_not_includes Account.active, accounts(:old_wallet)
  end

  test "the database rejects an unknown kind" do
    assert_violates("accounts_kind_allowed") { accounts(:cash_uah).update_column(:kind, "piggy_bank") }
  end

  # update_column still runs `normalizes` (it upper-cases), so the bad value goes in through SQL.
  test "the database rejects a malformed currency" do
    assert_violates("accounts_currency_format") do
      Account.where(id: accounts(:cash_uah)).update_all("currency = 'uah'")
    end
  end

  test "the database keeps names and external ids unique" do
    assert_violates("index_accounts_on_name", ActiveRecord::RecordNotUnique) do
      accounts(:savings_usd).update_column(:name, "Cash wallet")
    end
    assert_violates("index_accounts_on_external_id", ActiveRecord::RecordNotUnique) do
      accounts(:savings_usd).update_column(:external_id, "example-bank-card-0001")
    end
  end
end
