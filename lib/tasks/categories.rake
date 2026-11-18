# Writes the item categoriser's candidate categories (Categories::ItemCandidates) to FILE as JSON, the list the
# app sends the ML service with every request, for the offline runs of ml/evaluation/. The taxonomy holds no
# personal data; the file may go anywhere.
namespace :categories do
  desc "Write the receipt-item candidate categories to FILE as JSON (for ml/evaluation/item_categories_run)"
  task :export_items, [ :file ] => :environment do |_task, args|
    abort "Usage: bin/rails \"categories:export_items[FILE]\"" if args[:file].blank?

    payload = Categories::ItemCandidates.payload
    File.write(args[:file], JSON.pretty_generate({ categories: payload }) + "\n")
    puts "Item categories: #{payload.size} written"
  end
end
