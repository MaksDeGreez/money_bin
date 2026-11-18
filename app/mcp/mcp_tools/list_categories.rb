module McpTools
  # list_categories: CategoryTreeQuery, as GET /api/v1/categories.
  class ListCategories < Base
    tool_name "list_categories"
    title "List categories"
    description <<~TEXT.squish
      The category tree: every group with its categories, each with its id, slug, name and a description of
      what belongs there. Transaction lines and receipt items point at categories; a group only collects its
      categories. Slugs are stable keys: a group's slug is one word ("groceries"), a category's is
      "<group slug>/<category part>" ("groceries/groceries"). Use a slug (or id) as the category argument of
      search_transactions, and to find a category or group in spending_summary.
    TEXT
    input_schema(type: "object", properties: {}, additionalProperties: false)
    output_schema OutputSchema.of("CategoryTree")
    annotations(**ANNOTATIONS, title: "List categories")

    class << self
      private
        def answer
          json = { groups: CategoryTreeQuery.new.call.map { |node| CategorySerializer.tree_node(node) } }

          [ text(json), json ]
        end

        def text(json)
          lines = [ "Groups and their categories (slug: name - description):" ]
          json[:groups].each do |group|
            lines << line(group, "")
            group[:categories].each { |category| lines << line(category, "  ") }
          end
          lines.join("\n")
        end

        def line(category, indent)
          "#{indent}#{category[:slug]}: #{category[:name]}#{" - #{category[:description]}" if category[:description]} (id #{category[:id]})"
        end
    end
  end
end
