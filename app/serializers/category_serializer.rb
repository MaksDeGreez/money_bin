# The JSON of categories: a short reference (on lines, items and summaries) and the tree.
module CategorySerializer
  module_function

  # { id, slug, name }, or nil for "no category".
  def reference(category)
    return nil if category.nil?

    { id: category.id, slug: category.slug, name: category.name }
  end

  # One CategoryTreeQuery::Node: the group and its categories.
  def tree_node(node)
    full(node.group).merge(categories: node.categories.map { |category| full(category) })
  end

  def full(category)
    reference(category).merge(position: category.position, description: category.description)
  end
end
