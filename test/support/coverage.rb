# Line coverage with SimpleCov, and a minimum the full test suite must reach.
#
# Loaded by test/test_helper.rb before the app, so every app file is measured from its first line.
#
# Parallel tests: Rails forks one worker process per CPU when a run has enough tests. Each worker
# saves its own result under its own name (see parallelize_setup / parallelize_teardown in
# test/test_helper.rb). When the main process exits, SimpleCov merges those results with its own, writes
# one report to coverage/ and checks the minimum once, on the merged result.
#
# Partial runs: the minimum is only checked when the run is a full one, meaning that every test file was
# loaded and no test was filtered by name. Running one file (bin/rails test test/foo_test.rb) prints the
# coverage figure but never fails because of it.
require "minitest"
require "simplecov"
require "set"

module CoverageGate
  MINIMUM_LINE_COVERAGE = 80
  ROOT = File.expand_path("../..", __dir__)
  # The same files `bin/rails test` picks when it gets no arguments.
  TEST_FILES = "test/**/*_test.rb"
  SKIPPED_TEST_FILES = "test/{system,dummy,fixtures}/**/*_test.rb"

  class << self
    attr_accessor :filtered

    # Minitest calls this with the parsed command-line options (registered below).
    def minitest_plugin_init(options)
      self.filtered = options[:include] || options[:exclude] ? true : false
    end

    def full_run?
      return false if filtered

      loaded = $LOADED_FEATURES.to_set
      test_files.all? { |path| loaded.include?(path) || loaded.include?(File.realpath(path)) }
    end

    def test_files
      Dir.glob(TEST_FILES, base: ROOT).difference(Dir.glob(SKIPPED_TEST_FILES, base: ROOT))
        .map { |path| File.join(ROOT, path) }
    end
  end
end

Minitest.register_plugin(CoverageGate)

SimpleCov.start "rails" do
  # Runs in the main process only, after the tests and after the workers saved their results.
  at_exit do
    if CoverageGate.full_run?
      SimpleCov.minimum_coverage line: CoverageGate::MINIMUM_LINE_COVERAGE
    else
      puts "Coverage minimum (#{CoverageGate::MINIMUM_LINE_COVERAGE}%) not checked: this is not a full test run."
    end
    SimpleCov.result.format!
  end
end

# Every run starts from an empty result set, so results of an earlier run are never merged in.
FileUtils.rm_f(SimpleCov::ResultMerger.resultset_path)
