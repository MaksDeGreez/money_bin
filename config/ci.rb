# Run using bin/ci (or bin/ci --summary for one line per step).

# The Python steps need the ML service project (ml/pyproject.toml) and uv.
python_missing = [
  ("ml/pyproject.toml" unless File.exist?(File.expand_path("../ml/pyproject.toml", __dir__))),
  ("uv" unless system("command -v uv > /dev/null 2>&1"))
].compact

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"
  step "Style: Slim", "bin/slim-lint app/views"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Assets: Tailwind build", "bin/rails tailwindcss:build"
  step "Tests: Rails", "bin/rails test"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  if python_missing.empty?
    step "Style: Python (ruff check)", "cd ml && uv run ruff check"
    step "Style: Python (ruff format)", "cd ml && uv run ruff format --check"
    step "Tests: Python (pytest)", "cd ml && uv run pytest"
  else
    step "Python: skipped, missing #{python_missing.join(' and ')}", "true"
  end
end
