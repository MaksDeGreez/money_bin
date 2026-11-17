# Run using bin/ci (or bin/ci --summary for one line per step).

# The Python steps need uv and each project's pyproject.toml: the ML service in ml/ and the receipt ingest
# tool in tools/receipt_ingest/. The label is what the step names show.
uv_missing = !system("command -v uv > /dev/null 2>&1")
python_projects = { "Python" => "ml", "Receipt ingest" => "tools/receipt_ingest" }

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"
  step "Style: Slim", "bin/slim-lint app/views"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  # Forbidden terms from ~/Documents/money_bin_data/leak_terms.txt; warns and passes without that file.
  step "Security: Leak check (tracked files)", "bin/leak-check --tree"

  step "Assets: Tailwind build", "bin/rails tailwindcss:build"
  step "Tests: Rails", "bin/rails test"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  python_projects.each do |label, dir|
    missing = [
      ("#{dir}/pyproject.toml" unless File.exist?(File.expand_path("../#{dir}/pyproject.toml", __dir__))),
      ("uv" if uv_missing)
    ].compact

    if missing.empty?
      step "Style: #{label} (ruff check)", "cd #{dir} && uv run ruff check"
      step "Style: #{label} (ruff format)", "cd #{dir} && uv run ruff format --check"
      step "Tests: #{label} (pytest)", "cd #{dir} && uv run pytest"
    else
      step "#{label}: skipped, missing #{missing.join(' and ')}", "true"
    end
  end
end
