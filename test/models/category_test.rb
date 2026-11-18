require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def assert_violates(constraint, error = ActiveRecord::StatementInvalid, &block)
    exception = assert_raises(error) { Category.transaction(requires_new: true, &block) }
    assert_includes exception.message, constraint
  end

  test "groups and leaves" do
    assert_includes Category.groups, categories(:eating_out)
    assert_not_includes Category.groups, categories(:takeaway)
    assert_includes Category.leaves, categories(:takeaway)
    assert_not_includes Category.leaves, categories(:eating_out)
    assert categories(:eating_out).group?
    assert categories(:takeaway).leaf?
  end

  test "children are ordered by position" do
    assert_equal [ categories(:cafes), categories(:takeaway) ], categories(:eating_out).children.to_a
    assert_equal categories(:groceries_group), Category.groups.ordered.first
  end

  test "full name" do
    assert_equal "Eating out / Takeaway & fast food", categories(:takeaway).full_name
    assert_equal "Eating out", categories(:eating_out).full_name
  end

  test "uncategorised finds the seeded leaf category" do
    assert_equal categories(:uncategorised), Category.uncategorised
  end

  test "uncategorised raises when the taxonomy is not loaded" do
    categories(:uncategorised).update_column(:slug, "uncategorised/other")

    assert_raises(ActiveRecord::RecordNotFound) { Category.uncategorised }
  end

  test "a group slug is its parameterized name" do
    group = Category.create!(name: "Kids & school")

    assert_equal "kids-school", group.slug
  end

  test "a category slug is the group slug and its own part" do
    category = Category.create!(parent: categories(:eating_out), name: "Coffee to go")

    assert_equal "eating-out/coffee-to-go", category.slug
  end

  test "a given slug is kept, and renaming keeps the slug" do
    category = Category.create!(parent: categories(:eating_out), name: "Coffee", slug: "eating-out/coffee-shops")
    category.update!(name: "Coffee shops")

    assert_equal "eating-out/coffee-shops", category.reload.slug
  end

  test "a slug must be unique" do
    category = Category.new(parent: categories(:income), name: "Groceries", slug: "groceries/groceries")

    assert_not category.valid?
    assert_includes category.errors[:slug], "has already been taken"
  end

  test "a slug must have the right format" do
    [ "Eating-Out", "eating_out", "eating-out/", "a/b/c", "-x" ].each do |slug|
      group = Category.new(name: "Something", slug:)
      assert_not group.valid?, slug
    end
  end

  test "a name that gives no slug is rejected" do
    group = Category.new(name: "???")

    assert_not group.valid?
    assert_includes group.errors[:slug], "can't be blank"
  end

  test "a group slug has no slash and a category slug starts with its group slug" do
    group = Category.new(name: "Kids", slug: "kids/kids")
    assert_not group.valid?
    assert_includes group.errors[:slug], "of a group must not contain a slash"

    category = Category.new(parent: categories(:eating_out), name: "Coffee", slug: "groceries/coffee")
    assert_not category.valid?
    assert_includes category.errors[:slug], "must start with the group slug (eating-out/)"
  end

  test "name is required and unique inside its parent" do
    assert_not Category.new(name: " ").valid?

    duplicate = Category.new(parent: categories(:eating_out), name: "Takeaway & fast food", slug: "eating-out/takeaway-2")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"

    assert Category.new(parent: categories(:income), name: "Takeaway & fast food").valid?
  end

  test "group names are unique too" do
    group = Category.new(name: "Eating out", slug: "eating-out-2")

    assert_not group.valid?
    assert_includes group.errors[:name], "has already been taken"
  end

  test "position defaults to the end of its level" do
    category = Category.create!(parent: categories(:eating_out), name: "Coffee")
    group = Category.create!(name: "Kids")

    assert_equal 3, category.position
    assert_equal 22, group.position
  end

  test "position must be a non-negative integer" do
    assert_not Category.new(name: "Kids", position: -1).valid?
    assert_not Category.new(name: "Kids", position: 1.5).valid?
    assert Category.new(name: "Kids", position: 0).valid?
  end

  test "a category cannot be nested under a category" do
    nested = Category.new(parent: categories(:takeaway), name: "Pizza", slug: "eating-out/takeaway-fast-food-pizza")

    assert_not nested.valid?
    assert_includes nested.errors[:parent], "must be a group (a category without a parent)"
  end

  test "a group with categories cannot get a parent" do
    group = categories(:eating_out)
    group.parent = categories(:income)

    assert_not group.valid?
    assert_includes group.errors[:parent], "cannot change: a group cannot become a category while it has child categories"
  end

  test "a group that lines or items point at cannot become a category" do
    group = Category.create!(name: "Kids")
    TransactionLine.where(id: transaction_lines(:coffee_line)).update_all(category_id: group.id) # past the model, as bad data would be

    assert_not group.update(parent: categories(:income), slug: "income/kids")
    assert_includes group.errors[:parent], "cannot change: a group cannot become a category while it has transaction lines"
  end

  test "a category in use cannot become a group" do
    {
      categories(:cafes) => "transaction lines and runner-up transaction lines",
      categories(:household_supplies) => "transaction lines, receipt items, suggested receipt items, suggested transaction lines, and bulk acceptance items",
      categories(:takeaway) => "transaction lines and suggested receipt items"
    }.each do |category, uses|
      assert_not category.update(parent: nil, slug: nil), category.slug
      assert_includes category.errors[:parent], "cannot change: a category cannot become a group while it has #{uses}"
      assert category.reload.leaf?
    end
  end

  test "a category only a transaction suggestion points at cannot become a group; the suggestion goes with it" do
    category = Category.create!(parent: categories(:eating_out), name: "Picnics")
    transaction_lines(:subscription_line).update_columns(suggested_category_id: category.id)

    assert_not category.update(parent: nil, slug: nil)
    assert_includes category.errors[:parent], "cannot change: a category cannot become a group while it has suggested transaction lines"
    assert category.reload.destroy
    assert_nil transaction_lines(:subscription_line).reload.suggested_category_id
  end

  test "a category nothing points at can become a group, and back" do
    category = Category.create!(parent: categories(:eating_out), name: "Picnics")

    assert category.update(parent: nil, slug: nil)
    assert_equal "picnics", category.slug
    assert category.update(parent: categories(:eating_out), slug: nil)
    assert_equal "eating-out/picnics", category.slug
  end

  test "a category in use can move to another group" do
    category = categories(:cafes)

    assert category.update(parent: categories(:groceries_group), slug: nil)
    assert category.slug.start_with?("groceries/")
  end

  test "a group without categories can become a category" do
    group = Category.create!(name: "Kids")

    assert group.update(parent: categories(:income), slug: "income/kids")
  end

  test "a category cannot be its own parent" do
    group = Category.create!(name: "Kids")
    group.parent_id = group.id

    assert_not group.valid?
    assert_includes group.errors[:parent], "cannot be the category itself"
  end

  test "a parent id that does not exist is a validation error" do
    category = Category.new(name: "Coffee", parent_id: Category.maximum(:id) + 1, slug: "x/coffee")

    assert_not category.valid?
    assert_includes category.errors[:parent], "does not exist"
  end

  test "a category a card slip uses cannot be destroyed or become a group; a suggestion goes with it" do
    category = Category.create!(parent: categories(:eating_out), name: "Picnics")
    receipts(:corner_receipt).update_columns(category_id: category.id)

    assert_not category.destroy
    assert_not category.update(parent: nil, slug: nil)
    assert_includes category.errors[:parent], "cannot change: a category cannot become a group while it has receipts"

    receipts(:corner_receipt).update_columns(category_id: nil, suggested_category_id: category.id)
    assert category.reload.destroy
    assert_nil receipts(:corner_receipt).reload.suggested_category_id
  end

  test "a group with categories cannot be destroyed" do
    assert_not categories(:eating_out).destroy
    assert Category.exists?(categories(:eating_out).id)
  end

  test "the database keeps group names unique" do
    assert_violates("index_categories_on_parent_id_and_name", ActiveRecord::RecordNotUnique) do
      Category.insert_all!([ { name: "Eating out", slug: "eating-out-2", position: 9 } ])
    end
  end

  test "the database checks the slug format and level" do
    assert_violates("categories_slug_format") { categories(:eating_out).update_column(:slug, "Eating Out") }
    assert_violates("categories_slug_matches_level") { categories(:eating_out).update_column(:slug, "eating/out") }
    assert_violates("categories_slug_matches_level") { categories(:takeaway).update_column(:slug, "takeaway") }
  end

  test "the database rejects a category that is its own parent" do
    category = categories(:income)

    assert_violates("categories_not_own_parent") { category.update_column(:parent_id, category.id) }
  end
end
