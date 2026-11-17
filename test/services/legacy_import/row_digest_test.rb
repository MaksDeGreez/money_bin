require "test_helper"

module LegacyImport
  class RowDigestTest < ActiveSupport::TestCase
    setup do
      dataset = Verifier.call(ExportReader.call(LegacyExportFiles::FIXTURE))
      @categories = dataset.categories.index_by(&:legacy_id)
      @split = dataset.transactions.find { |row| row.legacy_id == "1003" }
      @account = dataset.accounts.first
    end

    def digest(row, payee_key: "example market", categories: @categories)
      RowDigest.transaction(row, payee_key:, category: ->(id) { id && categories.fetch(id) })
    end

    test "the canonical form has sorted keys and typed values" do
      fields = { b: BigDecimal("-120"), a: [ { z: nil, y: "x" } ] }

      assert_equal({ "a" => [ { "y" => "x", "z" => nil } ], "b" => BigDecimal("-120") }, RowDigest.canonical(fields))
      assert_equal "-120.0", RowDigest.decimal(BigDecimal("-120.00"))
      assert_equal ::Digest::SHA256.hexdigest('[1,"account",{"a":1}]'), RowDigest.hex("account", a: 1)
    end

    test "the same values give the same digest, however they were spelled" do
      respelled = @split.with(legacy_id: "1003", amount: BigDecimal("-900.0"),
        occurred_at: Time.iso8601("2026-01-12T16:30:00.000000Z"))

      assert_equal digest(@split), digest(respelled)
      assert_equal RowDigest.account(@account), RowDigest.account(@account.with(name: " #{@account.name}  "))
    end

    test "every field that is written changes the digest" do
      line = @split.lines.first
      changes = [
        @split.with(comment: "Other"), @split.with(occurred_at: nil), @split.with(account_legacy_id: "3"),
        @split.with(lines: [ line.with(comment: "Other"), *@split.lines.drop(1) ]),
        @split.with(lines: [ line.with(category_legacy_id: "10"), *@split.lines.drop(1) ]),
        @split.with(lines: @split.lines.reverse)
      ]
      digests = changes.map { |row| digest(row) }
      digests << digest(@split, payee_key: "corner bakery")
      other_path = @categories.merge("11" => @categories["11"].with(legacy_path: "Food / Other"))
      digests << digest(@split, categories: other_path)
      unmapped = @categories.merge("11" => @categories["11"].with(group_en: nil, category_en: nil))
      digests << digest(@split, categories: unmapped)

      assert_equal digests.size + 1, (digests + [ digest(@split) ]).uniq.size
      assert_not_equal RowDigest.account(@account), RowDigest.account(@account.with(archived: true))
    end
  end
end
