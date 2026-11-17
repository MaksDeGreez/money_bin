# Records every environment needs (development, test, production). Safe to run any number of times:
# `bin/rails db:seed` twice gives the same data as running it once.

# The category taxonomy (groups and categories), from db/seeds/taxonomy.yml.
result = Categories::TaxonomyLoader.call
puts "Taxonomy: #{result.groups} groups, #{result.categories} categories " \
  "(#{result.created} created, #{result.updated} updated)" unless Rails.env.test?
