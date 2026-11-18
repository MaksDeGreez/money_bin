module Categories
  # The categories a transaction line may be suggested: every category of the taxonomy except Uncategorised, which
  # means "not categorised yet". The transaction categoriser was trained on the history's categories, which can
  # include Adjustments, so those stay. The ML service gets the list with every request and matches its model's
  # classes to it by group and category name; a class the list lacks is refused there, so a category the app does
  # not know can never come back (docs/decisions/0006-transaction-categoriser.md, "Serving").
  #
  #   Categories::TransactionCandidates.payload  # => [{ slug:, name:, description:, group: }, ...]
  module TransactionCandidates
    EXCLUDED_GROUP_SLUGS = %w[uncategorised].freeze

    module_function

    def all
      Category.leaves.includes(:parent).reject { |category| EXCLUDED_GROUP_SLUGS.include?(category.parent.slug) }
        .sort_by { |category| [ category.parent.position, category.parent.name, category.position, category.name ] }
    end

    def payload(categories = all)
      ItemCandidates.payload(categories)
    end
  end
end
