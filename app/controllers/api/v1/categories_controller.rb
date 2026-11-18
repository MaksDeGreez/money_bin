module Api
  module V1
    # GET /api/v1/categories: the category tree, groups with their categories (CategoryTreeQuery).
    class CategoriesController < BaseController
      def index
        only_known_parameters
        render json: { groups: CategoryTreeQuery.new.call.map { |node| CategorySerializer.tree_node(node) } }
      end
    end
  end
end
