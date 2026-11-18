source "https://rubygems.org"

ruby file: ".ruby-version"

gem "rails", "~> 8.1.4", ">= 8.1.4.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.7"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Tailwind CSS v4 built by the bundled standalone CLI, no Node needed [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Slim templates [https://github.com/slim-template/slim-rails]
gem "slim-rails"
# Lucide icons as inline SVG helpers [https://github.com/heyvito/lucide-rails]
gem "lucide-rails"
# Merge conflicting Tailwind utilities when callers override component classes
gem "tailwind_merge"

# Redis backs the cache store, Action Cable and Sidekiq
gem "redis", ">= 5.0"
# Background jobs for Active Job [https://sidekiq.org]
gem "sidekiq", "~> 8.1"

# Password hashing for has_secure_password (the owner's sign-in)
gem "bcrypt", "~> 3.1"

# Load .env* files into ENV (.env.example lists the settings)
gem "dotenv"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.2"
# libvips bindings for image analysis and variants; image_processing 2.x no longer depends on it.
# Needs the libvips library (Homebrew `vips`; the CI workflow installs `libvips`).
gem "ruby-vips", "~> 2.3"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # Slim template linting [https://github.com/sds/slim-lint]
  gem "slim_lint", require: false

  # Process manager used by bin/dev
  gem "foreman", require: false
end

group :test do
  # Stubs HTTP in tests so no test ever reaches a real service [https://github.com/bblimke/webmock]
  gem "webmock"

  # Line coverage report and the minimum gate (see test/test_helper.rb)
  gem "simplecov", require: false

  # Checks API requests and responses against docs/openapi.yaml [https://github.com/interagent/committee]
  gem "committee", "~> 5.6"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end
