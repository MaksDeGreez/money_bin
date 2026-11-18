# The category tree: every group with its categories, each level in its `position` order (then name).
# One query.
class CategoryTreeQuery
  Node = Data.define(:group, :categories)

  def call
    all = Category.ordered.to_a
    children = all.reject(&:group?).group_by(&:parent_id)
    all.select(&:group?).map { |group| Node.new(group:, categories: children.fetch(group.id, [])) }
  end
end
