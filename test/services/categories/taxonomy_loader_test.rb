require "test_helper"

class Categories::TaxonomyLoaderTest < ActiveSupport::TestCase
  GROUPS = 21
  CATEGORIES = 39

  def snapshot
    Category.order(:id).pluck(:id, :parent_id, :name, :slug, :position, :description, :updated_at)
  end

  test "loads every group and category from the file" do
    result = Categories::TaxonomyLoader.call

    assert_equal GROUPS, result.groups
    assert_equal CATEGORIES, result.categories
    # The fixtures are a slice of the taxonomy with the same names, so they are found, not duplicated.
    assert_equal GROUPS, Category.groups.count
    assert_equal CATEGORIES, Category.leaves.count
  end

  test "builds slugs from the names" do
    Categories::TaxonomyLoader.call

    assert_equal "eating-out/takeaway-fast-food", Category.find_by!(name: "Takeaway & fast food").slug
    assert_equal "groceries/groceries", Category.leaves.find_by!(name: "Groceries").slug
    assert_equal "car/service-parts-tyres", Category.find_by!(name: "Service, parts & tyres").slug
    assert_equal "digital-communications", Category.groups.find_by!(name: "Digital & communications").slug
    assert_equal Category.find_by!(slug: Category::UNCATEGORISED_SLUG), Category.uncategorised
  end

  test "keeps the file order as positions" do
    Categories::TaxonomyLoader.call

    assert_equal [ "Groceries", "Eating out", "Housing" ], Category.groups.ordered.limit(3).pluck(:name)
    assert_equal "Uncategorised", Category.groups.ordered.last.name
    car = Category.groups.find_by!(name: "Car")
    assert_equal [ "Car other", "Fuel", "Service, parts & tyres" ], car.children.pluck(:name)
    assert_equal [ 1, 2, 3 ], car.children.pluck(:position)
  end

  test "every category has a description" do
    Categories::TaxonomyLoader.call

    assert_empty Category.leaves.where(description: [ nil, "" ]).pluck(:name)
  end

  test "a second run changes nothing" do
    Categories::TaxonomyLoader.call
    before = snapshot
    result = Categories::TaxonomyLoader.call

    assert_equal 0, result.created
    assert_equal 0, result.updated
    assert_equal before, snapshot
  end

  test "updates positions and descriptions in place and keeps slugs" do
    Categories::TaxonomyLoader.call
    takeaway = categories(:takeaway)
    takeaway.update_columns(position: 9, description: "Old text", slug: "eating-out/takeaway")

    result = Categories::TaxonomyLoader.call

    assert_equal 1, result.updated
    takeaway.reload
    assert_equal 2, takeaway.position
    assert_equal "Takeaway, food delivery and fast food.", takeaway.description
    assert_equal "eating-out/takeaway", takeaway.slug
  end

  test "never deletes a category the file does not list" do
    extra = Category.create!(parent: categories(:eating_out), name: "Coffee")

    Categories::TaxonomyLoader.call

    assert Category.exists?(extra.id)
  end

  test "db/seeds.rb can run twice" do
    2.times { Rails.application.load_seed }

    assert_equal GROUPS, Category.groups.count
    assert_equal CATEGORIES, Category.leaves.count
  end
end
