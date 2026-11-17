require "test_helper"

module LegacyImport
  class VerifierTest < ActiveSupport::TestCase
    def verify(dir = LegacyExportFiles::FIXTURE)
      Verifier.call(ExportReader.call(dir))
    end

    # The problems of a fixture copy after `edits` (file => block that changes its rows).
    def problems(edits)
      LegacyExportFiles.temp_copy do |dir|
        edits.each { |file, edit| LegacyExportFiles.edit(dir, file, &edit) }
        return assert_raises(Error) { verify(dir) }.problems
      end
    end

    def transaction_edit(legacy_id, &block)
      { "transactions.jsonl" => ->(rows) { block.call(rows.find { |row| row["legacy_id"] == legacy_id }) } }
    end

    test "turns the fixture into typed rows" do
      dataset = verify

      assert_equal [ 5, 7, 5, 11 ], [ dataset.accounts, dataset.categories, dataset.payees, dataset.transactions ].map(&:size)
      split = dataset.transactions.find { |row| row.legacy_id == "1003" }
      assert_equal BigDecimal("-900"), split.amount
      assert_equal [ "11", "12", nil ], split.lines.map(&:category_legacy_id)
      assert_equal [ "Food for the week", nil, nil ], split.lines.map(&:comment)
      assert_equal Date.new(2026, 1, 12), split.occurred_on
      leg = dataset.transactions.find { |row| row.legacy_id == "1007" }
      assert leg.transfer_leg?
      assert_empty dataset.warnings
    end

    test "an account kind that is not one of ours stops it" do
      found = problems("accounts.jsonl" => ->(rows) { rows.first["kind"] = "piggy_bank" })

      assert_equal [ "accounts.jsonl line 1 (legacy_id 1): kind is not one of cash, debit, credit, savings, ewallet, business" ], found
    end

    test "a missing key, a wrong type and a duplicate id stop it, all reported at once" do
      found = problems(
        "accounts.jsonl" => lambda do |rows|
          rows[1].delete("archived")
          rows[2]["legacy_id"] = 1
        end,
        "payees.jsonl" => ->(rows) { rows[0]["name"] = 42 },
        "categories.jsonl" => ->(rows) { rows[0]["legacy_id"] = nil }
      )

      assert_equal [
        "accounts.jsonl line 2 (legacy_id 2): archived is missing",
        "accounts.jsonl line 3 (legacy_id 1): legacy_id is a duplicate (first on line 1)",
        "categories.jsonl line 1: legacy_id must be an integer or a string",
        "payees.jsonl line 1 (legacy_id 20): name must be a string",
        # The category without an id and the account whose id became a duplicate are now unknown.
        "transactions.jsonl line 1 (legacy_id 1001): lines[0].category_legacy_id names a category that is not in categories.jsonl",
        "transactions.jsonl line 4 (legacy_id 1004): account_legacy_id names an account that is not in accounts.jsonl"
      ], found
    end

    test "a legacy id with spaces around it, or a blank one, stops it with its file and line" do
      found = problems(
        "accounts.jsonl" => ->(rows) { rows[1]["legacy_id"] = "2 " },
        "payees.jsonl" => ->(rows) { rows[0]["legacy_id"] = " " },
        "transactions.jsonl" => ->(rows) { rows[0]["legacy_id"] = " 1001" }
      )

      assert_equal [
        "accounts.jsonl line 2 (legacy_id not printable): legacy_id has spaces at the start or the end",
        "payees.jsonl line 1 (legacy_id not printable): legacy_id is empty",
        "transactions.jsonl line 1 (legacy_id not printable): legacy_id has spaces at the start or the end",
        # The account and the payee whose ids were refused are now unknown.
        "transactions.jsonl line 2 (legacy_id 1002): account_legacy_id names an account that is not in accounts.jsonl",
        "transactions.jsonl line 3 (legacy_id 1003): account_legacy_id names an account that is not in accounts.jsonl",
        "transactions.jsonl line 3 (legacy_id 1003): payee_legacy_id names a payee that is not in payees.jsonl",
        "transactions.jsonl line 6 (legacy_id 1006): account_legacy_id names an account that is not in accounts.jsonl",
        "transactions.jsonl line 7 (legacy_id 1007): account_legacy_id names an account that is not in accounts.jsonl",
        "transactions.jsonl line 9 (legacy_id 1009): account_legacy_id names an account that is not in accounts.jsonl"
      ], found
      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): account_legacy_id has spaces at the start or the end" ],
        problems(transaction_edit(1001) { |row| row["account_legacy_id"] = "1 " })
    end

    test "two accounts with one name stop it" do
      found = problems("accounts.jsonl" => ->(rows) { rows[3]["name"] = " #{rows[0]['name']} " })

      assert_equal [ "accounts.jsonl line 4 (legacy_id 4): name is the same as the account on line 1" ], found
    end

    test "a payee name that is blank once normalised stops it" do
      found = problems("payees.jsonl" => ->(rows) { rows[0]["name"] = "　" })

      assert_equal [ "payees.jsonl line 1 (legacy_id 20): name is blank once normalised" ], found
    end

    test "bad amounts stop it" do
      found = problems("transactions.jsonl" => lambda do |rows|
        rows[0]["amount"] = "-120.005"
        rows[1]["amount"] = 30000
        rows[2]["lines"][2]["amount"] = "0.00"
        rows[3]["original_amount"] = "ten"
      end)

      assert_equal [
        "transactions.jsonl line 1 (legacy_id 1001): amount has more than 2 decimal places",
        "transactions.jsonl line 2 (legacy_id 1002): amount must be a decimal string",
        "transactions.jsonl line 3 (legacy_id 1003): lines[2].amount is zero",
        "transactions.jsonl line 4 (legacy_id 1004): original_amount is not a decimal string"
      ], found
    end

    test "the transaction currency must be its account's" do
      found = problems(transaction_edit(1001) { |row| row["currency"] = "USD" })

      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): currency is not the currency of its account" ], found
    end

    test "the original amount must come with its currency, another currency and the same sign" do
      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): original_amount and original_currency must both be set or both be null" ],
        problems(transaction_edit(1001) { |row| row["original_amount"] = "-3.00" })
      assert_equal [ "transactions.jsonl line 4 (legacy_id 1004): original_amount must have the same sign as amount" ],
        problems(transaction_edit(1004) { |row| row["original_amount"] = "10.00" })
      assert_equal [ "transactions.jsonl line 4 (legacy_id 1004): original_currency must differ from the transaction currency" ],
        problems(transaction_edit(1004) { |row| row["original_currency"] = "UAH" })
    end

    test "lines must add up, and only a transfer leg has none" do
      assert_equal [ "transactions.jsonl line 3 (legacy_id 1003): lines do not add up to amount" ],
        problems(transaction_edit(1003) { |row| row["lines"].pop })
      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): lines must have at least one line (only a transfer leg has none)" ],
        problems(transaction_edit(1001) { |row| row["lines"] = [] })
      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): lines must be a JSON array" ],
        problems(transaction_edit(1001) { |row| row["lines"] = nil })
      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): lines[0] is not a JSON object" ],
        problems(transaction_edit(1001) { |row| row["lines"] = [ "-120.00" ] })
      assert_equal [ "transactions.jsonl line 1 (legacy_id 1001): lines[0].comment must be a string or null" ],
        problems(transaction_edit(1001) { |row| row["lines"][0]["comment"] = 5 })
      assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): lines must be empty for a transfer leg" ],
        problems(transaction_edit(1007) { |row| row["lines"] = [ { "amount" => "-1000.00", "category_legacy_id" => nil } ] })
    end

    test "unknown references stop it" do
      found = problems(transaction_edit(1003) do |row|
        row["account_legacy_id"] = 99
        row["payee_legacy_id"] = 98
        row["lines"][0]["category_legacy_id"] = 97
      end)

      assert_equal [
        "transactions.jsonl line 3 (legacy_id 1003): account_legacy_id names an account that is not in accounts.jsonl",
        "transactions.jsonl line 3 (legacy_id 1003): payee_legacy_id names a payee that is not in payees.jsonl",
        "transactions.jsonl line 3 (legacy_id 1003): lines[0].category_legacy_id names a category that is not in categories.jsonl"
      ], found
    end

    test "other malformed fields stop it" do
      found = problems(transaction_edit(1002) do |row|
        row["occurred_on"] = "2026-13-01"
        row["occurred_at"] = "2026-01-10 09:00"
        row["mcc"] = "54"
        row["transfer_key"] = ""
        row.delete("merchant")
      end)

      assert_equal [
        "transactions.jsonl line 2 (legacy_id 1002): occurred_on is not a real date",
        "transactions.jsonl line 2 (legacy_id 1002): occurred_at must be an ISO 8601 time with an offset",
        "transactions.jsonl line 2 (legacy_id 1002): mcc must be a string of four digits",
        "transactions.jsonl line 2 (legacy_id 1002): merchant is missing",
        "transactions.jsonl line 2 (legacy_id 1002): transfer_key is blank"
      ], found
    end

    test "a transfer key with one leg or with three stops it" do
      assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): transfer_key has 1 legs in the export; a transfer needs exactly two (legacy_ids 1007)" ],
        problems("transactions.jsonl" => ->(rows) { rows.reject! { |row| row["legacy_id"] == 1008 } })

      found = problems("transactions.jsonl" => lambda do |rows|
        rows.find { |row| row["legacy_id"] == 1009 }["transfer_key"] = "T-0001"
        rows.reject! { |row| row["legacy_id"] == 1010 }
      end)
      assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): transfer_key has 3 legs in the export; a transfer needs exactly two (legacy_ids 1007, 1008, 1009)" ],
        found
    end

    test "an unbalanced same-currency pair, one account or one sign stop it" do
      assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): transfer_key joins two same-currency legs that do not net to zero (the leg on line 8); a fee must be a separate expense row" ],
        problems(transaction_edit(1007) { |row| row["amount"] = "-1010.00" })
      assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): transfer_key joins two legs on the same account (the leg on line 8)" ],
        problems(transaction_edit(1008) { |row| row["account_legacy_id"] = 2 })
      assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): transfer_key joins two legs with the same sign (the leg on line 8)" ],
        problems(transaction_edit(1008) { |row| row["amount"] = "-1000.00" })
    end

    test "a cross-currency pair may have any two amounts" do
      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") { |rows| rows.find { |row| row["legacy_id"] == 1010 }["amount"] = "99.13" }

        assert_equal 11, verify(dir).transactions.size
      end
    end

    test "keys the contract does not name are ignored with a warning" do
      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "payees.jsonl") { |rows| rows.first(2).each { |row| row["colour"] = "red" } }
        LegacyExportFiles.edit(dir, "transactions.jsonl") { |rows| rows.first["lines"].first["note"] = "x" }

        assert_equal [
          "payees.jsonl: 2 rows have fields this importer does not read (colour); they were ignored",
          "transactions.jsonl: some lines have fields this importer does not read (note); they were ignored"
        ], verify(dir).warnings
      end
    end
  end
end
