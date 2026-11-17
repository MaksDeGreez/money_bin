require "test_helper"

module LegacyImport
  class RecordErrorsTest < ActiveSupport::TestCase
    LOCATION = Location.new(file: "accounts.jsonl", line: 3, legacy_id: 7)

    test "a refusal names the attributes and the error types, never a model's own sentence" do
      account = Account.new
      account.errors.add(:name, :taken)
      account.errors.add(:currency, "cannot change from Zorblax Private Bank to USD")

      error = assert_raises(Error) { RecordErrors.guard(LOCATION) { raise ActiveRecord::RecordInvalid, account } }

      assert_equal [ "accounts.jsonl line 3 (legacy_id 7): the account was refused (name taken; currency invalid)" ], error.problems
      assert_not_includes error.message, "Zorblax"
    end

    test "an error type given with a custom message is printed as its type" do
      transaction = Transaction.new
      transaction.errors.add(:lines, :unbalanced, message: "must add up to 123.45 Zorblax")

      assert_equal "lines unbalanced", RecordErrors.describe(transaction)
    end

    test "a stale row and a database refusal are reported without their messages" do
      stale = assert_raises(Error) do
        RecordErrors.guard(LOCATION) { raise ActiveRecord::StaleObjectError.new(Account.new, "update") }
      end
      refused = assert_raises(Error) do
        RecordErrors.guard(LOCATION) { raise ActiveRecord::StatementInvalid, "PG::Error: Zorblax" }
      end

      assert_equal [ "accounts.jsonl line 3 (legacy_id 7): the row changed in the database during the import" ], stale.problems
      assert_equal [ "accounts.jsonl line 3 (legacy_id 7): the database refused the row (ActiveRecord::StatementInvalid)" ],
        refused.problems
    end
  end
end
