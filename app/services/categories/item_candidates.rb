module Categories
  # The categories a receipt item may be suggested: every category of the taxonomy except the two that are not
  # spending (Uncategorised, which means "not categorised yet", and Adjustments, which is neither spending nor
  # income). 37 of the 39 today. The ML service gets them with every request, with names and descriptions, and
  # its answer may only name their slugs (docs/decisions/0015-item-categoriser.md); the label memory suggests
  # only them too.
  #
  #   Categories::ItemCandidates.all      # => [Category, ...] in taxonomy order (group, then category)
  #   Categories::ItemCandidates.payload  # => [{ slug:, name:, description:, group: }, ...]
  module ItemCandidates
    EXCLUDED_GROUP_SLUGS = %w[uncategorised adjustments].freeze

    module_function

    def all
      Category.leaves.includes(:parent).reject { |category| EXCLUDED_GROUP_SLUGS.include?(category.parent.slug) }
        .sort_by { |category| [ category.parent.position, category.parent.name, category.position, category.name ] }
    end

    def payload(categories = all)
      categories.map do |category|
        { slug: category.slug, name: category.name, description: category.description.to_s, group: category.parent.name }
      end
    end
  end
end
