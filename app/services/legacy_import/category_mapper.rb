module LegacyImport
  # Finds the taxonomy category for each old category. The importer never creates a category.
  #
  # An old category maps to the category whose group name is `group_en` and whose own name is `category_en`
  # (names compared exactly, after the same whitespace squish the Category model applies). When either value
  # is null the old category is unmapped; when the pair is not in the taxonomy, it is "not in taxonomy" and
  # a warning lists the old ids. Both go to Category.uncategorised. A line always keeps the old category's
  # `legacy_path`, mapped or not, so the detail of several old categories folded into one is never lost.
  class CategoryMapper
    # What a line gets: the category (nil for no category), the old path, and how it was found.
    Choice = Data.define(:category, :legacy_path, :outcome)
    NO_CATEGORY = Choice.new(category: nil, legacy_path: nil, outcome: :no_category)

    def initialize(rows, report)
      @report = report
      @uncategorised = Category.uncategorised
      @rows = rows.index_by(&:legacy_id)
      taxonomy = Category.leaves.includes(:parent).index_by { |category| [ category.parent.name, category.name ] }
      @choices = rows.to_h { |row| [ row.legacy_id, choice(row, taxonomy) ] }
      warn_not_in_taxonomy(rows)
    rescue ActiveRecord::RecordNotFound
      raise Error, "the Uncategorised category is missing: load the taxonomy first (bin/rails db:seed)"
    end

    # The Choice for a line's category_legacy_id (nil means the line had no category).
    def for(category_legacy_id)
      category_legacy_id.nil? ? NO_CATEGORY : @choices.fetch(category_legacy_id)
    end

    # The export row of an old category, or nil (for a line's digest, see RowDigest).
    def row(category_legacy_id)
      category_legacy_id && @rows.fetch(category_legacy_id)
    end

    def uncategorised?(category)
      category.nil? || category == @uncategorised
    end

    private
      def choice(row, taxonomy)
        if row.group_en.nil? || row.category_en.nil?
          Choice.new(category: @uncategorised, legacy_path: row.legacy_path, outcome: :unmapped)
        elsif (category = taxonomy[[ row.group_en.squish, row.category_en.squish ]])
          Choice.new(category:, legacy_path: row.legacy_path, outcome: :mapped)
        else
          Choice.new(category: @uncategorised, legacy_path: row.legacy_path, outcome: :not_in_taxonomy)
        end
      end

      def warn_not_in_taxonomy(rows)
        ids = rows.select { |row| @choices[row.legacy_id].outcome == :not_in_taxonomy }.map(&:legacy_id)
        return if ids.empty?

        shown = ids.first(20).map { |id| Values.printable_id(id) }.join(", ")
        shown += ", ..." if ids.size > 20
        @report.warn("#{ids.size} old #{'category'.pluralize(ids.size)} name a group and category that are not in " \
          "the taxonomy; their lines went to Uncategorised (legacy_ids #{shown})")
      end
  end
end
