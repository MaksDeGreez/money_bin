require "test_helper"

class LabelMemoryTest < ActiveSupport::TestCase
  # The fixture market receipt holds three items a person labelled: Rye bread and Hard cheese 1 kg as
  # groceries, Dish soap as household supplies.
  def label(name, category, accepted: true)
    receipt = receipts(:corner_receipt)
    position = (receipt.items.maximum(:position) || 0) + 1
    receipt.items.create!(position:, name:, amount: 1, category: categories(category), accepted_by_user: accepted)
  end

  test "item names are normalised as the shared cases say (the same file the ML evaluation reads)" do
    cases = JSON.parse(Rails.root.join("ml/tests/fixtures/item_name_keys.json").read).fetch("cases")

    cases.each { |name, key| assert_equal key, ItemName.key(name), name }
  end

  test "a name the owner labelled is found under another spelling" do
    found = LabelMemory.new.lookup([ "RYE  bread", "Unknown thing" ])

    assert_equal [ ItemName.key("Rye bread") ], found.keys
    suggestion = found.fetch(ItemName.key("rye bread"))
    assert_equal categories(:groceries).id, suggestion.category_id
    assert_equal [ 1, 1 ], [ suggestion.labels, suggestion.agreeing ]
    assert_in_delta 2 / 2.25, suggestion.confidence
  end

  test "repeated agreeing labels raise the confidence, a disagreement lowers it" do
    label("Rye bread", :groceries)
    assert_in_delta 3 / 3.25, LabelMemory.new.lookup([ "Rye bread" ]).values.sole.confidence

    label("Rye bread", :takeaway)
    suggestion = LabelMemory.new.lookup([ "Rye bread" ]).values.sole
    assert_equal [ 3, 2 ], [ suggestion.labels, suggestion.agreeing ]
    assert_in_delta 3 / 4.25, suggestion.confidence
  end

  test "a tie suggests nothing" do
    label("Dish soap", :groceries)

    assert_empty LabelMemory.new.lookup([ "Dish soap" ])
  end

  test "only a person's labels count, and only candidate categories" do
    label("Kettle", :groceries, accepted: false)
    label("Salary slip", :salary)
    label("Mystery", :uncategorised)

    assert_empty LabelMemory.new.lookup([ "Kettle", "Mystery" ])
    assert_equal 1, LabelMemory.new.lookup([ "Salary slip" ]).size
    assert_empty LabelMemory.new(categories: []).lookup([ "Rye bread" ])
  end

  test "the receipt being suggested for is left out" do
    assert_empty LabelMemory.new.lookup([ "Rye bread" ], except_receipt: receipts(:market_receipt))
    assert_equal 1, LabelMemory.new.lookup([ "Rye bread" ], except_receipt: receipts(:corner_receipt)).size
  end

  test "a name with no letters or digits is never looked up" do
    assert_empty LabelMemory.new.lookup([ "--", "" ])
  end

  test "the confidence rule" do
    assert_in_delta 0.889, LabelMemory.confidence(1, 1), 0.001
    assert_in_delta 0.952, LabelMemory.confidence(4, 4), 0.001
    assert_in_delta 0.706, LabelMemory.confidence(2, 3), 0.001
  end

  test "the categoriser name never looks like a fixed pre-fill value" do
    assert_not LabelMemory::CATEGORISER_NAME.start_with?("source:")
  end
end
