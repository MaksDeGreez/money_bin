require "test_helper"

class Categories::ItemCandidatesTest < ActiveSupport::TestCase
  test "every category except Uncategorised and Adjustments, in taxonomy order" do
    slugs = Categories::ItemCandidates.all.map(&:slug)

    assert_includes slugs, "groceries/groceries"
    assert_includes slugs, "income/salary-main-contracts"
    assert_not_includes slugs, Category::UNCATEGORISED_SLUG
    assert slugs.all? { |slug| slug.include?("/") }, "categories only, never a group"
    assert_equal slugs.first, "groceries/groceries"
  end

  test "the payload carries what the prompt needs and nothing else" do
    payload = Categories::ItemCandidates.payload

    assert_equal %i[slug name description group], payload.first.keys
    assert_equal({ slug: "groceries/groceries", name: "Groceries", description: categories(:groceries).description.to_s,
      group: "Groceries" }, payload.first)
  end

  test "the taxonomy gives 37 candidates of its 39 categories" do
    taxonomy = YAML.safe_load_file(Categories::TaxonomyLoader::DEFAULT_PATH).fetch("taxonomy")
    kept = taxonomy.reject { |entry| Categories::ItemCandidates::EXCLUDED_GROUP_SLUGS.include?(Category.slug_part(entry["group"])) }

    assert_equal 39, taxonomy.sum { |entry| entry["categories"].size }
    assert_equal 37, kept.sum { |entry| entry["categories"].size }
  end
end
