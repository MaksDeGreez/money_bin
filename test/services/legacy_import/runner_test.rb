require "test_helper"
require "rake"

module LegacyImport
  class RunnerTest < ActiveSupport::TestCase
    # The importer maps onto the whole taxonomy; the category fixtures are only a slice of it.
    setup { Categories::TaxonomyLoader.call }

    def import(dir = LegacyExportFiles::FIXTURE, dry_run: false)
      @output = StringIO.new
      Runner.call(dir, dry_run:, output: @output)
    end

    def legacy(legacy_id)
      Transaction.from_legacy.find_by!(external_id: legacy_id.to_s)
    end

    def account(legacy_id)
      Account.find_by!(external_id: "legacy:#{legacy_id}")
    end

    def category(group, name)
      Category.leaves.joins(:parent).find_by!(name:, parent: { name: group })
    end

    # Every imported row and line as stored, with ids, versions and timestamps, to prove nothing was written.
    def snapshot
      [ Account.order(:id).map(&:attributes), Payee.order(:id).map(&:attributes),
        Transaction.order(:id).map(&:attributes), TransactionLine.order(:id).map(&:attributes) ]
    end

    def counts(report)
      Report::ENTITIES.to_h { |entity| [ entity, report.counts(entity).values ] }
    end

    test "imports the fixture export" do
      report = import

      assert_equal({ accounts: [ 5, 0, 0 ], payees: [ 3, 0, 1 ], transactions: [ 11, 0, 0 ] }, counts(report))
      assert_equal 1, report.payees_folded
      assert_equal 2, report.transfer_pairs
      assert_equal({ mapped: 6, unmapped: 1, not_in_taxonomy: 1, no_category: 1 }, report.lines)
      assert_equal({ "confirmed" => 8, "needs_review" => 3 }, report.statuses)
      assert_equal 1, report.manifest_warnings
    end

    test "accounts get their kinds, currencies and archived flag" do
      import

      assert_equal %w[cash debit credit savings ewallet], (1..5).map { |id| account(id).kind }
      assert_equal %w[UAH UAH UAH USD USD], (1..5).map { |id| account(id).currency }
      assert account(5).archived?
      assert_equal "Home cash", account(1).name
    end

    test "transactions keep every field" do
      import

      salary = legacy(1002)
      assert salary.from_legacy?
      assert_equal BigDecimal("30000"), salary.amount
      assert_equal Time.utc(2026, 1, 10, 7), salary.occurred_at
      assert_equal "Example Bank feed", salary.source_system
      assert_equal "SALARY EXAMPLE EMPLOYER", salary.bank_description
      assert_equal "Example Employer", salary.payee.name
      assert_equal category("Income", "Salary & main contracts"), salary.lines.sole.category
      assert salary.confirmed?

      bread = legacy(1001)
      assert_nil bread.occurred_at
      assert_equal Date.new(2026, 1, 5), bread.occurred_on
      assert_nil bread.source_system

      purchase = legacy(1004)
      assert_equal [ BigDecimal("-410"), BigDecimal("-10"), "USD" ], [ purchase.amount, purchase.original_amount, purchase.original_currency ]
      assert_equal [ "5815", "Online Store" ], [ purchase.mcc, purchase.merchant ]
      assert_equal "Example Wallet app", legacy(1011).source_system
    end

    test "a split keeps its lines, comments and old paths; a line without a category needs review" do
      import
      split = legacy(1003)

      assert_equal [ BigDecimal("-600"), BigDecimal("-200"), BigDecimal("-100") ], split.lines.map(&:amount)
      assert_equal [ category("Groceries", "Groceries"), category("Eating out", "Cafes, bars & restaurants"), nil ],
        split.lines.map(&:category)
      assert_equal [ "Food / Supermarket", "Food / Cafe", nil ], split.lines.map(&:legacy_category_path)
      assert_equal [ "Food for the week", nil, nil ], split.lines.map(&:comment)
      assert split.needs_review?
      assert_equal [ "5411", "EXAMPLE MARKET 042", "Example Market" ], [ split.mcc, split.bank_description, split.merchant ]
    end

    test "unmapped and unknown categories go to Uncategorised and keep their old path" do
      report = import

      unmapped, unknown = legacy(1005).lines.sole, legacy(1006).lines.sole
      assert_equal [ Category.uncategorised, "Misc / Unsorted" ], [ unmapped.category, unmapped.legacy_category_path ]
      assert_equal [ Category.uncategorised, "Hobby / Model kits" ], [ unknown.category, unknown.legacy_category_path ]
      assert legacy(1005).needs_review?
      assert legacy(1006).needs_review?
      assert_equal "Food / Groceries", legacy(1001).lines.sole.legacy_category_path
      assert_includes report.warnings,
        "1 old category name a group and category that are not in the taxonomy; their lines went to Uncategorised (legacy_ids 15)"
    end

    test "payees are found by normalised name; spellings of one name fold into one payee" do
      import

      assert_equal payees(:example_market), legacy(1003).payee
      assert_equal payees(:example_market), legacy(1005).payee
      assert_equal "Corner Bakery", legacy(1001).payee.name
      assert_nil legacy(1006).payee
    end

    test "transfers get a deterministic id, no lines and status confirmed" do
      import

      out_leg, in_leg = legacy(1007), legacy(1008)
      assert_equal TransferId.for("T-0001"), out_leg.transfer_id
      assert_equal out_leg.transfer_id, in_leg.transfer_id
      assert_equal [ BigDecimal("-1000"), BigDecimal("1000") ], [ out_leg.amount, in_leg.amount ]
      assert_empty out_leg.lines
      assert out_leg.confirmed?
      assert in_leg.confirmed?
      assert_empty out_leg.transfer_problems

      usd_leg = legacy(1010)
      assert_equal TransferId.for("T-0002"), usd_leg.transfer_id
      assert_equal account(4), usd_leg.account
      assert_empty usd_leg.transfer_problems
    end

    test "a second run of the same export changes nothing" do
      import
      before = snapshot
      report = import

      assert_equal({ accounts: [ 0, 0, 5 ], payees: [ 0, 0, 4 ], transactions: [ 0, 0, 11 ] }, counts(report))
      assert_equal 0, report.pairs_recreated
      assert_equal before, snapshot
    end

    test "a changed row is updated in place, and its lines replaced only when they differ" do
      import
      bread, salary = legacy(1001), legacy(1002)
      salary_line = salary.lines.sole

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") do |rows|
          rows[0].merge!("amount" => "-125.00", "lines" => [ { "amount" => "-125.00", "category_legacy_id" => 12 } ])
          rows[1]["comment"] = "Pay for January"
          rows[4]["lines"][0]["category_legacy_id"] = 10
        end
        LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows[4]["archived"] = false }
        report = import(dir)

        assert_equal({ accounts: [ 0, 1, 4 ], payees: [ 0, 0, 4 ], transactions: [ 0, 3, 8 ] }, counts(report))
      end

      assert_equal bread.id, legacy(1001).id
      assert_equal [ BigDecimal("-125"), category("Eating out", "Cafes, bars & restaurants") ],
        [ legacy(1001).amount, legacy(1001).lines.sole.category ]
      assert_equal "Pay for January", salary.reload.comment
      assert_equal salary_line.id, salary.lines.sole.id
      assert legacy(1005).confirmed?, "a line that found its category no longer needs review"
      assert_not account(5).archived?
    end

    test "a same-currency pair whose amounts changed is destroyed and created again" do
      import
      old_ids = [ legacy(1007).id, legacy(1008).id ]
      usd_leg = legacy(1010)

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") do |rows|
          rows[6]["amount"] = "-1500.00"
          rows[7]["amount"] = "1500.00"
          rows[9]["comment"] = "Bought dollars"
        end
        report = import(dir)

        assert_equal [ 0, 3, 8 ], report.counts(:transactions).values
        assert_equal 1, report.pairs_recreated
      end

      new_legs = [ legacy(1007), legacy(1008) ]
      assert_empty old_ids & new_legs.map(&:id)
      assert_equal [ BigDecimal("-1500"), BigDecimal("1500") ], new_legs.map(&:amount)
      assert_equal TransferId.for("T-0001"), new_legs.first.transfer_id
      assert_empty new_legs.first.transfer_problems
      assert_equal usd_leg.id, legacy(1010).id, "a detail change keeps the legs"
      assert_equal "Bought dollars", legacy(1010).comment
    end

    test "a pair under a new transfer key replaces the old pair" do
      import

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") { |rows| rows[8..9].each { |row| row["transfer_key"] = "T-0099" } }
        report = import(dir)

        assert_equal [ 0, 2, 9 ], report.counts(:transactions).values
      end

      assert_equal TransferId.for("T-0099"), legacy(1009).transfer_id
      assert_not Transaction.exists?(transfer_id: TransferId.for("T-0002"))
    end

    test "a row that becomes a transfer leg, or stops being one, is replaced" do
      import

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") do |rows|
          rows[6].merge!("transfer_key" => nil, "lines" => [ { "amount" => "-1000.00", "category_legacy_id" => 10 } ])
          rows[7].merge!("transfer_key" => "T-0003")
          rows[0].merge!("transfer_key" => "T-0003", "lines" => [], "amount" => "-1000.00", "account_legacy_id" => 2)
        end
        report = import(dir)

        assert_equal [ 0, 3, 8 ], report.counts(:transactions).values
      end

      assert_not legacy(1007).transfer_leg?
      assert_equal 1, legacy(1007).lines.size
      assert_equal TransferId.for("T-0003"), legacy(1001).transfer_id
      assert_empty legacy(1001).transfer_problems
    end

    test "replacing a pair never deletes a stored row that the export does not have" do
      import
      before = snapshot

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") do |rows|
          rows.reject! { |row| row["legacy_id"] == 1008 }
          rows[6].merge!("transfer_key" => nil, "lines" => [ { "amount" => "-1000.00", "category_legacy_id" => 10 } ])
        end
        error = assert_raises(Error) { import(dir) }

        assert_match(/transactions.jsonl line 7 \(legacy_id 1007\): replacing this row would delete a stored transaction that is not in this export/,
          error.message)
      end
      assert_equal before, snapshot
    end

    test "rows missing from the export are left alone and counted in a warning" do
      import
      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "transactions.jsonl") { |rows| rows.reject! { |row| row["legacy_id"] == 1011 } }
        LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows.pop }
        report = import(dir)

        # transactions(:snack) is a legacy fixture row as well.
        assert_includes report.warnings, "2 legacy transactions in the database are not in this export; they were left alone"
        assert_includes report.warnings, "1 legacy accounts in the database are not in this export; they were left alone"
      end
      assert legacy(1011)
    end

    test "a dry run does everything, prints the counts and rolls back" do
      before = snapshot
      report = import(dry_run: true)

      assert_equal [ 11, 0, 0 ], report.counts(:transactions).values
      assert_includes @output.string, "Legacy import (dry run)"
      assert_includes @output.string, "Dry run: everything was rolled back, nothing was written."
      assert_equal before, snapshot
    end

    test "an error while writing rolls everything back" do
      before = snapshot
      # Not a UUID, so the column stores nil: the first leg becomes a row without lines, and the model refuses
      # it after the accounts, payees and ordinary rows were written.
      with_singleton_method(TransferId, :for, ->(_key) { "not a uuid" }) do
        error = assert_raises(Error) { import }

        assert_equal [ "transactions.jsonl line 7 (legacy_id 1007): the transaction was refused (lines invalid)" ],
          error.problems
      end
      assert_equal before, snapshot
    end

    test "a pair the database holds as invalid after writing stops the import" do
      with_singleton_method(Transaction, :transfer_problems, ->(_id) { [ "an invented problem" ] }) do
        error = assert_raises(Error) { import }

        assert_includes error.problems, "transactions.jsonl line 7 (legacy_id 1007): transfer_key an invented problem"
      end
      assert_not Transaction.exists?(external_id: "1001")
    end

    test "a refused account names the row, the attribute and the kind of error only" do
      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows[1]["name"] = accounts(:cash_uah).name }
        error = assert_raises(Error) { import(dir) }

        assert_equal [ "accounts.jsonl line 2 (legacy_id 2): the account was refused (name taken)" ], error.problems
      end
    end

    test "the taxonomy must be loaded" do
      with_singleton_method(Category, :uncategorised, -> { raise ActiveRecord::RecordNotFound }) do
        error = assert_raises(Error) { import }

        assert_match(/the Uncategorised category is missing/, error.message)
      end
    end

    test "an unexpected exception becomes an Error without its message" do
      with_singleton_method(PayeeLoader, :call, ->(*) { raise "secret detail" }) do
        error = assert_raises(Error) { import }

        assert_match(/unexpected RuntimeError at /, error.message)
        assert_not_includes error.message, "secret detail"
      end
    end

    test "output, errors and the log never show names, comments or amounts" do
      secrets = [ "Plughxyzzy Account", "Zyxwvut Secret Shop", "Qwertyuiop private note", "777.77", "Frobnicate line note",
                  "Vexillum bank text" ]
      Account.create!(name: secrets[1], kind: :cash, currency: "UAH")
      log = StringIO.new
      logger = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = ActiveSupport::Logger.new(log)

      LegacyExportFiles.temp_copy do |dir|
        LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows[0]["name"] = secrets[0] }
        LegacyExportFiles.edit(dir, "payees.jsonl") { |rows| rows[2]["name"] = secrets[1] }
        LegacyExportFiles.edit(dir, "transactions.jsonl") do |rows|
          rows[0].merge!("amount" => "-777.77", "comment" => secrets[2], "bank_description" => secrets[5],
            "lines" => [ { "amount" => "-777.77", "category_legacy_id" => 10, "comment" => secrets[4] } ])
        end
        LegacyExportFiles.edit_manifest(dir) { |manifest| manifest["warnings"] << "#{secrets[1]} was skipped" }
        import(dir)
        texts = [ @output.string ]

        # A failure in the verifier, one at write time, and one after writing.
        LegacyExportFiles.edit(dir, "transactions.jsonl") { |rows| rows[0]["lines"][0]["amount"] = "-777.70" }
        texts << assert_raises(Error) { import(dir) }.message
        LegacyExportFiles.edit(dir, "transactions.jsonl") { |rows| rows[0]["lines"][0]["amount"] = "-777.77" }
        LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows[1]["name"] = secrets[1] }
        texts << assert_raises(Error) { import(dir) }.message
        with_singleton_method(Transaction, :transfer_problems, ->(_id) { [ "an invented problem" ] }) do
          LegacyExportFiles.edit(dir, "accounts.jsonl") { |rows| rows[1]["name"] = "Daily debit card" }
          texts << assert_raises(Error) { import(dir) }.message
        end

        texts.each { |text| secrets.each { |secret| assert_not_includes text, secret } }
        assert_equal 4, texts.size
      end
      secrets.each { |secret| assert_not_includes log.string, secret }
    ensure
      ActiveRecord::Base.logger = logger
    end

    test "the rake task imports, supports a dry run and exits non-zero on failure" do
      Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "import:money_bin" }
      task = Rake::Task["import:money_bin"]
      arguments = ->(dir) { Rake::TaskArguments.new([ :dir ], [ dir ]) }

      ENV["DRY_RUN"] = "1"
      stdout, = capture_io { task.execute(arguments.call(LegacyExportFiles::FIXTURE)) }
      assert_includes stdout, "Dry run"
      assert_not Transaction.exists?(external_id: "1001")

      ENV.delete("DRY_RUN")
      stdout, = capture_io { task.execute(arguments.call(LegacyExportFiles::FIXTURE)) }
      assert_includes stdout, "Done: the import was committed."
      assert Transaction.exists?(external_id: "1001")

      _stdout, stderr = capture_io do
        exit = assert_raises(SystemExit) { task.execute(arguments.call("/nonexistent/export")) }
        assert_not exit.success?
      end
      assert_includes stderr, "the export folder does not exist"

      _stdout, stderr = capture_io { assert_raises(SystemExit) { task.execute(arguments.call(nil)) } }
      assert_includes stderr, "Usage:"
    ensure
      ENV.delete("DRY_RUN")
    end
  end
end
