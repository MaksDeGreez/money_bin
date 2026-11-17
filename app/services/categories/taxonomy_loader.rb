module Categories
  # Loads the category taxonomy (db/seeds/taxonomy.yml) into the categories table. db/seeds.rb calls it.
  #
  # Idempotent: groups and categories are found by name (a category inside its group), created when missing
  # and otherwise updated in place (position and description). Running it twice changes nothing. It never
  # deletes a category that the file no longer lists, because transaction lines may point at it, and it
  # never touches a slug that already exists.
  class TaxonomyLoader
    DEFAULT_PATH = Rails.root.join("db/seeds/taxonomy.yml")

    # Counts of what the run saw and did.
    Result = Data.define(:groups, :categories, :created, :updated)

    def self.call(path = DEFAULT_PATH)
      new(path).call
    end

    def initialize(path = DEFAULT_PATH)
      @path = path
    end

    def call
      @created = @updated = 0
      groups = categories = 0

      Category.transaction do
        taxonomy.each.with_index(1) do |entry, group_position|
          group = upsert(parent: nil, name: entry.fetch("group"), position: group_position, description: entry["description"])
          groups += 1

          entry.fetch("categories").each.with_index(1) do |item, position|
            upsert(parent: group, name: item.fetch("name"), position:, description: item["description"])
            categories += 1
          end
        end
      end

      Result.new(groups:, categories:, created: @created, updated: @updated)
    end

    private
      def taxonomy
        YAML.safe_load_file(@path).fetch("taxonomy")
      end

      def upsert(parent:, name:, position:, description:)
        category = Category.find_or_initialize_by(parent:, name:)
        category.assign_attributes(position:, description:)
        return category unless category.changed?

        category.new_record? ? @created += 1 : @updated += 1
        category.save!
        category
      end
  end
end
