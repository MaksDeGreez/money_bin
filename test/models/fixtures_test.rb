require "test_helper"

# Fixtures are written straight into the database, past every validation. This test loads each fixture
# record through its model and checks that it is valid, so the fixtures cannot drift from the rules.
class FixturesTest < ActiveSupport::TestCase
  MODELS = [ Account, Category, Payee, Transaction, TransactionLine, Receipt, ReceiptItem, ReceiptGroundTruth, User, ApiToken,
    TransactionSuggestionRun, BulkAcceptance, BulkAcceptanceItem ].freeze

  test "every fixture record is valid" do
    MODELS.each do |model|
      assert model.exists?, "#{model.name} has no fixtures"
      model.find_each do |record|
        assert record.valid?, "#{model.name} ##{record.id}: #{record.errors.full_messages.to_sentence}"
      end
    end
  end

  test "every fixture transfer is a valid pair" do
    Transaction.transfer_legs.distinct.pluck(:transfer_id).each do |transfer_id|
      assert_empty Transaction.transfer_problems(transfer_id), transfer_id
    end
  end

  test "every accepted fixture receipt matches its transaction" do
    Receipt.reviewed.where.not(transaction_id: nil).find_each do |receipt|
      assert_equal receipt.ledger_transaction.amount.abs, receipt.items_total, receipt.id
    end
  end
end
