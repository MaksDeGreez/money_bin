require "test_helper"

class PayeeTest < ActiveSupport::TestCase
  test "normalize_name squishes, lower-cases and applies NFKC" do
    assert_equal "example market", Payee.normalize_name("  EXAMPLE \t\n Market ")
    # Full-width letters and a no-break space become plain ones under NFKC.
    assert_equal "example market", Payee.normalize_name("ＥＸＡＭＰＬＥ Market")
    # The ligature "ﬁ" becomes "fi".
    assert_equal "fine foods", Payee.normalize_name("ﬁne Foods")
    assert_equal "", Payee.normalize_name(nil)
  end

  test "normalize_name lower-cases Cyrillic and other scripts" do
    assert_equal "приклад маркет", Payee.normalize_name("ПРИКЛАД  Маркет")
    assert_equal "ünïcode straße", Payee.normalize_name("ÜNÏCODE Straße")
  end

  test "normalize_name keeps punctuation" do
    assert_equal "example-market, ltd.", Payee.normalize_name("Example-Market, Ltd.")
  end

  test "normalized name is set on save" do
    payee = Payee.create!(name: "  Green   GROCER ")

    assert_equal "Green GROCER", payee.name
    assert_equal "green grocer", payee.normalized_name
  end

  test "normalized name follows a rename" do
    payee = payees(:corner_cafe)
    payee.update!(name: "Corner Cafe & Bakery")

    assert_equal "corner cafe & bakery", payee.reload.normalized_name
  end

  test "name is required" do
    payee = Payee.new(name: "  ")

    assert_not payee.valid?
    assert_includes payee.errors[:name], "can't be blank"
  end

  test "two names that normalise the same are one payee" do
    payee = Payee.new(name: "EXAMPLE  market")

    assert_not payee.valid?
    assert_includes payee.errors[:normalized_name], "has already been taken"
  end

  test "find_or_create_by_name! finds through the normalised name" do
    assert_no_difference -> { Payee.count } do
      assert_equal payees(:example_market), Payee.find_or_create_by_name!(" example MARKET ")
    end
  end

  test "find_or_create_by_name! creates a missing payee" do
    payee = nil
    assert_difference -> { Payee.count }, 1 do
      payee = Payee.find_or_create_by_name!("Приклад Маркет")
    end

    assert_equal "Приклад Маркет", payee.name
    assert_equal payee, Payee.find_or_create_by_name!("ПРИКЛАД МАРКЕТ")
  end

  # A race: the first lookup misses, another process inserts the same name, and our insert hits the unique
  # index (validation passed for both, as it does in a real race).
  test "find_or_create_by_name! reads the winner when a parallel insert got there first" do
    existing = payees(:example_market)
    original_find_by = Payee.method(:find_by)
    lookups = 0
    miss_once = ->(*args, **options) { (lookups += 1) == 1 ? nil : original_find_by.call(*args, **options) }
    insert_without_validation = ->(name:) { Payee.new(name:).save!(validate: false) }

    with_singleton_method(Payee, :find_by, miss_once) do
      with_singleton_method(Payee, :create!, insert_without_validation) do
        assert_no_difference -> { Payee.count } do
          assert_equal existing, Payee.find_or_create_by_name!("EXAMPLE MARKET")
        end
      end
    end
  end

  test "find_or_create_by_name! refuses a blank name" do
    assert_raises(ArgumentError) { Payee.find_or_create_by_name!(" ") }
  end

  test "a payee with transactions cannot be destroyed" do
    assert_not payees(:corner_cafe).destroy
    assert Payee.create!(name: "Unused Shop").destroy
  end

  test "the database keeps normalised names unique" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      payees(:corner_cafe).update_column(:normalized_name, "example market")
    end
  end
end
