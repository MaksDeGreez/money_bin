require "test_helper"

class ReceiptItemTest < ActiveSupport::TestCase
  def build_item(**attributes)
    receipts(:new_receipt).items.build({ position: 1, name: "Apples", amount: "42.00" }.merge(attributes))
  end

  def assert_violates(constraint, error = ActiveRecord::StatementInvalid, &block)
    exception = assert_raises(error) { ReceiptItem.transaction(requires_new: true, &block) }
    assert_includes exception.message, constraint
  end

  test "a new item is valid with defaults" do
    item = build_item

    assert item.save
    assert_equal BigDecimal("0"), item.discount
    assert_not item.accepted_by_user?
  end

  test "name is required and squished" do
    assert_equal "Green apples", build_item(name: " Green   apples ").name
    assert_not build_item(name: " ").valid?
  end

  test "position is a non-negative integer, unique inside the receipt" do
    assert_not build_item(position: nil).valid?
    assert_not build_item(position: -1).valid?
    assert_not build_item(position: 1.5).valid?

    taken = receipts(:corner_receipt).items.build(position: 1, name: "Apples", amount: 1)
    assert_not taken.valid?
    assert_includes taken.errors[:position], "has already been taken"
  end

  test "amount is required and may be zero or negative" do
    assert_not build_item(amount: nil).valid?
    assert build_item(amount: 0).valid?
    assert build_item(amount: "-2.50").valid?
    assert_not build_item(amount: 10**13).valid?
  end

  test "discount is never negative" do
    assert build_item(discount: "5.00").valid?

    item = build_item(discount: "-5.00")
    assert_not item.valid?
    assert_includes item.errors[:discount], "must be greater than or equal to 0"
  end

  test "quantity is positive when present" do
    assert build_item(quantity: "0.125").valid?
    assert build_item(quantity: nil).valid?
    assert_not build_item(quantity: 0).valid?
  end

  test "unit price may be any amount in range" do
    assert build_item(unit_price: "-2.50").valid?
    assert_not build_item(unit_price: 10**13).valid?
  end

  test "money has at most two decimal places and quantity at most three" do
    item = build_item(amount: "1.005", unit_price: "0.335", discount: "0.001", quantity: "1.0005")

    assert_not item.valid?
    %i[amount unit_price discount].each { |field| assert_includes item.errors[field], "must have at most 2 decimal places (it is never rounded)" }
    assert_includes item.errors[:quantity], "must have at most 3 decimal places (it is never rounded)"
    assert build_item(amount: "1.01", unit_price: "0.34", discount: "0.10", quantity: "1.005").valid?
  end

  test "confidence is between 0 and 1 when present" do
    assert build_item(confidence: 0).valid?
    assert build_item(confidence: 1).valid?
    assert_not build_item(confidence: 1.01).valid?
    assert_not build_item(confidence: -0.1).valid?
  end

  test "categories must be categories, not groups" do
    item = build_item(category: categories(:eating_out), suggested_category: categories(:groceries_group))

    assert_not item.valid?
    assert_includes item.errors[:category], "must be a category, not a group"
    assert_includes item.errors[:suggested_category], "must be a category, not a group"
    assert build_item(category: categories(:takeaway), suggested_category: categories(:cafes)).valid?
  end

  test "a category id that does not exist is a validation error" do
    missing = Category.maximum(:id) + 1
    item = build_item(category_id: missing, suggested_category_id: missing)

    assert_not item.valid?
    assert_includes item.errors[:category], "does not exist"
    assert_includes item.errors[:suggested_category], "does not exist"
  end

  test "a category used by an item cannot be destroyed; a suggestion is dropped" do
    coffee = Category.create!(parent: categories(:eating_out), name: "Coffee")
    item = build_item(suggested_category: coffee).tap(&:save!)

    assert coffee.destroy
    assert_nil item.reload.suggested_category_id

    TransactionLine.where(category: categories(:household_supplies)).update_all(category_id: nil)
    assert_not categories(:household_supplies).destroy
  end

  test "the database checks the item constraints" do
    item = receipt_items(:corner_water)

    assert_violates("receipt_items_position_non_negative") { item.update_column(:position, -1) }
    assert_violates("receipt_items_quantity_positive") { item.update_column(:quantity, 0) }
    assert_violates("receipt_items_discount_non_negative") { item.update_column(:discount, -1) }
    assert_violates("receipt_items_confidence_range") { item.update_column(:confidence, 1.5) }
    assert_violates("index_receipt_items_on_receipt_id_and_position", ActiveRecord::RecordNotUnique) do
      item.update_column(:position, 2)
    end
  end
end
